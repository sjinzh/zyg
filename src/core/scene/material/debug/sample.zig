const Base = @import("../sample_base.zig").SampleBase;
const Renderstate = @import("../../renderstate.zig").Renderstate;
const bxdf = @import("../bxdf.zig");
const Sampler = @import("../../../sampler/sampler.zig").Sampler;

const base = @import("base");
const math = base.math;
const Vec4f = math.Vec4f;
const RNG = base.rnd.Generator;

pub const Sample = struct {
    super: Base,

    pub fn init(rs: Renderstate, wo: Vec4f, albedo: Vec4f) Sample {
        return .{ .super = Base.init(
            rs,
            wo,
            albedo,
            @splat(2, @as(f32, 1.0)),
            0.0,
        ) };
    }

    pub fn evaluate(self: *const Sample, wi: Vec4f) bxdf.Result {
        const n_dot_wi = self.super.frame.clampNdot(wi);
        const pdf = n_dot_wi * math.pi_inv;

        const reflection = @splat(4, pdf) * self.super.albedo;

        return bxdf.Result.init(reflection, pdf);
    }

    pub fn sample(self: *const Sample, sampler: *Sampler) bxdf.Sample {
        const s2d = sampler.sample2D();

        const is = math.smpl.hemisphereCosine(s2d);
        const wi = math.normalize3(self.super.frame.tangentToWorld(is));

        const n_dot_wi = self.super.frame.clampNdot(wi);
        const pdf = n_dot_wi * math.pi_inv;

        const reflection = @splat(4, pdf) * self.super.albedo;

        return .{
            .reflection = reflection,
            .wi = wi,
            .h = undefined,
            .pdf = pdf,
            .wavelength = 0.0,
            .h_dot_wi = undefined,
            .class = .{ .diffuse = true, .reflection = true },
        };
    }
};
