const Model = @import("model.zig").Model;
const Sky = @import("sky.zig").Sky;
const Base = @import("../scene/material/material_base.zig").Base;
const Sample = @import("../scene/material/light/sample.zig").Sample;
const Renderstate = @import("../scene/renderstate.zig").Renderstate;
const Emittance = @import("../scene/light/emittance.zig").Emittance;
const Scene = @import("../scene/scene.zig").Scene;
const Resources = @import("../resource/manager.zig").Manager;
const Shape = @import("../scene/shape/shape.zig").Shape;
const Trafo = @import("../scene/composed_transformation.zig").ComposedTransformation;
const ts = @import("../image/texture/texture_sampler.zig");
const Texture = @import("../image/texture/texture.zig").Texture;
const Image = @import("../image/image.zig").Image;

const base = @import("base");
const math = base.math;
const Vec2i = math.Vec2i;
const Vec2f = math.Vec2f;
const Vec4f = math.Vec4f;
const Mat3x3 = math.Mat3x3;
const Distribution1D = math.Distribution1D;
const Distribution2D = math.Distribution2D;
const Threads = base.thread.Pool;
const spectrum = base.spectrum;
const RNG = base.rnd.Generator;

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Material = struct {
    super: Base,

    emission_map: Texture,
    distribution: Distribution2D = .{},
    sun_radiance: math.InterpolatedFunction1D(Vec4f) = .{},
    average_emission: Vec4f = @splat(4, @as(f32, -1.0)),
    total_weight: f32 = undefined,

    pub fn initSky(emission_map: Texture) Material {
        return Material{
            .super = .{ .sampler_key = .{ .address = .{ .u = .Clamp, .v = .Clamp } } },
            .emission_map = emission_map,
        };
    }

    pub fn initSun(alloc: Allocator) !Material {
        return Material{
            .super = .{ .sampler_key = .{ .address = .{ .u = .Clamp, .v = .Clamp } } },
            .emission_map = .{},
            .sun_radiance = try math.InterpolatedFunction1D(Vec4f).init(alloc, 0.0, 1.0, 1024),
        };
    }

    pub fn deinit(self: *Material, alloc: Allocator) void {
        self.sun_radiance.deinit(alloc);
        self.distribution.deinit(alloc);
    }

    pub fn commit(self: *Material) void {
        self.super.properties.emissive = true;
        self.super.properties.emission_map = self.emission_map.valid();
    }

    pub fn setSunRadiance(self: *Material, rotation: Mat3x3, model: Model) void {
        const n = @intToFloat(f32, self.sun_radiance.samples.len - 1);

        var rng = RNG.init(0, 0);

        for (self.sun_radiance.samples, 0..) |*s, i| {
            const v = @intToFloat(f32, i) / n;
            var wi = sunWi(rotation, v);
            wi[1] = std.math.max(wi[1], 0.0);

            s.* = model.evaluateSkyAndSun(wi, &rng);
        }

        var total = @splat(4, @as(f32, 0.0));
        var tw: f32 = 0.0;
        var i: u32 = 0;
        while (i < self.sun_radiance.samples.len - 1) : (i += 1) {
            const s0 = self.sun_radiance.samples[i];
            const s1 = self.sun_radiance.samples[i + 1];

            const v = (@intToFloat(f32, i) + 0.5) / @intToFloat(f32, self.sun_radiance.samples.len);
            const wi = sunWi(rotation, v);

            const w = @sin(v);
            tw += w;

            if (wi[1] >= 0.0) {
                total += (s0 + s1) * @splat(4, 0.5 * w);
            }
        }

        self.average_emission = total / @splat(4, tw);
    }

    pub fn setSunRadianceZero(self: *Material) void {
        for (self.sun_radiance.samples) |*s| {
            s.* = @splat(4, @as(f32, 0.0));
        }

        self.average_emission = @splat(4, @as(f32, 0.0));
    }

    pub fn prepareSampling(
        self: *Material,
        alloc: Allocator,
        shape: *const Shape,
        scene: *const Scene,
        threads: *Threads,
    ) Vec4f {
        if (self.average_emission[0] >= 0.0) {
            // Hacky way to check whether prepare_sampling has been called before
            // average_emission_ is initialized with negative values...
            return self.average_emission;
        }

        var avg = @splat(4, @as(f32, 0.0));

        {
            const d = self.emission_map.description(scene).dimensions;
            const height = @intCast(u32, d[1]);

            var context = Context{
                .shape = shape,
                .image = scene.imagePtr(self.emission_map.image),
                .dimensions = .{ d[0], d[1] },
                .conditional = self.distribution.allocate(alloc, height) catch
                    return @splat(4, @as(f32, 0.0)),
                .averages = alloc.alloc(Vec4f, threads.numThreads()) catch
                    return @splat(4, @as(f32, 0.0)),
                .alloc = alloc,
            };

            defer alloc.free(context.averages);

            const num = threads.runRange(&context, Context.calculate, 0, height, 0);
            for (context.averages[0..num]) |a| {
                avg += a;
            }
        }

        const average_emission = avg / @splat(4, avg[3]);

        self.average_emission = average_emission;

        self.total_weight = avg[3];

        self.distribution.configure(alloc) catch
            return @splat(4, @as(f32, 0.0));

        return average_emission;
    }

    pub fn sample(wo: Vec4f, rs: Renderstate) Sample {
        var result = Sample.init(rs, wo);
        result.super.frame.setTangentFrame(rs.t, rs.b, rs.n);
        return result;
    }

    pub fn evaluateRadiance(
        self: *const Material,
        wi: Vec4f,
        uv: Vec2f,
        trafo: Trafo,
        filter: ?ts.Filter,
        scene: *const Scene,
    ) Vec4f {
        if (self.emission_map.valid()) {
            const key = ts.resolveKey(self.super.sampler_key, filter);
            return ts.sample2D_3(key, self.emission_map, uv, scene);
        }

        return self.sun_radiance.eval(sunV(trafo.rotation, wi));
    }

    fn sunWi(rotation: Mat3x3, v: f32) Vec4f {
        const y = (2.0 * v) - 1.0;

        const ls = Vec4f{ 0.0, y * Sky.Radius, 0.0, 0.0 };
        const ws = rotation.transformVector(ls);

        return math.normalize3(ws - rotation.r[2]);
    }

    fn sunV(rotation: Mat3x3, wi: Vec4f) f32 {
        const k = wi - rotation.r[2];
        const c = math.dot3(rotation.r[1], k) / Sky.Radius;
        return std.math.max((c + 1.0) * 0.5, 0.0);
    }

    pub fn radianceSample(self: *const Material, r3: Vec4f) Base.RadianceSample {
        const result = self.distribution.sampleContinuous(.{ r3[0], r3[1] });

        return Base.RadianceSample.init2(result.uv, result.pdf * self.total_weight);
    }

    pub fn emissionPdf(self: *const Material, uv: Vec2f) f32 {
        if (self.emission_map.valid()) {
            return self.distribution.pdf(self.super.sampler_key.address.address2(uv)) * self.total_weight;
        }

        return 1.0;
    }
};

