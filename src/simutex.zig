const std = @import("std");
const Io = std.Io;

pub const agent_init = @import("agent_init.zig");
pub const CoreSimulator = @import("core_simulator.zig");

test {
    _ = agent_init;
    _ = CoreSimulator;
}

pub const Device = struct {
    name: []const u8,
    udid: []const u8,
    state: []const u8,
};

pub const Inventory = struct {
    parsed: std.json.Parsed(std.json.Value),
    devices: []Device,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Inventory) void {
        self.allocator.free(self.devices);
        self.parsed.deinit();
        self.* = undefined;
    }
};

pub const Claim = union(enum) {
    acquired,
    already_owned,
    locked_by: []u8,

    pub fn deinit(self: Claim, allocator: std.mem.Allocator) void {
        switch (self) {
            .locked_by => |owner| allocator.free(owner),
            else => {},
        }
    }
};

pub const Release = union(enum) {
    released,
    not_locked,
    owned_by: []u8,

    pub fn deinit(self: Release, allocator: std.mem.Allocator) void {
        switch (self) {
            .owned_by => |owner| allocator.free(owner),
            else => {},
        }
    }
};

pub fn discover(allocator: std.mem.Allocator, io: Io) !Inventory {
    var connection = CoreSimulator.Connection.init() catch {
        return discoverViaSimctl(allocator, io);
    };
    defer connection.deinit();

    return discoverWithConnection(allocator, connection) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return discoverViaSimctl(allocator, io),
    };
}

pub fn discoverWithConnection(
    allocator: std.mem.Allocator,
    connection: CoreSimulator.Connection,
) !Inventory {
    const json = try connection.snapshotJson(allocator);
    defer allocator.free(json);
    return parseInventory(allocator, json);
}

pub fn discoverViaSimctl(allocator: std.mem.Allocator, io: Io) !Inventory {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "xcrun", "simctl", "list", "devices", "available", "--json" },
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.SimctlFailed,
        else => return error.SimctlFailed,
    }
    return parseInventory(allocator, result.stdout);
}

pub fn parseInventory(allocator: std.mem.Allocator, json: []const u8) !Inventory {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    errdefer parsed.deinit();

    var devices: std.ArrayList(Device) = .empty;
    defer devices.deinit(allocator);

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidSimctlOutput,
    };
    const runtimes_value = root.get("devices") orelse return error.InvalidSimctlOutput;
    const runtimes = switch (runtimes_value) {
        .object => |object| object,
        else => return error.InvalidSimctlOutput,
    };

    var runtime_iterator = runtimes.iterator();
    while (runtime_iterator.next()) |runtime| {
        if (std.mem.indexOf(u8, runtime.key_ptr.*, ".iOS-") == null) continue;
        const runtime_devices = switch (runtime.value_ptr.*) {
            .array => |array| array,
            else => continue,
        };
        for (runtime_devices.items) |value| {
            const object = switch (value) {
                .object => |item| item,
                else => continue,
            };
            if (!jsonBool(object.get("isAvailable")) or
                jsonString(object.get("name")) == null or
                jsonString(object.get("udid")) == null or
                jsonString(object.get("state")) == null)
            {
                continue;
            }
            try devices.append(allocator, .{
                .name = jsonString(object.get("name")).?,
                .udid = jsonString(object.get("udid")).?,
                .state = jsonString(object.get("state")).?,
            });
        }
    }

    return .{
        .parsed = parsed,
        .devices = try devices.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |string| string,
        else => null,
    };
}

fn jsonBool(value: ?std.json.Value) bool {
    const present = value orelse return false;
    return switch (present) {
        .bool => |boolean| boolean,
        else => false,
    };
}

pub fn openStateDir(io: Io, path: []const u8) !Io.Dir {
    return Io.Dir.cwd().createDirPathOpen(io, path, .{
        .open_options = .{ .iterate = true },
    });
}

pub fn claim(
    allocator: std.mem.Allocator,
    io: Io,
    state_dir: Io.Dir,
    udid: []const u8,
    owner: []const u8,
) !Claim {
    try validateUdid(udid);
    try validateOwner(owner);
    const lock_name = try lockName(allocator, udid);
    defer allocator.free(lock_name);

    state_dir.symLink(io, owner, lock_name, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {
            const current_owner = (try readOwner(allocator, io, state_dir, udid)) orelse
                return error.InvalidLock;
            if (std.mem.eql(u8, current_owner, owner)) {
                allocator.free(current_owner);
                return .already_owned;
            }
            return .{ .locked_by = current_owner };
        },
        else => |other| return other,
    };
    return .acquired;
}

