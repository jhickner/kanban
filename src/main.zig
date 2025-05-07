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

    // Dialogs for user input
    show_dialog: bool = false,
    input_dialog: ?*InputDialog = null,

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

    fn listWidgetBuilder(ptr: *const anyopaque, idx: usize, cursor: usize) ?vxfw.Widget {
        const self: *const ListData = @ptrCast(@alignCast(ptr));

        if (self.col_idx >= self.model.kanban.columns.items.len) return null;
        if (idx >= self.model.kanban.columns.items[self.col_idx].cards.items.len) return null;

        const is_selected = self.col_idx == self.model.col_idx and
            idx == cursor;

        const card = &self.model.kanban.columns.items[self.col_idx].cards.items[idx];
        
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
                    'n' => return self.showDialog(ctx, "New Card", createCardCallback),
                    'a' => return self.showDialog(ctx, "New Column", createColumnCallback),
                    'e' => {
                        try self.editFile();
                        return ctx.consumeEvent();
                    },
                    'x' => {
                        if (key.mods.shift) {
                            try self.deleteColumn(ctx);
                            return ctx.consumeAndRedraw();
                        } else {
                            try self.deleteCard(ctx);
                            return ctx.consumeAndRedraw();
                        }
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

    fn deleteCard(self: *Model, _: *vxfw.EventContext) !void {
        var col = &self.kanban.columns.items[self.col_idx];
        // If there are no cards in this column, nothing to delete
        if (col.cards.items.len == 0) return;

        const cursor = self.lists.items[self.col_idx].cursor;
        // Remove the card at the current cursor position
        var card = col.cards.orderedRemove(cursor);
        card.deinit(self.allocator);

        // Adjust cursor if needed (if we deleted the last card)
        if (cursor >= col.cards.items.len and col.cards.items.len > 0) {
            self.lists.items[self.col_idx].cursor = @intCast(col.cards.items.len - 1);
        }
    }

    fn deleteColumn(self: *Model, ctx: *vxfw.EventContext) !void {
        // If this is the only column, don't delete it
        if (self.kanban.columns.items.len <= 1) return;

        // Check if the column is empty
        const col = &self.kanban.columns.items[self.col_idx];
        if (col.cards.items.len > 0) return; // Don't delete non-empty columns

        // Remove the column
        var column = self.kanban.columns.orderedRemove(self.col_idx);
        column.deinit(self.allocator);

        // Adjust the current column index if needed
        if (self.col_idx >= self.kanban.columns.items.len) {
            self.col_idx = self.kanban.columns.items.len - 1;
        }

        try ctx.requestFocus(self.lists.items[self.col_idx].widget());
        return ctx.consumeAndRedraw();
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
        const spacing = 1;
        const total_spacing = spacing * (self.kanban.columns.items.len - 1);
        const total_available_width = if (size.width > total_spacing) size.width - total_spacing else size.width;
        const col_width = @min(25, total_available_width / self.kanban.columns.items.len);
        var surfaces = std.ArrayList(vxfw.SubSurface).init(ctx.arena);

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
            try surfaces.append(.{
                .origin = .{ .row = 2, .col = @intCast(idx * (col_width + spacing)) },
                .surface = try self.lists.items[idx].draw(ctx.withConstraints(
                    ctx.min,
                    .{ .width = col_width, .height = list_height },
                )),
            });

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
        if (self.show_dialog) {
            // Create a border around the dialog
            const border = Border{
                .child = self.input_dialog.?.widget(),
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

    fn showDialog(self: *Model, ctx: *vxfw.EventContext, dialog_title: []const u8, callback: InputDialogCallback) !void {
        if (self.input_dialog == null) {
            const dialog = try self.allocator.create(InputDialog);
            dialog.* = try InputDialog.init(self, dialog_title, callback);
            self.input_dialog = dialog;
        } else {
            self.input_dialog.?.* = try InputDialog.init(self, dialog_title, callback);
        }

        self.show_dialog = true;
        try ctx.requestFocus(self.input_dialog.?.widget());
        return ctx.consumeAndRedraw();
    }

    pub fn deinit(self: *Model) void {
        self.kanban.deinit();
        self.freeListUserData();
        self.lists.deinit();

        if (self.input_dialog) |dialog| {
            dialog.deinit();
            self.allocator.destroy(dialog);
        }
    }
};

const ListData = struct {
    col_idx: usize,
    model: *Model,
};

pub const InputDialogCallback = *const fn (model: *Model, ctx: *vxfw.EventContext, input: []const u8) anyerror!void;

const InputDialog = struct {
    title_field: TextField,
    model: *Model,
    allocator: std.mem.Allocator,
    dialog_title: []const u8,
    callback: InputDialogCallback,

    pub fn init(
        model: *Model,
        dialog_title: []const u8,
        callback: InputDialogCallback,
    ) !InputDialog {
        return InputDialog{
            .title_field = TextField.init(model.allocator, model.unicode_data),
            .model = model,
            .allocator = model.allocator,
            .dialog_title = dialog_title,
            .callback = callback,
        };
    }

    pub fn deinit(self: *InputDialog) void {
        self.title_field.deinit();
    }

    pub fn widget(self: *InputDialog) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = InputDialog.eventHandler,
            .drawFn = InputDialog.drawFn,
        };
    }

    fn eventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *InputDialog = @ptrCast(@alignCast(ptr));

        // Handle Enter key for submission manually to avoid conflicts
        if (event == .key_press) {
            const key = event.key_press;
            if (key.codepoint == Key.enter) {
                // Get the current text from the text field
                const input = try self.title_field.toOwnedSlice();
                defer self.allocator.free(input);

                if (input.len > 0) {
                    // Submit the input using the callback
                    try self.callback(self.model, ctx, input);

                    // Close the dialog
                    // NOTE: callback should set fallback focus
                    self.model.show_dialog = false;
                    return ctx.consumeAndRedraw();
                }
            } else if (key.codepoint == Key.escape) {
                // Cancel
                self.model.show_dialog = false;
                try ctx.requestFocus(self.model.widget());
                return ctx.consumeAndRedraw();
            }
        }

        // Pass all other events to the text field
        return self.title_field.handleEvent(ctx, event);
    }

    fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *InputDialog = @ptrCast(@alignCast(ptr));

        const width = 36;
        const height = 7;

        var dialog = try vxfw.Surface.init(
            ctx.arena,
            self.widget(),
            .{ .width = width, .height = height },
        );

        var surfaces = std.ArrayList(vxfw.SubSurface).init(ctx.arena);

        const title_text = vxfw.Text{
            .text = self.dialog_title,
        };

        try surfaces.append(.{
            .origin = .{ .row = 0, .col = @intCast((width - self.dialog_title.len) / 2) },
            .surface = try title_text.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = width, .height = 1 },
            )),
        });

        const text_field = Border{ .child = self.title_field.widget() };

        try surfaces.append(.{
            .origin = .{ .row = 2, .col = 2 },
            .surface = try text_field.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = width - 4, .height = 3 },
            )),
        });

        // help text
        const help_text = vxfw.Text{ .text = "Enter: Submit  Esc: Cancel" };

        try surfaces.append(.{
            .origin = .{ .row = 6, .col = @intCast((width - "Enter: Submit  Esc: Cancel".len) / 2) },
            .surface = try help_text.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = width, .height = 1 },
            )),
        });

        dialog.children = surfaces.items;

        return dialog;
    }
};