const Context = struct {
    shape: *const Shape,
    image: *const Image,
    dimensions: Vec2i,
    conditional: []Distribution1D,
    averages: []Vec4f,
    alloc: Allocator,

    pub fn calculate(context: Threads.Context, id: u32, begin: u32, end: u32) void {
        const self = @intToPtr(*Context, context);

        const d = self.dimensions;

        var luminance = self.alloc.alloc(f32, @intCast(usize, d[0])) catch return;
        defer self.alloc.free(luminance);

        const idf = @splat(2, @as(f32, 1.0)) / math.vec2iTo2f(d);

        var avg = @splat(4, @as(f32, 0.0));

        var y = begin;
        while (y < end) : (y += 1) {
            const v = idf[1] * (@intToFloat(f32, y) + 0.5);

            var x: u32 = 0;
            while (x < d[0]) : (x += 1) {
                const u = idf[0] * (@intToFloat(f32, x) + 0.5);
                const uv_weight = self.shape.uvWeight(.{ u, v });

                const li = math.vec3fTo4f(self.image.Float3.get2D(@intCast(i32, x), @intCast(i32, y)));
                const wli = @splat(4, uv_weight) * li;

                avg += Vec4f{ wli[0], wli[1], wli[2], uv_weight };

                luminance[x] = spectrum.luminance(wli);
            }

            self.conditional[y].configure(self.alloc, luminance, 0) catch {};
        }

        self.averages[id] = avg;
    }
};
