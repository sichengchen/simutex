const std = @import("std");
const Io = std.Io;
const simutex = @import("simutex");

const fallback_refresh_interval_ms = 1000;
const health_refresh_interval_ms = 30_000;
const default_columns = 80;
const default_rows = 24;

const enter_screen = "\x1b[?1049h\x1b[?25l";
const leave_screen = "\x1b[0m\x1b[?25h\x1b[?1049l";
const clear_screen = "\x1b[H\x1b[2J";

pub const Row = struct {
    name: []const u8,
    udid: []const u8,
    state: []const u8,
    owner: ?[]const u8,
};

const TerminalSize = struct {
    columns: usize,
    rows: usize,
};

const WaitResult = enum {
    refresh,
    exit,
};

const EventKind = enum(usize) {
    input = 1,
    core_simulator = 2,
    lock_directory = 3,
    terminal_resize = 4,
};

const EventWaiter = struct {
    kqueue_fd: std.posix.fd_t,
    has_core_simulator: bool,

    fn init(state_dir_fd: std.posix.fd_t, core_simulator_fd: ?std.posix.fd_t) !EventWaiter {
        const kqueue_fd = std.c.kqueue();
        switch (std.posix.errno(kqueue_fd)) {
            .SUCCESS => {},
            .MFILE, .NFILE => return error.SystemResources,
            else => |err| return std.posix.unexpectedErrno(err),
        }
        errdefer _ = std.posix.system.close(kqueue_fd);

        var changes: [4]std.posix.Kevent = undefined;
        var change_count: usize = 0;
        const flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.CLEAR;

        changes[change_count] = .{
            .ident = std.posix.STDIN_FILENO,
            .filter = std.c.EVFILT.READ,
            .flags = flags,
            .fflags = 0,
            .data = 0,
            .udata = @intFromEnum(EventKind.input),
        };
        change_count += 1;

        if (core_simulator_fd) |fd| {
            changes[change_count] = .{
                .ident = @intCast(fd),
                .filter = std.c.EVFILT.READ,
                .flags = flags,
                .fflags = 0,
                .data = 0,
                .udata = @intFromEnum(EventKind.core_simulator),
            };
            change_count += 1;
        }

        changes[change_count] = .{
            .ident = @bitCast(@as(isize, state_dir_fd)),
            .filter = std.c.EVFILT.VNODE,
            .flags = flags,
            .fflags = std.c.NOTE.DELETE | std.c.NOTE.WRITE | std.c.NOTE.RENAME | std.c.NOTE.REVOKE,
            .data = 0,
            .udata = @intFromEnum(EventKind.lock_directory),
        };
        change_count += 1;

        changes[change_count] = .{
            .ident = @intFromEnum(std.c.SIG.WINCH),
            .filter = std.c.EVFILT.SIGNAL,
            .flags = flags,
            .fflags = 0,
            .data = 0,
            .udata = @intFromEnum(EventKind.terminal_resize),
        };
        change_count += 1;

        _ = try std.Io.Kqueue.kevent(kqueue_fd, changes[0..change_count], &.{}, null);
        return .{
            .kqueue_fd = kqueue_fd,
            .has_core_simulator = core_simulator_fd != null,
        };
    }

    fn deinit(self: *EventWaiter) void {
        _ = std.posix.system.close(self.kqueue_fd);
        self.* = undefined;
    }

    fn wait(
        self: EventWaiter,
        connection: ?simutex.CoreSimulator.Connection,
    ) !WaitResult {
        const timeout_ms: i32 = if (self.has_core_simulator)
            health_refresh_interval_ms
        else
            fallback_refresh_interval_ms;
        var timeout: std.posix.timespec = .{
            .sec = @divTrunc(timeout_ms, 1000),
            .nsec = @rem(timeout_ms, 1000) * std.time.ns_per_ms,
        };
        var events: [4]std.posix.Kevent = undefined;

        while (true) {
            const event_count = try std.Io.Kqueue.kevent(
                self.kqueue_fd,
                &.{},
                &events,
                &timeout,
            );
            if (event_count == 0) return .refresh;

            var should_refresh = false;
            for (events[0..event_count]) |event| {
                switch (@as(EventKind, @enumFromInt(event.udata))) {
                    .input => if (try readExitInput()) return .exit,
                    .core_simulator => {
                        if (connection) |core_simulator| core_simulator.drainEvents();
                        should_refresh = true;
                    },
                    .lock_directory, .terminal_resize => should_refresh = true,
                }
            }
            if (should_refresh) return .refresh;
        }
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    state_dir: Io.Dir,
    writer: *Io.Writer,
) !void {
    if (!try Io.File.stdin().isTty(io) or !try Io.File.stdout().isTty(io)) {
        return error.TerminalRequired;
    }

    const original_termios = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
    var raw_termios = original_termios;
    raw_termios.lflag.ECHO = false;
    raw_termios.lflag.ICANON = false;
    raw_termios.lflag.ISIG = false;
    raw_termios.lflag.IEXTEN = false;
    raw_termios.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw_termios.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw_termios);
    defer std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, original_termios) catch {};

    try writer.writeAll(enter_screen);
    try writer.flush();
    defer {
        writer.writeAll(leave_screen) catch {};
        writer.flush() catch {};
    }

    var previous_frame: ?[]u8 = null;
    defer if (previous_frame) |frame| allocator.free(frame);

    var connection: ?simutex.CoreSimulator.Connection =
        simutex.CoreSimulator.Connection.init() catch null;
    defer if (connection) |*core_simulator| core_simulator.deinit();

    var events = try EventWaiter.init(
        state_dir.handle,
        if (connection) |core_simulator| core_simulator.eventFd() else null,
    );
    defer events.deinit();

    while (true) {
        var frame: Io.Writer.Allocating = .init(allocator);
        defer frame.deinit();

        refresh(allocator, io, state_dir, connection, &frame.writer) catch |err| {
            try renderError(&frame.writer, terminalSize(io), err);
        };
        if (try presentIfChanged(allocator, writer, &previous_frame, frame.written())) {
            try writer.flush();
        }

        if (try events.wait(connection) == .exit) return;
    }
}

