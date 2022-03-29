const base = @import("base");
const math = base.math;
const Vec4f = math.Vec4f;

const std = @import("std");

pub const Value = struct {
    pub const Class = enum(u5) {
        Albedo,
        Depth,
        MaterialId,
        ShadingNormal,

        pub fn default(class: Class) Vec4f {
            return switch (class) {
                .Depth => @splat(4, @as(f32, std.math.f32_max)),
                .ShadingNormal => @splat(4, @as(f32, -1.0)),
                else => @splat(4, @as(f32, 0.0)),
            };
        }
    };

    pub const Num_classes = @typeInfo(Class).Enum.fields.len;

    slots: u32,

    values: [Num_classes]Vec4f = undefined,

    pub fn active(self: Value) bool {
        return 0 != self.slots;
    }

    pub fn activeClass(self: Value, class: Class) bool {
        const bit = @as(u32, 1) << @enumToInt(class);
        return 0 != (self.slots & bit);
    }

    pub fn clear(self: *Value) void {
        if (0 == self.slots) {
            return;
        }

        var i: u5 = 0;
        while (i < Num_classes) : (i += 1) {
            const bit = @as(u32, 1) << i;
            if (0 != (self.slots & bit)) {
                self.values[i] = @intToEnum(Class, i).default();
            }
        }
    }

    pub fn insert3(self: *Value, class: Class, value: Vec4f) void {
        self.values[@enumToInt(class)] = value;
    }

    pub fn insert1(self: *Value, class: Class, value: f32) void {
        self.values[@enumToInt(class)][0] = value;
    }
};

pub const Factory = struct {
    slots: u32 = 0,

    pub fn create(self: Factory) Value {
        return .{ .slots = self.slots };
    }

    pub fn activeClass(self: Factory, class: Value.Class) bool {
        const bit = @as(u32, 1) << @enumToInt(class);
        return 0 != (self.slots & bit);
    }

    pub fn set(self: *Factory, class: Value.Class, value: bool) void {
        const bit = @as(u32, 1) << @enumToInt(class);

        if (value) {
            self.slots |= bit;
        } else {
            self.slots &= ~bit;
        }
    }
};
