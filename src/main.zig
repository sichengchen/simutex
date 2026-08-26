const std = @import("std");
const Io = std.Io;
const simutex = @import("simutex");
const monitor = @import("monitor.zig");

const usage =
    \\simutex - coordinate exclusive access to local iOS simulators
    \\
    \\Usage:
    \\  simutex list
    \\  simutex monitor
    \\  simutex claim [UDID] [--owner OWNER]
    \\  simutex status UDID
    \\  simutex release UDID [--owner OWNER]
    \\  simutex reset
    \\  simutex init [--all] [--dry-run]
    \\  simutex version
    \\
    \\Set SIMUTEX_AGENT instead of passing --owner on every command.
    \\Set SIMUTEX_STATE_DIR to override the shared lock directory.
    \\
;

const Options = struct {
    positional: ?[]const u8 = null,
    owner: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    run(init) catch |err| {
        stderr.print("simutex: {s}\n", .{messageForError(err)}) catch {};
        stderr.flush() catch {};
        std.process.exit(if (err == error.InvalidArguments) 2 else 1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    if (args.len < 2 or std.mem.eql(u8, args[1], "help") or std.mem.eql(u8, args[1], "--help")) {
        try stdout.writeAll(usage);
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version")) {
        if (args.len != 2) return error.InvalidArguments;
        try stdout.writeAll("simutex 0.2.1\n");
        return;
    }
    if (std.mem.eql(u8, command, "init")) {
        return simutex.agent_init.run(
            allocator,
            init.io,
            init.environ_map,
            args[2..],
            stdout,
        );
    }

    const options = try parseOptions(args[2..]);
    const state_path = try statePath(allocator, init.environ_map);
    var state_dir = try simutex.openStateDir(init.io, state_path);
    defer state_dir.close(init.io);

    if (std.mem.eql(u8, command, "list") or std.mem.eql(u8, command, "available")) {
        if (options.positional != null or options.owner != null) return error.InvalidArguments;
        return list(allocator, init.io, state_dir, stdout);
    }
    if (std.mem.eql(u8, command, "monitor")) {
        if (options.positional != null or options.owner != null) return error.InvalidArguments;
        return monitor.run(allocator, init.io, state_dir, stdout);
    }
    if (std.mem.eql(u8, command, "reset")) {
        if (options.positional != null or options.owner != null) return error.InvalidArguments;
        return resetAll(allocator, init.io, state_dir, stdout);
    }
    if (std.mem.eql(u8, command, "claim")) {
        const owner = options.owner orelse init.environ_map.get("SIMUTEX_AGENT") orelse
            return error.OwnerRequired;
        return claimOne(allocator, init.io, state_dir, stdout, options.positional, owner);
    }
    if (std.mem.eql(u8, command, "status")) {
        if (options.positional == null or options.owner != null) return error.InvalidArguments;
        return status(allocator, init.io, state_dir, stdout, options.positional.?);
    }
    if (std.mem.eql(u8, command, "release")) {
        if (options.positional == null) return error.InvalidArguments;
        const owner = options.owner orelse init.environ_map.get("SIMUTEX_AGENT") orelse
            return error.OwnerRequired;
        return releaseOne(allocator, init.io, state_dir, stdout, options.positional.?, owner);
    }
    return error.InvalidArguments;
}

fn parseOptions(args: []const []const u8) !Options {
    var options: Options = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--owner")) {
            index += 1;
            if (index >= args.len or options.owner != null) return error.InvalidArguments;
            options.owner = args[index];
        } else if (std.mem.startsWith(u8, args[index], "-")) {
            return error.InvalidArguments;
        } else {
            if (options.positional != null) return error.InvalidArguments;
            options.positional = args[index];
        }
    }
    return options;
}

fn statePath(allocator: std.mem.Allocator, environ: *std.process.Environ.Map) ![]const u8 {
    if (environ.get("SIMUTEX_STATE_DIR")) |path| return path;
    const temp = environ.get("TMPDIR") orelse "/tmp";
    return std.fs.path.join(allocator, &.{ temp, "simutex" });
}

fn list(
    allocator: std.mem.Allocator,
    io: Io,
    state_dir: Io.Dir,
    writer: *Io.Writer,
) !void {
    var inventory = try simutex.discover(allocator, io);
    defer inventory.deinit();
    for (inventory.devices) |device| {
        if (try simutex.readOwner(allocator, io, state_dir, device.udid)) |owner| {
            defer allocator.free(owner);
            try writer.print("🔒\t{s}\t{s}\t{s}\t{s}\n", .{
                device.udid, device.state, device.name, owner,
            });
        } else {
            try writer.print("🟢\t{s}\t{s}\t{s}\n", .{
                device.udid, device.state, device.name,
            });
        }
    }
}

