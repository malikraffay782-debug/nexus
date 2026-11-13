// ============================================================================
//  GameAssets.hpp  -  C++17, header-only, zero dependencies
//
//  Contents
//   1) makeSword()          detailed fantasy longsword (fuller, bevels, wire-wrapped grip, gems)
//   2) makeWoodenCrate()    framed wooden crate with X-braces and metal corner brackets
//      makeTreasureChest()  chest with arched lid, iron bands, gold lock
//      makeMetalCase()      military supply case (chamfered, ribs, handles, latches)
//   3) Particle effects (CPU billboards, engine-agnostic):
//      makeCampfireSmoke()  rising smoke + embers
//      makeExplosion()      fireball + dark smoke + sparks + dust ring (burst)
//      makeMagicAura()      swirling glowing motes + mist (e.g. around the sword)
//      makeGroundFog()      slow low-lying fog (pre-warmed at the origin: use teleport())
//      + makeSmokeTexture() / makeGlowTexture()  (procedural RGBA8 textures)
//
//  Conventions
//   - Right-handed, Y-up, units = meters, triangles are CCW (front faces).
//   - Sword: origin = middle of the grip, blade points +Y, flat faces look +/-Z.
//   - Boxes: origin = bottom center.
//   - Vertex = pos(3f) normal(3f) uv(2f) = 32 bytes. Indices = uint32_t.
//   - addBox / addChamferBox-free faces use METRIC UVs (1 uv unit = 1 meter in
//     the builder's local space), so textures are not stretched on thin parts.
//   - Image rows: row 0 = BOTTOM of the image (v = 0), matching the particle quad
//     uv (0,0) = bottom-left. D3D/Vulkan-style APIs: flip v in the shader.
//   - Unreal/Unity-style engines: just remap axes/handedness when importing.
//
//  Quick use
//     ga::Mesh sword = ga::makeSword();
//     // upload sword.vertices.data() / sword.indices.data() to your GPU buffers,
//     // then draw each sword.subMeshes[i] (firstIndex, indexCount) with
//     // sword.materials[subMesh.material].
//
//     ga::Effect fx = ga::makeExplosion();
//     fx.setPosition({0,0,0}); fx.burst();
//     // each frame:
//     fx.update(dt);
//     for (auto& layer : fx.layers) {
//         std::vector<ga::ParticleVertex> v; std::vector<uint32_t> i;
//         layer.buildBillboards(camPos, camRight, camUp, v, i);
//         // draw with layer.desc().blend and texture layer.desc().texture
//     }
//     if (fx.aliveCount() == 0) { /* one-shot effect finished: recycle it */ }
//
//     setPosition() moves only the emitter (good for trailing smoke).
//     teleport()    also moves the particles already alive (good for placing
//                   pre-warmed effects such as makeGroundFog()).
//
//  Test:  g++ -std=c++17 -O2 -DGA_DEMO_MAIN demo.cpp   (demo.cpp includes this file)
//         writes sword.obj, crate.obj, chest.obj, metalcase.obj, smoke.tga, glow.tga
// ============================================================================
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <numeric>
#include <string>
#include <utility>
#include <vector>

