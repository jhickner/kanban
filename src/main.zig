const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Key = vaxis.Key;
const editor = @import("editor.zig");
const kanban = @import("kanban.zig");
const Kanban = kanban.Kanban;
const Card = kanban.Card;

pub const panic = vaxis.panic_handler;

const Model = struct {
    app: *vxfw.App,
    allocator: std.mem.Allocator,
    unicode_data: *const vaxis.Unicode,
    kanban: Kanban,
    col_idx: usize = 0,
    file_path: []const u8,

    lists: std.ArrayList(vxfw.ListView),

    pub fn stopLoop(self: *Model) void {
        if (self.app.loop) |*loop| loop.stop();
    }

    pub fn startLoop(self: *Model) !void {
        if (self.app.loop) |*loop| try loop.start();
    }

    pub fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Model.typeErasedEventHandler,
            .drawFn = Model.typeErasedDrawFn,
        };
    }

    fn listWidgetBuilder(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const ListData = @ptrCast(@alignCast(ptr));

        if (self.col_idx >= self.model.kanban.columns.items.len) return null;
        if (idx >= self.model.kanban.columns.items[self.col_idx].cards.items.len) return null;
        return cardWidget(&self.model.kanban.columns.items[self.col_idx].cards.items[idx]);
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => {
                return ctx.requestFocus(self.lists.items[0].widget());
            },
            .key_press => |key| {
                switch (key.codepoint) {
                    'q' => ctx.quit = true,
                    'c' => if (key.mods.ctrl) {
                        ctx.quit = true;
                        return;
                    },
                    's' => if (key.mods.ctrl) {
                        try self.kanban.write_file(self.file_path);
                        return ctx.consumeEvent();
                    },
                    Key.enter => {
                        try self.tryOpenLink();
                        return ctx.consumeEvent();
                    },
                    'e' => {
                        self.stopLoop();
                        try editor.edit(self.allocator, self.file_path);
                        try self.load_file(self.file_path);
                        try self.startLoop();
                        return ctx.consumeEvent();
                    },
                    Key.left => if (key.mods.shift) try self.moveCardLeft(ctx) else try self.colLeft(ctx),
                    Key.right => if (key.mods.shift) try self.moveCardRight(ctx) else try self.colRight(ctx),
                    Key.up => if (key.mods.shift) try self.moveCardUp(ctx) else {},
                    Key.down => if (key.mods.shift) try self.moveCardDown(ctx) else {},
                    else => {},
                }
                //
            },
            else => {},
        }
    }

    fn tryOpenLink(self: *Model) !void {
        var col = &self.kanban.columns.items[self.col_idx];
        const card = &col.cards.items[self.lists.items[self.col_idx].cursor];
        if (card.link) |link| {
            const args = [_][]const u8{ "open", link };
            var child = std.process.Child.init(&args, self.allocator);
            try child.spawn();
        }
    }

    fn moveCardLeft(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.col_idx > 0) {
            var col = &self.kanban.columns.items[self.col_idx];
            const card = col.cards.orderedRemove(self.lists.items[self.col_idx].cursor);
            col = &self.kanban.columns.items[self.col_idx - 1];
            try col.cards.insert(0, card);
            try self.colLeft(ctx);
        }
    }

    fn moveCardRight(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.col_idx < self.lists.items.len - 1) {
            var col = &self.kanban.columns.items[self.col_idx];
            const card = col.cards.orderedRemove(self.lists.items[self.col_idx].cursor);
            col = &self.kanban.columns.items[self.col_idx + 1];
            try col.cards.insert(0, card);
            try self.colRight(ctx);
        }
    }

    fn moveCardUp(self: *Model, ctx: *vxfw.EventContext) !void {
        var col = &self.kanban.columns.items[self.col_idx];
        const cursor = self.lists.items[self.col_idx].cursor;
        if (cursor > 0) {
            const card = col.cards.orderedRemove(cursor);
            try col.cards.insert(cursor - 1, card);
            self.lists.items[self.col_idx].cursor -= 1;
            return ctx.consumeAndRedraw();
        }
    }

    fn moveCardDown(self: *Model, ctx: *vxfw.EventContext) !void {
        var col = &self.kanban.columns.items[self.col_idx];
        const cursor = self.lists.items[self.col_idx].cursor;
        if (cursor < col.cards.items.len - 1) {
            const card = col.cards.orderedRemove(cursor);
            try col.cards.insert(cursor + 1, card);
            self.lists.items[self.col_idx].cursor += 1;
            return ctx.consumeAndRedraw();
        }
    }

    fn colLeft(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.col_idx > 0) {
            var col = &self.lists.items[self.col_idx];
            col.draw_cursor = false;

            self.col_idx -= 1;

            col = &self.lists.items[self.col_idx];
            col.draw_cursor = true;
            col.cursor = 0;

            try ctx.requestFocus(col.widget());
            return ctx.consumeAndRedraw();
        }
    }

    fn colRight(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.col_idx < self.lists.items.len - 1) {
            var col = &self.lists.items[self.col_idx];
            col.draw_cursor = false;

            self.col_idx += 1;

            col = &self.lists.items[self.col_idx];
            col.draw_cursor = true;
            col.cursor = 0;

            try ctx.requestFocus(col.widget());
            return ctx.consumeAndRedraw();
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));

        const size = ctx.max.size();
        const col_width = @min(25, size.width / self.kanban.columns.items.len);
        var surfaces = std.ArrayList(vxfw.SubSurface).init(ctx.arena);

        for (self.kanban.columns.items, 0..) |col, idx| {
            // headers
            const text = vxfw.Text{
                .text = col.title,
                .style = if (idx == self.col_idx)
                    .{ .fg = .{ .rgb = [_]u8{ 255, 255, 255 } } }
                else
                    .{},
            };
            try surfaces.append(.{
                .origin = .{ .row = 0, .col = @intCast(idx * col_width) },
                .surface = try text.draw(ctx.withConstraints(
                    ctx.min,
                    .{ .width = col_width, .height = 1 },
                )),
            });

            // lists
            // don't render list if it's empty
            if (self.kanban.columns.items[idx].cards.items.len > 0) {
                try surfaces.append(.{
                    .origin = .{ .row = 2, .col = @intCast(idx * col_width) },
                    .surface = try self.lists.items[idx].draw(ctx.withConstraints(
                        ctx.min,
                        .{ .width = col_width, .height = size.height -| 2 },
                    )),
                });
            }
        }

        return .{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .focusable = true,
            .buffer = &.{},
            .children = try surfaces.toOwnedSlice(),
        };
    }

    pub fn load_file(self: *Model, path: []const u8) !void {
        try self.kanban.parse_file(path);
        self.file_path = path;

        self.freeListUserData();
        self.lists.clearRetainingCapacity();
        self.col_idx = 0;

        for (0..self.kanban.columns.items.len) |idx| {
            const data = try self.allocator.create(ListData);
            data.* = .{ .col_idx = idx, .model = self };
            try self.lists.append(.{
                .draw_cursor = (idx == 0),
                .children = .{ .builder = .{
                    .buildFn = Model.listWidgetBuilder,
                    .userdata = data,
                } },
            });
        }
    }

    fn freeListUserData(self: *Model) void {
        for (self.lists.items) |list| {
            const list_data: *const ListData = @ptrCast(@alignCast(list.children.builder.userdata));
            self.allocator.destroy(list_data);
        }
    }

    pub fn deinit(self: *Model) void {
        self.kanban.deinit();
        self.freeListUserData();
        self.lists.deinit();
    }
};

