const std = @import("std");

pub fn Array2D(comptime T: type) type {
    return struct {
        data: std.ArrayList(std.ArrayList(T)),
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .data = std.ArrayList(std.ArrayList(T)).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.data.items) |*row| {
                row.deinit();
            }
            self.data.deinit();
        }

        pub fn append(self: *Self, row: std.ArrayList(T)) !void {
            try self.data.append(row);
        }

        pub fn appendRow(self: *Self) !void {
            try self.data.append(std.ArrayList(T).init(self.allocator));
        }

        pub fn appendInRow(self: *Self, row: usize, value: T) !void {
            if (row >= self.data.items.len) return error.RowIndexOutOfBounds;
            try self.data.items[row].append(value);
        }

        pub fn getRow(self: Self, row: usize) !*std.ArrayList(T) {
            if (row >= self.data.items.len) return error.RowIndexOutOfBounds;
            return &self.data.items[row];
        }

        pub fn get(self: Self, row: usize, col: usize) !T {
            if (row >= self.data.items.len) return error.RowIndexOutOfBounds;
            if (col >= self.data.items[row].items.len) return error.ColIndexOutOfBounds;
            return self.data.items[row].items[col];
        }

        // New reordering functions
        pub fn swapInRow(self: *Self, row: usize, idx1: usize, idx2: usize) !void {
            if (row >= self.data.items.len) return error.RowIndexOutOfBounds;
            const row_data = &self.data.items[row];
            if (idx1 >= row_data.items.len or idx2 >= row_data.items.len)
                return error.ColIndexOutOfBounds;

            const temp = row_data.items[idx1];
            row_data.items[idx1] = row_data.items[idx2];
            row_data.items[idx2] = temp;
        }

        pub fn moveInRow(self: *Self, row: usize, from_idx: usize, to_idx: usize) !void {
            if (row >= self.data.items.len) return error.RowIndexOutOfBounds;
            const row_data = &self.data.items[row];
            if (from_idx >= row_data.items.len or to_idx >= row_data.items.len)
                return error.ColIndexOutOfBounds;

            const item = row_data.items[from_idx];
            _ = row_data.orderedRemove(from_idx);
            try row_data.insert(to_idx, item);
        }

        pub fn rotateRowLeft(self: *Self, row: usize, positions: usize) !void {
            if (row >= self.data.items.len) return error.RowIndexOutOfBounds;
            const row_data = &self.data.items[row];
            if (row_data.items.len == 0) return;

            const effective_positions = positions % row_data.items.len;
            if (effective_positions == 0) return;

            var temp = try std.ArrayList(T).initCapacity(self.allocator, effective_positions);
            defer temp.deinit();

            // Save first elements
            for (0..effective_positions) |i| {
                try temp.append(row_data.items[i]);
            }

            // Shift elements left
            std.mem.copyForwards(T, row_data.items[0 .. row_data.items.len - effective_positions], row_data.items[effective_positions..]);

            // Move saved elements to end
            std.mem.copyForwards(T, row_data.items[row_data.items.len - effective_positions ..], temp.items);
        }
    };
}

test "Array2D reordering" {
    const allocator = std.testing.allocator;
    var array = Array2D(i32).init(allocator);
    defer array.deinit();

    try array.appendRow();
    try array.appendInRow(0, 1);
    try array.appendInRow(0, 2);
    try array.appendInRow(0, 3);

    try array.appendRow();
    try array.appendInRow(1, 1);
    try array.appendInRow(1, 2);

    try array.swapInRow(1, 0, 1);
    try std.testing.expectEqual(try array.get(1, 0), 2);
    try std.testing.expectEqual(try array.get(1, 1), 1);

    try array.swapInRow(0, 0, 2);
    try std.testing.expectEqual(try array.get(0, 0), 3);
    try std.testing.expectEqual(try array.get(0, 2), 1);

    try array.moveInRow(0, 0, 1);
    try std.testing.expectEqual(try array.get(0, 1), 3);

    try array.rotateRowLeft(0, 1);
    try std.testing.expectEqual(try array.get(0, 2), 2);
}
