const tk = @import("take.zig");
pub const Take = tk.Take;
pub const View = tk.View;

const cam = @import("../camera/perspective.zig");
const snsr = @import("../rendering/sensor/sensor.zig");
const smpl = @import("../sampler/sampler.zig");
const surface = @import("../rendering/integrator/surface/integrator.zig");
const volume = @import("../rendering/integrator/volume/integrator.zig");
const tm = @import("../rendering/postprocessor/tonemapping/tonemapper.zig");
const Scene = @import("../scene/scene.zig").Scene;
const Resources = @import("../resource/manager.zig").Manager;
const ReadStream = @import("../file/read_stream.zig").ReadStream;

const base = @import("base");
const json = base.json;
const math = base.math;

const Vec2i = math.Vec2i;
const Vec4i = math.Vec4i;
const Vec4f = math.Vec4f;
const Transformation = math.Transformation;

const std = @import("std");
const Allocator = std.mem.Allocator;

const Error = error{
    NoScene,
};

pub fn load(alloc: *Allocator, stream: *ReadStream, scene: *Scene, resources: *Resources) !Take {
    _ = resources;

    const buffer = try stream.readAll(alloc);
    defer alloc.free(buffer);

    var parser = std.json.Parser.init(alloc, false);
    defer parser.deinit();

    var document = try parser.parse(buffer);
    defer document.deinit();

    var take = try Take.init(alloc);

    const root = document.root;

    var integrator_value_ptr: ?*std.json.Value = null;
    var post_value_ptr: ?*std.json.Value = null;
    var sampler_value_ptr: ?*std.json.Value = null;

    var iter = root.Object.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, "camera", entry.key_ptr.*)) {
            try loadCamera(alloc, &take.view.camera, entry.value_ptr.*, scene);
        } else if (std.mem.eql(u8, "integrator", entry.key_ptr.*)) {
            integrator_value_ptr = entry.value_ptr;
        } else if (std.mem.eql(u8, "post", entry.key_ptr.*)) {
            post_value_ptr = entry.value_ptr;
        } else if (std.mem.eql(u8, "sampler", entry.key_ptr.*)) {
            sampler_value_ptr = entry.value_ptr;
        } else if (std.mem.eql(u8, "scene", entry.key_ptr.*)) {
            const string = entry.value_ptr.String;
            take.scene_filename = try alloc.alloc(u8, string.len);
            std.mem.copy(u8, take.scene_filename, string);
        }
    }

    if (0 == take.scene_filename.len) {
        return Error.NoScene;
    }

    if (integrator_value_ptr) |integrator_value| {
        loadIntegrators(integrator_value.*, &take.view);
    }

    if (null == take.view.surfaces) {
        take.view.surfaces = surface.Factory{ .AO = .{
            .settings = .{ .num_samples = 1, .radius = 1.0 },
        } };
    }

    if (null == take.view.volumes) {
        take.view.volumes = volume.Factory{ .Multi = .{} };
    }

    if (sampler_value_ptr) |sampler_value| {
        take.view.samplers = loadSampler(sampler_value.*, &take.view.num_samples_per_pixel);
    }

    if (post_value_ptr) |post_value| {
        loadPostProcessors(post_value.*, &take.view);
    }

    try take.view.configure(alloc);

    return take;
}

