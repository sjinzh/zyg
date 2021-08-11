const base = @import("base");
usingnamespace base;
usingnamespace base.math;

const std = @import("std");

pub const IndexTriangle = struct {
    i: [3]u32,
    part: u32,
};

pub fn intersect(ray: *Ray, a: Vec4f, b: Vec4f, c: Vec4f, u_out: *f32, v_out: *f32) bool {
    const e1 = b.sub3(a);
    const e2 = c.sub3(a);

    const tvec = ray.origin.sub3(a);
    const pvec = ray.direction.cross3(e2);
    const qvec = tvec.cross3(e1);

    const e1_d_pv = e1.dot3(pvec);
    const tv_d_pv = tvec.dot3(pvec);
    const di_d_qv = ray.direction.dot3(qvec);
    const e2_d_qv = e2.dot3(qvec);

    const inv_det = 1.0 / e1_d_pv;

    const u = tv_d_pv * inv_det;
    const v = di_d_qv * inv_det;
    const hit_t = e2_d_qv * inv_det;

    const uv = u + v;

    if (u >= 0.0 and 1.0 >= u and v >= 0.0 and 1.0 >= uv and hit_t >= ray.minT() and ray.maxT() >= hit_t) {
        ray.setMaxT(hit_t);
        u_out.* = u;
        v_out.* = v;
        return true;
    }

    return false;
}

pub fn intersectP(ray: Ray, a: Vec4f, b: Vec4f, c: Vec4f) bool {
    const e1 = b.sub3(a);
    const e2 = c.sub3(a);

    const tvec = ray.origin.sub3(a);
    const pvec = ray.direction.cross3(e2);
    const qvec = tvec.cross3(e1);

    const e1_d_pv = e1.dot3(pvec);
    const tv_d_pv = tvec.dot3(pvec);
    const di_d_qv = ray.direction.dot3(qvec);
    const e2_d_qv = e2.dot3(qvec);

    const inv_det = 1.0 / e1_d_pv;

    const u = tv_d_pv * inv_det;
    const v = di_d_qv * inv_det;
    const hit_t = e2_d_qv * inv_det;

    const uv = u + v;

    if (u >= 0.0 and 1.0 >= u and v >= 0.0 and 1.0 >= uv and hit_t >= ray.minT() and ray.maxT() >= hit_t) {
        return true;
    }

    return false;
}

pub fn interpolateP(a: Vec4f, b: Vec4f, c: Vec4f, u: f32, v: f32) Vec4f {
    const w = 1.0 - u - v;
    return a.mulScalar3(w).add3(b.mulScalar3(u)).add3(c.mulScalar3(v));
}
