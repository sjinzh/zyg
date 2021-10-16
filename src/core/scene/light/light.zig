const Scene = @import("../scene.zig").Scene;
const Sampler = @import("../../sampler/sampler.zig").Sampler;
const Worker = @import("../worker.zig").Worker;
const Ray = @import("../ray.zig").Ray;
const Prop = @import("../prop/prop.zig").Prop;
const Intersection = @import("../prop/intersection.zig").Intersection;
const Filter = @import("../../image/texture/sampler.zig").Filter;
const shp = @import("../shape/sample.zig");
const SampleTo = shp.To;
const Transformation = @import("../composed_transformation.zig").ComposedTransformation;
const base = @import("base");
const math = base.math;
const AABB = math.AABB;
const Vec4f = math.Vec4f;
const Threads = base.thread.Pool;

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Light = packed struct {
    pub const Type = enum(u8) {
        Prop,
        PropImage,
        Volume,
        VolumeImage,
    };

    typef: Type,
    two_sided: bool,
    variant: u16 = undefined,
    prop: u32,
    part: u32,
    extent: f32 = undefined,

    pub fn isLight(id: u32) bool {
        return Prop.Null != id;
    }

    pub fn prepareSampling(
        self: Light,
        alloc: *Allocator,
        light_id: usize,
        time: u64,
        scene: *Scene,
        threads: *Threads,
    ) void {
        scene.propPrepareSampling(alloc, self.prop, self.part, light_id, time, threads);
    }

    pub fn power(self: Light, average_radiance: Vec4f, scene_bb: AABB, scene: Scene) Vec4f {
        const extent = if (self.two_sided) 2.0 * self.extent else self.extent;

        const radiance = @splat(4, extent) * average_radiance;

        if (scene.propShape(self.prop).isFinite()) {
            return radiance;
        }

        return @splat(4, math.squaredLength3(scene_bb.extent())) * radiance;
    }

    pub fn sampleTo(
        self: Light,
        p: Vec4f,
        n: Vec4f,
        time: u64,
        total_sphere: bool,
        sampler: *Sampler,
        sampler_d: usize,
        worker: *Worker,
    ) ?SampleTo {
        const trafo = worker.scene.propTransformationAt(self.prop, time);

        return switch (self.typef) {
            .Prop => self.propSampleTo(
                p,
                n,
                trafo,
                total_sphere,
                sampler,
                sampler_d,
                worker,
            ),
            .PropImage => self.propImageSampleTo(
                p,
                n,
                trafo,
                total_sphere,
                sampler,
                sampler_d,
                worker,
            ),
            else => null,
        };
    }

    pub fn evaluateTo(self: Light, sample: SampleTo, filter: ?Filter, worker: Worker) Vec4f {
        const material = worker.scene.propMaterial(self.prop, self.part);

        return material.evaluateRadiance(sample.wi, sample.n, sample.uvw, self.extent, filter, worker);
    }

    pub fn pdf(self: Light, ray: Ray, n: Vec4f, isec: Intersection, total_sphere: bool, worker: Worker) f32 {
        const trafo = worker.scene.propTransformationAt(self.prop, ray.time);

        return switch (self.typef) {
            .Prop => self.propPdf(ray, n, isec, trafo, total_sphere, worker),
            .PropImage => self.propImagePdf(ray, isec, trafo, worker),
            else => 0.0,
        };
    }

    fn propSampleTo(
        self: Light,
        p: Vec4f,
        n: Vec4f,
        trafo: Transformation,
        total_sphere: bool,
        sampler: *Sampler,
        sampler_d: usize,
        worker: *Worker,
    ) ?SampleTo {
        const shape = worker.scene.propShape(self.prop);
        const result = shape.sampleTo(
            self.part,
            self.variant,
            p,
            n,
            trafo,
            self.extent,
            self.two_sided,
            total_sphere,
            sampler,
            &worker.rng,
            sampler_d,
        ) orelse return null;

        if (math.dot3(result.wi, n) > 0.0 or total_sphere) {
            return result;
        }

        return null;
    }

    fn propImageSampleTo(
        self: Light,
        p: Vec4f,
        n: Vec4f,
        trafo: Transformation,
        total_sphere: bool,
        sampler: *Sampler,
        sampler_d: usize,
        worker: *Worker,
    ) ?SampleTo {
        const s2d = sampler.sample2D(&worker.rng, sampler_d);

        const material = worker.scene.propMaterial(self.prop, self.part);
        const rs = material.radianceSample(.{ s2d[0], s2d[1], 0.0, 0.0 });
        if (0.0 == rs.pdf()) {
            return null;
        }

        const shape = worker.scene.propShape(self.prop);
        // this pdf includes the uv weight which adjusts for texture distortion by the shape
        var result = shape.sampleToUv(
            self.part,
            p,
            .{ rs.uvw[0], rs.uvw[1] },
            trafo,
            self.extent,
            self.two_sided,
        ) orelse return null;

        result.mulAssignPdf(rs.pdf());

        if (math.dot3(result.wi, n) > 0.0 or total_sphere) {
            return result;
        }

        return null;
    }

    fn propPdf(
        self: Light,
        ray: Ray,
        n: Vec4f,
        isec: Intersection,
        trafo: Transformation,
        total_sphere: bool,
        worker: Worker,
    ) f32 {
        const two_sided = isec.material(worker).isTwoSided();

        return isec.shape(worker).pdf(
            self.variant,
            ray,
            n,
            isec.geo,
            trafo,
            self.extent,
            two_sided,
            total_sphere,
        );
    }

    fn propImagePdf(self: Light, ray: Ray, isec: Intersection, trafo: Transformation, worker: Worker) f32 {
        const material = isec.material(worker);
        const two_sided = material.isTwoSided();

        const uv = isec.geo.uv;
        const material_pdf = material.emissionPdf(.{ uv[0], uv[1], 0.0, 0.0 });

        // this pdf includes the uv weight which adjusts for texture distortion by the shape
        const shape_pdf = isec.shape(worker).pdfUv(ray, isec.geo, trafo, self.extent, two_sided);

        return material_pdf * shape_pdf;
    }
};
