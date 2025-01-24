const std = @import("std");
const c = @cImport({
    @cInclude("toml.h");
});

pub const Card = struct {
    title: []const u8,
    desc: ?[]const u8,
    link: ?[]const u8,
    initial_idx: usize,

    pub fn deinit(self: *Card, alloc: std.mem.Allocator) void {
        if (self.desc) |desc| alloc.free(desc);
        if (self.link) |link| alloc.free(link);
        alloc.free(self.title);
    }
};

pub const Column = struct {
    title: []const u8,
    cards: std.ArrayList(Card),

    pub fn init(alloc: std.mem.Allocator, title: []const u8) !Column {
        return .{
            .title = try alloc.dupe(u8, title),
            .cards = std.ArrayList(Card).init(alloc),
        };
    }

    pub fn deinit(self: *Column, alloc: std.mem.Allocator) void {
        for (self.cards.items) |*card| {
            card.deinit(alloc);
        }
        self.cards.deinit();
        alloc.free(self.title);
    }
};

pub const Kanban = struct {
    allocator: std.mem.Allocator,
    columns: std.ArrayList(Column),

    pub fn init(alloc: std.mem.Allocator) Kanban {
        return .{
            .allocator = alloc,
            .columns = std.ArrayList(Column).init(alloc),
        };
    }

    pub fn deinit(self: *Kanban) void {
        for (self.columns.items) |*column| {
            column.deinit(self.allocator);
        }
        self.columns.deinit();
    }

    pub fn parse_file(self: *Kanban, path: []const u8) !void {
        // clear all existing cards
        for (self.columns.items) |*card| {
            card.deinit(self.allocator);
        }
        self.columns.clearRetainingCapacity();

        return c_parse_kanban(self, path);
    }

    pub fn write_file(self: *Kanban, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try write_kanban(self, file.writer());
    }
};

fn write_card(card: *Card, idx: usize, writer: anytype) !void {
    try writer.print("title = \"{s}\"\n", .{card.title});
    if (card.desc) |desc| {
        try writer.print("desc = \"\"\"\n{s}\"\"\"\n", .{desc});
    }
    if (card.link) |link| {
        try writer.print("link = \"{s}\"\n", .{link});
    }
    try writer.print("column = {d}\n", .{idx});
}

fn write_kanban(kanban: *Kanban, writer: anytype) !void {
    try writer.writeAll("columns = [\n");
    for (kanban.columns.items) |column| {
        try writer.print("  \"{s}\",\n", .{column.title});
    }
    try writer.writeAll("]\n\n");

    for (kanban.columns.items, 0..) |column, col_idx| {
        for (column.cards.items) |card| {
            try writer.writeAll("[[card]]\n");
            try writer.print("title = \"{s}\"\n", .{card.title});
            if (card.desc) |desc| {
                try writer.print("desc = \"\"\"\n{s}\"\"\"\n", .{desc});
            }
            if (card.link) |link| {
                try writer.print("link = \"{s}\"\n", .{link});
            }
            try writer.print("column = {d}\n\n", .{col_idx});
        }
    }
}

/// Parse kanban file, ensure c allocs are freed
fn c_parse_kanban(kanban: *Kanban, path: []const u8) !void {
    const fp = c.fopen(@ptrCast(path.ptr), "r");
    if (fp == null) {
        std.debug.print("couldn't open file", .{});
        return;
    }

    var errbuf: [200]u8 = [_]u8{0} ** 200;

    const conf = c.toml_parse_file(fp, errbuf[0..].ptr, errbuf.len);
    defer c.toml_free(conf);
    if (conf == null) {
        std.debug.print("couldn't parse file: {s}\n", .{errbuf});
        return error.ParsingFailed;
    }

    const columns = c.toml_array_in(conf, "columns");
    if (columns == null) {
        std.debug.print("columns field is required, must be array of strings\n", .{});
        return error.ParsingFailed;
    }
    const n_cols = c.toml_array_nelem(columns);
    for (0..@intCast(n_cols)) |i| {
        const column = c.toml_string_at(columns, @intCast(i));
        if (column.ok == 0) {
            std.debug.print("columns field must be array of strings\n", .{});
            return error.ParsingFailed;
        }
        defer std.c.free(column.u.s);
        try kanban.columns.append(
            try Column.init(kanban.allocator, std.mem.span(column.u.s)),
        );
    }

    const cards = c.toml_array_in(conf, "card");
    if (cards != null) {
        const n_cards = c.toml_array_nelem(cards);
        for (0..@intCast(n_cards)) |i| {
            const raw_card = c.toml_table_at(cards, @intCast(i));
            if (raw_card == null) {
                std.debug.print("card must be a table\n", .{});
                return error.ParsingFailed;
            }
            var card = try c_parse_card(kanban.allocator, raw_card.?);
            errdefer card.deinit(kanban.allocator);

            if (card.initial_idx >= kanban.columns.items.len) {
                std.debug.print("card references non-existent column: {}\n", .{card.initial_idx});
                return error.ParsingFailed;
            } else {
                try kanban.columns.items[card.initial_idx].cards.append(card);
            }
        }
    }
}

fn c_parse_card(alloc: std.mem.Allocator, card: *c.toml_table_t) !Card {
    const title = c.toml_string_in(card, "title");
    if (title.ok == 0) {
        std.debug.print("card title is required\n", .{});
        return error.ParsingFailed;
    }
    defer std.c.free(title.u.s);

    const raw_desc = c.toml_string_in(card, "desc");
    defer std.c.free(raw_desc.u.s);
    const desc = if (raw_desc.ok != 0) try alloc.dupe(u8, std.mem.span(raw_desc.u.s)) else null;

    const raw_link = c.toml_string_in(card, "link");
    defer std.c.free(raw_link.u.s);
    const link = if (raw_link.ok != 0) try alloc.dupe(u8, std.mem.span(raw_link.u.s)) else null;

    const idx = c.toml_int_in(card, "column");
    if (idx.ok == 0) {
        std.debug.print("card column is required, must be int\n", .{});
        return error.ParsingFailed;
    }

    return .{
        .title = try alloc.dupe(u8, std.mem.span(title.u.s)),
        .link = link,
        .desc = desc,
        .initial_idx = @intCast(idx.u.i),
    };
}
