const base = @import("base");
const math = base.math;
const Vec4f = math.Vec4f;
const spectrum = base.spectrum;

const std = @import("std");

pub const Emittance = struct {
    const Quantity = enum {
        Flux,
        Intensity,
        Radiosity,
        Radiance,
    };

    value: Vec4f,
    quantity: Quantity,

    // unit: lumen
    pub fn setLuminousFlux(self: *Emittance, color: Vec4f, value: f32) void {
        const luminance = spectrum.luminance(color);

        self.value = @splat(4, value / (std.math.pi * luminance)) * color;
        self.quantity = .Intensity;
    }

    // unit: lumen per unit solid angle (lm / sr == candela (cd))
    pub fn setLuminousIntensity(self: *Emittance, color: Vec4f, value: f32) void {
        const luminance = spectrum.luminance(color);

        self.value = @splat(4, value / luminance) * color;
        self.quantity = .Intensity;
    }

    // unit: lumen per unit solid angle per unit projected area (lm / sr / m^2 == cd / m^2)
    pub fn setLuminance(self: *Emittance, color: Vec4f, value: f32) void {
        const luminance = spectrum.luminance(color);

        self.value = @splat(4, value / luminance) * color;
        self.quantity = .Radiance;
    }

    // unit: watt per unit solid angle (W / sr)
    pub fn setRadiantIntensity(self: *Emittance, color: Vec4f, value: f32) void {
        self.value = @splat(4, value) * color;
        self.quantity = Quantity.Intensity;
    }

    // unit: watt per unit solid angle per unit projected area (W / sr / m^2)
    pub fn setRadiance(self: *Emittance, rad: Vec4f) void {
        self.value = rad;
        self.quantity = Quantity.Radiance;
    }

    pub fn radiance(self: Emittance, area: f32) Vec4f {
        if (self.quantity == .Intensity) {
            return self.value / @splat(4, area);
        }

        return self.value;
    }
};
