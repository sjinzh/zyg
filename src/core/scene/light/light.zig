const Scene = @import("../scene.zig").Scene;
const Sampler = @import("../../sampler/sampler.zig").Sampler;
const Ray = @import("../ray.zig").Ray;
const Prop = @import("../prop/prop.zig").Prop;
const Intersection = @import("../prop/intersection.zig").Intersection;
const Filter = @import("../../image/texture/texture_sampler.zig").Filter;
const shp = @import("../shape/sample.zig");
const SampleTo = shp.To;
const SampleFrom = shp.From;
const Trafo = @import("../composed_transformation.zig").ComposedTransformation;

const base = @import("base");
const math = base.math;
const AABB = math.AABB;
const Vec2f = math.Vec2f;
const Vec4f = math.Vec4f;
const Threads = base.thread.Pool;

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Light = struct {
    pub const Volume_mask: u32 = 0x10000000;

    pub const Class = enum(u8) {
        Prop,
        PropImage,
        Volume,
        VolumeImage,
    };

    class: Class align(16),
    two_sided: bool,
    prop: u32,
    part: u32,
    variant: u32 = undefined,

    pub fn isLight(id: u32) bool {
        return Prop.Null != id;
    }

    pub fn isAreaLight(id: u32) bool {
        return 0 == (id & Volume_mask);
    }

    pub fn stripMask(id: u32) u32 {
        return ~Volume_mask & id;
    }

    pub fn finite(self: Light, scene: *const Scene) bool {
        return scene.propShape(self.prop).finite();
    }

    pub fn volumetric(self: Light) bool {
        return switch (self.class) {
            .Volume, .VolumeImage => true,
            else => false,
        };
    }

    pub fn power(self: Light, average_radiance: Vec4f, extent: f32, scene_bb: AABB, scene: *const Scene) Vec4f {
        const radiance = @splat(4, extent) * average_radiance;

        if (scene.propShape(self.prop).finite() or scene_bb.empty()) {
            return radiance;
        }

        return @splat(4, math.squaredLength3(scene_bb.extent())) * radiance;
    }

    pub fn sampleTo(self: Light, p: Vec4f, n: Vec4f, time: u64, total_sphere: bool, sampler: *Sampler, scene: *const Scene) ?SampleTo {
        const trafo = scene.propTransformationAt(self.prop, time);

        return switch (self.class) {
            .Prop => self.propSampleTo(
                p,
                n,
                trafo,
                total_sphere,
                sampler,
                scene,
            ),
            .PropImage => self.propImageSampleTo(
                p,
                n,
                trafo,
                total_sphere,
                sampler,
                scene,
            ),
            .Volume => self.volumeSampleTo(
                p,
                n,
                trafo,
                total_sphere,
                sampler,
                scene,
            ),
            .VolumeImage => self.volumeImageSampleTo(
                p,
                n,
                trafo,
                total_sphere,
                sampler,
                scene,
            ),
        };
    }

    pub fn sampleFrom(self: Light, time: u64, sampler: *Sampler, bounds: AABB, scene: *const Scene) ?SampleFrom {
        const trafo = scene.propTransformationAt(self.prop, time);

        return switch (self.class) {
            .Prop => self.propSampleFrom(trafo, sampler, bounds, scene),
            .PropImage => self.propImageSampleFrom(trafo, sampler, bounds, scene),
            .VolumeImage => self.volumeImageSampleFrom(trafo, sampler, scene),
            else => null,
        };
    }

    pub fn evaluateTo(self: Light, p: Vec4f, sample: SampleTo, filter: ?Filter, scene: *const Scene) Vec4f {
        const material = scene.propMaterial(self.prop, self.part);
        return material.evaluateRadiance(p, sample.wi, sample.n, sample.uvw, sample.trafo, self.prop, self.part, filter, scene);
    }

    pub fn evaluateFrom(self: Light, p: Vec4f, sample: SampleFrom, filter: ?Filter, scene: *const Scene) Vec4f {
        const material = scene.propMaterial(self.prop, self.part);
        return material.evaluateRadiance(p, -sample.dir, sample.n, sample.uvw, sample.trafo, self.prop, self.part, filter, scene);
    }

    pub fn pdf(self: Light, ray: Ray, n: Vec4f, isec: Intersection, total_sphere: bool, scene: *const Scene) f32 {
        return switch (self.class) {
            .Prop => scene.propShape(self.prop).pdf(
                self.part,
                self.variant,
                ray,
                n,
                isec.geo,
                self.two_sided,
                total_sphere,
            ),
            .PropImage => self.propImagePdf(ray, isec, scene),
            .Volume => scene.propShape(self.prop).volumePdf(ray, isec.geo),
            .VolumeImage => self.volumeImagePdf(ray, isec, scene),
        };
    }

    fn propSampleTo(
        self: Light,
        p: Vec4f,
        n: Vec4f,
        trafo: Trafo,
        total_sphere: bool,
        sampler: *Sampler,
        scene: *const Scene,
    ) ?SampleTo {
        const shape = scene.propShape(self.prop);
        const result = shape.sampleTo(
            self.part,
            self.variant,
            p,
            n,
            trafo,
            self.two_sided,
            total_sphere,
            sampler,
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
        trafo: Trafo,
        total_sphere: bool,
        sampler: *Sampler,
        scene: *const Scene,
    ) ?SampleTo {
        const s2 = sampler.sample2D();

        const material = scene.propMaterial(self.prop, self.part);
        const rs = material.radianceSample(.{ s2[0], s2[1], 0.0, 0.0 });
        if (0.0 == rs.pdf()) {
            return null;
        }

        const shape = scene.propShape(self.prop);

        // this pdf includes the uv weight which adjusts for texture distortion by the shape
        var result = shape.sampleToUv(
            self.part,
            p,
            .{ rs.uvw[0], rs.uvw[1] },
            trafo,
            self.two_sided,
        ) orelse return null;

        result.mulAssignPdf(rs.pdf());

        if (math.dot3(result.wi, n) > 0.0 or total_sphere) {
            return result;
        }

        return null;
    }

    fn propSampleFrom(self: Light, trafo: Trafo, sampler: *Sampler, bounds: AABB, scene: *const Scene) ?SampleFrom {
        const s4 = sampler.sample4D();

        const uv = Vec2f{ s4[0], s4[1] };
        const importance_uv = Vec2f{ s4[2], s4[3] };

        const cos_a = scene.propMaterial(self.prop, self.part).super().emittance.cos_a;

        const shape = scene.propShape(self.prop);
        return shape.sampleFrom(
            self.part,
            self.variant,
            trafo,
            cos_a,
            self.two_sided,
            sampler,
            uv,
            importance_uv,
            bounds,
            false,
        );
    }

    fn propImageSampleFrom(self: Light, trafo: Trafo, sampler: *Sampler, bounds: AABB, scene: *const Scene) ?SampleFrom {
        const s4 = sampler.sample4D();

        const material = scene.propMaterial(self.prop, self.part);
        const rs = material.radianceSample(.{ s4[0], s4[1], 0.0, 0.0 });
        if (0.0 == rs.pdf()) {
            return null;
        }

        const importance_uv = Vec2f{ s4[2], s4[3] };

        const cos_a = scene.propMaterial(self.prop, self.part).super().emittance.cos_a;

        const shape = scene.propShape(self.prop);

        // this pdf includes the uv weight which adjusts for texture distortion by the shape
        var result = shape.sampleFrom(
            self.part,
            self.variant,
            trafo,
            cos_a,
            self.two_sided,
            sampler,
            .{ rs.uvw[0], rs.uvw[1] },
            importance_uv,
            bounds,
            true,
        ) orelse return null;

        result.mulAssignPdf(rs.pdf());

        return result;
    }

    fn volumeSampleTo(self: Light, p: Vec4f, n: Vec4f, trafo: Trafo, total_sphere: bool, sampler: *Sampler, scene: *const Scene) ?SampleTo {
        const shape = scene.propShape(self.prop);
        const result = shape.sampleVolumeTo(
            self.part,
            p,
            trafo,
            sampler,
        ) orelse return null;

        if (math.dot3(result.wi, n) > 0.0 or total_sphere) {
            return result;
        }

        return null;
    }

    fn volumeImageSampleTo(self: Light, p: Vec4f, n: Vec4f, trafo: Trafo, total_sphere: bool, sampler: *Sampler, scene: *const Scene) ?SampleTo {
        const material = scene.propMaterial(self.prop, self.part);
        const rs = material.radianceSample(sampler.sample3D());
        if (0.0 == rs.pdf()) {
            return null;
        }

        const shape = scene.propShape(self.prop);
        var result = shape.sampleVolumeToUvw(
            self.part,
            p,
            rs.uvw,
            trafo,
        ) orelse return null;

        if (math.dot3(result.wi, n) > 0.0 or total_sphere) {
            result.mulAssignPdf(rs.pdf());
            return result;
        }

        return null;
    }

    fn volumeImageSampleFrom(self: Light, trafo: Trafo, sampler: *Sampler, scene: *const Scene) ?SampleFrom {
        const material = scene.propMaterial(self.prop, self.part);
        const rs = material.radianceSample(sampler.sample3D());
        if (0.0 == rs.pdf()) {
            return null;
        }

        const importance_uv = sampler.sample2D();

        const shape = scene.propShape(self.prop);
        var result = shape.sampleVolumeFromUvw(
            self.part,
            rs.uvw,
            trafo,
            importance_uv,
        ) orelse return null;

        result.mulAssignPdf(rs.pdf());

        return result;
    }

    fn propImagePdf(self: Light, ray: Ray, isec: Intersection, scene: *const Scene) f32 {
        const uv = isec.geo.uv;
        const material_pdf = isec.material(scene).emissionPdf(.{ uv[0], uv[1], 0.0, 0.0 });

        // this pdf includes the uv weight which adjusts for texture distortion by the shape
        const shape_pdf = scene.propShape(self.prop).pdfUv(ray, isec.geo, self.two_sided);

        return material_pdf * shape_pdf;
    }

    fn volumeImagePdf(self: Light, ray: Ray, isec: Intersection, scene: *const Scene) f32 {
        const material_pdf = isec.material(scene).emissionPdf(isec.geo.p);
        const shape_pdf = scene.propShape(self.prop).volumePdf(ray, isec.geo);

        return material_pdf * shape_pdf;
    }
};
