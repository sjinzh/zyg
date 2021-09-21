const cam = @import("../camera/perspective.zig");
const Scene = @import("../scene/scene.zig").Scene;
const Ray = @import("../scene/ray.zig").Ray;
const Intersection = @import("../scene/prop/intersection.zig").Intersection;
const smpl = @import("../sampler/sampler.zig");
const Sampler = smpl.Sampler;
const Scene_worker = @import("../scene/worker.zig").Worker;
const Filter = @import("../image/texture/sampler.zig").Filter;
const surface = @import("integrator/surface/integrator.zig");

const math = @import("base").math;
const Vec2i = math.Vec2i;
const Vec4i = math.Vec4i;
const Vec4f = math.Vec4f;

const Allocator = @import("std").mem.Allocator;

pub const Worker = struct {
    super: Scene_worker = undefined,

    sampler: Sampler = undefined,

    surface_integrator: surface.Integrator = undefined,

    pub fn deinit(self: *Worker, alloc: *Allocator) void {
        self.surface_integrator.deinit(alloc);
        self.sampler.deinit(alloc);
    }

    pub fn configure(
        self: *Worker,
        alloc: *Allocator,
        camera: *cam.Perspective,
        scene: *Scene,
        num_samples_per_pixel: u32,
        samplers: smpl.Factory,
        surfaces: surface.Factory,
    ) !void {
        self.super.configure(camera, scene);

        self.sampler = try samplers.create(alloc, 1, 2, num_samples_per_pixel);

        self.surface_integrator = try surfaces.create(alloc, num_samples_per_pixel);
    }

    pub fn render(self: *Worker, tile: Vec4i, num_samples: u32) void {
        var camera = self.super.camera;
        const sensor = &camera.sensor;
        const scene = self.super.scene;

        const offset = @splat(2, @as(i32, 0));

        var crop = camera.crop;
        crop.v[2] -= crop.v[0] + 1;
        crop.v[3] -= crop.v[1] + 1;
        crop.v[0] += offset[0];
        crop.v[1] += offset[1];

        const xy = offset + Vec2i{ tile.v[0], tile.v[1] };
        const zw = offset + Vec2i{ tile.v[2], tile.v[3] };
        const view_tile = Vec4i.init4(xy[0], xy[1], zw[0], zw[1]);

        var isolated_bounds = sensor.isolatedTile(view_tile);
        isolated_bounds.v[2] -= isolated_bounds.v[0];
        isolated_bounds.v[3] -= isolated_bounds.v[1];

        const fr = sensor.filterRadiusInt();

        const r = camera.resolution + @splat(2, 2 * fr);

        const o0 = 0; //uint64_t(iteration) * @intCast(u64, r.v[0] * r.v[1]);

        const y_back = tile.v[3];
        var y: i32 = tile.v[1];
        while (y <= y_back) : (y += 1) {
            const o1 = @intCast(u64, (y + fr) * r[0]) + o0;
            const x_back = tile.v[2];
            var x: i32 = tile.v[0];
            while (x <= x_back) : (x += 1) {
                self.super.rng.start(0, o1 + @intCast(u64, x + fr));

                self.sampler.startPixel();
                self.surface_integrator.startPixel();

                const pixel = Vec2i{ x, y };

                var s: u32 = 0;
                while (s < num_samples) : (s += 1) {
                    const sample = self.sampler.cameraSample(&self.super.rng, pixel);

                    if (camera.generateRay(sample, scene.*)) |*ray| {
                        const color = self.li(ray);
                        sensor.addSample(sample, color, offset, isolated_bounds, crop);
                    } else {
                        sensor.addSample(sample, @splat(4, @as(f32, 0.0)), offset, isolated_bounds, crop);
                    }
                }
            }
        }
    }

    fn li(self: *Worker, ray: *Ray) Vec4f {
        var isec = Intersection{};
        if (self.super.intersectAndResolveMask(ray, null, &isec)) {
            return self.surface_integrator.li(ray, &isec, self);
        }

        return @splat(4, @as(f32, 0.0));
    }
};