fn presentIfChanged(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    previous_frame: *?[]u8,
    frame: []const u8,
) !bool {
    if (previous_frame.*) |previous| {
        if (std.mem.eql(u8, previous, frame)) return false;
    }

    const saved_frame = try allocator.dupe(u8, frame);
    errdefer allocator.free(saved_frame);
    try writer.writeAll(frame);

    if (previous_frame.*) |previous| allocator.free(previous);
    previous_frame.* = saved_frame;
    return true;
}

fn refresh(
    allocator: std.mem.Allocator,
    io: Io,
    state_dir: Io.Dir,
    connection: ?simutex.CoreSimulator.Connection,
    writer: *Io.Writer,
) !void {
    var inventory = if (connection) |core_simulator|
        try simutex.discoverWithConnection(allocator, core_simulator)
    else
        try simutex.discoverViaSimctl(allocator, io);
    defer inventory.deinit();

    var rows: std.ArrayList(Row) = .empty;
    defer {
        for (rows.items) |row| if (row.owner) |owner| allocator.free(owner);
        rows.deinit(allocator);
    }

    for (inventory.devices) |device| {
        try rows.append(allocator, .{
            .name = device.name,
            .udid = device.udid,
            .state = device.state,
            .owner = try simutex.readOwner(allocator, io, state_dir, device.udid),
        });
    }

    try render(writer, terminalSize(io), rows.items);
}

fn terminalSize(io: Io) TerminalSize {
    var size: std.posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    const result = (io.operate(.{ .device_io_control = .{
        .file = .stdout(),
        .code = std.posix.T.IOCGWINSZ,
        .arg = &size,
    } }) catch return .{ .columns = default_columns, .rows = default_rows }).device_io_control;

    if (result < 0 or size.col == 0 or size.row == 0) {
        return .{ .columns = default_columns, .rows = default_rows };
    }
    return .{ .columns = size.col, .rows = size.row };
}

fn readExitInput() !bool {
    var input: [32]u8 = undefined;
    const length = try std.posix.read(std.posix.STDIN_FILENO, &input);
    for (input[0..length]) |byte| {
        if (byte == 'q' or byte == 'Q' or byte == 3) return true;
    }
    return false;
}

fn render(writer: *Io.Writer, size: TerminalSize, rows: []const Row) !void {
    var available_count: usize = 0;
    for (rows) |row| if (row.owner == null) {
        available_count += 1;
    };

    try writer.writeAll(clear_screen);
    try writer.writeAll("\x1b[1msimutex monitor\x1b[0m");
    try endLine(writer);
    try writer.print("{d} simulators  \x1b[32m{d} available\x1b[0m  \x1b[33m{d} claimed\x1b[0m", .{
        rows.len,
        available_count,
        rows.len - available_count,
    });
    try endLine(writer);
    try endLine(writer);

    // Header, summary, table heading, overflow marker, spacer, and footer.
    const reserved_rows = 7;
    const visible_count = @min(rows.len, size.rows -| reserved_rows);
    if (size.columns >= 100) {
        try renderWide(writer, size.columns, rows[0..visible_count]);
    } else if (size.columns >= 60) {
        try renderMedium(writer, size.columns, rows[0..visible_count]);
    } else {
        try renderNarrow(writer, size.columns, rows[0..visible_count]);
    }

    if (visible_count < rows.len) {
        try writer.print("… {d} more", .{rows.len - visible_count});
        try endLine(writer);
    }
    try endLine(writer);
    try writer.writeAll("\x1b[2mPress q or Ctrl-C to exit · updates on change\x1b[0m");
}

