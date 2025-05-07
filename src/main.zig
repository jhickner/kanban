const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Key = vaxis.Key;
const Border = vxfw.Border;
const TextField = vxfw.TextField;
const kanban = @import("kanban.zig");
const Kanban = kanban.Kanban;
const Card = kanban.Card;

const Direction = enum {
    left,
    right,
    up,
    down,
};

const Model = struct {
    app: *vxfw.App,
    allocator: std.mem.Allocator,
    unicode_data: *const vaxis.Unicode,

    file_path: []const u8,
    kanban: Kanban,
    col_idx: usize = 0,
    enable_preview: bool = true,

    // New card dialog state
    show_new_card_dialog: bool = false,
    new_card_dialog: ?*NewCardDialog = null,

    lists: std.ArrayList(vxfw.ListView),

    pub fn stopLoop(self: *Model) void {
        self.app.loop.stop();
    }

    pub fn startLoop(self: *Model) !void {
        try self.app.loop.start();
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

        // Check if this card is selected (current column and item at cursor position)
        const is_selected = (self.col_idx == self.model.col_idx) and
            (idx == self.model.lists.items[self.col_idx].cursor);

        return cardWidget(&self.model.kanban.columns.items[self.col_idx].cards.items[idx], is_selected);
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => {
                return ctx.requestFocus(self.lists.items[0].widget());
            },
            .key_press => |key| {
                switch (key.codepoint) {
                    ' ' => {
                        self.enable_preview = !self.enable_preview;
                        return ctx.consumeAndRedraw();
                    },
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
                    'n' => {
                        // Create and show the new card dialog
                        if (self.new_card_dialog == null) {
                            const dialog = try self.allocator.create(NewCardDialog);
                            dialog.* = try NewCardDialog.init(self);
                            self.new_card_dialog = dialog;
                        }

                        self.show_new_card_dialog = true;
                        try ctx.requestFocus(self.new_card_dialog.?.widget());
                        return ctx.consumeAndRedraw();
                    },
                    'e' => {
                        try self.editFile();
                        return ctx.consumeEvent();
                    },
                    Key.left => if (key.mods.shift) try self.moveCard(ctx, .left) else try self.navigateColumn(ctx, .left),
                    Key.right => if (key.mods.shift) try self.moveCard(ctx, .right) else try self.navigateColumn(ctx, .right),
                    Key.up => if (key.mods.shift) try self.moveCard(ctx, .up) else {},
                    Key.down => if (key.mods.shift) try self.moveCard(ctx, .down) else {},
                    else => {},
                }
                //
            },
            else => {},
        }
    }

    fn editFile(self: *Model) !void {
        self.stopLoop();
        try edit(self.allocator, self.file_path);
        try self.load_file(self.file_path);
        try self.startLoop();
    }

    fn tryOpenLink(self: *Model) !void {
        var col = &self.kanban.columns.items[self.col_idx];
        if (col.cards.items.len == 0) return;
        const card = &col.cards.items[self.lists.items[self.col_idx].cursor];
        if (card.link) |link| {
            const args = [_][]const u8{ "open", link };
            var child = std.process.Child.init(&args, self.allocator);
            try child.spawn();
        }
    }

    fn moveCard(self: *Model, ctx: *vxfw.EventContext, direction: Direction) !void {
        var col = &self.kanban.columns.items[self.col_idx];
        if (col.cards.items.len == 0) return;
        const cursor = self.lists.items[self.col_idx].cursor;

        switch (direction) {
            .left => {
                if (self.col_idx > 0) {
                    const card = col.cards.orderedRemove(cursor);
                    col = &self.kanban.columns.items[self.col_idx - 1];
                    try col.cards.insert(0, card);
                    try self.navigateColumn(ctx, .left);
                }
            },
            .right => {
                if (self.col_idx < self.lists.items.len - 1) {
                    const card = col.cards.orderedRemove(cursor);
                    col = &self.kanban.columns.items[self.col_idx + 1];
                    try col.cards.insert(0, card);
                    try self.navigateColumn(ctx, .right);
                }
            },
            .up => {
                if (cursor > 0) {
                    const card = col.cards.orderedRemove(cursor);
                    try col.cards.insert(cursor - 1, card);
                    self.lists.items[self.col_idx].cursor -= 1;
                    return ctx.consumeAndRedraw();
                }
            },
            .down => {
                if (cursor < col.cards.items.len - 1) {
                    const card = col.cards.orderedRemove(cursor);
                    try col.cards.insert(cursor + 1, card);
                    self.lists.items[self.col_idx].cursor += 1;
                    return ctx.consumeAndRedraw();
                }
            },
        }
    }

    fn navigateColumn(self: *Model, ctx: *vxfw.EventContext, direction: Direction) !void {
        const can_move = switch (direction) {
            .left => self.col_idx > 0,
            .right => self.col_idx < self.lists.items.len - 1,
            else => false, // up/down aren't valid for column navigation
        };

        if (can_move) {
            switch (direction) {
                .left => self.col_idx -= 1,
                .right => self.col_idx += 1,
                else => {},
            }

            var col = &self.lists.items[self.col_idx];
            col.cursor = 0;

            if (self.kanban.columns.items[self.col_idx].cards.items.len > 0) {
                try ctx.requestFocus(col.widget());
            }
            return ctx.consumeAndRedraw();
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));

        const size = ctx.max.size();
        // Adjust column width to account for spacing
        const spacing = 1; // Add 1 space between columns
        const total_spacing = spacing * (self.kanban.columns.items.len - 1);
        const total_available_width = if (size.width > total_spacing) size.width - total_spacing else size.width;
        const col_width = @min(25, total_available_width / self.kanban.columns.items.len);
        var surfaces = std.ArrayList(vxfw.SubSurface).init(ctx.arena);

        // If we're showing the dialog, create it on-demand if needed
        if (self.show_new_card_dialog) {
            if (self.new_card_dialog == null) {
                const dialog = try self.allocator.create(NewCardDialog);
                dialog.* = try NewCardDialog.init(self);
                self.new_card_dialog = dialog;
            }

            // Dialog will be drawn on top
        }

        // force preview disable for small screens
        if (size.height < 25) self.enable_preview = false;

        const preview_y = 16;
        const list_height = if (self.enable_preview) preview_y else size.height -| 2;

        for (self.kanban.columns.items, 0..) |col, idx| {
            // headers
            const header_text = vxfw.Text{
                .text = col.title,
                .style = if (idx == self.col_idx)
                    .{ .fg = .{ .rgb = [_]u8{ 255, 255, 255 } } }
                else
                    .{},
            };
            try surfaces.append(.{
                .origin = .{ .row = 0, .col = @intCast(idx * (col_width + spacing)) },
                .surface = try header_text.draw(ctx.withConstraints(
                    ctx.min,
                    .{ .width = col_width, .height = 1 },
                )),
            });

            // lists
            // don't render list if it's empty
            //if (self.kanban.columns.items[idx].cards.items.len > 0) {
            try surfaces.append(.{
                .origin = .{ .row = 2, .col = @intCast(idx * (col_width + spacing)) },
                .surface = try self.lists.items[idx].draw(ctx.withConstraints(
                    ctx.min,
                    .{ .width = col_width, .height = list_height },
                )),
            });
            //}

            // preview
            if (self.enable_preview) {
                var current_col = &self.kanban.columns.items[self.col_idx];
                if (current_col.cards.items.len > 0) {
                    const cursor = self.lists.items[self.col_idx].cursor;
                    const card = &current_col.cards.items[cursor];
                    if (card.desc != null or card.link != null) {
                        var copy = std.ArrayList(u8).init(ctx.arena);
                        try copy.appendNTimes('-', size.width);
                        try copy.append('\n');

                        if (card.desc) |desc| {
                            try copy.appendSlice(desc);
                            try copy.append('\n');
                        }

                        if (card.link) |link| {
                            try copy.appendSlice(link);
                        }

                        const desc_text = vxfw.Text{ .text = copy.items };
                        try surfaces.append(.{
                            .origin = .{ .row = preview_y + 1, .col = 0 },
                            .surface = try desc_text.draw(ctx),
                        });
                    }
                }
            }
        }

        // Draw the dialog on top if it's visible
        if (self.show_new_card_dialog and self.new_card_dialog != null) {
            // Create a border around the dialog
            const border = Border{
                .child = self.new_card_dialog.?.widget(),
                .style = .{},
            };

            // Draw the bordered dialog
            const dialog_surface = try border.draw(ctx);

            // Center the dialog on screen
            const width = dialog_surface.size.width;
            const height = dialog_surface.size.height;
            const start_row = @max(0, @divFloor(@as(usize, size.height - height), 2));
            const start_col = @max(0, @divFloor(@as(usize, size.width - width), 2));

            try surfaces.append(.{ .origin = .{ .row = @intCast(start_row), .col = @intCast(start_col) }, .surface = dialog_surface });
        }

        // Create the surface with all the child surfaces
        return vxfw.Surface{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = surfaces.items,
        };
    }

    pub fn load_file(self: *Model, path: []const u8) !void {
        try self.kanban.parse_file(path);
        self.file_path = path;

        self.freeListUserData();
        self.lists.clearRetainingCapacity();

        const old_col_idx = self.col_idx;
        const old_cursor = if (self.lists.items.len > 0) self.lists.items[old_col_idx].cursor else 0;
        self.col_idx = 0;

        for (0..self.kanban.columns.items.len) |idx| {
            const data = try self.allocator.create(ListData);
            data.* = .{ .col_idx = idx, .model = self };
            try self.lists.append(.{
                .draw_cursor = false, // Disable the default cursor indicator
                .children = .{ .builder = .{
                    .buildFn = Model.listWidgetBuilder,
                    .userdata = data,
                } },
            });
        }

        if (old_col_idx < self.kanban.columns.items.len) {
            self.col_idx = old_col_idx;
            self.lists.items[self.col_idx].cursor = old_cursor;
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

        if (self.new_card_dialog) |dialog| {
            dialog.deinit();
            self.allocator.destroy(dialog);
        }
    }
};