namespace ga {

constexpr float kPi = 3.14159265358979323846f;

// ----------------------------------------------------------------------------
//  Math
// ----------------------------------------------------------------------------
struct Vec2 { float x = 0, y = 0; };
struct Vec3 { float x = 0, y = 0, z = 0; };
struct Vec4 { float x = 0, y = 0, z = 0, w = 0; };

inline Vec3 operator+(Vec3 a, Vec3 b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
inline Vec3 operator-(Vec3 a, Vec3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
inline Vec3 operator*(Vec3 a, float s) { return {a.x * s, a.y * s, a.z * s}; }
inline Vec3 operator*(float s, Vec3 a) { return a * s; }
inline Vec3& operator+=(Vec3& a, Vec3 b) { a = a + b; return a; }
inline float dot(Vec3 a, Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline Vec3 cross(Vec3 a, Vec3 b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
inline float length(Vec3 a) { return std::sqrt(dot(a, a)); }
inline Vec3 normalize(Vec3 a, Vec3 fallback = {0, 1, 0}) {
    float l = length(a);
    return l > 1e-12f ? a * (1.0f / l) : fallback;
}
inline float lerp(float a, float b, float t) { return a + (b - a) * t; }
inline Vec3 lerp(Vec3 a, Vec3 b, float t) { return a + (b - a) * t; }
inline Vec4 lerp(Vec4 a, Vec4 b, float t) {
    return {lerp(a.x, b.x, t), lerp(a.y, b.y, t), lerp(a.z, b.z, t), lerp(a.w, b.w, t)};
}
inline float clamp01(float x) { return x < 0.f ? 0.f : (x > 1.f ? 1.f : x); }
inline float smoothstep(float e0, float e1, float x) {
    float t = clamp01((x - e0) / (e1 - e0));
    return t * t * (3.f - 2.f * t);
}

// 3x3 rotation matrix stored as columns.
struct Mat3 { Vec3 c0{1, 0, 0}, c1{0, 1, 0}, c2{0, 0, 1}; };
inline Vec3 operator*(const Mat3& m, Vec3 v) { return m.c0 * v.x + m.c1 * v.y + m.c2 * v.z; }
inline Mat3 operator*(const Mat3& a, const Mat3& b) { return {a * b.c0, a * b.c1, a * b.c2}; }
inline Mat3 rotX(float a) { float c = std::cos(a), s = std::sin(a); return {{1, 0, 0}, {0, c, s}, {0, -s, c}}; }
inline Mat3 rotY(float a) { float c = std::cos(a), s = std::sin(a); return {{c, 0, -s}, {0, 1, 0}, {s, 0, c}}; }
inline Mat3 rotZ(float a) { float c = std::cos(a), s = std::sin(a); return {{c, s, 0}, {-s, c, 0}, {0, 0, 1}}; }

// Rotation + uniform scale + translation.
struct Xf {
    Mat3 R;
    Vec3 t{0, 0, 0};
    float s = 1.f;
    Vec3 point(Vec3 p) const { return R * (p * s) + t; }
    Vec3 dir(Vec3 d) const { return normalize(R * d); }
};
inline Xf operator*(const Xf& a, const Xf& b) {
    Xf r;
    r.R = a.R * b.R;
    r.s = a.s * b.s;
    r.t = a.R * (b.t * a.s) + a.t;
    return r;
}
inline Xf moveTo(Vec3 t) { Xf x; x.t = t; return x; }
inline Xf makeXf(const Mat3& R, Vec3 t = {0, 0, 0}, float s = 1.f) { Xf x; x.R = R; x.t = t; x.s = s; return x; }

// ----------------------------------------------------------------------------
//  Mesh data
// ----------------------------------------------------------------------------
struct Vertex { Vec3 pos; Vec3 normal; Vec2 uv; };
static_assert(sizeof(Vertex) == 32, "Vertex must be tightly packed (32 bytes)");

struct Material {
    std::string name;
    Vec3 baseColor{1, 1, 1};
    float metallic = 0.f;
    float roughness = 0.5f;
    Vec3 emissive{0, 0, 0};
};

struct SubMesh {
    uint32_t firstIndex = 0;
    uint32_t indexCount = 0;
    int material = 0;
};

struct Mesh {
    std::vector<Vertex> vertices;
    std::vector<uint32_t> indices;
    std::vector<SubMesh> subMeshes;
    std::vector<Material> materials;
    size_t triangleCount() const { return indices.size() / 3; }
};

struct ProfilePt { float r, y; bool hard = false; };  // for lathe (surface of revolution)

class MeshBuilder {
public:
    int addMaterial(Material m) { mesh_.materials.push_back(std::move(m)); return (int)mesh_.materials.size() - 1; }

    void useMaterial(int id) {
        closeSub();
        SubMesh s;
        s.firstIndex = (uint32_t)mesh_.indices.size();
        s.material = id;
        mesh_.subMeshes.push_back(s);
        subOpen_ = true;
    }

    Mesh finish() { closeSub(); return std::move(mesh_); }

    // ---- transform stack -------------------------------------------------
    void push(const Xf& x) { stack_.push_back(cur_); cur_ = cur_ * x; }
    void pop() { cur_ = stack_.back(); stack_.pop_back(); }

    // ---- low level -------------------------------------------------------
    uint32_t vert(Vec3 p, Vec3 n, Vec2 uv) {
        Vertex v;
        v.pos = cur_.point(p);
        v.normal = cur_.dir(n);
        v.uv = uv;
        mesh_.vertices.push_back(v);
        return (uint32_t)mesh_.vertices.size() - 1;
    }
    void tri(uint32_t a, uint32_t b, uint32_t c) {
        mesh_.indices.push_back(a);
        mesh_.indices.push_back(b);
        mesh_.indices.push_back(c);
    }

    // Flat-shaded quad, corners in CCW order (seen from the front).
    void quadFlat(Vec3 p0, Vec3 p1, Vec3 p2, Vec3 p3,
                  Vec2 t0 = {0, 0}, Vec2 t1 = {1, 0}, Vec2 t2 = {1, 1}, Vec2 t3 = {0, 1}) {
        Vec3 n = cross(p2 - p0, p3 - p1);
        if (dot(n, n) < 1e-18f) return;
        n = normalize(n);
        uint32_t a = vert(p0, n, t0), b = vert(p1, n, t1), c = vert(p2, n, t2), d = vert(p3, n, t3);
        if (area2(p0, p1, p2) > 1e-20f) tri(a, b, c);
        if (area2(p0, p2, p3) > 1e-20f) tri(a, c, d);
    }
    // Same, but flips the winding if the quad faces away from `outward`.
    // The UVs travel with their corners when the winding is flipped.
    void quadAuto(Vec3 p0, Vec3 p1, Vec3 p2, Vec3 p3, Vec3 outward,
                  Vec2 t0 = {0, 0}, Vec2 t1 = {1, 0}, Vec2 t2 = {1, 1}, Vec2 t3 = {0, 1}) {
        Vec3 n = cross(p2 - p0, p3 - p1);
        if (dot(n, outward) < 0.f) quadFlat(p0, p3, p2, p1, t0, t3, t2, t1);
        else quadFlat(p0, p1, p2, p3, t0, t1, t2, t3);
    }
    void triAuto(Vec3 a, Vec3 b, Vec3 c, Vec3 outward) {
        Vec3 n = cross(b - a, c - a);
        if (dot(n, outward) < 0.f) std::swap(b, c);
        n = normalize(cross(b - a, c - a));
        if (area2(a, b, c) < 1e-20f) return;
        uint32_t ia = vert(a, n, {0, 0}), ib = vert(b, n, {1, 0}), ic = vert(c, n, {0.5f, 1});
        tri(ia, ib, ic);
    }

    // ---- primitives ------------------------------------------------------
    // Metric UVs: each face is mapped 1 uv unit per meter, so a 0.11 x 1.0 beam
    // is not stretched like a 1 x 1 face would be.
    void addBox(Vec3 c, Vec3 h) {
        for (int a = 0; a < 3; ++a)
            for (int s = -1; s <= 1; s += 2) {
                int b = (a + 1) % 3, d = (a + 2) % 3;
                static const int ob[4] = {-1, 1, 1, -1}, od[4] = {-1, -1, 1, 1};
                Vec3 p[4];
                Vec2 t[4];
                for (int k = 0; k < 4; ++k) {
                    float e[3];
                    e[a] = s * comp(h, a);
                    e[b] = ob[k] * comp(h, b);
                    e[d] = od[k] * comp(h, d);
                    p[k] = c + Vec3{e[0], e[1], e[2]};
                    t[k] = {(float)(ob[k] + 1) * comp(h, b), (float)(od[k] + 1) * comp(h, d)};
                }
                float o[3] = {0, 0, 0};
                o[a] = (float)s;
                quadAuto(p[0], p[1], p[2], p[3], {o[0], o[1], o[2]}, t[0], t[1], t[2], t[3]);
            }
    }

    void addOrientedBox(Vec3 c, Vec3 h, const Mat3& R) {
        push(makeXf(R, c));
        addBox({0, 0, 0}, h);
        pop();
    }

    // Box with 45-degree chamfered edges.
    void addChamferBox(Vec3 c, Vec3 h, float ch) {
        ch = std::min(ch, std::min(h.x, std::min(h.y, h.z)) * 0.99f);
        auto Q = [&](const int sg[3], int full) {
            float e[3];
            for (int i = 0; i < 3; ++i) e[i] = sg[i] * (comp(h, i) - (i == full ? 0.f : ch));
            return c + Vec3{e[0], e[1], e[2]};
        };
        // faces
        for (int a = 0; a < 3; ++a)
            for (int s = -1; s <= 1; s += 2) {
                int b = (a + 1) % 3, d = (a + 2) % 3;
                static const int ob[4] = {-1, 1, 1, -1}, od[4] = {-1, -1, 1, 1};
                Vec3 p[4];
                for (int k = 0; k < 4; ++k) {
                    int sg[3];
                    sg[a] = s; sg[b] = ob[k]; sg[d] = od[k];
                    p[k] = Q(sg, a);
                }
                Vec3 ctr = (p[0] + p[1] + p[2] + p[3]) * 0.25f;
                quadAuto(p[0], p[1], p[2], p[3], ctr - c);
            }
        // edges
        for (int a = 0; a < 3; ++a) {
            int b = (a + 1) % 3, d = (a + 2) % 3;
            for (int sa = -1; sa <= 1; sa += 2)
                for (int sb = -1; sb <= 1; sb += 2) {
                    int s0[3], s1[3], s2[3], s3[3];
                    s0[a] = sa; s0[b] = sb; s0[d] = -1;
                    s1[a] = sa; s1[b] = sb; s1[d] = 1;
                    s2[a] = sa; s2[b] = sb; s2[d] = 1;
                    s3[a] = sa; s3[b] = sb; s3[d] = -1;
                    Vec3 p0 = Q(s0, a), p1 = Q(s1, a), p2 = Q(s2, b), p3 = Q(s3, b);
                    Vec3 ctr = (p0 + p1 + p2 + p3) * 0.25f;
                    quadAuto(p0, p1, p2, p3, ctr - c);
                }
        }
        // corners
        for (int sx = -1; sx <= 1; sx += 2)
            for (int sy = -1; sy <= 1; sy += 2)
                for (int sz = -1; sz <= 1; sz += 2) {
                    int sg[3] = {sx, sy, sz};
                    Vec3 p0 = Q(sg, 0), p1 = Q(sg, 1), p2 = Q(sg, 2);
                    Vec3 ctr = (p0 + p1 + p2) * (1.f / 3.f);
                    triAuto(p0, p1, p2, ctr - c);
                }
    }

    // Surface of revolution around the Y axis. Profile goes bottom -> top.
    // A point with r == 0 closes the surface (cap / pole).
    void addLathe(const std::vector<ProfilePt>& p, int seg) {
        const size_t n = p.size();
        if (n < 2 || seg < 3) return;
        std::vector<Vec2> sn(n - 1);
        for (size_t i = 0; i + 1 < n; ++i) {
            float dr = p[i + 1].r - p[i].r, dy = p[i + 1].y - p[i].y;
            float l = std::sqrt(dr * dr + dy * dy);
            sn[i] = l < 1e-9f ? Vec2{1, 0} : Vec2{dy / l, -dr / l};
        }
        auto avg = [](Vec2 a, Vec2 b) {
            Vec2 m{a.x + b.x, a.y + b.y};
            float l = std::sqrt(m.x * m.x + m.y * m.y);
            return l < 1e-9f ? a : Vec2{m.x / l, m.y / l};
        };
        for (size_t i = 0; i + 1 < n; ++i) {
            Vec2 n0 = sn[i], n1 = sn[i];
            if (i > 0 && !p[i].hard) n0 = avg(sn[i - 1], sn[i]);
            if (i + 2 < n && !p[i + 1].hard) n1 = avg(sn[i], sn[i + 1]);
            float v0 = (float)i / (float)(n - 1), v1 = (float)(i + 1) / (float)(n - 1);
            std::vector<uint32_t> r0(seg + 1), r1(seg + 1);
            for (int j = 0; j <= seg; ++j) {
                float u = (float)j / (float)seg, th = 2.f * kPi * u;
                float cs = std::cos(th), sg = std::sin(th);
                r0[j] = vert({p[i].r * cs, p[i].y, p[i].r * sg}, {n0.x * cs, n0.y, n0.x * sg}, {u, v0});
                r1[j] = vert({p[i + 1].r * cs, p[i + 1].y, p[i + 1].r * sg}, {n1.x * cs, n1.y, n1.x * sg}, {u, v1});
            }
            bool deg0 = p[i].r < 1e-6f, deg1 = p[i + 1].r < 1e-6f;
            for (int j = 0; j < seg; ++j) {
                uint32_t a = r0[j], b = r0[j + 1], c = r1[j + 1], d = r1[j];
                if (!deg0) tri(a, c, b);
                if (!deg1) tri(a, d, c);
            }
        }
    }

    void addCylinder(float r, float y0, float y1, int seg) {
        addLathe({{0, y0}, {r, y0, true}, {r, y1, true}, {0, y1}}, seg);
    }

    void addSphere(Vec3 c, float r, int seg = 24, int rings = 12) {
        std::vector<ProfilePt> prof;
        for (int i = 0; i <= rings; ++i) {
            float ph = kPi * (float)i / (float)rings;
            prof.push_back({i == 0 || i == rings ? 0.f : r * std::sin(ph), -r * std::cos(ph), false});
        }
        push(moveTo(c));
        addLathe(prof, seg);
        pop();
    }

    // Circle swept along a polyline (parallel-transport frames).
    void addTube(const std::vector<Vec3>& path, const std::vector<float>& radii, int sides,
                 bool capStart = true, bool capEnd = true) {
        const size_t n = path.size();
        if (n < 2 || radii.size() != n || sides < 3) return;
        std::vector<Vec3> T(n), N(n), B(n);
        for (size_t i = 0; i < n; ++i) {
            Vec3 d = i == 0 ? path[1] - path[0] : (i == n - 1 ? path[n - 1] - path[n - 2] : path[i + 1] - path[i - 1]);
            T[i] = normalize(d);
        }
        Vec3 ref = std::fabs(T[0].y) < 0.9f ? Vec3{0, 1, 0} : Vec3{1, 0, 0};
        Vec3 cur = normalize(ref - T[0] * dot(ref, T[0]));
        for (size_t i = 0; i < n; ++i) {
            if (i > 0) cur = normalize(cur - T[i] * dot(cur, T[i]));
            N[i] = cur;
            B[i] = cross(T[i], cur);
        }
        std::vector<std::vector<uint32_t>> rings(n, std::vector<uint32_t>(sides + 1));
        for (size_t i = 0; i < n; ++i)
            for (int k = 0; k <= sides; ++k) {
                float u = (float)k / (float)sides, ph = 2.f * kPi * u;
                Vec3 dir = N[i] * std::cos(ph) + B[i] * std::sin(ph);
                rings[i][k] = vert(path[i] + dir * radii[i], dir, {u, (float)i / (float)(n - 1)});
            }
        for (size_t i = 0; i + 1 < n; ++i)
            for (int k = 0; k < sides; ++k) {
                uint32_t a = rings[i][k], b = rings[i][k + 1], c = rings[i + 1][k + 1], d = rings[i + 1][k];
                tri(a, b, c);
                tri(a, c, d);
            }
        auto cap = [&](size_t i, bool end) {
            Vec3 nrm = end ? T[i] : T[i] * -1.f;
            uint32_t ctr = vert(path[i], nrm, {0.5f, 0.5f});
            std::vector<uint32_t> rim(sides + 1);
            for (int k = 0; k <= sides; ++k) {
                float ph = 2.f * kPi * (float)k / (float)sides;
                Vec3 dir = N[i] * std::cos(ph) + B[i] * std::sin(ph);
                rim[k] = vert(path[i] + dir * radii[i], nrm, {0.5f + 0.5f * std::cos(ph), 0.5f + 0.5f * std::sin(ph)});
            }
            for (int k = 0; k < sides; ++k) {
                if (end) tri(ctr, rim[k], rim[k + 1]);
                else tri(ctr, rim[k + 1], rim[k]);
            }
        };
        if (capStart) cap(0, false);
        if (capEnd) cap(n - 1, true);
    }

    // Half-cylinder "arch" (chest lid): axis along X, rises from y = cy, front at +Z.
    void addArch(float xc, float width, float R, float cy, int seg, bool caps = true) {
        float x0 = xc - width * 0.5f, x1 = xc + width * 0.5f;
        for (int k = 0; k < seg; ++k) {
            float a0 = kPi * (float)k / (float)seg, a1 = kPi * (float)(k + 1) / (float)seg;
            Vec3 n0{0, std::sin(a0), std::cos(a0)}, n1{0, std::sin(a1), std::cos(a1)};
            float v0 = (float)k / (float)seg, v1 = (float)(k + 1) / (float)seg;
            uint32_t A = vert({x0, cy + R * n0.y, R * n0.z}, n0, {0, v0});
            uint32_t B = vert({x1, cy + R * n0.y, R * n0.z}, n0, {1, v0});
            uint32_t C = vert({x1, cy + R * n1.y, R * n1.z}, n1, {1, v1});
            uint32_t D = vert({x0, cy + R * n1.y, R * n1.z}, n1, {0, v1});
            tri(A, B, C);
            tri(A, C, D);
        }
        if (!caps) return;
        for (int side = -1; side <= 1; side += 2) {
            float x = side > 0 ? x1 : x0;
            Vec3 nrm{(float)side, 0, 0};
            uint32_t ctr = vert({x, cy, 0}, nrm, {0.5f, 0.f});
            std::vector<uint32_t> rim(seg + 1);
            for (int k = 0; k <= seg; ++k) {
                float a = kPi * (float)k / (float)seg;
                rim[k] = vert({x, cy + R * std::sin(a), R * std::cos(a)}, nrm, {0.5f + 0.5f * std::cos(a), 0.5f * std::sin(a)});
            }
            for (int k = 0; k < seg; ++k) {
                if (side > 0) tri(ctr, rim[k + 1], rim[k]);
                else tri(ctr, rim[k], rim[k + 1]);
            }
        }
    }

private:
    static float comp(Vec3 v, int i) { return i == 0 ? v.x : (i == 1 ? v.y : v.z); }
    static float area2(Vec3 a, Vec3 b, Vec3 c) { Vec3 n = cross(b - a, c - a); return dot(n, n); }
    void closeSub() {
        if (!subOpen_) return;
        SubMesh& s = mesh_.subMeshes.back();
        s.indexCount = (uint32_t)mesh_.indices.size() - s.firstIndex;
        if (s.indexCount == 0) mesh_.subMeshes.pop_back();
        subOpen_ = false;
    }

    Mesh mesh_;
    Xf cur_;
    std::vector<Xf> stack_;
    bool subOpen_ = false;
};

class ScopedXf {
public:
    ScopedXf(MeshBuilder& b, const Xf& x) : b_(b) { b_.push(x); }
    ~ScopedXf() { b_.pop(); }
    ScopedXf(const ScopedXf&) = delete;
    ScopedXf& operator=(const ScopedXf&) = delete;
private:
    MeshBuilder& b_;
};

// ============================================================================
//  1) SWORD
// ============================================================================
inline Mesh makeSword() {
    MeshBuilder mb;
    const int mSteel = mb.addMaterial({"blade_steel", {0.78f, 0.80f, 0.84f}, 0.95f, 0.22f, {0, 0, 0}});
    const int mGold = mb.addMaterial({"guard_gold", {1.00f, 0.78f, 0.36f}, 0.90f, 0.32f, {0, 0, 0}});
    const int mLeather = mb.addMaterial({"grip_leather", {0.17f, 0.09f, 0.05f}, 0.0f, 0.80f, {0, 0, 0}});
    const int mWire = mb.addMaterial({"grip_wire", {0.62f, 0.47f, 0.22f}, 0.85f, 0.38f, {0, 0, 0}});
    const int mGem = mb.addMaterial({"gem_ruby", {0.85f, 0.04f, 0.10f}, 0.0f, 0.08f, {0.60f, 0.0f, 0.05f}});

    // ---------------- blade ----------------
    // Cross-section (x = fraction of half-width, z = fraction of half-thickness), 14 points.
    // Double bevel + central fuller (blood groove) on both faces.
    mb.useMaterial(mSteel);
    {
        const int kSections = 48;
        const float y0 = 0.118f, L = 0.855f;       // starts hidden inside the guard
        const float W0 = 0.026f, T0 = 0.0048f;     // half width / half thickness at the base
        static const float cs[14][2] = {
            {1.00f, 0.f},   {0.50f, 0.75f}, {0.20f, 1.0f},  {0.12f, 0.f},  {-0.12f, 0.f}, {-0.20f, 1.0f}, {-0.50f, 0.75f},
            {-1.00f, 0.f},  {-0.50f, -0.75f}, {-0.20f, -1.0f}, {-0.12f, 0.f}, {0.12f, 0.f},  {0.20f, -1.0f}, {0.50f, -0.75f}};
        auto section = [&](float t, Vec3 out[14]) {
            float tipT = clamp01((t - 0.78f) / 0.22f);
            float shW = std::pow(std::max(0.f, 1.f - tipT), 0.75f);
            float shT = std::pow(std::max(0.f, 1.f - tipT), 0.90f);
            float ww = W0 * (1.f - 0.16f * t) * shW;
            float tt = T0 * (1.f - 0.35f * t) * shT;
            float fuller = smoothstep(0.03f, 0.12f, t) * (1.f - smoothstep(0.60f, 0.78f, t));
            float groove = 1.f - 0.60f * fuller;
            for (int i = 0; i < 14; ++i) {
                float zf = cs[i][1];
                if (i == 3 || i == 4) zf = groove;
                if (i == 10 || i == 11) zf = -groove;
                out[i] = {cs[i][0] * ww, y0 + t * L, zf * tt};
            }
        };
        Vec3 ringA[14], ringB[14];
        section(0.f, ringA);
        for (int s = 0; s < kSections; ++s) {
            float t0 = (float)s / kSections, t1 = (float)(s + 1) / kSections;
            section(t1, ringB);
            for (int k = 0; k < 14; ++k) {
                int k2 = (k + 1) % 14;
                float u0 = (float)k / 14.f, u1 = (float)(k + 1) / 14.f;
                // CCW from outside: (a, d, c, b)
                mb.quadFlat(ringA[k], ringB[k], ringB[k2], ringA[k2], {u0, t0}, {u0, t1}, {u1, t1}, {u1, t0});
            }
            for (int k = 0; k < 14; ++k) ringA[k] = ringB[k];
        }
    }

    // ---------------- guard, collars, pommel (gold) ----------------
    mb.useMaterial(mGold);
    mb.addChamferBox({0, 0.112f, 0}, {0.034f, 0.011f, 0.017f}, 0.004f);
    for (int side = -1; side <= 1; side += 2) {
        std::vector<Vec3> path;
        std::vector<float> rad;
        const int N = 14;
        for (int i = 0; i <= N; ++i) {
            float t = (float)i / N;
            path.push_back({side * (0.030f + t * 0.105f), 0.112f + 0.030f * t * t, 0.f});
            rad.push_back(lerp(0.0085f, 0.0058f, t));
        }
        mb.addTube(path, rad, 12, false, false);
        mb.addSphere(path.back(), 0.0085f, 16, 10);
    }
    mb.addCylinder(0.0195f, -0.108f, -0.100f, 24);   // lower collar
    mb.addCylinder(0.0195f, 0.098f, 0.104f, 24);     // upper collar
    mb.addLathe({{0.f, -0.172f}, {0.010f, -0.170f}, {0.020f, -0.162f}, {0.027f, -0.148f}, {0.029f, -0.135f},
                 {0.026f, -0.122f}, {0.018f, -0.114f}, {0.0125f, -0.109f, true}, {0.f, -0.109f}}, 32);
    mb.addSphere({0, -0.176f, 0}, 0.0075f, 16, 10);   // pommel button

    // ---------------- grip ----------------
    mb.useMaterial(mLeather);
    static const float gp[7][2] = {{-0.100f, 0.0135f}, {-0.085f, 0.0150f}, {-0.050f, 0.0162f}, {-0.010f, 0.0170f},
                                   {0.020f, 0.0170f},  {0.060f, 0.0160f},  {0.098f, 0.0140f}};
    mb.addLathe({{0.f, -0.100f}, {0.0135f, -0.100f, true}, {0.0150f, -0.085f}, {0.0162f, -0.050f}, {0.0170f, -0.010f},
                 {0.0170f, 0.020f}, {0.0160f, 0.060f}, {0.0140f, 0.098f, true}, {0.f, 0.098f}}, 28);

    // wire wrap (helix)
    mb.useMaterial(mWire);
    {
        auto gripR = [&](float y) {
            for (int i = 0; i < 6; ++i)
                if (y <= gp[i + 1][0]) return lerp(gp[i][1], gp[i + 1][1], (y - gp[i][0]) / (gp[i + 1][0] - gp[i][0]));
            return gp[6][1];
        };
        std::vector<Vec3> path;
        std::vector<float> rad;
        const int turns = 12, perTurn = 14, N = turns * perTurn;
        for (int i = 0; i <= N; ++i) {
            float t = (float)i / N, a = 2.f * kPi * turns * t;
            float y = lerp(-0.098f, 0.096f, t), r = gripR(y) + 0.0009f;
            path.push_back({r * std::cos(a), y, r * std::sin(a)});
            rad.push_back(0.0018f);
        }
        mb.addTube(path, rad, 6, true, true);
    }

    // ---------------- gems (front + back of guard) ----------------
    mb.useMaterial(mGem);
    mb.addSphere({0, 0.112f, 0.0165f}, 0.0078f, 14, 8);
    mb.addSphere({0, 0.112f, -0.0165f}, 0.0078f, 14, 8);

    return mb.finish();
}

// ============================================================================
//  2) BOXES
// ============================================================================
inline Mesh makeWoodenCrate(float size = 1.0f) {
    MeshBuilder mb;
    const int mPlank = mb.addMaterial({"crate_planks", {0.58f, 0.38f, 0.19f}, 0.0f, 0.85f, {0, 0, 0}});
    const int mFrame = mb.addMaterial({"crate_frame", {0.40f, 0.25f, 0.12f}, 0.0f, 0.85f, {0, 0, 0}});
    const int mMetal = mb.addMaterial({"crate_metal", {0.30f, 0.31f, 0.33f}, 0.85f, 0.45f, {0, 0, 0}});
    ScopedXf scope(mb, makeXf(Mat3{}, {0, 0.5f * size, 0}, size));   // origin at bottom center

    const float h = 0.5f, b = 0.055f;
    mb.useMaterial(mPlank);
    mb.addBox({0, 0, 0}, {h - 0.02f, h - 0.02f, h - 0.02f});

    mb.useMaterial(mFrame);
    // 12 edge beams (x-beams are full length, y/z-beams butt against them -> no z-fighting)
    for (int a = 0; a < 3; ++a) {
        int bb = (a + 1) % 3, cc = (a + 2) % 3;
        for (int sb = -1; sb <= 1; sb += 2)
            for (int sc = -1; sc <= 1; sc += 2) {
                float cen[3], hf[3];
                cen[a] = 0; cen[bb] = sb * (h - b); cen[cc] = sc * (h - b);
                hf[a] = (a == 0) ? h : h - 2 * b; hf[bb] = b; hf[cc] = b;
                mb.addBox({cen[0], cen[1], cen[2]}, {hf[0], hf[1], hf[2]});
            }
    }
    // diagonal brace on each of the 6 faces
    const Vec3 axes[3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};
    for (int a = 0; a < 3; ++a)
        for (int s = -1; s <= 1; s += 2) {
            Vec3 n = axes[a] * (float)s;
            Vec3 u = s > 0 ? axes[(a + 1) % 3] : axes[(a + 2) % 3];
            Vec3 v = s > 0 ? axes[(a + 2) % 3] : axes[(a + 1) % 3];
            const float k = 0.70710678f;
            Mat3 R{(u + v) * k, (v - u) * k, n};
            mb.addOrientedBox(n * (h - 0.012f), {0.60f, 0.045f, 0.012f}, R);
        }

    mb.useMaterial(mMetal);
    for (int sx = -1; sx <= 1; sx += 2)
        for (int sy = -1; sy <= 1; sy += 2)
            for (int sz = -1; sz <= 1; sz += 2)
                mb.addBox({sx * (h - 0.062f), sy * (h - 0.062f), sz * (h - 0.062f)}, {0.07f, 0.07f, 0.07f});
    return mb.finish();
}

inline Mesh makeTreasureChest() {
    MeshBuilder mb;
    const int mWood = mb.addMaterial({"chest_wood", {0.45f, 0.27f, 0.12f}, 0.0f, 0.80f, {0, 0, 0}});
    const int mIron = mb.addMaterial({"chest_iron", {0.24f, 0.24f, 0.27f}, 0.85f, 0.45f, {0, 0, 0}});
    const int mGold = mb.addMaterial({"chest_gold", {1.00f, 0.78f, 0.30f}, 0.95f, 0.28f, {0, 0, 0}});
    const int mDark = mb.addMaterial({"chest_dark", {0.03f, 0.03f, 0.03f}, 0.0f, 0.9f, {0, 0, 0}});

    mb.useMaterial(mWood);
    const float h3 = 0.5f / 3.f;
    for (int i = 0; i < 3; ++i)   // three planks, alternate depth -> visible seams
        mb.addBox({0, (i + 0.5f) * h3, 0}, {0.5f, h3 * 0.5f, 0.3f - ((i % 2) ? 0.004f : 0.f)});
    mb.addArch(0, 1.0f, 0.3f, 0.5f, 28, true);   // lid

    mb.useMaterial(mIron);
    for (int s = -1; s <= 1; s += 2) {
        // FIX: spans y = 0 .. 0.505 (previously started at -0.005, below the floor)
        mb.addBox({s * 0.30f, 0.2525f, 0}, {0.04f, 0.2525f, 0.305f});       // body bands
        mb.addArch(s * 0.30f, 0.08f, 0.308f, 0.5f, 28, true);               // lid bands
        for (int sz = -1; sz <= 1; sz += 2)                                  // vertical corner plates
            mb.addBox({s * 0.476f, 0.2525f, sz * 0.276f}, {0.03f, 0.2525f, 0.03f});
    }
    mb.addBox({0, 0.5f, 0}, {0.505f, 0.012f, 0.305f});                       // lid seam trim
    mb.addBox({0, 0.47f, 0.305f}, {0.04f, 0.09f, 0.005f});                   // hasp strap

    mb.useMaterial(mGold);
    mb.addChamferBox({0, 0.48f, 0.312f}, {0.05f, 0.075f, 0.012f}, 0.005f);   // lock plate
    for (int sx = -1; sx <= 1; sx += 2)
        for (int sy = 0; sy <= 1; sy += 1)
            mb.addSphere({sx * 0.30f, 0.12f + sy * 0.26f, 0.306f}, 0.011f, 12, 8);   // rivets

    mb.useMaterial(mDark);
    mb.addBox({0, 0.47f, 0.326f}, {0.009f, 0.022f, 0.004f});                 // keyhole
    (void)mWood;
    return mb.finish();
}

inline Mesh makeMetalCase() {
    MeshBuilder mb;
    const int mOlive = mb.addMaterial({"case_olive", {0.27f, 0.32f, 0.20f}, 0.60f, 0.55f, {0, 0, 0}});
    const int mDark = mb.addMaterial({"case_olive_dark", {0.19f, 0.23f, 0.14f}, 0.60f, 0.60f, {0, 0, 0}});
    const int mSteel = mb.addMaterial({"case_steel", {0.62f, 0.64f, 0.67f}, 0.90f, 0.35f, {0, 0, 0}});

    mb.useMaterial(mOlive);
    mb.addChamferBox({0, 0.225f, 0}, {0.45f, 0.225f, 0.25f}, 0.03f);
    for (int s = -1; s <= 1; s += 2)
        mb.addBox({s * 0.30f, 0.455f, 0}, {0.02f, 0.006f, 0.19f});           // raised ribs on the lid

    mb.useMaterial(mDark);
    mb.addBox({0, 0.30f, 0}, {0.4525f, 0.006f, 0.2525f});                    // lid seam

    mb.useMaterial(mSteel);
    {   // top carry handle
        std::vector<Vec3> path;
        std::vector<float> rad;
        const int N = 16;
        for (int i = 0; i <= N; ++i) {
            float a = kPi * (float)i / N;
            path.push_back({-0.12f * std::cos(a), 0.452f + 0.07f * std::sin(a), 0.f});
            rad.push_back(0.012f);
        }
        mb.addTube(path, rad, 10, false, false);
        for (int s = -1; s <= 1; s += 2) mb.addChamferBox({s * 0.12f, 0.458f, 0}, {0.03f, 0.012f, 0.025f}, 0.004f);
    }
    for (int s = -1; s <= 1; s += 2) {   // side handles
        std::vector<Vec3> path;
        std::vector<float> rad;
        const int N = 14;
        for (int i = 0; i <= N; ++i) {
            float a = -kPi * 0.5f + kPi * (float)i / N;
            path.push_back({s * (0.44f + 0.045f * std::cos(a)), 0.225f + 0.07f * std::sin(a), 0.f});
            rad.push_back(0.009f);
        }
        mb.addTube(path, rad, 8, false, false);
    }
    for (int s = -1; s <= 1; s += 2) {
        mb.addChamferBox({s * 0.25f, 0.30f, 0.258f}, {0.03f, 0.04f, 0.008f}, 0.003f);       // front latches
        mb.addChamferBox({s * 0.25f, 0.33f, 0.262f}, {0.012f, 0.012f, 0.006f}, 0.002f);
        mb.addChamferBox({s * 0.25f, 0.30f, -0.258f}, {0.035f, 0.05f, 0.008f}, 0.003f);     // rear hinges
    }
    return mb.finish();
}

// ============================================================================
//  Mesh utilities
// ============================================================================
// Number of triangles whose winding disagrees with their vertex normals (should be 0).
inline size_t countInvertedTriangles(const Mesh& m) {
    size_t bad = 0;
    for (size_t i = 0; i + 2 < m.indices.size(); i += 3) {
        const Vertex &a = m.vertices[m.indices[i]], &b = m.vertices[m.indices[i + 1]], &c = m.vertices[m.indices[i + 2]];
        Vec3 n = cross(b.pos - a.pos, c.pos - a.pos);
        if (dot(n, n) < 1e-16f) continue;
        if (dot(n, a.normal + b.normal + c.normal) < 0.f) ++bad;
    }
    return bad;
}

// Wavefront OBJ + MTL export (open in Blender to inspect).
inline bool writeOBJ(const Mesh& m, const std::string& path) {
    std::string base = path;
    // FIX: only strip an extension that belongs to the file name, not to a directory ("./out/sword").
    size_t slashB = base.find_last_of("/\\");
    size_t dotPos = base.rfind('.');
    if (dotPos != std::string::npos && (slashB == std::string::npos || dotPos > slashB)) base.resize(dotPos);
    std::string mtlPath = base + ".mtl";
    size_t slash = mtlPath.find_last_of("/\\");
    std::string mtlName = slash == std::string::npos ? mtlPath : mtlPath.substr(slash + 1);

    FILE* f = std::fopen(path.c_str(), "w");
    if (!f) return false;
    std::fprintf(f, "mtllib %s\n", mtlName.c_str());
    for (const auto& v : m.vertices) std::fprintf(f, "v %.6f %.6f %.6f\n", v.pos.x, v.pos.y, v.pos.z);
    for (const auto& v : m.vertices) std::fprintf(f, "vt %.6f %.6f\n", v.uv.x, v.uv.y);
    for (const auto& v : m.vertices) std::fprintf(f, "vn %.6f %.6f %.6f\n", v.normal.x, v.normal.y, v.normal.z);
    for (const auto& s : m.subMeshes) {
        std::fprintf(f, "usemtl %s\n", m.materials[s.material].name.c_str());
        for (uint32_t i = s.firstIndex; i < s.firstIndex + s.indexCount; i += 3) {
            uint32_t a = m.indices[i] + 1, b = m.indices[i + 1] + 1, c = m.indices[i + 2] + 1;
            std::fprintf(f, "f %u/%u/%u %u/%u/%u %u/%u/%u\n", a, a, a, b, b, b, c, c, c);
        }
    }
    std::fclose(f);
    FILE* g = std::fopen(mtlPath.c_str(), "w");
    if (!g) return false;
    for (const auto& mt : m.materials) {
        std::fprintf(g, "newmtl %s\nKd %.3f %.3f %.3f\nKs %.3f %.3f %.3f\nKe %.3f %.3f %.3f\nNs %.1f\n\n",
                     mt.name.c_str(), mt.baseColor.x, mt.baseColor.y, mt.baseColor.z,
                     mt.metallic, mt.metallic, mt.metallic, mt.emissive.x, mt.emissive.y, mt.emissive.z,
                     (1.f - mt.roughness) * 200.f);
    }
    std::fclose(g);
    return true;
}

// ============================================================================
//  3) PARTICLES / SMOKE
// ============================================================================
struct ParticleVertex { Vec3 pos; Vec2 uv; Vec4 color; };   // uv (0,0) = bottom-left of the quad

enum class Blend { Alpha, Additive };
enum class EmitShape { Point, Sphere, Disc, Cylinder };
enum class TexKind { Smoke, Glow };
struct ColorStop { float t; Vec4 c; };

struct ParticleDesc {
    std::string name;
    Blend blend = Blend::Alpha;
    TexKind texture = TexKind::Smoke;
    EmitShape shape = EmitShape::Point;
    float shapeRadius = 0.1f, shapeHeight = 0.f;
    size_t maxParticles = 256;
    float rate = 20.f;                 // particles / second (continuous)
    int burstCount = 0;                // particles per burst()
    float lifeMin = 1.f, lifeMax = 2.f;
    float speedMin = 0.5f, speedMax = 1.f;
    Vec3 direction{0, 1, 0};
    float spreadDeg = 15.f;            // cone half-angle around `direction`
    bool radialVelocity = false;       // fly away from the emitter center instead
    float radialUpBias = 0.f;
    Vec3 gravity{0, 0, 0};             // constant acceleration (use +Y for buoyancy)
    float drag = 0.f;
    float turbulence = 0.f, turbulenceScale = 1.f;
    float orbitSpeed = 0.f;            // rad/s swirl around the emitter's Y axis
    float sizeMin = 0.2f, sizeMax = 0.3f, sizeEndScale = 3.f;
    float rotSpeedMin = -0.5f, rotSpeedMax = 0.5f;
    float fadeIn = 0.1f;               // fraction of life used to fade in
    std::vector<ColorStop> gradient;   // color over normalized life
};

struct Rng {
    uint32_t s;
    explicit Rng(uint32_t seed = 1) : s(seed * 2654435761u | 1u) {}
    uint32_t nextU() { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return s; }
    float next() { return (float)(nextU() >> 8) * (1.f / 16777216.f); }
    float range(float a, float b) { return a + (b - a) * next(); }
    Vec3 unitVec() {
        float z = range(-1.f, 1.f), a = range(0.f, 2.f * kPi), r = std::sqrt(std::max(0.f, 1.f - z * z));
        return {r * std::cos(a), z, r * std::sin(a)};
    }
};

inline float hash31(int x, int y, int z) {
    uint32_t h = (uint32_t)x * 374761393u + (uint32_t)y * 668265263u + (uint32_t)z * 2147483647u;
    h = (h ^ (h >> 13)) * 1274126177u;
    return (float)((h ^ (h >> 16)) & 0xFFFFFFu) / 16777215.f;
}
inline float valueNoise(Vec3 p) {
    int xi = (int)std::floor(p.x), yi = (int)std::floor(p.y), zi = (int)std::floor(p.z);
    float fx = p.x - xi, fy = p.y - yi, fz = p.z - zi;
    float ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy), uz = fz * fz * (3 - 2 * fz);
    auto h = [&](int dx, int dy, int dz) { return hash31(xi + dx, yi + dy, zi + dz); };
    float x00 = lerp(h(0, 0, 0), h(1, 0, 0), ux), x10 = lerp(h(0, 1, 0), h(1, 1, 0), ux);
    float x01 = lerp(h(0, 0, 1), h(1, 0, 1), ux), x11 = lerp(h(0, 1, 1), h(1, 1, 1), ux);
    return lerp(lerp(x00, x10, uy), lerp(x01, x11, uy), uz);
}
inline float fbm(Vec3 p, int oct) {
    float a = 0.5f, sum = 0.f, norm = 0.f;
    for (int i = 0; i < oct; ++i) { sum += a * valueNoise(p); norm += a; p = p * 2.03f; a *= 0.5f; }
    return sum / norm;
}
inline Vec3 turbulenceVec(Vec3 p) {
    return {valueNoise(p) * 2.f - 1.f, valueNoise(p + Vec3{31.4f, 17.7f, 5.1f}) * 2.f - 1.f,
            valueNoise(p + Vec3{-12.9f, 41.3f, 23.8f}) * 2.f - 1.f};
}
inline Vec3 perpendicularTo(Vec3 d) {
    Vec3 ref = std::fabs(d.y) < 0.99f ? Vec3{0, 1, 0} : Vec3{1, 0, 0};
    return normalize(cross(d, ref));
}
inline Vec3 coneDir(Vec3 axis, float spreadRad, Rng& r) {
    axis = normalize(axis);
    float cosT = lerp(1.f, std::cos(spreadRad), r.next());
    float sinT = std::sqrt(std::max(0.f, 1.f - cosT * cosT)), ph = r.range(0.f, 2.f * kPi);
    Vec3 u = perpendicularTo(axis), v = cross(axis, u);
    return normalize(axis * cosT + (u * std::cos(ph) + v * std::sin(ph)) * sinT);
}
inline Vec4 sampleGradient(const std::vector<ColorStop>& g, float t) {
    if (g.empty()) return {1, 1, 1, 1};
    if (t <= g.front().t) return g.front().c;
    for (size_t i = 1; i < g.size(); ++i)
        if (t <= g[i].t) return lerp(g[i - 1].c, g[i].c, (t - g[i - 1].t) / std::max(1e-6f, g[i].t - g[i - 1].t));
    return g.back().c;
}

class ParticleSystem {
public:
    explicit ParticleSystem(ParticleDesc d, uint32_t seed = 1) : d_(std::move(d)), rng_(seed) { p_.reserve(d_.maxParticles); }

    const ParticleDesc& desc() const { return d_; }
    // Moves only the emitter: particles already alive keep their world position (trailing smoke).
    void setPosition(Vec3 p) { pos_ = p; }
    // Moves the emitter AND every live particle (placing pre-warmed effects such as ground fog).
    void teleport(Vec3 p) {
        Vec3 d = p - pos_;
        for (auto& q : p_) q.pos += d;
        pos_ = p;
    }
    void setEmitting(bool e) { emitting_ = e; }
    void clear() { p_.clear(); acc_ = 0.f; }
    size_t aliveCount() const { return p_.size(); }
    void burst(int n = -1) { for (int i = 0, c = n < 0 ? d_.burstCount : n; i < c; ++i) spawn(); }
    void prewarm(float seconds, float step = 0.05f) { for (float t = 0.f; t < seconds; t += step) update(step); }

    void update(float dt) {
        dt = std::min(std::max(dt, 0.f), 0.1f);   // a frame hitch must not blow up the simulation
        time_ += dt;
        for (size_t i = 0; i < p_.size();) {
            Particle& q = p_[i];
            q.age += dt;
            if (q.age >= q.life) { q = p_.back(); p_.pop_back(); continue; }
            q.vel += d_.gravity * dt;
            if (d_.turbulence > 0.f) {
                Vec3 tp = q.pos * d_.turbulenceScale + Vec3{0.f, time_ * 0.35f, time_ * 0.2f};
                q.vel += turbulenceVec(tp) * (d_.turbulence * dt);
            }
            if (d_.drag > 0.f) q.vel = q.vel * std::exp(-d_.drag * dt);
            q.pos += q.vel * dt;
            if (d_.orbitSpeed != 0.f) {
                Vec3 rel = q.pos - pos_;
                float a = d_.orbitSpeed * dt, c = std::cos(a), s = std::sin(a);
                q.pos = pos_ + Vec3{rel.x * c + rel.z * s, rel.y, -rel.x * s + rel.z * c};
            }
            q.rot += q.rotVel * dt;
            ++i;
        }
        if (emitting_ && d_.rate > 0.f) {
            acc_ += d_.rate * dt;
            int guard = 0;
            while (acc_ >= 1.f && guard++ < 1000) { spawn(); acc_ -= 1.f; }
        }
    }

    // Appends camera-facing quads (CCW as seen by the camera). Alpha layers are sorted back-to-front.
    // Uses internal scratch buffers (no per-frame allocations once warm); not thread-safe on the same layer.
    void buildBillboards(Vec3 camPos, Vec3 camRight, Vec3 camUp,
                         std::vector<ParticleVertex>& outV, std::vector<uint32_t>& outI) const {
        outV.reserve(outV.size() + p_.size() * 4);
        outI.reserve(outI.size() + p_.size() * 6);
        order_.resize(p_.size());
        std::iota(order_.begin(), order_.end(), 0u);
        if (d_.blend == Blend::Alpha) {
            dist_.resize(p_.size());
            for (size_t i = 0; i < p_.size(); ++i) { Vec3 d = p_[i].pos - camPos; dist_[i] = dot(d, d); }
            std::sort(order_.begin(), order_.end(), [&](uint32_t a, uint32_t b) { return dist_[a] > dist_[b]; });
        }
        for (uint32_t id : order_) {
            const Particle& q = p_[id];
            float t = clamp01(q.age / q.life);
            float ease = 1.f - (1.f - t) * (1.f - t);
            float size = q.size0 * lerp(1.f, d_.sizeEndScale, ease);
            Vec4 col = sampleGradient(d_.gradient, t);
            if (d_.fadeIn > 0.f) col.w *= smoothstep(0.f, d_.fadeIn, t);
            float c = std::cos(q.rot), s = std::sin(q.rot);
            Vec3 r = (camRight * c + camUp * s) * (size * 0.5f);
            Vec3 u = (camUp * c - camRight * s) * (size * 0.5f);
            uint32_t base = (uint32_t)outV.size();
            outV.push_back({q.pos - r - u, {0, 0}, col});
            outV.push_back({q.pos + r - u, {1, 0}, col});
            outV.push_back({q.pos + r + u, {1, 1}, col});
            outV.push_back({q.pos - r + u, {0, 1}, col});
            const uint32_t idx[6] = {0, 1, 2, 0, 2, 3};
            for (uint32_t k : idx) outI.push_back(base + k);
        }
    }

private:
    struct Particle { Vec3 pos, vel; float age = 0, life = 1, size0 = 0.1f, rot = 0, rotVel = 0; };

    void spawn() {
        if (p_.size() >= d_.maxParticles) return;
        Particle q;
        Vec3 off{0, 0, 0};
        switch (d_.shape) {
            case EmitShape::Point: break;
            case EmitShape::Sphere: off = rng_.unitVec() * (d_.shapeRadius * std::cbrt(rng_.next())); break;
            case EmitShape::Disc:
            case EmitShape::Cylinder: {
                float a = rng_.range(0.f, 2.f * kPi), r = d_.shapeRadius * std::sqrt(rng_.next());
                off = {r * std::cos(a), d_.shape == EmitShape::Cylinder ? rng_.next() * d_.shapeHeight : 0.f, r * std::sin(a)};
                break;
            }
        }
        q.pos = pos_ + off;
        Vec3 dir;
        if (d_.radialVelocity) {
            Vec3 o = off;
            if (d_.shape == EmitShape::Cylinder) o.y = 0.f;
            dir = length(o) > 1e-4f ? normalize(o) : rng_.unitVec();
            dir = normalize(dir + Vec3{0, 1, 0} * d_.radialUpBias);
        } else {
            dir = coneDir(d_.direction, d_.spreadDeg * kPi / 180.f, rng_);
        }
        q.vel = dir * rng_.range(d_.speedMin, d_.speedMax);
        q.life = rng_.range(d_.lifeMin, d_.lifeMax);
        q.size0 = rng_.range(d_.sizeMin, d_.sizeMax);
        q.rot = rng_.range(0.f, 2.f * kPi);
        q.rotVel = rng_.range(d_.rotSpeedMin, d_.rotSpeedMax);
        p_.push_back(q);
    }

    ParticleDesc d_;
    Rng rng_;
    std::vector<Particle> p_;
    Vec3 pos_{0, 0, 0};
    float acc_ = 0.f, time_ = 0.f;
    bool emitting_ = true;
    mutable std::vector<uint32_t> order_;   // scratch for buildBillboards
    mutable std::vector<float> dist_;
};

// A named bundle of particle layers (draw each layer with its own blend mode/texture).
struct Effect {
    std::string name;
    std::vector<ParticleSystem> layers;
    void setPosition(Vec3 p) { for (auto& l : layers) l.setPosition(p); }
    void teleport(Vec3 p) { for (auto& l : layers) l.teleport(p); }
    void setEmitting(bool e) { for (auto& l : layers) l.setEmitting(e); }
    void burst() { for (auto& l : layers) l.burst(); }
    void update(float dt) { for (auto& l : layers) l.update(dt); }
    void prewarm(float seconds) { for (auto& l : layers) l.prewarm(seconds); }
    void clear() { for (auto& l : layers) l.clear(); }
    // Total live particles; for one-shot effects (explosion) 0 means "finished, safe to recycle".
    size_t aliveCount() const { size_t n = 0; for (const auto& l : layers) n += l.aliveCount(); return n; }
};

// ---- presets ---------------------------------------------------------------
inline Effect makeCampfireSmoke() {
    Effect e;
    e.name = "campfire_smoke";
    ParticleDesc s;
    s.name = "smoke";
    s.blend = Blend::Alpha; s.texture = TexKind::Smoke;
    s.shape = EmitShape::Disc; s.shapeRadius = 0.15f;
    s.maxParticles = 160; s.rate = 14.f;
    s.lifeMin = 3.5f; s.lifeMax = 5.5f;
    s.speedMin = 0.5f; s.speedMax = 0.9f;
    s.direction = {0, 1, 0}; s.spreadDeg = 12.f;
    s.gravity = {0.06f, 0.25f, 0.f}; s.drag = 0.35f;
    s.turbulence = 0.9f; s.turbulenceScale = 0.9f;
    s.sizeMin = 0.25f; s.sizeMax = 0.40f; s.sizeEndScale = 6.f;
    s.fadeIn = 0.12f;
    s.gradient = {{0.f, {0.35f, 0.33f, 0.30f, 0.55f}}, {0.6f, {0.22f, 0.22f, 0.23f, 0.30f}}, {1.f, {0.18f, 0.18f, 0.20f, 0.f}}};
    e.layers.emplace_back(s, 11);

    ParticleDesc m;
    m.name = "embers";
    m.blend = Blend::Additive; m.texture = TexKind::Glow;
    m.shape = EmitShape::Disc; m.shapeRadius = 0.2f;
    m.maxParticles = 48; m.rate = 6.f;
    m.lifeMin = 1.5f; m.lifeMax = 3.f;
    m.speedMin = 0.6f; m.speedMax = 1.4f; m.spreadDeg = 35.f;
    m.gravity = {0.f, 0.3f, 0.f}; m.drag = 0.4f;
    m.turbulence = 1.6f; m.turbulenceScale = 1.5f;
    m.sizeMin = 0.03f; m.sizeMax = 0.05f; m.sizeEndScale = 0.3f;
    m.fadeIn = 0.05f;
    m.gradient = {{0.f, {1.f, 0.75f, 0.30f, 1.f}}, {0.5f, {1.f, 0.35f, 0.08f, 0.8f}}, {1.f, {0.4f, 0.05f, 0.f, 0.f}}};
    e.layers.emplace_back(m, 12);
    return e;
}

inline Effect makeExplosion() {
    Effect e;
    e.name = "explosion";

    ParticleDesc fire;
    fire.name = "fireball";
    fire.blend = Blend::Additive; fire.texture = TexKind::Smoke;
    fire.shape = EmitShape::Sphere; fire.shapeRadius = 0.2f;
    fire.maxParticles = 64; fire.rate = 0.f; fire.burstCount = 28;
    fire.lifeMin = 0.35f; fire.lifeMax = 0.8f;
    fire.speedMin = 2.f; fire.speedMax = 5.f; fire.radialVelocity = true; fire.drag = 3.f;
    fire.sizeMin = 0.6f; fire.sizeMax = 1.0f; fire.sizeEndScale = 2.6f;
    fire.fadeIn = 0.05f;
    fire.gradient = {{0.f, {1.f, 0.95f, 0.7f, 0.f}}, {0.05f, {1.f, 0.8f, 0.35f, 1.f}},
                     {0.4f, {1.f, 0.35f, 0.05f, 0.7f}}, {1.f, {0.2f, 0.02f, 0.f, 0.f}}};
    e.layers.emplace_back(fire, 21);

    ParticleDesc smoke;
    smoke.name = "smoke";
    smoke.blend = Blend::Alpha; smoke.texture = TexKind::Smoke;
    smoke.shape = EmitShape::Sphere; smoke.shapeRadius = 0.3f;
    smoke.maxParticles = 96; smoke.rate = 0.f; smoke.burstCount = 40;
    smoke.lifeMin = 2.f; smoke.lifeMax = 4.f;
    smoke.speedMin = 1.f; smoke.speedMax = 3.5f; smoke.radialVelocity = true; smoke.radialUpBias = 0.6f;
    smoke.drag = 1.6f; smoke.gravity = {0.f, 0.5f, 0.f};
    smoke.turbulence = 1.5f; smoke.turbulenceScale = 0.8f;
    smoke.sizeMin = 0.8f; smoke.sizeMax = 1.4f; smoke.sizeEndScale = 4.5f;
    smoke.fadeIn = 0.08f;
    smoke.gradient = {{0.f, {0.10f, 0.10f, 0.10f, 0.85f}}, {0.5f, {0.28f, 0.27f, 0.26f, 0.5f}}, {1.f, {0.35f, 0.35f, 0.36f, 0.f}}};
    e.layers.emplace_back(smoke, 22);

    ParticleDesc sparks;
    sparks.name = "sparks";
    sparks.blend = Blend::Additive; sparks.texture = TexKind::Glow;
    sparks.shape = EmitShape::Sphere; sparks.shapeRadius = 0.1f;
    sparks.maxParticles = 96; sparks.rate = 0.f; sparks.burstCount = 60;
    sparks.lifeMin = 0.6f; sparks.lifeMax = 1.6f;
    sparks.speedMin = 4.f; sparks.speedMax = 11.f; sparks.radialVelocity = true; sparks.radialUpBias = 0.4f;
    sparks.gravity = {0.f, -9.8f, 0.f}; sparks.drag = 0.4f;
    sparks.sizeMin = 0.04f; sparks.sizeMax = 0.08f; sparks.sizeEndScale = 0.2f;
    sparks.fadeIn = 0.f;
    sparks.gradient = {{0.f, {1.f, 0.9f, 0.5f, 1.f}}, {0.5f, {1.f, 0.4f, 0.1f, 0.9f}}, {1.f, {0.5f, 0.1f, 0.f, 0.f}}};
    e.layers.emplace_back(sparks, 23);

    ParticleDesc dust;
    dust.name = "dust_ring";
    dust.blend = Blend::Alpha; dust.texture = TexKind::Smoke;
    dust.shape = EmitShape::Disc; dust.shapeRadius = 0.5f;
    dust.maxParticles = 48; dust.rate = 0.f; dust.burstCount = 24;
    dust.lifeMin = 1.2f; dust.lifeMax = 2.2f;
    dust.speedMin = 3.f; dust.speedMax = 5.f; dust.radialVelocity = true; dust.drag = 2.5f;
    dust.turbulence = 0.8f;
    dust.sizeMin = 0.7f; dust.sizeMax = 1.2f; dust.sizeEndScale = 3.f;
    dust.gradient = {{0.f, {0.50f, 0.42f, 0.33f, 0.7f}}, {1.f, {0.50f, 0.42f, 0.33f, 0.f}}};
    e.layers.emplace_back(dust, 24);
    return e;
}

// Emitter origin = base of the blade; the cylinder rises 0.9 m along +Y.
// (Blade starts at y = 0.118 in sword space, so place it at swordPos + (0, 0.118, 0).)
inline Effect makeMagicAura() {
    Effect e;
    e.name = "magic_aura";
    ParticleDesc g;
    g.name = "motes";
    g.blend = Blend::Additive; g.texture = TexKind::Glow;
    g.shape = EmitShape::Cylinder; g.shapeRadius = 0.12f; g.shapeHeight = 0.9f;
    g.maxParticles = 200; g.rate = 90.f;
    g.lifeMin = 0.8f; g.lifeMax = 1.4f;
    g.speedMin = 0.15f; g.speedMax = 0.5f; g.spreadDeg = 25.f;
    g.orbitSpeed = 2.8f; g.turbulence = 0.4f; g.turbulenceScale = 2.f;
    g.sizeMin = 0.03f; g.sizeMax = 0.07f; g.sizeEndScale = 0.2f;
    g.fadeIn = 0.15f;
    g.gradient = {{0.f, {0.4f, 0.8f, 1.f, 0.f}}, {0.15f, {0.5f, 0.85f, 1.f, 1.f}},
                  {0.7f, {0.6f, 0.3f, 1.f, 0.6f}}, {1.f, {0.3f, 0.1f, 0.8f, 0.f}}};
    e.layers.emplace_back(g, 31);

    ParticleDesc m;
    m.name = "mist";
    m.blend = Blend::Additive; m.texture = TexKind::Smoke;
    m.shape = EmitShape::Cylinder; m.shapeRadius = 0.08f; m.shapeHeight = 0.9f;
    m.maxParticles = 40; m.rate = 12.f;
    m.lifeMin = 1.2f; m.lifeMax = 2.f;
    m.speedMin = 0.05f; m.speedMax = 0.2f; m.spreadDeg = 40.f;
    m.orbitSpeed = 1.6f; m.turbulence = 0.3f;
    m.sizeMin = 0.3f; m.sizeMax = 0.5f; m.sizeEndScale = 1.8f;
    m.gradient = {{0.f, {0.3f, 0.4f, 1.f, 0.f}}, {0.3f, {0.3f, 0.4f, 1.f, 0.18f}}, {1.f, {0.4f, 0.2f, 0.9f, 0.f}}};
    e.layers.emplace_back(m, 32);
    return e;
}

// Pre-warmed at the origin. To place it elsewhere call fog.teleport(pos) (NOT setPosition),
// otherwise the already-spawned fog stays behind at the origin.
inline Effect makeGroundFog() {
    Effect e;
    e.name = "ground_fog";
    ParticleDesc f;
    f.name = "fog";
    f.blend = Blend::Alpha; f.texture = TexKind::Smoke;
    f.shape = EmitShape::Disc; f.shapeRadius = 3.f;
    f.maxParticles = 120; f.rate = 5.f;
    f.lifeMin = 8.f; f.lifeMax = 12.f;
    f.speedMin = 0.05f; f.speedMax = 0.15f; f.spreadDeg = 80.f; f.direction = {1, 0.1f, 0};
    f.drag = 0.5f; f.turbulence = 0.25f; f.turbulenceScale = 0.4f;
    f.sizeMin = 1.6f; f.sizeMax = 2.6f; f.sizeEndScale = 1.5f;
    f.rotSpeedMin = -0.1f; f.rotSpeedMax = 0.1f; f.fadeIn = 0.2f;
    f.gradient = {{0.f, {0.76f, 0.80f, 0.88f, 0.16f}}, {0.8f, {0.76f, 0.80f, 0.88f, 0.12f}}, {1.f, {0.76f, 0.80f, 0.88f, 0.f}}};
    e.layers.emplace_back(f, 41);
    e.prewarm(10.f);
    return e;
}

// ---- procedural textures (RGBA8, row 0 = BOTTOM / v = 0) ----------------------
struct Image { int w = 0, h = 0; std::vector<uint8_t> rgba; };

inline Image makeSmokeTexture(int size = 128, uint32_t seed = 7) {
    Image im;
    im.w = im.h = size;
    im.rgba.resize((size_t)size * size * 4);
    float off = (float)(seed % 97) * 0.37f;
    for (int y = 0; y < size; ++y)
        for (int x = 0; x < size; ++x) {
            float nx = (x + 0.5f) / size * 2.f - 1.f, ny = (y + 0.5f) / size * 2.f - 1.f;
            float r = std::sqrt(nx * nx + ny * ny);
            float falloff = 1.f - smoothstep(0.30f, 1.0f, r);
            float n = fbm({nx * 3.f + off, ny * 3.f + off * 0.5f, off}, 4);
            float a = clamp01(falloff * (0.45f + 0.85f * n));
            a = a * a * (3.f - 2.f * a);
            uint8_t c = (uint8_t)(255.f * (0.75f + 0.25f * n));
            size_t i = ((size_t)y * size + x) * 4;
            im.rgba[i] = im.rgba[i + 1] = im.rgba[i + 2] = c;
            im.rgba[i + 3] = (uint8_t)(255.f * a);
        }
    return im;
}

inline Image makeGlowTexture(int size = 64) {
    Image im;
    im.w = im.h = size;
    im.rgba.resize((size_t)size * size * 4);
    for (int y = 0; y < size; ++y)
        for (int x = 0; x < size; ++x) {
            float nx = (x + 0.5f) / size * 2.f - 1.f, ny = (y + 0.5f) / size * 2.f - 1.f;
            float r = std::sqrt(nx * nx + ny * ny);
            float a = std::pow(clamp01(1.f - r), 2.2f);
            size_t i = ((size_t)y * size + x) * 4;
            im.rgba[i] = im.rgba[i + 1] = im.rgba[i + 2] = 255;
            im.rgba[i + 3] = (uint8_t)(255.f * a);
        }
    return im;
}

inline bool writeTGA(const Image& im, const std::string& path) {
    FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) return false;
    uint8_t hdr[18] = {0};
    hdr[2] = 2;
    hdr[12] = (uint8_t)(im.w & 255); hdr[13] = (uint8_t)(im.w >> 8);
    hdr[14] = (uint8_t)(im.h & 255); hdr[15] = (uint8_t)(im.h >> 8);
    hdr[16] = 32; hdr[17] = 0x08;   // 32 bpp, bottom-left origin (row 0 = bottom), 8 alpha bits
    std::fwrite(hdr, 1, 18, f);
    for (size_t i = 0; i < (size_t)im.w * im.h; ++i) {
        uint8_t px[4] = {im.rgba[i * 4 + 2], im.rgba[i * 4 + 1], im.rgba[i * 4 + 0], im.rgba[i * 4 + 3]};
        std::fwrite(px, 1, 4, f);
    }
    std::fclose(f);
    return true;
}

}  // namespace ga

// ============================================================================
//  Optional self-test: compile with -DGA_DEMO_MAIN
// ============================================================================
#ifdef GA_DEMO_MAIN
int main() {
    using namespace ga;
    struct Item { const char* file; Mesh mesh; };
    std::vector<Item> items;
    items.push_back({"sword.obj", makeSword()});
    items.push_back({"crate.obj", makeWoodenCrate()});
    items.push_back({"chest.obj", makeTreasureChest()});
    items.push_back({"metalcase.obj", makeMetalCase()});
    for (auto& it : items) {
        writeOBJ(it.mesh, it.file);
        std::printf("%-14s verts=%zu tris=%zu submeshes=%zu inverted=%zu\n", it.file, it.mesh.vertices.size(),
                    it.mesh.triangleCount(), it.mesh.subMeshes.size(), countInvertedTriangles(it.mesh));
    }
    std::vector<Effect> fx;
    fx.push_back(makeCampfireSmoke());
    fx.push_back(makeExplosion());
    fx.push_back(makeMagicAura());
    fx.push_back(makeGroundFog());
    fx[1].burst();
    for (auto& e : fx) {
        for (int i = 0; i < 180; ++i) e.update(1.f / 60.f);
        for (auto& l : e.layers) {
            std::vector<ParticleVertex> v;
            std::vector<uint32_t> idx;
            l.buildBillboards({0, 2, 6}, {1, 0, 0}, {0, 1, 0}, v, idx);
            std::printf("%-15s layer %-9s alive=%zu verts=%zu\n", e.name.c_str(), l.desc().name.c_str(), l.aliveCount(), v.size());
        }
    }
    writeTGA(makeSmokeTexture(), "smoke.tga");
    writeTGA(makeGlowTexture(), "glow.tga");
    return 0;
}
#endif
