const tr = @import("tree.zig");
const Tree = tr.Tree;
const Node = tr.Node;
const Scene = @import("../scene.zig").Scene;
const base = @import("base");
const math = base.math;
const AABB = math.AABB;
const Vec4f = math.Vec4f;
const Threads = base.thread.Pool;

const std = @import("std");
const Allocator = std.mem.Allocator;

const Scene_sweep_threshold = 128;
const Num_slices = 16;

const BuildNode = struct {
    bounds: AABB,
    cone: Vec4f,

    power: f32,
    variance: f32,

    middle: u32,
    children_or_light: u32,
    num_lights: u32,

    two_sided: bool,

    pub fn hasChildren(self: BuildNode) bool {
        return self.middle > 0;
    }

    pub fn countMaxSplits(self: BuildNode, depth: u32, nodes: []const BuildNode, splits: *u32) void {
        if (0 == self.middle) {
            if (depth < Tree.Max_split_depth) {
                splits.* += self.num_lights;
            } else {
                splits.* += 1;
            }
        } else {
            if (depth == Tree.Max_split_depth - 1) {
                splits.* += 2;
            } else {
                nodes[self.children_or_light].countMaxSplits(depth + 1, nodes, splits);
                nodes[self.children_or_light + 1].countMaxSplits(depth + 1, nodes, splits);
            }
        }
    }
};

const SplitCandidate = struct {
    aabbs: [2]AABB,
    cones: [2]Vec4f,
    powers: [2]f32,
    d: f32,
    cost: f32,
    axis: u32,
    two_sideds: [2]bool,
    exhausted: bool,

    const Self = @This();

    pub fn configure(self: *Self, p: Vec4f, axis: u32) void {
        self.d = p[axis];
        self.axis = axis;
    }

    pub fn behind(self: Self, point: Vec4f) bool {
        return point[self.axis] < self.d;
    }

    pub fn evaluate(self: *Self, lights: []u32, bounds: AABB, cone_weight: f32, set: anytype, variant: u32) void {
        if (Scene == @TypeOf(set)) {
            self.evaluateScene(lights, bounds, cone_weight, set);
        }

        _ = variant;
    }

    fn evaluateScene(self: *Self, lights: []u32, bounds: AABB, cone_weight: f32, scene: Scene) void {
        var num_sides: [2]u32 = .{ 0, 0 };
        var boxs: [2]AABB = .{ math.aabb.empty, math.aabb.empty };
        var cones: [2]Vec4f = .{ @splat(4, @as(f32, 1.0)), @splat(4, @as(f32, 1.0)) };
        var two_sideds: [2]bool = .{ false, false };
        var powers: [2]f32 = .{ 0.0, 0.0 };

        for (lights) |l| {
            const box = scene.lightAabb(l);
            const cone = scene.lightCone(l);
            const two_sided = scene.lightTwoSided(0, l);
            const power = scene.lightPower(0, l);

            if (0.0 == power) {
                continue;
            }

            const side: u32 = if (self.behind(box.bounds[1])) 0 else 1;

            num_sides[side] += 1;
            boxs[side].mergeAssign(box);
            cones[side] = math.cone.merge(cones[side], cone);
            two_sideds[side] = two_sideds[side] or two_sided;
            powers[side] += power;
        }

        const extent = bounds.extent();
        const reg = math.maxComponent3(extent) / extent[self.axis];
        const surface_area = bounds.surfaceArea();

        self.aabbs = boxs;
        self.cones = cones;
        self.powers = powers;
        self.two_sideds = two_sideds;

        const empty_side = 0 == num_sides[0] or 0 == num_sides[1];
        if (empty_side) {
            self.cost = 2.0 * reg * (powers[0] + powers[1]) * (4.0 * std.math.pi) * surface_area * @intToFloat(f32, lights.len);
            self.exhausted = true;
        } else {
            const cone_weight_a = coneCost(cones[0][3]) * @as(f32, (if (two_sideds[0]) 2.0 else 1.0));
            const cone_weight_b = coneCost(cones[1][3]) * @as(f32, (if (two_sideds[1]) 2.0 else 1.0));

            const surface_area_a = boxs[0].surfaceArea();
            const surface_area_b = boxs[1].surfaceArea();

            self.cost = reg * (((powers[0] * cone_weight_a * surface_area_a) +
                (powers[1] * cone_weight_b * surface_area_b)) /
                (surface_area * cone_weight));

            self.exhausted = false;
        }

        // std.debug.print("{} \n", .{
        //     self.aabbs[0],
        // });
    }
};