const ListData = struct {
    col_idx: usize,
    model: *Model,
};

const NewCardDialog = struct {
    title_field: TextField,
    model: *Model,
    allocator: std.mem.Allocator,
    card_title: []u8 = &[_]u8{},

    pub fn init(model: *Model) !NewCardDialog {
        // Initialize with the required allocator and unicode data
        return NewCardDialog{
            .title_field = TextField.init(model.allocator, model.unicode_data),
            .model = model,
            .allocator = model.allocator,
        };
    }

    pub fn deinit(self: *NewCardDialog) void {
        // Clean up the text field
        self.title_field.deinit();
    }

    pub fn widget(self: *NewCardDialog) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = NewCardDialog.eventHandler,
            .drawFn = NewCardDialog.drawFn,
        };
    }

    fn eventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *NewCardDialog = @ptrCast(@alignCast(ptr));

        // Handle Enter key for submission manually to avoid conflicts
        if (event == .key_press) {
            const key = event.key_press;
            if (key.codepoint == Key.enter) {
                // Get the current text from the text field
                const title = try self.title_field.toOwnedSlice();
                defer self.allocator.free(title);

                if (title.len > 0) {
                    // Submit the title
                    try insertCard(self.model.file_path, self.model.col_idx, title);
                    try self.model.load_file(self.model.file_path);
                    self.model.show_new_card_dialog = false;
                    try ctx.requestFocus(self.model.widget());
                    return ctx.consumeAndRedraw();
                }
            } else if (key.codepoint == Key.escape) {
                // Cancel
                self.model.show_new_card_dialog = false;
                try ctx.requestFocus(self.model.widget());
                return ctx.consumeAndRedraw();
            }
        }

        // Pass all other events to the text field
        return self.title_field.handleEvent(ctx, event);
    }

    fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *NewCardDialog = @ptrCast(@alignCast(ptr));

        const width = 36; // Width of the dialog content (will get +2 from border)
        const height = 5; // Height of the dialog content (will get +2 from border)

        // Create a surface for the dialog
        var dialog = try vxfw.Surface.init(
            ctx.arena,
            self.widget(),
            .{ .width = width, .height = height },
        );

        // Create a surface for the children
        var surfaces = std.ArrayList(vxfw.SubSurface).init(ctx.arena);

        // Create a text widget for the title
        const title_text = vxfw.Text{
            .text = "New Card",
            .style = .{ .fg = .{ .rgb = [_]u8{ 255, 255, 255 } } },
        };

        // Add the title
        try surfaces.append(.{
            .origin = .{ .row = 0, .col = @intCast((width - "New Card".len) / 2) },
            .surface = try title_text.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = width, .height = 1 },
            )),
        });

        // Add the text field
        try surfaces.append(.{
            .origin = .{ .row = 2, .col = 2 },
            .surface = try self.title_field.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = width - 4, .height = 1 },
            )),
        });

        // Add help text
        const help_text = vxfw.Text{
            .text = "Enter: Submit  Esc: Cancel",
            .style = .{ .fg = .{ .rgb = [_]u8{ 200, 200, 200 } } },
        };

        try surfaces.append(.{
            .origin = .{ .row = 4, .col = @intCast((width - "Enter: Submit  Esc: Cancel".len) / 2) },
            .surface = try help_text.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = width, .height = 1 },
            )),
        });

        // Add all surfaces to the dialog
        dialog.children = surfaces.items;

        return dialog;
    }
};

