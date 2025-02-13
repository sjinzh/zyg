const core = @import("core");
const scn = core.scn;

const base = @import("base");
const math = base.math;
const Pack4f = math.Pack4f;
const Threads = base.thread.Pool;

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Operator = struct {
    pub const Class = enum {
        Add,
        Average,
        Diff,
        Over,
        Tonemap,
    };

    class: Class,

    textures: std.ArrayListUnmanaged(core.tx.Texture) = .{},
    input_ids: std.ArrayListUnmanaged(u32) = .{},
    target: core.image.Float4 = .{},
    tonemapper: core.Tonemapper,
    scene: *const scn.Scene,
    current: u32 = 0,

    const Self = @This();

    pub fn configure(self: *Self, alloc: Allocator) !void {
        if (0 == self.textures.items.len) {
            return;
        }

        const desc = self.textures.items[0].description(self.scene);

        try self.target.resize(alloc, desc);
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        self.input_ids.deinit(alloc);
        self.textures.deinit(alloc);
    }

    pub fn iterations(self: Self) u32 {
        return switch (self.class) {
            .Diff => @intCast(u32, self.textures.items.len - 1),
            .Tonemap => @intCast(u32, self.textures.items.len),
            else => 1,
        };
    }

    pub fn run(self: Self, threads: *Threads) void {
        const texture = self.textures.items[self.current];

        const dim = texture.description(self.scene).dimensions;

        _ = threads.runRange(&self, runRange, 0, @intCast(u32, dim[1]), 0);
    }

    fn runRange(context: Threads.Context, id: u32, begin: u32, end: u32) void {
        _ = id;

        var self = @intToPtr(*Self, context);

        if (.Diff == self.class) {
            const texture_a = self.textures.items[0];
            const texture_b = self.textures.items[self.current + 1];

            const dim = texture_a.description(self.scene).dimensions;
            const width = dim[0];

            var y = begin;
            while (y < end) : (y += 1) {
                const iy = @intCast(i32, y);

                var x: u32 = 0;
                while (x < width) : (x += 1) {
                    const ix = @intCast(i32, x);

                    const color_a = texture_a.get2D_4(ix, iy, self.scene);
                    const color_b = texture_b.get2D_4(ix, iy, self.scene);

                    const dif = @fabs(color_a - color_b);

                    self.target.set2D(ix, iy, Pack4f.init4(dif[0], dif[1], dif[2], dif[3]));
                }
            }
        } else {
            const current = self.current;
            const texture = self.textures.items[current];

            const dim = texture.description(self.scene).dimensions;
            const width = dim[0];

            const factor = @splat(4, if (.Average == self.class) 1.0 / @intToFloat(f32, self.textures.items.len) else 1.0);

            var y = begin;
            while (y < end) : (y += 1) {
                const iy = @intCast(i32, y);

                var x: u32 = 0;
                while (x < width) : (x += 1) {
                    const ix = @intCast(i32, x);

                    const source = texture.get2D_4(ix, iy, self.scene);

                    const color = switch (self.class) {
                        .Add, .Average => blk: {
                            var color = factor * source;

                            for (self.textures.items[current + 1 ..]) |t| {
                                const other = t.get2D_4(ix, iy, self.scene);
                                color += factor * other;
                            }

                            break :blk color;
                        },
                        .Over => blk: {
                            var color = source;

                            for (self.textures.items[current + 1 ..]) |t| {
                                const other = t.get2D_4(ix, iy, self.scene);
                                color += other * @splat(4, 1.0 - color[3]);
                            }

                            break :blk color;
                        },
                        .Tonemap => source,
                        else => unreachable,
                    };

                    const tm = self.tonemapper.tonemap(color);
                    self.target.set2D(ix, iy, Pack4f.init4(tm[0], tm[1], tm[2], color[3]));
                }
            }
        }
    }
};
