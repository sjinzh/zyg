const ComposedTransformation = @import("scene/composed_transformation.zig").ComposedTransformation;
const Light = @import("scene/light/light.zig").Light;
const BvhNode = @import("scene/bvh/node.zig").Node;
const LightNode = @import("scene/light/light_tree.zig").Node;
const mt = @import("scene/material/material.zig");
const intf = @import("scene/prop/interface.zig");
const PropIntersection = @import("scene/prop/intersection.zig").Intersection;
const smpl = @import("scene/shape/sample.zig");
const Mesh = @import("scene/shape/triangle/mesh.zig").Mesh;
const TriangleBvh = @import("scene/shape/triangle/bvh/triangle_tree.zig").Tree;
const Texture = @import("image/texture/texture.zig").Texture;
const Worker = @import("rendering/worker.zig").Worker;

const base = @import("base");
const math = base.math;

const std = @import("std");

pub fn testSize() void {
    std.debug.print("Name: actual size (expected size); alignment\n", .{});

    testType(math.Vec2f, "Vec2f", 8);
    testType(math.Pack3f, "Pack3f", 12);
    testType(math.Vec4f, "Vec4f", 16);
    testType(math.Pack4f, "Pack4f", 16);
    testType(math.Distribution1D, "Distribution1D", 32);
    testType(ComposedTransformation, "ComposedTransformation", 64);
    testType(Light, "Light", 16);
    testType(PropIntersection, "PropIntersection", 176);
    testType(smpl.To, "SampleTo", 112);
    testType(smpl.From, "SampleFrom", 144);
    testType(BvhNode, "BvhNode", 32);
    testType(LightNode, "LightNode", 48);
    testType(intf.Interface, "Interface", 16);
    testType(intf.Stack, "InterfaceStack", 240);
    testType(mt.Material, "Material", 400);
    testType(mt.Substitute, "SubstituteMaterial", 368);
    testType(mt.Sample, "MaterialSample", 256);
    testType(Texture, "Texture", 16);
    testType(Mesh, "Mesh", 80);
    testType(TriangleBvh, "TriangleBvh", 56);
    testType(Worker, "Worker", 1152);
}

fn testType(comptime T: type, name: []const u8, expected: usize) void {
    const measured = @sizeOf(T);
    const ao = @alignOf(T);

    if (measured != expected) {
        std.debug.print("alarm: ", .{});
    }

    std.debug.print("{s}: {} ({}); {}\n", .{ name, measured, expected, ao });
}
