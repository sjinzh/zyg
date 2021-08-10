pub const Plane = @import("plane.zig").Plane;
pub const Rectangle = @import("rectangle.zig").Rectangle;
pub const Sphere = @import("sphere.zig").Sphere;
pub const Triangle_mesh = @import("triangle/mesh.zig").Mesh;
const Intersection = @import("intersection.zig").Intersection;
const Transformation = @import("../composed_transformation.zig").Composed_transformation;

const base = @import("base");
usingnamespace base;

const AABB = math.AABB;
const Vec4f = base.math.Vec4f;
const Ray = math.Ray;

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Shape = union(enum) {
    Null,
    Plane: Plane,
    Rectangle: Rectangle,
    Sphere: Sphere,
    Triangle_mesh: Triangle_mesh,

    pub fn deinit(self: *Shape, alloc: *Allocator) void {
        switch (self.*) {
            .Triangle_mesh => |*m| m.deinit(alloc),
            else => {},
        }
    }

    pub fn isComplex(self: Shape) bool {
        return switch (self) {
            .Triangle_mesh => true,
            else => false,
        };
    }

    pub fn aabb(self: Shape) AABB {
        return switch (self) {
            .Null, .Plane => math.aabb.empty,
            .Rectangle => AABB.init(Vec4f.init3(-1.0, -1.0, -0.01), Vec4f.init3(1.0, 1.0, 0.01)),
            .Sphere => AABB.init(Vec4f.init1(-1.0), Vec4f.init1(1.0)),
            .Triangle_mesh => |m| m.tree.aabb(),
        };
    }

    pub fn intersect(self: Shape, ray: *Ray, trafo: Transformation, isec: *Intersection) bool {
        return switch (self) {
            .Null => false,
            .Plane => Plane.intersect(ray, trafo, isec),
            .Rectangle => Rectangle.intersect(ray, trafo, isec),
            .Sphere => Sphere.intersect(ray, trafo, isec),
            .Triangle_mesh => |m| m.intersect(ray, trafo, isec),
        };
    }

    pub fn intersectP(self: Shape, ray: Ray, trafo: Transformation) bool {
        return switch (self) {
            .Null => false,
            .Plane => Plane.intersectP(ray, trafo),
            .Rectangle => Rectangle.intersectP(ray, trafo),
            .Sphere => Sphere.intersectP(ray, trafo),
            .Triangle_mesh => |m| m.intersectP(ray, trafo),
        };
    }
};
