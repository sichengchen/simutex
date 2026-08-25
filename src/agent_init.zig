const std = @import("std");
const Io = std.Io;

const skill_contents = @embedFile("skill/simutex/SKILL.md");

pub const Target = struct {
    label: []const u8,
    skills_path: []const u8,
};

pub const InstallResult = enum {
    installed,
    updated,
    unchanged,
};

const TargetDefinition = struct {
    label: []const u8,
    markers: []const []const u8,
    skills_dir: []const u8,
};

const target_definitions = [_]TargetDefinition{
    .{
        .label = "Codex / shared Agent Skills",
        .markers = &.{ ".agents", ".codex" },
        .skills_dir = ".agents/skills",
    },
    .{
        .label = "Claude Code",
        .markers = &.{".claude"},
        .skills_dir = ".claude/skills",
    },
    .{
        .label = "Cursor",
        .markers = &.{".cursor"},
        .skills_dir = ".cursor/skills",
    },
    .{
        .label = "Gemini CLI",
        .markers = &.{".gemini"},
        .skills_dir = ".gemini/skills",
    },
};

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    args: []const []const u8,
    writer: *Io.Writer,
) !void {
    var install_all = false;
    var dry_run = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--all")) {
            if (install_all) return error.InvalidArguments;
            install_all = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            if (dry_run) return error.InvalidArguments;
            dry_run = true;
        } else {
            return error.InvalidArguments;
        }
    }

    const home = environ.get("HOME") orelse return error.HomeRequired;
    const targets = try detectTargets(allocator, io, home);
    if (targets.len == 0) return error.NoAgentsDetected;

    const selected = try allocator.alloc(bool, targets.len);
    @memset(selected, install_all);

    if (!install_all) {
        if (!try Io.File.stdin().isTty(io)) return error.InteractiveInputRequired;
        try renderMenu(writer, targets);
        try writer.flush();

        var input_buffer: [256]u8 = undefined;
        var stdin_reader = Io.File.stdin().reader(io, &input_buffer);
        const input = (try stdin_reader.interface.takeDelimiter('\n')) orelse "";
        if (!try parseSelection(input, selected)) {
            try writer.writeAll("Cancelled.\n");
            return;
        }
    }

    var installed_count: usize = 0;
    for (targets, selected) |target, is_selected| {
        if (!is_selected) continue;
        installed_count += 1;
        if (dry_run) {
            try writer.print("would install\t{s}\t{s}/simutex\n", .{ target.label, target.skills_path });
            continue;
        }
        const result = try installSkill(io, target.skills_path);
        try writer.print("{s}\t{s}\t{s}/simutex\n", .{
            @tagName(result), target.label, target.skills_path,
        });
    }
    if (installed_count == 0) return error.NoAgentsSelected;
}

pub fn detectTargets(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
) ![]Target {
    var targets: std.ArrayList(Target) = .empty;
    defer targets.deinit(allocator);

    for (target_definitions) |definition| {
        var detected = false;
        for (definition.markers) |marker| {
            const marker_path = try std.fs.path.join(allocator, &.{ home, marker });
            defer allocator.free(marker_path);
            if (try pathExists(io, marker_path)) {
                detected = true;
                break;
            }
        }
        if (!detected) continue;
        try targets.append(allocator, .{
            .label = definition.label,
            .skills_path = try std.fs.path.join(allocator, &.{ home, definition.skills_dir }),
        });
    }
    return targets.toOwnedSlice(allocator);
}

fn pathExists(io: Io, path: []const u8) !bool {
    Io.Dir.accessAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |other| return other,
    };
    return true;
}

fn renderMenu(writer: *Io.Writer, targets: []const Target) !void {
    try writer.writeAll(
        \\simutex init
        \\
        \\Install the simulator coordination skill for local agents.
        \\
    );
    for (targets, 1..) |target, index| {
        try writer.print("  {d}. [x] {s}\n      {s}/simutex\n", .{
            index, target.label, target.skills_path,
        });
    }
    try writer.writeAll(
        \\Choose numbers separated by commas, "all", or "q".
        \\Press Enter to install all detected targets [all]:
        \\> 
    );
}

pub fn parseSelection(input: []const u8, selected: []bool) !bool {
    @memset(selected, false);
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "all")) {
        @memset(selected, true);
        return true;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "q") or std.ascii.eqlIgnoreCase(trimmed, "quit")) {
        return false;
    }

    var choices = std.mem.tokenizeAny(u8, trimmed, ", \t");
    var count: usize = 0;
    while (choices.next()) |choice| {
        const number = std.fmt.parseInt(usize, choice, 10) catch return error.InvalidSelection;
        if (number == 0 or number > selected.len or selected[number - 1]) {
            return error.InvalidSelection;
        }
        selected[number - 1] = true;
        count += 1;
    }
    if (count == 0) return error.InvalidSelection;
    return true;
}

pub fn installSkill(io: Io, skills_path: []const u8) !InstallResult {
    const skill_path = try std.fs.path.join(std.heap.page_allocator, &.{ skills_path, "simutex" });
    defer std.heap.page_allocator.free(skill_path);
    var skill_dir = try Io.Dir.cwd().createDirPathOpen(io, skill_path, .{});
    defer skill_dir.close(io);

    var existing_buffer: [skill_contents.len + 1]u8 = undefined;
    const existing = skill_dir.readFile(io, "SKILL.md", &existing_buffer) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |other| return other,
    };
    if (existing) |contents| {
        if (std.mem.eql(u8, contents, skill_contents)) return .unchanged;
    }

    var atomic_file = try skill_dir.createFileAtomic(io, "SKILL.md", .{ .replace = true });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, skill_contents);
    try atomic_file.replace(io);
    return if (existing == null) .installed else .updated;
}

test "selection defaults to all and accepts a subset" {
    var selected = [_]bool{ false, false, false };
    try std.testing.expect(try parseSelection("", &selected));
    try std.testing.expectEqualSlices(bool, &.{ true, true, true }, &selected);

    try std.testing.expect(try parseSelection("1, 3", &selected));
    try std.testing.expectEqualSlices(bool, &.{ true, false, true }, &selected);
    try std.testing.expect(!(try parseSelection("q", &selected)));
    try std.testing.expectError(error.InvalidSelection, parseSelection("4", &selected));
}

test "skill installation is atomic and idempotent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const skills_path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/skills", .{tmp.sub_path});
    try std.testing.expectEqual(InstallResult.installed, try installSkill(std.testing.io, skills_path));
    try std.testing.expectEqual(InstallResult.unchanged, try installSkill(std.testing.io, skills_path));

    var skill_dir = try tmp.dir.openDir(std.testing.io, "skills/simutex", .{});
    defer skill_dir.close(std.testing.io);
    var contents_buffer: [skill_contents.len + 1]u8 = undefined;
    const contents = try skill_dir.readFile(std.testing.io, "SKILL.md", &contents_buffer);
    try std.testing.expectEqualStrings(skill_contents, contents);
}