pub const Builder = struct {
    current_node: u32 = undefined,
    light_order: u32 = undefined,

    build_nodes: []BuildNode = &.{},
    candidates: []SplitCandidate = &.{},

    pub fn deinit(self: *Builder, alloc: *Allocator) void {
        alloc.free(self.candidates);
        alloc.free(self.build_nodes);
    }

    pub fn build(
        self: *Builder,
        alloc: *Allocator,
        tree: *Tree,
        scene: Scene,
        threads: *Threads,
    ) !void {
        const num_lights = scene.numLights();

        try tree.allocateLightMapping(alloc, num_lights);

        self.light_order = 0;

        var lm: u32 = 0;
        {
            var l: u32 = 0;
            while (l < num_lights) : (l += 1) {
                if (!scene.light(l).isFinite(scene)) {
                    tree.light_mapping[lm] = l;
                    lm += 1;
                }
            }
        }

        const num_infinite_lights = lm;

        {
            var l: u32 = 0;
            while (l < num_lights) : (l += 1) {
                if (scene.light(l).isFinite(scene)) {
                    tree.light_mapping[lm] = l;
                    lm += 1;
                }
            }
        }

        try tree.allocate(alloc, num_infinite_lights);

        var infinite_total_power: f32 = 0.0;
        for (tree.light_mapping[0..num_infinite_lights]) |l, i| {
            const power = scene.lightPower(0, l);
            tree.infinite_light_powers[i] = power;
            tree.light_orders[l] = self.light_order;
            self.light_order += 1;

            infinite_total_power += power;
        }

        tree.infinite_end = self.light_order;
        try tree.infinite_light_distribution.configure(alloc, tree.infinite_light_powers[0..tree.num_infinite_lights], 0);

        const num_finite_lights = num_lights - num_infinite_lights;
        var infinite_depth_bias: u32 = 0;

        if (num_finite_lights > 0) {
            try self.allocate(alloc, num_finite_lights, Scene_sweep_threshold);

            self.current_node = 1;

            var bounds = math.aabb.empty;
            var cone = @splat(4, @as(f32, 1.0));
            var two_sided = false;
            var total_power: f32 = 0.0;

            for (tree.light_mapping[num_infinite_lights..num_lights]) |l| {
                bounds.mergeAssign(scene.lightAabb(l));
                cone = math.cone.merge(cone, scene.lightCone(l));
                two_sided = two_sided or scene.lightTwoSided(0, l);
                total_power += scene.lightPower(0, l);
            }

            _ = self.split(tree, 0, num_infinite_lights, num_lights, bounds, cone, two_sided, total_power, scene, threads);

            try tree.allocateNodes(alloc, self.current_node);
            self.serialize(tree.nodes, tree.node_middles);

            var max_splits: u32 = 0;
            self.build_nodes[0].countMaxSplits(0, self.build_nodes, &max_splits);

            if (num_infinite_lights > 0 and num_infinite_lights < Tree.Max_lights - 1) {
                const left = Tree.Max_lights - max_splits;
                if (left < num_infinite_lights) {
                    const rest = @intToFloat(f32, num_infinite_lights - left);
                    infinite_depth_bias = std.math.max(@floatToInt(u32, @ceil(@log2(rest))), 1);
                }
            }
        } else {
            try tree.allocateNodes(alloc, 0);
        }

        tree.infinite_depth_bias = infinite_depth_bias;

        const p0 = infinite_total_power;
        const p1 = if (0 == num_finite_lights) 0.0 else self.build_nodes[0].power;
        const pt = p0 + p1;
        const infinite_weight = if (0 == num_lights) 0.0 else p0 / pt;

        tree.infinite_weight = infinite_weight;

        // This is because I'm afraid of the 1.f == random case
        tree.infinite_guard = if (0 == num_finite_lights)
            @as(f32, (if (0 == num_infinite_lights) 0.0 else 1.1))
        else
            infinite_weight;

        _ = threads;
    }

    fn allocate(self: *Builder, alloc: *Allocator, num_lights: u32, sweep_threshold: u32) !void {
        const num_nodes = 2 * num_lights - 1;

        if (num_nodes > self.build_nodes.len) {
            self.build_nodes = try alloc.realloc(self.build_nodes, num_nodes);
        }

        const num_slices = std.math.min(num_lights, sweep_threshold);
        const num_candidates = if (num_slices >= 2) num_slices * 3 else 0;

        if (num_candidates > self.candidates.len) {
            self.candidates = try alloc.realloc(self.candidates, num_candidates);
        }
    }

    fn split(
        self: *Builder,
        tree: *Tree,
        node_id: u32,
        begin: u32,
        end: u32,
        bounds: AABB,
        cone: Vec4f,
        two_sided: bool,
        total_power: f32,
        scene: Scene,
        threads: *Threads,
    ) u32 {
        const lights = tree.light_mapping[begin..end];

        var node = &self.build_nodes[node_id];

        const len = end - begin;

        if (len <= 4) {
            var node_two_sided = false;

            for (lights) |l| {
                tree.light_orders[l] = self.light_order;
                self.light_order += 1;
                node_two_sided = node_two_sided or scene.lightTwoSided(0, l);
            }

            node.bounds = bounds;
            node.cone = cone;
            node.power = total_power;
            node.variance = variance(lights, scene, 0);
            node.middle = 0;
            node.children_or_light = begin;
            node.num_lights = len;
            node.two_sided = node_two_sided;

            return begin + len;
        }

        const child0 = self.current_node;

        self.current_node += 2;

        const cone_weight = coneCost(cone[3]);

        const sc = evaluateSplits(lights, bounds, cone_weight, Scene_sweep_threshold, self.candidates, scene, 0, threads);

        const predicate = Predicate{ .sc = &sc, .scene = &scene };
        const split_node = begin + @intCast(u32, base.memory.partition(u32, lights, predicate));

        const c0_end = self.split(tree, child0, begin, split_node, sc.aabbs[0], sc.cones[0], sc.two_sideds[0], sc.powers[0], scene, threads);
        const c1_end = self.split(tree, child0 + 1, split_node, end, sc.aabbs[1], sc.cones[1], sc.two_sideds[1], sc.powers[1], scene, threads);

        node.bounds = bounds;
        node.cone = cone;
        node.power = total_power;
        node.variance = variance(lights, scene, 0);
        node.middle = c0_end;
        node.children_or_light = child0;
        node.num_lights = len;
        node.two_sided = two_sided;

        return c1_end;
    }

    const Predicate = struct {
        sc: *const SplitCandidate,
        scene: *const Scene,

        pub fn f(self: Predicate, l: u32) bool {
            return self.sc.behind(self.scene.lightAabb(l).bounds[1]);
        }
    };

    fn serialize(self: Builder, nodes: [*]Node, node_middles: [*]u32) void {
        for (self.build_nodes[0..self.current_node]) |source, i| {
            var dest = &nodes[i];
            const bounds = source.bounds;
            const p = bounds.position();

            dest.center = Vec4f{ p[0], p[1], p[2], 0.5 * math.length3(bounds.extent()) };
            dest.cone = source.cone;
            dest.power = source.power;
            dest.variance = source.variance;
            dest.has_children = source.hasChildren();
            dest.children_or_light = @intCast(u30, source.children_or_light);
            dest.num_lights = source.num_lights;
            dest.two_sided = source.two_sided;

            node_middles[i] = source.middle;
        }
    }

    fn variance(lights: []u32, set: anytype, variant: u32) f32 {
        var ap: f32 = 0.0;
        var aps: f32 = 0.0;

        var n: u32 = 0;
        for (lights) |l| {
            const p = set.lightPower(variant, l);
            if (p > 0.0) {
                n += 1;
                const in = 1.0 / @intToFloat(f32, n);

                ap += (p - ap) * in;
                aps += (p * p - aps) * in;
            }
        }

        return @fabs(aps - ap * ap);
    }

    fn evaluateSplits(
        lights: []u32,
        bounds: AABB,
        cone_weight: f32,
        sweep_threshold: u32,
        candidates: []SplitCandidate,
        set: anytype,
        variant: u32,
        threads: *Threads,
    ) SplitCandidate {
        const X = 0;
        const Y = 1;
        const Z = 2;

        var num_candidates: u32 = 0;

        if (lights.len < sweep_threshold) {
            for (lights) |l| {
                const max = set.lightAabb(l).bounds[1];

                candidates[num_candidates].configure(max, X);
                num_candidates += 1;
                candidates[num_candidates].configure(max, Y);
                num_candidates += 1;
                candidates[num_candidates].configure(max, Z);
                num_candidates += 1;
            }
        } else {
            const position = bounds.position();
            const extent = bounds.extent();
            const min = bounds.bounds[0];

            const la = math.indexMaxComponent3(extent);
            const step = extent[la] / @intToFloat(f32, Num_slices);

            var a: u32 = 0;
            while (a < 3) : (a += 1) {
                const extent_a = extent[a];
                const num_steps = @floatToInt(u32, std.math.ceil(extent_a / step));
                const step_a = extent_a / @intToFloat(f32, num_steps);

                var i: u32 = 1;
                while (i < num_steps) : (i += 1) {
                    const fi = @intToFloat(f32, i);

                    var slice = position;
                    slice[a] = min[a] + fi * step_a;

                    candidates[num_candidates].configure(slice, a);
                    num_candidates += 1;
                }
            }
        }

        if (lights.len * num_candidates > 1024) {
            const context = EvaluateContext{
                .lights = lights,
                .bounds = bounds,
                .cone_weight = cone_weight,
                .candidates = candidates,
                .set = &set,
                .variant = variant,
            };

            _ = threads.runRange(&context, EvaluateContext.run, 0, num_candidates);
        } else {
            for (candidates[0..num_candidates]) |*c| {
                c.evaluate(lights, bounds, cone_weight, set, variant);
            }
        }

        var min_cost = candidates[0].cost;
        var sc: usize = 0;
        for (candidates[1..num_candidates]) |c, i| {
            const cost = c.cost;
            if (cost < min_cost) {
                sc = i + 1;
                min_cost = cost;
            }
        }

        return candidates[sc];
    }

    const EvaluateContext = struct {
        lights: []u32,
        bounds: AABB,
        cone_weight: f32,
        candidates: []SplitCandidate,
        set: *const Scene,
        variant: u32,

        pub fn run(context: Threads.Context, id: u32, begin: u32, end: u32) void {
            _ = id;

            const self = @intToPtr(*EvaluateContext, context);

            for (self.candidates[begin..end]) |*c| {
                c.evaluate(self.lights, self.bounds, self.cone_weight, self.set, self.variant);
            }
        }
    };
};

fn coneCost(cos: f32) f32 {
    const o = std.math.acos(cos);
    const w = std.math.min(o + (std.math.pi / 2.0), std.math.pi);

    const sin = @sin(o);
    const b = (std.math.pi / 2.0) * (2.0 * w * sin - @cos(o - 2.0 * w) - 2.0 * o * sin + cos);

    return (2.0 * std.math.pi) * (1.0 - cos) + b;
}
