const std = @import("std");
const temp = @import("temp");

pub fn edit(
    alloc: std.mem.Allocator,
    file_path: []const u8,
) !void {
    const editor = std.process.getEnvVarOwned(alloc, "EDITOR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try alloc.dupe(u8, "nvim"),
        else => return err,
    };
    defer alloc.free(editor);

    var child = std.process.Child.init(&.{ editor, file_path }, alloc);
    _ = try child.spawnAndWait();
}

pub fn editTempFileReturningContents(alloc: std.mem.Allocator, pattern: []const u8) ![]u8 {
    var tmp_file = try temp.create_file(alloc, pattern);
    defer tmp_file.deinit();
    const tmp_file_path = try tmp_file.parent_dir.realpathAlloc(alloc, tmp_file.basename);
    defer alloc.free(tmp_file_path);
    return try editReturningContents(alloc, tmp_file_path);
}

pub fn editReturningContents(alloc: std.mem.Allocator, file_path: []const u8) ![]u8 {
    try edit(alloc, file_path);
    const file = try std.fs.cwd().openFile(file_path, .{});

    // const file = if (std.fs.path.isAbsolute(file_path))
    //     try std.fs.openFileAbsolute(file_path, .{})
    // else
    //     try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    return try file.readToEndAlloc(alloc, std.math.maxInt(usize));
}