fn cardWidget(card: *kanban.Card, is_selected: bool) vxfw.Widget {
    if (is_selected) {
        return .{
            .userdata = card,
            .drawFn = selectedCardWidgetDrawFn,
        };
    } else {
        return .{
            .userdata = card,
            .drawFn = cardWidgetDrawFn,
        };
    }
}

fn cardWidgetDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const card: *Card = @ptrCast(@alignCast(ptr));

    // Create the text widget for the card content
    const text = vxfw.Text{
        .text = try std.fmt.allocPrint(ctx.arena, "{s}\n", .{card.title}),
    };

    // Create a border with default style
    const border = Border{
        .child = text.widget(),
        .style = .{}, // Default style
    };

    // Draw the bordered text
    return try border.draw(ctx);
}

fn selectedCardWidgetDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const card: *Card = @ptrCast(@alignCast(ptr));

    // Create the text widget for the card content with bright white text
    const text = vxfw.Text{
        .text = try std.fmt.allocPrint(ctx.arena, "{s}\n", .{card.title}),
        .style = .{ .fg = .{ .rgb = [_]u8{ 255, 255, 255 } } }, // Bright white text
    };

    // Create a border with bright white style for selected items
    const border = Border{
        .child = text.widget(),
        .style = .{ .fg = .{ .rgb = [_]u8{ 255, 255, 255 } } }, // Bright white border
    };

    // Draw the bordered text
    return try border.draw(ctx);
}

