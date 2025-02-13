const anim = @import("animation_loader.zig");
const Graph = @import("scene_graph.zig").Graph;

const core = @import("core");
const log = core.log;
const img = core.img;
const scn = core.scn;
const Scene = scn.Scene;
const Prop = scn.Prop;
const Material = scn.Material;
const Shape = scn.Shape;
const resource = core.resource;
const Resources = resource.Manager;
const Take = core.tk.Take;

const base = @import("base");
const json = base.json;
const string = base.string;
const math = base.math;
const Vec4f = math.Vec4f;
const Transformation = math.Transformation;

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;

const Key = struct {
    shape: u32,
    materials: []u32 = &.{},

    const Self = @This();

    pub fn clone(self: Self, alloc: Allocator) !Self {
        return Self{
            .shape = self.shape,
            .materials = try alloc.dupe(u32, self.materials),
        };
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        alloc.free(self.materials);
    }
};

const KeyContext = struct {
    const Self = @This();

    pub fn hash(self: Self, k: Key) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);

        hasher.update(std.mem.asBytes(&k.shape));

        for (k.materials) |m| {
            hasher.update(std.mem.asBytes(&m));
        }

        return hasher.final();
    }

    pub fn eql(self: Self, a: Key, b: Key) bool {
        _ = self;

        if (a.shape != b.shape) {
            return false;
        }

        if (a.materials.len != b.materials.len) {
            return false;
        }

        for (a.materials, 0..) |m, i| {
            if (m != b.materials[i]) {
                return false;
            }
        }

        return true;
    }
};

