const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Allocator = std.mem.Allocator;

const Card = @This();

pub fn widget(self: *const Card) vxfw.Widget {
    return .{
        .userdata = @constCast(self),
        .eventHandler = vxfw.noopEventHandler,
        .drawFn = typeErasedDrawFn,
    };
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *const Card = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn draw(self: *const Card, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    //
}