fn loadCamera(alloc: *Allocator, camera: *cam.Perspective, value: std.json.Value, scene: *Scene) !void {
    var type_value_ptr: ?*std.json.Value = null;

    {
        var iter = value.Object.iterator();

        while (iter.next()) |entry| {
            type_value_ptr = entry.value_ptr;
        }
    }

    if (null == type_value_ptr) {
        return;
    }

    var param_value_ptr: ?*std.json.Value = null;
    var sensor_value_ptr: ?*std.json.Value = null;

    var trafo = Transformation{
        .position = @splat(4, @as(f32, 0.0)),
        .scale = @splat(4, @as(f32, 1.0)),
        .rotation = math.quaternion.identity,
    };

    if (type_value_ptr) |type_value| {
        var iter = type_value.Object.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, "parameters", entry.key_ptr.*)) {
                param_value_ptr = entry.value_ptr;
                // const fov = entry.value_ptr.Object.get("fov") orelse continue;
                // camera.fov = math.degreesToRadians(json.readFloat(fov));
            } else if (std.mem.eql(u8, "transformation", entry.key_ptr.*)) {
                json.readTransformation(entry.value_ptr.*, &trafo);
            } else if (std.mem.eql(u8, "sensor", entry.key_ptr.*)) {
                sensor_value_ptr = entry.value_ptr;
            }
        }
    }

    if (sensor_value_ptr) |sensor_value| {
        const resolution = json.readVec2iMember(sensor_value.*, "resolution", .{ 0, 0 });
        const crop = json.readVec4iMember(sensor_value.*, "crop", Vec4i.init4(0, 0, resolution[0], resolution[1]));

        camera.setResolution(resolution, crop);

        camera.setSensor(loadSensor(sensor_value.*));
    } else {
        return;
    }

    if (param_value_ptr) |param_value| {
        camera.setParameters(param_value.*);
    }

    const prop_id = try scene.createEntity(alloc);

    scene.propSetWorldTransformation(prop_id, trafo);

    camera.entity = prop_id;
}

fn identity(x: f32) f32 {
    return x;
}

const Blackman = struct {
    r: f32,

    pub fn eval(self: Blackman, x: f32) f32 {
        const a0 = 0.35875;
        const a1 = 0.48829;
        const a2 = 0.14128;
        const a3 = 0.01168;

        const b = (std.math.pi * (x + self.r)) / self.r;

        return a0 - a1 * @cos(b) + a2 * @cos(2.0 * b) - a3 * @cos(3.0 * b);
    }
};

fn loadSensor(value: std.json.Value) snsr.Sensor {
    var alpha_transparency = false;

    var filter_value_ptr: ?*std.json.Value = null;

    {
        var iter = value.Object.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, "alpha_transparency", entry.key_ptr.*)) {
                alpha_transparency = json.readBool(entry.value_ptr.*);
            } else if (std.mem.eql(u8, "filter", entry.key_ptr.*)) {
                filter_value_ptr = entry.value_ptr;
            }
        }
    }

    if (filter_value_ptr) |filter_value| {
        var iter = filter_value.Object.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, "Gaussian", entry.key_ptr.*) or
                std.mem.eql(u8, "Blackman", entry.key_ptr.*) or
                std.mem.eql(u8, "Mitchell", entry.key_ptr.*))
            {
                const radius = json.readFloatMember(entry.value_ptr.*, "radius", 2.0);

                if (alpha_transparency) {} else {
                    if (radius <= 1.0) {
                        return snsr.Sensor{
                            .Filtered_1p0_opaque = snsr.Filtered_1p0_opaque.init(
                                radius,
                                Blackman{ .r = radius },
                            ),
                        };
                    } else if (radius <= 2.0) {
                        return snsr.Sensor{
                            .Filtered_2p0_opaque = snsr.Filtered_2p0_opaque.init(
                                radius,
                                Blackman{ .r = radius },
                            ),
                        };
                    }
                }
            }
        }
    }

    if (alpha_transparency) {
        return snsr.Sensor{ .Unfiltered_transparent = .{} };
    }

    return snsr.Sensor{ .Unfiltered_opaque = .{} };
}

fn loadIntegrators(value: std.json.Value, view: *View) void {
    var iter = value.Object.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, "surface", entry.key_ptr.*)) {
            loadSurfaceIntegrator(entry.value_ptr.*, view);
        }
    }
}

