const std = @import("std");

const bridge = @cImport({
    @cInclude("core_simulator_bridge.h");
});

pub const Connection = struct {
    handle: *bridge.SimutexCoreSimulatorConnection,

    pub fn init() !Connection {
        var error_message: [*c]u8 = null;
        const handle = bridge.simutex_core_simulator_connection_create(&error_message) orelse {
            defer if (error_message != null) bridge.simutex_core_simulator_string_free(error_message);
            if (error_message != null) {
                std.log.debug("CoreSimulator connection failed: {s}", .{std.mem.span(error_message)});
            }
            return error.CoreSimulatorUnavailable;
        };
        if (error_message != null) bridge.simutex_core_simulator_string_free(error_message);
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Connection) void {
        bridge.simutex_core_simulator_connection_destroy(self.handle);
        self.* = undefined;
    }

    pub fn eventFd(self: Connection) std.posix.fd_t {
        return bridge.simutex_core_simulator_connection_event_fd(self.handle);
    }

    pub fn drainEvents(self: Connection) void {
        bridge.simutex_core_simulator_connection_drain_events(self.handle);
    }

    pub fn snapshotJson(
        self: Connection,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        var error_message: [*c]u8 = null;
        const json = bridge.simutex_core_simulator_connection_copy_inventory_json(
            self.handle,
            &error_message,
        ) orelse {
            defer if (error_message != null) bridge.simutex_core_simulator_string_free(error_message);
            if (error_message != null) {
                std.log.debug("CoreSimulator snapshot failed: {s}", .{std.mem.span(error_message)});
            }
            return error.CoreSimulatorFailed;
        };
        defer bridge.simutex_core_simulator_string_free(json);
        if (error_message != null) bridge.simutex_core_simulator_string_free(error_message);
        return allocator.dupe(u8, std.mem.span(json));
    }
};
