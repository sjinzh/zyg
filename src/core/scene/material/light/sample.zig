const Base = @import("../sample_base.zig").SampleBase;
const Renderstate = @import("../../renderstate.zig").Renderstate;
const bxdf = @import("../bxdf.zig");

const math = @import("base").math;
const Vec4f = math.Vec4f;

pub const Sample = struct {
    super: Base,

    pub fn init(rs: Renderstate, wo: Vec4f) Sample {
        return .{ .super = Base.init(
            rs,
            wo,
            @splat(4, @as(f32, 0.0)),
            @splat(2, @as(f32, 1.0)),
            0.0,
        ) };
    }

    pub fn sample() bxdf.Sample {
        return .{ .wavelength = 0.0 };
    }
};