fn renderWide(writer: *Io.Writer, columns: usize, rows: []const Row) !void {
    const name_width = @max(@as(usize, 18), columns -| 78);
    try writeCell(writer, "LOCK", 10);
    try writeCell(writer, "SIMULATOR", name_width);
    try writeCell(writer, "STATE", 11);
    try writeCell(writer, "OWNER", 18);
    try writer.writeAll("UDID");
    try endLine(writer);

    for (rows) |row| {
        try writeStatus(writer, row.owner != null, 10);
        try writeCell(writer, row.name, name_width);
        try writeCell(writer, row.state, 11);
        try writeCell(writer, row.owner orelse "—", 18);
        try writeClipped(writer, row.udid, 36);
        try endLine(writer);
    }
}

fn renderMedium(writer: *Io.Writer, columns: usize, rows: []const Row) !void {
    const name_width = @max(@as(usize, 18), columns -| 42);
    try writeCell(writer, "LOCK", 10);
    try writeCell(writer, "SIMULATOR", name_width);
    try writeCell(writer, "STATE", 11);
    try writer.writeAll("OWNER");
    try endLine(writer);

    for (rows) |row| {
        try writeStatus(writer, row.owner != null, 10);
        try writeCell(writer, row.name, name_width);
        try writeCell(writer, row.state, 11);
        try writeClipped(writer, row.owner orelse "—", 18);
        try endLine(writer);
    }
}

fn renderNarrow(writer: *Io.Writer, columns: usize, rows: []const Row) !void {
    try writer.writeAll("STATUS     SIMULATOR");
    try endLine(writer);
    for (rows) |row| {
        try writeStatus(writer, row.owner != null, 10);
        try writeClipped(writer, row.name, columns -| 10);
        try endLine(writer);
    }
}

fn renderError(writer: *Io.Writer, size: TerminalSize, err: anyerror) !void {
    try writer.writeAll(clear_screen);
    try writer.writeAll("\x1b[1msimutex monitor\x1b[0m");
    try endLine(writer);
    try endLine(writer);
    try writer.writeAll("\x1b[31mUnable to refresh simulator status: \x1b[0m");
    try writeClipped(writer, @errorName(err), size.columns -| 36);
    try endLine(writer);
    try endLine(writer);
    try writer.writeAll("\x1b[2mRetrying · press q or Ctrl-C to exit\x1b[0m");
}

fn writeStatus(writer: *Io.Writer, claimed: bool, width: usize) !void {
    if (claimed) {
        try writer.writeAll("\x1b[33mCLAIMED\x1b[0m");
        try writePadding(writer, width -| "CLAIMED".len);
    } else {
        try writer.writeAll("\x1b[32mAVAILABLE\x1b[0m");
        try writePadding(writer, width -| "AVAILABLE".len);
    }
}

fn writeCell(writer: *Io.Writer, value: []const u8, width: usize) !void {
    const length = @min(value.len, width -| 1);
    try writer.writeAll(value[0..length]);
    try writePadding(writer, width - length);
}

fn writeClipped(writer: *Io.Writer, value: []const u8, width: usize) !void {
    try writer.writeAll(value[0..@min(value.len, width)]);
}

fn writePadding(writer: *Io.Writer, count: usize) !void {
    for (0..count) |_| try writer.writeByte(' ');
}

fn endLine(writer: *Io.Writer) !void {
    try writer.writeAll("\x1b[0K\r\n");
}

test "render includes summary and lock ownership" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const rows = [_]Row{
        .{ .name = "iPhone 16", .udid = "SIM-1", .state = "Booted", .owner = "agent-a" },
        .{ .name = "iPhone 16 Pro", .udid = "SIM-2", .state = "Shutdown", .owner = null },
    };
    try render(&output.writer, .{ .columns = 120, .rows = 24 }, &rows);

    const result = output.written();
    try std.testing.expect(std.mem.indexOf(u8, result, "2 simulators") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "1 available") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "1 claimed") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "agent-a") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "SIM-2") != null);
}

test "render clips rows to the terminal height" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const rows = [_]Row{
        .{ .name = "one", .udid = "1", .state = "Shutdown", .owner = null },
        .{ .name = "two", .udid = "2", .state = "Shutdown", .owner = null },
        .{ .name = "three", .udid = "3", .state = "Shutdown", .owner = null },
    };
    try render(&output.writer, .{ .columns = 50, .rows = 8 }, &rows);

    const result = output.written();
    try std.testing.expect(std.mem.indexOf(u8, result, "one") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "two") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "… 2 more") != null);
}

test "present writes only changed frames" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    var previous_frame: ?[]u8 = null;
    defer if (previous_frame) |frame| std.testing.allocator.free(frame);

    try std.testing.expect(try presentIfChanged(
        std.testing.allocator,
        &output.writer,
        &previous_frame,
        "first",
    ));
    try std.testing.expect(!try presentIfChanged(
        std.testing.allocator,
        &output.writer,
        &previous_frame,
        "first",
    ));
    try std.testing.expectEqualStrings("first", output.written());

    try std.testing.expect(try presentIfChanged(
        std.testing.allocator,
        &output.writer,
        &previous_frame,
        "second",
    ));
    try std.testing.expectEqualStrings("firstsecond", output.written());
}
