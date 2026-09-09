const std = @import("std");
const Io = std.Io;
const simutex = @import("simutex");
const monitor = @import("monitor.zig");

const usage =
    \\simutex - coordinate exclusive access to local iOS simulators
    \\
    \\Usage:
    \\  simutex list [--json]
    \\  simutex monitor
    \\  simutex claim [UDID] [--owner OWNER]
    \\  simutex status UDID [--json]
    \\  simutex release UDID [--owner OWNER]
    \\  simutex describe UDID DESCRIPTION
    \\  simutex watch --json
    \\  simutex takeover UDID --owner OWNER --expected-owner OWNER
    \\  simutex hooks show UDID [--json] [--hooks FILE]
    \\  simutex hooks set UDID --event pre-claim|post-claim --config FILE
    \\  simutex hooks disable|inherit UDID --event pre-claim|post-claim
    \\  simutex reset
    \\  simutex init [--all] [--dry-run]
    \\  simutex version
    \\
    \\Claim/takeover hook options: --hooks FILE, --pre-claim EXECUTABLE,
    \\  --post-claim EXECUTABLE, --no-pre-claim, --no-post-claim.
    \\New owners: manual:<username> or agent:<purpose>.
    \\Set SIMUTEX_METADATA_PATH for simulator descriptions and hooks.
    \\Set SIMUTEX_HOOKS for default hooks (no automatic project discovery).
    \\Set SIMUTEX_AGENT instead of passing --owner on every command.
    \\Set SIMUTEX_STATE_DIR to override the shared lock directory.
    \\
;


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
        try stdout.writeAll("simutex 0.2.0\n");
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

    if (std.mem.eql(u8, command, "monitor")) {
        if (args.len != 2) return error.InvalidArguments;
        var state_dir = try simutex.openStateDir(init.io, try statePath(allocator, init.environ_map));
        defer state_dir.close(init.io);
        return monitor.run(allocator, init.io, state_dir, stdout);
    }
    const argv = try allocator.alloc([*:0]const u8, args.len - 1);
    for (args[1..], 0..) |arg, i| argv[i] = try allocator.dupeZ(u8, arg);
    const result = simutex_cli_run(@intCast(argv.len), argv.ptr);
    if (result != 0) std.process.exit(@intCast(result));
}

extern fn simutex_cli_run(argc: c_int, argv: [*]const [*:0]const u8) c_int;

fn statePath(allocator: std.mem.Allocator, environ: *std.process.Environ.Map) ![]const u8 {
    if (environ.get("SIMUTEX_STATE_DIR")) |path| return path;
    const temp = environ.get("TMPDIR") orelse "/tmp";
    return std.fs.path.join(allocator, &.{ temp, "simutex" });
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