pub const Loader = struct {
    pub const Error = error{
        OutOfMemory,
    };

    resources: *Resources,

    fallback_material: u32,

    materials: List(u32) = .{},

    instances: std.HashMapUnmanaged(Key, u32, KeyContext, 80) = .{},

    const Null = resource.Null;

    const LocalMaterials = struct {
        materials: std.StringHashMap(*std.json.Value),

        pub fn init(alloc: Allocator) LocalMaterials {
            return .{ .materials = std.StringHashMap(*std.json.Value).init(alloc) };
        }

        pub fn deinit(self: *LocalMaterials) void {
            self.materials.deinit();
        }
    };

    pub fn init(alloc: Allocator, resources: *Resources, fallback_material: Material) Loader {
        return .{
            .resources = resources,
            .fallback_material = resources.materials.store(alloc, Null, fallback_material) catch Null,
        };
    }

    pub fn deinit(self: *Loader, alloc: Allocator) void {
        self.instances.deinit(alloc);
        self.materials.deinit(alloc);
    }

    pub fn load(self: *Loader, alloc: Allocator, take: *const Take, graph: *Graph) !void {
        const camera = take.view.camera;
        graph.scene.calculateNumInterpolationFrames(camera.frame_step, camera.frame_duration);

        const take_mount_folder = string.parentDirectory(take.resolved_filename);

        const parent_id: u32 = Prop.Null;

        const parent_trafo = Transformation{
            .position = @splat(4, @as(f32, 0.0)),
            .scale = @splat(4, @as(f32, 1.0)),
            .rotation = math.quaternion.identity,
        };

        var parser = std.json.Parser.init(alloc, false);
        defer parser.deinit();

        try self.loadFile(alloc, &parser, take.scene_filename, take_mount_folder, parent_id, parent_trafo, false, graph);

        self.instances.clearAndFree(alloc);

        self.resources.commitAsync();
    }

    fn loadFile(
        self: *Loader,
        alloc: Allocator,
        parser: *std.json.Parser,
        filename: []const u8,
        take_mount_folder: []const u8,
        parent_id: u32,
        parent_trafo: Transformation,
        animated: bool,
        graph: *Graph,
    ) !void {
        const fs = &self.resources.fs;

        if (take_mount_folder.len > 0) {
            try fs.pushMount(alloc, take_mount_folder);
        }

        var stream = try fs.readStream(alloc, filename);

        if (take_mount_folder.len > 0) {
            fs.popMount(alloc);
        }

        const buffer = try stream.readAll(alloc);
        stream.deinit();
        defer alloc.free(buffer);

        var document = try parser.parse(buffer);
        defer document.deinit();

        const root = document.root;

        var local_materials = LocalMaterials.init(alloc);
        defer local_materials.deinit();

        if (root.Object.get("materials")) |materials_node| {
            try readMaterials(materials_node, &local_materials);
        }

        try fs.pushMount(alloc, string.parentDirectory(fs.lastResolvedName()));

        var iter = root.Object.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, "entities", entry.key_ptr.*)) {
                try self.loadEntities(
                    alloc,
                    entry.value_ptr.*,
                    parent_id,
                    parent_trafo,
                    animated,
                    local_materials,
                    graph,
                );
            }
        }

        fs.popMount(alloc);
    }

    fn readMaterials(value: std.json.Value, local_materials: *LocalMaterials) !void {
        for (value.Array.items) |*m| {
            const name_node = m.Object.get("name") orelse continue;

            try local_materials.materials.put(name_node.String, m);
        }
    }

    fn loadEntities(
        self: *Loader,
        alloc: Allocator,
        value: std.json.Value,
        parent_id: u32,
        parent_trafo: Transformation,
        animated: bool,
        local_materials: LocalMaterials,
        graph: *Graph,
    ) Error!void {
        const scene = &graph.scene;

        var parser = std.json.Parser.init(alloc, false);
        defer parser.deinit();

        for (value.Array.items) |entity| {
            if (entity.Object.get("file")) |file_node| {
                const filename = file_node.String;
                self.loadFile(alloc, &parser, filename, "", parent_id, parent_trafo, animated, graph) catch |e| {
                    log.err("Loading scene \"{s}\": {}", .{ filename, e });
                };
                parser.reset();
                continue;
            }

            const type_node = entity.Object.get("type") orelse continue;
            const type_name = type_node.String;

            var entity_id: u32 = Prop.Null;
            var is_light = false;

            if (std.mem.eql(u8, "Light", type_name)) {
                entity_id = try self.loadProp(alloc, entity, local_materials, graph, false);
                is_light = true;
            } else if (std.mem.eql(u8, "Prop", type_name)) {
                entity_id = try self.loadProp(alloc, entity, local_materials, graph, true);
            } else if (std.mem.eql(u8, "Sky", type_name)) {
                entity_id = try loadSky(alloc, entity, graph);
            }

            var trafo = Transformation{
                .position = @splat(4, @as(f32, 0.0)),
                .scale = @splat(4, @as(f32, 1.0)),
                .rotation = math.quaternion.identity,
            };

            var animation_ptr: ?*std.json.Value = null;
            var children_ptr: ?*std.json.Value = null;
            var visibility_ptr: ?*std.json.Value = null;

            var iter = entity.Object.iterator();
            while (iter.next()) |entry| {
                if (std.mem.eql(u8, "transformation", entry.key_ptr.*)) {
                    json.readTransformation(entry.value_ptr.*, &trafo);
                } else if (std.mem.eql(u8, "animation", entry.key_ptr.*)) {
                    animation_ptr = entry.value_ptr;
                } else if (std.mem.eql(u8, "entities", entry.key_ptr.*)) {
                    children_ptr = entry.value_ptr;
                } else if (std.mem.eql(u8, "visibility", entry.key_ptr.*)) {
                    visibility_ptr = entry.value_ptr;
                }
            }

            if (trafo.scale[1] <= 0.0 and trafo.scale[2] <= 2 and 1 == scene.propShape(entity_id).numParts()) {
                const material = scene.propMaterial(entity_id, 0);
                if (material.heterogeneousVolume()) {
                    if (material.usefulTexture()) |t| {
                        const voxel_scale = @splat(4, trafo.scale[0]);
                        const dimensions = t.description(scene).dimensions;
                        var offset = @splat(4, @as(i32, 0));

                        if (self.resources.images.meta(t.image)) |meta| {
                            offset = meta.queryOrDef("offset", @splat(4, @as(i32, 0)));
                        }

                        trafo.scale = @splat(4, @as(f32, 0.5)) * voxel_scale * math.vec4iTo4f(dimensions);
                        trafo.position += trafo.scale + voxel_scale * math.vec4iTo4f(offset);
                    }
                }
            }

            const animation = if (animation_ptr) |animation|
                try anim.load(alloc, animation.*, trafo, if (Prop.Null == parent_id) parent_trafo else null, graph)
            else
                Prop.Null;

            const local_animation = Prop.Null != animation;
            const world_animation = animated or local_animation;

            var graph_id: u32 = Prop.Null;

            if (world_animation) {
                graph_id = try graph.createEntity(alloc, entity_id);

                try graph.propAllocateFrames(alloc, graph_id, world_animation, local_animation);

                if (local_animation) {
                    graph.animationSetEntity(animation, graph_id);
                }

                if (Prop.Null != parent_id) {
                    graph.propSerializeChild(parent_id, graph_id);
                }
            }

            const world_trafo = parent_trafo.transform(trafo);

            if (!local_animation) {
                if (Prop.Null != graph_id) {
                    graph.propSetTransformation(graph_id, trafo);
                }

                if (Prop.Null != entity_id) {
                    scene.propSetWorldTransformation(entity_id, world_trafo);
                }
            }

            if (visibility_ptr) |visibility| {
                setVisibility(entity_id, visibility.*, scene);
            }

            if (is_light and scene.prop(entity_id).visibleInReflection()) {
                try scene.createLight(alloc, entity_id);
            }

            if (children_ptr) |children| {
                try self.loadEntities(
                    alloc,
                    children.*,
                    graph_id,
                    world_trafo,
                    world_animation,
                    local_materials,
                    graph,
                );
            }
        }
    }

    fn loadProp(
        self: *Loader,
        alloc: Allocator,
        value: std.json.Value,
        local_materials: LocalMaterials,
        graph: *Graph,
        instancing: bool,
    ) !u32 {
        const scene = &graph.scene;

        const shape = if (value.Object.get("shape")) |s| self.loadShape(alloc, s) else Prop.Null;
        if (Prop.Null == shape) {
            return Prop.Null;
        }

        const num_materials = scene.shape(shape).numMaterials();

        try self.materials.ensureTotalCapacity(alloc, num_materials);
        self.materials.clearRetainingCapacity();

        if (value.Object.get("materials")) |m| {
            self.loadMaterials(alloc, m, num_materials, local_materials);
        }

        while (self.materials.items.len < num_materials) {
            self.materials.appendAssumeCapacity(self.fallback_material);
        }

        if (instancing) {
            const key = Key{ .shape = shape, .materials = self.materials.items };

            if (self.instances.get(key)) |instance| {
                return try scene.createPropInstance(alloc, instance);
            }

            const entity = try scene.createProp(alloc, shape, self.materials.items);
            try self.instances.put(alloc, try key.clone(alloc), entity);
            return entity;
        } else {
            return try scene.createProp(alloc, shape, self.materials.items);
        }
    }

    fn setVisibility(prop: u32, value: std.json.Value, scene: *Scene) void {
        var in_camera = true;
        var in_reflection = true;
        var in_shadow = true;

        var iter = value.Object.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, "in_camera", entry.key_ptr.*)) {
                in_camera = json.readBool(entry.value_ptr.*);
            } else if (std.mem.eql(u8, "in_reflection", entry.key_ptr.*)) {
                in_reflection = json.readBool(entry.value_ptr.*);
            } else if (std.mem.eql(u8, "in_shadow", entry.key_ptr.*)) {
                in_shadow = json.readBool(entry.value_ptr.*);
            }
        }

        scene.propSetVisibility(prop, in_camera, in_reflection, in_shadow);
    }

    fn loadShape(self: *const Loader, alloc: Allocator, value: std.json.Value) u32 {
        const type_name = json.readStringMember(value, "type", "");
        if (type_name.len > 0) {
            return getShape(type_name);
        }

        const file = json.readStringMember(value, "file", "");
        if (file.len > 0) {
            return self.resources.loadFile(Shape, alloc, file, .{}) catch Null;
        }

        return Null;
    }

    fn getShape(type_name: []const u8) u32 {
        if (std.mem.eql(u8, "Canopy", type_name)) {
            return @enumToInt(Scene.ShapeID.Canopy);
        } else if (std.mem.eql(u8, "Cube", type_name)) {
            return @enumToInt(Scene.ShapeID.Cube);
        } else if (std.mem.eql(u8, "Disk", type_name)) {
            return @enumToInt(Scene.ShapeID.Disk);
        } else if (std.mem.eql(u8, "Distant_sphere", type_name)) {
            return @enumToInt(Scene.ShapeID.DistantSphere);
        } else if (std.mem.eql(u8, "Infinite_sphere", type_name)) {
            return @enumToInt(Scene.ShapeID.InfiniteSphere);
        } else if (std.mem.eql(u8, "Plane", type_name)) {
            return @enumToInt(Scene.ShapeID.Plane);
        } else if (std.mem.eql(u8, "Rectangle", type_name)) {
            return @enumToInt(Scene.ShapeID.Rectangle);
        } else if (std.mem.eql(u8, "Sphere", type_name)) {
            return @enumToInt(Scene.ShapeID.Sphere);
        }

        return Null;
    }

    fn loadMaterials(
        self: *Loader,
        alloc: Allocator,
        value: std.json.Value,
        num_materials: usize,
        local_materials: LocalMaterials,
    ) void {
        for (value.Array.items, 0..) |m, i| {
            self.materials.appendAssumeCapacity(self.loadMaterial(alloc, m.String, local_materials));

            if (i == num_materials - 1) {
                return;
            }
        }
    }

    fn loadMaterial(
        self: *const Loader,
        alloc: Allocator,
        name: []const u8,
        local_materials: LocalMaterials,
    ) u32 {
        // First, check if we maybe already have cached the material.
        if (self.resources.getByName(Material, name, .{})) |material| {
            return material;
        }

        // Otherwise, see if it is among the locally defined materials.
        if (local_materials.materials.get(name)) |material_node| {
            const data = @ptrToInt(material_node);

            const material = self.resources.loadData(Material, alloc, Null, data, .{}) catch Null;
            if (Null != material) {
                self.resources.associate(Material, alloc, material, name, .{}) catch {};
                return material;
            }
        }

        // Lastly, try loading the material from the filesystem.
        const material = self.resources.loadFile(Material, alloc, name, .{}) catch {
            log.warning("Using fallback for material \"{s}\"", .{name});
            return self.fallback_material;
        };

        return material;
    }

    fn loadSky(alloc: Allocator, value: std.json.Value, graph: *Graph) !u32 {
        const sky = try graph.scene.createSky(alloc);

        // try graph.bumpProps(alloc);

        if (value.Object.get("parameters")) |parameters| {
            sky.setParameters(parameters);
        }

        return sky.sun;
    }
};