const ListData = struct {
    col_idx: usize,
    model: *Model,
};

fn cardWidget(card: *kanban.Card) vxfw.Widget {
    return .{
        .userdata = card,
        .eventHandler = vxfw.noopEventHandler,
        .drawFn = cardWidgetDrawFn,
    };
}

fn cardWidgetDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Card = @ptrCast(@alignCast(ptr));
    const text = vxfw.Text{
        .text = try std.fmt.allocPrint(ctx.arena, "{s}\n", .{self.title}),
    };
    return try text.draw(ctx);
}

// Init the file with a template if it doesn't exist
fn initTemplate(file_path: []const u8) !void {
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const file_new = try std.fs.cwd().createFile(file_path, .{});
            try file_new.writeAll(template);
            file_new.close();
            return;
        },
        else => return err,
    };
    file.close();
}

const template =
    \\columns = [
    \\  "Column 1"
    \\]
    \\
    \\[[card]]
    \\title = "Press e to edit\nthe board"
    \\column = 0
    \\#link = "http://www.google.com/"
    \\#desc = """a possibly multiline description"""
;

fn usage() void {
    std.debug.print("Usage: kanban <filename.toml>\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        //fail test; can't try in defer as defer is executed after we return
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        usage();
        std.process.exit(1);
    }

    const file_path = args[1];

    var app = try vxfw.App.init(allocator);
    errdefer app.deinit();

    const model = try allocator.create(Model);
    defer allocator.destroy(model);
    defer model.deinit();

    model.* = .{
        .app = &app,
        .allocator = allocator,
        .unicode_data = &app.vx.unicode,
        .lists = std.ArrayList(vxfw.ListView).init(allocator),
        .kanban = Kanban.init(allocator),
        .file_path = "",
    };

    try initTemplate(file_path);
    try model.load_file(file_path);

    try app.run(model.widget(), .{});
    app.deinit();
}

test {
    std.testing.refAllDecls(@This());
}