fn cardWidgetDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const card: *Card = @ptrCast(@alignCast(ptr));

    const text = vxfw.Text{
        .text = try std.fmt.allocPrint(ctx.arena, "{s}\n", .{card.title}),
    };

    const border = Border{ .child = text.widget() };

    // Draw the bordered text
    return try border.draw(ctx);
}

fn selectedCardWidgetDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const card: *Card = @ptrCast(@alignCast(ptr));

    const text = vxfw.Text{
        .text = try std.fmt.allocPrint(ctx.arena, "{s}\n", .{card.title}),
        .style = .{ .fg = .{ .rgb = [_]u8{ 255, 255, 255 } } },
    };

    const border = Border{
        .child = text.widget(),
        .style = .{ .fg = .{ .rgb = [_]u8{ 255, 255, 255 } } },
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
    \\- Press 'x' to delete the currently selected card.
    \\- Ctrl-s to save the board.
    \\- 'q' to quit
    \\"""
    \\
    \\[[card]]
    \\title = "This is another card."
    \\column = 0
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

// Callback for creating a new card
fn createCardCallback(model: *Model, ctx: *vxfw.EventContext, title: []const u8) !void {
    // Create a new card and add it directly to the model
    const newCard = Card{
        .title = try model.allocator.dupe(u8, title),
        .desc = null,
        .link = null,
        .initial_idx = model.col_idx,
    };

    // Add the card to the current column
    try model.kanban.columns.items[model.col_idx].cards.append(newCard);

    // Set focus to the column where the card was added
    try ctx.requestFocus(model.lists.items[model.col_idx].widget());
}

// Callback for creating a new column
fn createColumnCallback(model: *Model, ctx: *vxfw.EventContext, title: []const u8) !void {
    // Add the new column to the model
    try model.kanban.columns.append(try kanban.Column.init(model.allocator, title));

    // Update the lists data structure to match columns
    const colIdx = model.kanban.columns.items.len - 1;
    const data = try model.allocator.create(ListData);
    data.* = .{ .col_idx = colIdx, .model = model };

    try model.lists.append(.{
        .draw_cursor = false, // Disable the default cursor indicator
        .children = .{ .builder = .{
            .buildFn = Model.listWidgetBuilder,
            .userdata = data,
        } },
    });

    // Update the column index and set focus to the new column
    model.col_idx = colIdx;
    try ctx.requestFocus(model.lists.items[colIdx].widget());
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