fn loadSurfaceIntegrator(value: std.json.Value, view: *View) void {
    const Default_min_bounces = 4;
    const Default_max_bounces = 8;
    const Default_caustics = true;

    var iter = value.Object.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, "AO", entry.key_ptr.*)) {
            const num_samples = json.readUIntMember(entry.value_ptr.*, "num_samples", 1);

            const radius = json.readFloatMember(entry.value_ptr.*, "radius", 1.0);

            view.surfaces = surface.Factory{ .AO = .{
                .settings = .{ .num_samples = num_samples, .radius = radius },
            } };
        } else if (std.mem.eql(u8, "PT", entry.key_ptr.*)) {
            const num_samples = json.readUIntMember(entry.value_ptr.*, "num_samples", 1);
            const min_bounces = json.readUIntMember(entry.value_ptr.*, "min_bounces", Default_min_bounces);
            const max_bounces = json.readUIntMember(entry.value_ptr.*, "max_bounces", Default_max_bounces);
            const enable_caustics = json.readBoolMember(entry.value_ptr.*, "caustics", Default_caustics);

            view.surfaces = surface.Factory{ .PT = .{
                .settings = .{
                    .num_samples = num_samples,
                    .min_bounces = min_bounces,
                    .max_bounces = max_bounces,
                    .avoid_caustics = !enable_caustics,
                },
            } };
        } else if (std.mem.eql(u8, "PTDL", entry.key_ptr.*)) {
            const num_samples = json.readUIntMember(entry.value_ptr.*, "num_samples", 1);
            const min_bounces = json.readUIntMember(entry.value_ptr.*, "min_bounces", Default_min_bounces);
            const max_bounces = json.readUIntMember(entry.value_ptr.*, "max_bounces", Default_max_bounces);
            const enable_caustics = json.readBoolMember(entry.value_ptr.*, "caustics", Default_caustics);

            view.surfaces = surface.Factory{ .PTDL = .{
                .settings = .{
                    .num_samples = num_samples,
                    .min_bounces = min_bounces,
                    .max_bounces = max_bounces,
                    .avoid_caustics = !enable_caustics,
                },
            } };
        } else if (std.mem.eql(u8, "PTMIS", entry.key_ptr.*)) {
            const num_samples = json.readUIntMember(entry.value_ptr.*, "num_samples", 1);
            const min_bounces = json.readUIntMember(entry.value_ptr.*, "min_bounces", Default_min_bounces);
            const max_bounces = json.readUIntMember(entry.value_ptr.*, "max_bounces", Default_max_bounces);
            const enable_caustics = json.readBoolMember(entry.value_ptr.*, "caustics", Default_caustics);

            view.surfaces = surface.Factory{ .PTMIS = .{
                .settings = .{
                    .num_samples = num_samples,
                    .min_bounces = min_bounces,
                    .max_bounces = max_bounces,
                    .avoid_caustics = !enable_caustics,
                },
            } };
        }
    }
}

fn loadSampler(value: std.json.Value, num_samples_per_pixel: *u32) smpl.Factory {
    var iter = value.Object.iterator();
    while (iter.next()) |entry| {
        num_samples_per_pixel.* = json.readUIntMember(entry.value_ptr.*, "samples_per_pixel", 1);

        if (std.mem.eql(u8, "Random", entry.key_ptr.*)) {
            return .{ .Random = {} };
        }

        if (std.mem.eql(u8, "Golden_ratio", entry.key_ptr.*)) {
            return .{ .GoldenRatio = {} };
        }
    }

    return .{ .Random = {} };
}

fn loadPostProcessors(value: std.json.Value, view: *View) void {
    for (value.Array.items) |pp| {
        if (pp.Object.iterator().next()) |entry| {
            if (std.mem.eql(u8, "tonemapper", entry.key_ptr.*)) {
                view.pipeline.tonemapper = loadTonemapper(entry.value_ptr.*);
            }
        }
    }
}

fn loadTonemapper(value: std.json.Value) tm.Tonemapper {
    var iter = value.Object.iterator();
    while (iter.next()) |entry| {
        const exposure = json.readFloatMember(entry.value_ptr.*, "exposure", 0.0);

        if (std.mem.eql(u8, "ACES", entry.key_ptr.*)) {
            return .{ .ACES = tm.ACES.init(exposure) };
        }

        if (std.mem.eql(u8, "Linear", entry.key_ptr.*)) {
            return .{ .Linear = tm.Linear.init(exposure) };
        }
    }

    return .{ .Linear = tm.Linear.init(0.0) };
}
