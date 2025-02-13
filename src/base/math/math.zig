pub const aabb = @import("aabb.zig");
pub const AABB = aabb.AABB;
pub const cone = @import("cone.zig");
pub usingnamespace @import("distribution_1d.zig");
pub usingnamespace @import("distribution_2d.zig");
pub usingnamespace @import("distribution_3d.zig");
pub usingnamespace @import("interpolated_function.zig");
pub const quaternion = @import("quaternion.zig");
pub const Quaternion = quaternion.Quaternion;
pub usingnamespace @import("matrix3x3.zig");
pub usingnamespace @import("matrix4x4.zig");
pub usingnamespace @import("ray.zig");
pub usingnamespace @import("sample_distribution.zig");
pub const smpl = @import("sampling.zig");
pub usingnamespace @import("transformation.zig");
const vec2 = @import("vector2.zig");
pub usingnamespace vec2;
pub usingnamespace @import("vector3.zig");
const vec4 = @import("vector4.zig");
pub usingnamespace vec4;
pub const plane = @import("plane.zig");

const std = @import("std");

pub const pi_inv = 1.0 / std.math.pi;

pub fn degreesToRadians(degrees: anytype) @TypeOf(degrees) {
    return degrees * (std.math.pi / 180.0);
}

pub fn radiansToDegrees(radians: anytype) @TypeOf(radians) {
    return radians * (180.0 / std.math.pi);
}

pub inline fn saturate(x: f32) f32 {
    return std.math.clamp(x, 0.0, 1.0);
}

pub inline fn lerp(a: anytype, b: anytype, t: f32) @TypeOf(a, b) {
    switch (@typeInfo(@TypeOf(a))) {
        .Float => {
            const u = 1.0 - t;
            return @mulAdd(f32, u, a, t * b);
        },
        .Vector => |v| {
            const l = comptime v.len;
            const u = 1.0 - t;
            return @mulAdd(@TypeOf(a), @splat(l, u), a, @splat(l, t) * b);
        },
        else => comptime unreachable,
    }
}

pub inline fn frac(x: anytype) @TypeOf(x) {
    return x - @floor(x);
}

pub fn pow2(x: f32) f32 {
    return x * x;
}

pub fn pow5(x: f32) f32 {
    const x2 = x * x;
    const x4 = x2 * x2;
    return x4 * x;
}

pub inline fn bilinear(comptime T: type, c: [4]T, s: f32, t: f32) T {
    switch (@typeInfo(T)) {
        .Float => {
            const _s = 1.0 - s;
            const _t = 1.0 - t;

            return _t * (_s * c[0] + s * c[1]) + t * (_s * c[2] + s * c[3]);
        },
        .Vector => |v| {
            const l = comptime v.len;

            const vs = @splat(l, s);
            const vt = @splat(l, t);

            const _s = @splat(l, @as(f32, 1.0)) - vs;
            const _t = @splat(l, @as(f32, 1.0)) - vt;

            return _t * (_s * c[0] + vs * c[1]) + vt * (_s * c[2] + vs * c[3]);
        },
        else => comptime unreachable,
    }
}

pub fn cubic1(c: *const [4]f32, t: f32) f32 {
    const t2 = t * t;
    const a0 = c[3] - c[2] - c[0] + c[1];
    const a1 = c[0] - c[1] - a0;
    const a2 = c[2] - c[0];
    const a3 = c[1];

    return a0 * t * t2 + a1 * t2 + a2 * t + a3;
}

pub fn bicubic1(c: [16]f32, s: f32, t: f32) f32 {
    const d: [4]f32 = .{
        cubic1(c[0..4], s),
        cubic1(c[4..8], s),
        cubic1(c[8..12], s),
        cubic1(c[12..16], s),
    };

    return cubic1(&d, t);
}

pub fn roundUp(comptime T: type, x: T, m: T) T {
    return ((x + m - 1) / m) * m;
}

pub inline fn solidAngleCone(c: f32) f32 {
    return (2.0 * std.math.pi) * (1.0 - c);
}
