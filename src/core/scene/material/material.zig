pub const Debug = @import("debug/material.zig").Material;
pub const Glass = @import("glass/material.zig").Material;
pub const Light = @import("light/material.zig").Material;
pub const Substitute = @import("substitute/material.zig").Material;
pub const Volumetric = @import("volumetric/material.zig").Material;
const Sky = @import("../../sky/material.zig").Material;
pub const Sample = @import("sample.zig").Sample;
pub const Base = @import("material_base.zig").Base;
const Gridtree = @import("volumetric/gridtree.zig").Gridtree;
const ccoef = @import("collision_coefficients.zig");
const CC = ccoef.CC;
const CCE = ccoef.CCE;
const Renderstate = @import("../renderstate.zig").Renderstate;
const Scene = @import("../scene.zig").Scene;
const Shape = @import("../shape/shape.zig").Shape;
const Trafo = @import("../composed_transformation.zig").ComposedTransformation;
const Worker = @import("../../rendering/worker.zig").Worker;
const image = @import("../../image/image.zig");
const Texture = @import("../../image/texture/texture.zig").Texture;
const ts = @import("../../image/texture/texture_sampler.zig");

const base = @import("base");
const math = base.math;
const Vec2f = math.Vec2f;
const Vec4f = math.Vec4f;
const Threads = base.thread.Pool;

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Material = union(enum) {
    Debug: Debug,
    Glass: Glass,
    Light: Light,
    Sky: Sky,
    Substitute: Substitute,
    Volumetric: Volumetric,

    pub fn deinit(self: *Material, alloc: Allocator) void {
        switch (self.*) {
            .Light => |*m| m.deinit(alloc),
            .Sky => |*m| m.deinit(alloc),
            .Volumetric => |*m| m.deinit(alloc),
            else => {},
        }
    }

    pub fn super(self: *const Material) *const Base {
        return switch (self.*) {
            inline else => |*m| &m.super,
        };
    }

    pub fn commit(self: *Material, alloc: Allocator, scene: *const Scene, threads: *Threads) !void {
        switch (self.*) {
            .Debug => {},
            .Volumetric => |*m| try m.commit(alloc, scene, threads),
            inline else => |*m| m.commit(),
        }
    }

    pub fn prepareSampling(
        self: *Material,
        alloc: Allocator,
        shape: *const Shape,
        part: u32,
        trafo: Trafo,
        extent: f32,
        scene: *const Scene,
        threads: *Threads,
    ) Vec4f {
        _ = part;
        _ = trafo;

        return switch (self.*) {
            .Light => |*m| m.prepareSampling(alloc, shape, extent, scene, threads),
            .Sky => |*m| m.prepareSampling(alloc, shape, scene, threads),
            .Substitute => |*m| m.prepareSampling(extent, scene),
            .Volumetric => |*m| m.prepareSampling(alloc, scene, threads),
            else => @splat(4, @as(f32, 0.0)),
        };
    }

    pub fn twoSided(self: *const Material) bool {
        return self.super().properties.two_sided;
    }

    pub fn caustic(self: *const Material) bool {
        return self.super().properties.caustic;
    }

    pub fn evaluateVisibility(self: *const Material) bool {
        return self.super().properties.evaluate_visibility;
    }

    pub fn emissive(self: *const Material) bool {
        return self.super().properties.emissive;
    }

    pub fn emissionMapped(self: *const Material) bool {
        return self.super().properties.emission_map;
    }

    pub fn pureEmissive(self: *const Material) bool {
        return switch (self.*) {
            .Light, .Sky => true,
            else => false,
        };
    }

    pub fn scatteringVolume(self: *const Material) bool {
        return self.super().properties.scattering_volume;
    }

    pub fn heterogeneousVolume(self: *const Material) bool {
        return switch (self.*) {
            .Volumetric => |*m| m.density_map.valid(),
            else => false,
        };
    }

    pub fn denseSSSOptimization(self: *const Material) bool {
        return self.super().properties.dense_sss_optimization;
    }

    pub fn volumetricTree(self: *const Material) ?Gridtree {
        return switch (self.*) {
            .Volumetric => |*m| if (m.density_map.valid()) m.tree else null,
            else => null,
        };
    }

    pub fn ior(self: *const Material) f32 {
        return self.super().ior;
    }

    pub fn collisionCoefficients(self: *const Material, uvw: Vec4f, filter: ?ts.Filter, scene: *const Scene) CC {
        const sup = self.super();
        const cc = sup.cc;

        switch (self.*) {
            .Volumetric => |*m| {
                const d = @splat(4, m.density(uvw, filter, scene));
                return .{ .a = d * cc.a, .s = d * cc.s };
            },
            else => {
                const color_map = sup.color_map;
                if (color_map.valid()) {
                    const key = ts.resolveKey(sup.sampler_key, filter);
                    const color = ts.sample2D_3(key, color_map, .{ uvw[0], uvw[1] }, scene);
                    return ccoef.scattering(cc.a, color, sup.volumetric_anisotropy);
                }

                return cc;
            },
        }
    }

    pub fn collisionCoefficientsEmission(self: *const Material, uvw: Vec4f, filter: ?ts.Filter, scene: *const Scene) CCE {
        const sup = self.super();
        const cc = sup.cc;

        switch (self.*) {
            .Volumetric => |*m| {
                return m.collisionCoefficientsEmission(uvw, filter, scene);
            },
            else => {
                const e = self.super().emittance.value;

                const color_map = sup.color_map;
                if (color_map.valid()) {
                    const key = ts.resolveKey(sup.sampler_key, filter);
                    const color = ts.sample2D_3(key, color_map, .{ uvw[0], uvw[1] }, scene);
                    return .{
                        .cc = ccoef.scattering(cc.a, color, sup.volumetric_anisotropy),
                        .e = e,
                    };
                }

                return .{ .cc = cc, .e = e };
            },
        }
    }

    pub fn sample(self: *const Material, wo: Vec4f, rs: Renderstate, worker: *const Worker) Sample {
        return switch (self.*) {
            .Debug => .{ .Debug = Debug.sample(wo, rs) },
            .Glass => |*g| .{ .Glass = g.sample(wo, rs, worker.scene) },
            .Light => .{ .Light = Light.sample(wo, rs) },
            .Sky => .{ .Light = Sky.sample(wo, rs) },
            .Substitute => |*s| s.sample(wo, rs, worker),
            .Volumetric => |*v| v.sample(wo, rs),
        };
    }

    pub fn evaluateRadiance(
        self: *const Material,
        shading_p: Vec4f,
        wi: Vec4f,
        n: Vec4f,
        uvw: Vec4f,
        trafo: Trafo,
        prop: u32,
        part: u32,
        filter: ?ts.Filter,
        scene: *const Scene,
    ) Vec4f {
        return switch (self.*) {
            .Light => |*m| m.evaluateRadiance(shading_p, wi, .{ uvw[0], uvw[1] }, trafo, prop, part, filter, scene),
            .Sky => |*m| m.evaluateRadiance(wi, .{ uvw[0], uvw[1] }, trafo, filter, scene),
            .Substitute => |*m| m.evaluateRadiance(shading_p, wi, n, .{ uvw[0], uvw[1] }, trafo, prop, part, filter, scene),
            .Volumetric => |*m| m.evaluateRadiance(uvw, scene),
            else => @splat(4, @as(f32, 0.0)),
        };
    }

    pub fn radianceSample(self: *const Material, r3: Vec4f) Base.RadianceSample {
        return switch (self.*) {
            .Light => |*m| m.radianceSample(r3),
            .Sky => |*m| m.radianceSample(r3),
            .Volumetric => |*m| m.radianceSample(r3),
            else => Base.RadianceSample.init3(r3, 1.0),
        };
    }

    pub fn emissionPdf(self: *const Material, uvw: Vec4f) f32 {
        return switch (self.*) {
            .Light => |*m| m.emissionPdf(.{ uvw[0], uvw[1] }),
            .Sky => |*m| m.emissionPdf(.{ uvw[0], uvw[1] }),
            .Volumetric => |*m| m.emissionPdf(uvw),
            else => 1.0,
        };
    }

    pub fn opacity(self: *const Material, uv: Vec2f, filter: ?ts.Filter, scene: *const Scene) f32 {
        return self.super().opacity(uv, filter, scene);
    }

    pub fn visibility(self: *const Material, wi: Vec4f, n: Vec4f, uv: Vec2f, filter: ?ts.Filter, scene: *const Scene) ?Vec4f {
        switch (self.*) {
            .Glass => |*m| {
                return m.visibility(wi, n, uv, filter, scene);
            },
            else => {
                const o = self.opacity(uv, filter, scene);
                return if (o < 1.0) @splat(4, 1.0 - o) else null;
            },
        }
    }

    pub fn usefulTexture(self: *const Material) ?Texture {
        switch (self.*) {
            .Light => |*m| {
                if (m.emission_map.valid()) {
                    return m.emission_map;
                }
            },
            .Sky => |*m| {
                if (m.emission_map.valid()) {
                    return m.emission_map;
                }
            },
            .Substitute => |*m| {
                if (m.emission_map.valid()) {
                    return m.emission_map;
                }
            },
            .Volumetric => |*m| {
                if (m.density_map.valid()) {
                    return m.density_map;
                }
            },
            else => {},
        }

        const color_map = self.super().color_map;
        return if (color_map.valid()) color_map else null;
    }
};