fn claimOne(
    allocator: std.mem.Allocator,
    io: Io,
    state_dir: Io.Dir,
    writer: *Io.Writer,
    requested_udid: ?[]const u8,
    owner: []const u8,
) !void {
    var inventory = try simutex.discover(allocator, io);
    defer inventory.deinit();

    var found_requested = false;
    for (inventory.devices) |device| {
        if (requested_udid) |udid| {
            if (!std.mem.eql(u8, udid, device.udid)) continue;
            found_requested = true;
        }

        const result = try simutex.claim(allocator, io, state_dir, device.udid, owner);
        defer result.deinit(allocator);
        switch (result) {
            .acquired, .already_owned => {
                try writer.print("{s}\n", .{device.udid});
                return;
            },
            .locked_by => |current_owner| {
                if (requested_udid != null) {
                    std.log.err("simulator {s} is locked by {s}", .{ device.udid, current_owner });
                    return error.SimulatorLocked;
                }
            },
        }
    }
    if (requested_udid != null and !found_requested) return error.SimulatorNotFound;
    return error.NoSimulatorAvailable;
}

fn status(
    allocator: std.mem.Allocator,
    io: Io,
    state_dir: Io.Dir,
    writer: *Io.Writer,
    udid: []const u8,
) !void {
    if (try simutex.readOwner(allocator, io, state_dir, udid)) |owner| {
        defer allocator.free(owner);
        try writer.print("locked\t{s}\n", .{owner});
    } else {
        try writer.writeAll("available\n");
    }
}

fn releaseOne(
    allocator: std.mem.Allocator,
    io: Io,
    state_dir: Io.Dir,
    writer: *Io.Writer,
    udid: []const u8,
    owner: []const u8,
) !void {
    const result = try simutex.release(allocator, io, state_dir, udid, owner);
    defer result.deinit(allocator);
    switch (result) {
        .released => try writer.writeAll("released\n"),
        .not_locked => try writer.writeAll("not locked\n"),
        .owned_by => |current_owner| {
            std.log.err("simulator {s} is locked by {s}", .{ udid, current_owner });
            return error.NotLockOwner;
        },
    }
}

fn resetAll(
    allocator: std.mem.Allocator,
    io: Io,
    state_dir: Io.Dir,
    writer: *Io.Writer,
) !void {
    var udids: std.ArrayList([]u8) = .empty;
    defer {
        for (udids.items) |udid| allocator.free(udid);
        udids.deinit(allocator);
    }

    var iterator = state_dir.iterate();
    while (try iterator.next(io)) |entry| {
        const suffix = ".lock";
        if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
        const udid = entry.name[0 .. entry.name.len - suffix.len];
        if (udid.len == 0) continue;
        try udids.append(allocator, try allocator.dupe(u8, udid));
    }

    var released_count: usize = 0;
    for (udids.items) |udid| {
        if (try simutex.forceRelease(allocator, io, state_dir, udid)) released_count += 1;
    }
    try writer.print("reset\t{d}\n", .{released_count});
}

fn messageForError(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidArguments => "invalid arguments (run `simutex help`)",
        error.OwnerRequired => "owner required; pass --owner or set SIMUTEX_AGENT",
        error.SimctlFailed => "xcrun simctl failed",
        error.InvalidSimctlOutput => "xcrun simctl returned unexpected JSON",
        error.SimulatorLocked => "simulator is already locked",
        error.SimulatorNotFound => "simulator was not found or is unavailable",
        error.NoSimulatorAvailable => "no unlocked iOS simulator is available",
        error.NotLockOwner => "only the lock owner can release this simulator",
        error.InvalidUdid => "invalid simulator UDID",
        error.InvalidOwner => "invalid owner",
        error.InvalidLock => "lock file is invalid",
        error.HomeRequired => "HOME is required to locate local agent skill directories",
        error.NoAgentsDetected => "no supported local agents were detected",
        error.NoAgentsSelected => "no agents were selected",
        error.InteractiveInputRequired => "interactive input is required; use `simutex init --all` for automation",
        error.TerminalRequired => "monitor requires an interactive terminal",
        error.InvalidSelection => "invalid agent selection",
        else => @errorName(err),
    };
}
