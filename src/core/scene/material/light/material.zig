const Base = @import("../material_base.zig").Base;
const Sample = @import("sample.zig").Sample;
const Renderstate = @import("../../renderstate.zig").Renderstate;
const Emittance = @import("../../light/emittance.zig").Emittance;
const Worker = @import("../../worker.zig").Worker;
const Scene = @import("../../scene.zig").Scene;
const Shape = @import("../../shape/shape.zig").Shape;
const Transformation = @import("../../composed_transformation.zig").ComposedTransformation;
const ts = @import("../../../image/texture/sampler.zig");
const Texture = @import("../../../image/texture/texture.zig").Texture;
const math = @import("base").math;
const Vec4f = math.Vec4f;
const Distribution2D = math.Distribution1D;

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Material = struct {
    super: Base,

    emission_map: Texture = undefined,
    distribution: Distribution2D = .{},
    emittance: Emittance = undefined,
    average_emission: Vec4f = undefined,
    emission_factor: f32 = undefined,
    total_weight: f32 = undefined,

    pub fn init(sampler_key: ts.Key, two_sided: bool) Material {
        return .{ .super = Base.init(sampler_key, two_sided) };
    }

    pub fn deinit(self: *Material, alloc: *Allocator) void {
        self.distribution.deinit(alloc);
    }

    pub fn commit(self: *Material) void {
        self.super.properties.set(.EmissionMap, self.emission_map.isValid());
    }

    pub fn prepareSampling(self: *Material, shape: Shape, area: f32, scene: Scene) Vec4f {
        _ = shape;
        _ = scene;

        return self.emittance.radiance(area);
    }

    pub fn sample(self: Material, wo: Vec4f, rs: Renderstate, worker: *Worker) Sample {
        var radiance: Vec4f = undefined;

        if (self.emission_map.isValid()) {
            const key = ts.resolveKey(self.super.sampler_key, rs.filter);

            const ef = @splat(4, self.emission_factor);
            radiance = ef * ts.sample2D_3(key, self.emission_map, rs.uv, worker.scene);
        } else {
            radiance = self.emittance.radiance(worker.scene.lightArea(rs.prop, rs.part));
        }

        var result = Sample.init(rs, wo, radiance);
        result.super.layer.setTangentFrame(rs.t, rs.b, rs.n);
        return result;
    }

    pub fn evaluateRadiance(self: Material, extent: f32) Vec4f {
        return self.emittance.radiance(extent);
    }
};
