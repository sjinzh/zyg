const Ray = @import("../../../scene/ray.zig").Ray;
const Worker = @import("../../worker.zig").Worker;
const Intersection = @import("../../../scene/prop/intersection.zig").Intersection;
const Filter = @import("../../../image/texture/sampler.zig").Filter;
const scn = @import("../../../scene/constants.zig");
const sampler = @import("../../../sampler/sampler.zig");
const math = @import("base").math;
const Vec4f = math.Vec4f;

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Pathtracer = struct {
    const Num_dedicated_samplers = 3;

    pub const Settings = struct {
        num_samples: u32,
        min_bounces: u32,
        max_bounces: u32,
    };

    settings: Settings,

    samplers: [Num_dedicated_samplers + 1]sampler.Sampler,

    const Self = @This();

    pub fn init(alloc: *Allocator, settings: Settings, max_samples_per_pixel: u32) !Self {
        const total_samples_per_pixel = settings.num_samples * max_samples_per_pixel;

        return Pathtracer{
            .settings = settings,
            .samplers = .{
                .{ .GoldenRatio = try sampler.GoldenRatio.init(alloc, 1, 1, total_samples_per_pixel) },
                .{ .GoldenRatio = try sampler.GoldenRatio.init(alloc, 1, 1, total_samples_per_pixel) },
                .{ .GoldenRatio = try sampler.GoldenRatio.init(alloc, 1, 1, total_samples_per_pixel) },
                .{ .Random = .{} },
            },
        };
    }

    pub fn deinit(self: *Self, alloc: *Allocator) void {
        for (self.samplers) |*s| {
            s.deinit(alloc);
        }
    }

    pub fn startPixel(self: *Self) void {
        for (self.samplers) |*s| {
            s.startPixel();
        }
    }

    pub fn li(self: *Self, ray: *Ray, isec: *Intersection, worker: *Worker) Vec4f {
        const num_samples_reciprocal = 1.0 / @intToFloat(f32, self.settings.num_samples);

        var result = @splat(4, @as(f32, 0.0));

        var i = self.settings.num_samples;
        while (i > 0) : (i -= 1) {
            var split_ray = ray.*;
            var split_isec = isec.*;

            result += @splat(4, num_samples_reciprocal) * self.integrate(&split_ray, &split_isec, worker);
        }

        return result;
    }

    fn integrate(self: *Self, ray: *Ray, isec: *Intersection, worker: *Worker) Vec4f {
        _ = self;
        _ = ray;

        var throughput = @splat(4, @as(f32, 1.0));
        var result = @splat(4, @as(f32, 0.0));

        var i: u32 = 0;
        while (true) : (i += 1) {
            const wo = -ray.ray.direction;

            const filter: ?Filter = if (ray.depth <= 1) null else .Nearest;

            const mat_sample = isec.sample(wo, ray.*, filter, &worker.super);

            if (mat_sample.super().sameHemisphere(wo)) {
                result += throughput * mat_sample.super().radiance;
            }

            if (mat_sample.isPureEmissive()) {
                break;
            }

            if (ray.depth >= self.settings.max_bounces) {
                break;
            }

            const sample_result = mat_sample.sample(self.materialSampler(ray.depth), &worker.super.rng);
            if (0.0 == sample_result.pdf) {
                break;
            }

            ray.depth += 1;

            ray.ray.origin = isec.offsetP(sample_result.wi);
            ray.ray.setDirection(sample_result.wi);

            ray.ray.setMaxT(scn.Ray_max_t);

            throughput *= sample_result.reflection / @splat(4, sample_result.pdf);

            if (!worker.super.intersectAndResolveMask(ray, filter, isec)) {
                break;
            }
        }

        return result;
    }

    fn materialSampler(self: *Self, bounce: u32) *sampler.Sampler {
        if (bounce < Num_dedicated_samplers) {
            return &self.samplers[bounce];
        }

        return &self.samplers[Num_dedicated_samplers];
    }
};

pub const Factory = struct {
    settings: Pathtracer.Settings = .{ .num_samples = 1, .radius = 1.0 },

    pub fn create(self: Factory, alloc: *Allocator, max_samples_per_pixel: u32) !Pathtracer {
        return try Pathtracer.init(alloc, self.settings, max_samples_per_pixel);
    }
};