pub fn release(
    allocator: std.mem.Allocator,
    io: Io,
    state_dir: Io.Dir,
    udid: []const u8,
    owner: []const u8,
) !Release {
    try validateUdid(udid);
    try validateOwner(owner);
    const current_owner = (try readOwner(allocator, io, state_dir, udid)) orelse return .not_locked;
    defer allocator.free(current_owner);
    if (!std.mem.eql(u8, current_owner, owner)) {
        return .{ .owned_by = try allocator.dupe(u8, current_owner) };
    }

    const lock_name = try lockName(allocator, udid);
    defer allocator.free(lock_name);
    state_dir.deleteFile(io, lock_name) catch |err| switch (err) {
        error.FileNotFound => return .not_locked,
        else => |other| return other,
    };
    return .released;
}

pub fn forceRelease(
    allocator: std.mem.Allocator,
    io: Io,
    state_dir: Io.Dir,
    udid: []const u8,
) !bool {
    const lock_name = try lockName(allocator, udid);
    defer allocator.free(lock_name);
    state_dir.deleteFile(io, lock_name) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |other| return other,
    };
    return true;
}

pub fn readOwner(
    allocator: std.mem.Allocator,
    io: Io,
    state_dir: Io.Dir,
    udid: []const u8,
) !?[]u8 {
    try validateUdid(udid);
    const lock_name = try lockName(allocator, udid);
    defer allocator.free(lock_name);
    var owner_buffer: [256]u8 = undefined;
    const owner_length = state_dir.readLink(io, lock_name, &owner_buffer) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.NotLink => return error.InvalidLock,
        else => |other| return other,
    };
    const owner = owner_buffer[0..owner_length];
    try validateOwner(owner);
    return try allocator.dupe(u8, owner);
}

fn lockName(allocator: std.mem.Allocator, udid: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.lock", .{udid});
}

fn validateUdid(udid: []const u8) !void {
    if (udid.len == 0 or udid.len > 128 or
        std.mem.indexOfAny(u8, udid, "/\\\n\r\x00") != null)
    {
        return error.InvalidUdid;
    }
}

fn validateOwner(owner: []const u8) !void {
    if (owner.len == 0 or owner.len > 256 or
        std.mem.indexOfAny(u8, owner, "\n\r\x00") != null)
    {
        return error.InvalidOwner;
    }
}

test "inventory contains only available iOS simulators" {
    const fixture =
        \\{"devices":{
        \\  "com.apple.CoreSimulator.SimRuntime.iOS-18-5":[
        \\    {"name":"iPhone 16","udid":"IOS-1","state":"Shutdown","isAvailable":true},
        \\    {"name":"Old iPhone","udid":"IOS-2","state":"Shutdown","isAvailable":false}
        \\  ],
        \\  "com.apple.CoreSimulator.SimRuntime.tvOS-18-5":[
        \\    {"name":"Apple TV","udid":"TV-1","state":"Shutdown","isAvailable":true}
        \\  ]
        \\}}
    ;
    var inventory = try parseInventory(std.testing.allocator, fixture);
    defer inventory.deinit();

    try std.testing.expectEqual(@as(usize, 1), inventory.devices.len);
    try std.testing.expectEqualStrings("iPhone 16", inventory.devices[0].name);
    try std.testing.expectEqualStrings("IOS-1", inventory.devices[0].udid);
}

test "claim is exclusive, idempotent for its owner, and owner-only to release" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const first = try claim(allocator, io, tmp.dir, "SIM-1", "agent-a");
    defer first.deinit(allocator);
    try std.testing.expect(first == .acquired);

    const same = try claim(allocator, io, tmp.dir, "SIM-1", "agent-a");
    defer same.deinit(allocator);
    try std.testing.expect(same == .already_owned);

    const other = try claim(allocator, io, tmp.dir, "SIM-1", "agent-b");
    defer other.deinit(allocator);
    try std.testing.expectEqualStrings("agent-a", other.locked_by);

    const denied = try release(allocator, io, tmp.dir, "SIM-1", "agent-b");
    defer denied.deinit(allocator);
    try std.testing.expectEqualStrings("agent-a", denied.owned_by);

    const released = try release(allocator, io, tmp.dir, "SIM-1", "agent-a");
    defer released.deinit(allocator);
    try std.testing.expect(released == .released);
    try std.testing.expect((try readOwner(allocator, io, tmp.dir, "SIM-1")) == null);
}

test "force release clears a lock regardless of owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const acquired = try claim(allocator, io, tmp.dir, "SIM-1", "agent-a");
    defer acquired.deinit(allocator);
    try std.testing.expect(try forceRelease(allocator, io, tmp.dir, "SIM-1"));
    try std.testing.expect((try readOwner(allocator, io, tmp.dir, "SIM-1")) == null);
    try std.testing.expect(!(try forceRelease(allocator, io, tmp.dir, "SIM-1")));
}