const NEW_TEMPLATE =
    \\columns = [
    \\  # add more column here
    \\  "Column 1",
    \\  "Column 2"
    \\]
    \\
    \\[[card]]
    \\title = "This is a card.\nCard titles can be long."
    \\column = 0
    \\link = "http://www.google.com/"
    \\desc = """
    \\This is the card description.
    \\Press 'e' to edit the card in your editor. ($EDITOR env var)
    \\Save and exit to return to the board.
    \\
    \\- Press 'space' to toggle the description pane.
    \\- Navigate the board with arrow keys.
    \\- Move cards by holding shift + arrow keys.
    \\- Press 'enter' on a card to navigate to the link URL (if set)
    \\- Ctrl-s to save the board.
    \\- 'q' to quit
    \\"""
    \\
    \\[[card]]
    \\title = "This is another card."
    \\column = 0
;

const NEW_CARD =
    \\
    \\
    \\[[card]]
    \\title = "{s}"
    \\column = {d}
;

fn usage() void {
    std.debug.print("Usage: kanban <filename.toml>\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
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

/// insert a new card in the currently selected column
fn insertCard(file_path: []const u8, col_idx: usize, title: []const u8) !void {
    const file = try std.fs.cwd().openFile(file_path, .{ .mode = .read_write });
    defer file.close();
    try file.seekFromEnd(0);
    try std.fmt.format(file.writer(), NEW_CARD, .{ title, col_idx });
}

// Init the file with a template if it doesn't exist
fn initTemplate(file_path: []const u8) !void {
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const file_new = try std.fs.cwd().createFile(file_path, .{});
            try file_new.writeAll(NEW_TEMPLATE);
            file_new.close();
            return;
        },
        else => return err,
    };
    file.close();
}

test {
    std.testing.refAllDecls(@This());
}
