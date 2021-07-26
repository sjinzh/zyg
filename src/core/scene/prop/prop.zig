pub const Intersection = @import("intersection.zig").Intersection;

const base = @import("base");
usingnamespace base;

//const Vec4f = base.math.Vec4f;
const Ray = base.math.Ray;

const Scene = @import("../scene.zig").Scene;

const shp = @import("../shape/intersection.zig");

pub const Null = 0xFFFFFFFF;

pub const Prop = struct {
    shape: u32 = Null,

    pub fn configure(self: *Prop, shape: u32) void {
        self.shape = shape;
    }

    pub fn intersect(
        self: Prop,
        entity: usize,
        ray: *Ray,
        scene: Scene,
        isec: *shp.Intersection,
    ) bool {
        _ = self;

        const trafo = scene.propTransformationAt(entity);

        return scene.propShape(entity).intersect(ray, trafo, isec);
    }
};
