/// The Metal every scene's source is compiled after: the types scene functions return, the
/// context they get, and noise, SDF and color helpers.
///
/// A scene defines (not `static`):
///
///     Surface surface(Hit h, Ctx c);          // required: the static world's materials
///     float3 sky(float3 dir, Ctx c);          // required: evaluated live, baked at t = 0
///
/// and, each behind its `#define`:
///
///     HAS_EMISSION     Emission emission(Hit h, Ctx c);
///     HAS_GROUP_TINT   float3 groupTint(uint group, float3 p, Ctx c);
///     HAS_LIVE         Live live(float3 ro, float3 rd, float maxDist, Ctx c);
///     HAS_ATMOSPHERE   Atmosphere atmosphere(float3 ro, float3 rd, float dist, Ctx c);
///     HAS_OPACITY      float opacity(Hit h, Ctx c);       // for meshes added with cutOut: true
///     HAS_LIVE_NORMAL  float3 liveNormal(Hit h, Ctx c);   // mirrors' normal each frame
///
/// plus one `Particle name(uint i, Ctx c)` per particle system.
enum ShaderPrelude {
    static let source = #"""
    #include <metal_stdlib>
    #include <metal_raytracing>
    using namespace metal;
    using namespace raytracing;

    #define PI 3.14159265f
    #define TAU 6.28318531f
    #define MAX_GROUPS \#(SaverWorld.maxGroups)
    #define MAX_PARAMS \#(SaverFrame.maxParams)
    #define MAX_LIVE_LIGHTS \#(SaverFrame.maxLights)
    #define NO_GROUP 0xFFFFFFFFu
    #define FAR 10000.0f
    // Seconds the shutter is open: particles streak over it, and live motion should blur over it.
    #define SHUTTER (1.0f / 60)
    // Ray masks for Context::intersect: what the eye sees, and what casts shadows.
    #define CAMERA_MASK 1u
    #define SHADOW_MASK 2u
    // Which lights Context::inscatter gathers.
    #define DISTANT_LIGHTS 1u  // directional lights and the sky
    #define LOCAL_LIGHTS 2u    // spheres and tubes
    #define LIVE_LIGHTS 4u     // the frame's lights
    #define ALL_LIGHTS 7u

    // MARK: What scene functions get and return

    // Where a ray met the static world.
    struct Hit {
        uint material;  // as given to SaverWorld.add
        uint tag;       // as given to SaverWorld.add
        uint instance;  // which copy: stable for the scene's life, for varying copies
        uint bounce;    // 0 for what the eye sees; past that, skip fine detail like bump, which
                        // can't show in bounced light and is most of what the bake costs
        float3 p;       // world position
        float3 n;       // world normal facing the ray; in the live pass's emission() call, the perturbed one
        float3 local;   // position in the mesh's own space, so patterns follow the object
        float2 uv;      // the mesh's uvs; 0 in the live pass, which knows the copy but not the triangle
    };

    struct Surface {
        float3 albedo;
        float roughness;     // 0 mirror to 1 matte. Highlights of the analytic lights fade in from 0.2
                             // to 0.4 as reflected emission fades out; the live sky fades out from 0.05 to 0.15.
        float metallic;
        float3 normal;       // perturbed world normal
        float transmission;  // the chance of being a smooth dielectric (glass, water) at this point
        float ior;
        float translucency;  // the share of diffuse light that passes through to the other side (leaves)
        bool reflectsLive;   // whether it mirrors live() when world.liveReflections is on
    };

    // A matte, non-metallic surface; change the other fields as needed.
    static Surface material(float3 albedo, float roughness, float3 normal) {
        Surface s;
        s.albedo = albedo;
        s.roughness = roughness;
        s.metallic = 0;
        s.normal = normal;
        s.transmission = 0;
        s.ior = 1.5;
        s.translucency = 0;
        s.reflectsLive = true;
        return s;
    }

    // Light a surface gives off, scaled live by its group's tint.
    struct Emission {
        float3 color;
        uint group;
    };

    // What live() draws along a ray: premultiplied color, coverage, and the distance it sits at
    // (for particles and atmosphere where alpha > 0.5). Set hazed when the color has been through
    // atmosphere() already; the core then hazes only what's behind it.
    struct Live {
        float3 color;
        float alpha;
        float depth;
        bool hazed = false;
    };

    static Live nothing() { return Live{float3(0), 0, FAR}; }

    // front composited over back, both premultiplied.
    static Live over(Live front, Live back) {
        return Live{front.color + back.color * (1 - front.alpha), front.alpha + back.alpha * (1 - front.alpha), min(front.depth, back.depth), front.hazed || back.hazed};
    }
    static float4 over(float4 front, float4 back) { return front + (1 - front.a) * back; }

    struct Atmosphere {
        float3 inscatter;
        float3 transmittance;
    };

    // One particle at the frame's time. Velocity stretches it into a streak over half a frame.
    struct Particle {
        float3 position;
        float3 velocity = 0;
        float size;      // radius, in world units
        float3 color;    // light it gives (additive) or its lit color (alpha)
        float alpha;     // 0 hides it
        float puff = 0;  // 0 a soft round dot, 1 a ragged puff of smoke
        float glow = 0;  // a soft halo around the dot, this bright against the dot's center
        float halo = 6;  // the halo's radius, in sizes
        float tail = 0;  // 0 an even streak, 1 fading from its head to nothing at its tail
    };

    // MARK: Per-frame values, the same for every screen

    struct LiveLight {
        float4 position;  // w: radius
        float4 color;     // w: 1 if it casts shadows
        float4 spot;      // xyz: the cone's axis, zero for none; w: cosine of its outer angle
        float4 falloff;   // x: range, infinite for none; y: cosine of the cone's inner angle; z: glow in fog;
                          // w: the radius of the sphere round range and cone, centred that far along the
                          // cone's axis (0: the range's)
    };

    struct Frame {
        float time;
        uint lightCount;
        uint skyGroup;
        uint liveLightCount;
        uint baking;
        float4 tint[MAX_GROUPS];
        float4 params[MAX_PARAMS];
        LiveLight liveLights[MAX_LIVE_LIGHTS];
    };

    struct Light {
        float4 a;      // sphere: center, radius; tube: start, radius; directional: direction, angle
        float4 b;      // tube: end; w: kind (0 sphere, 1 tube, 2 directional)
        float4 color;  // w: group
    };

    struct Instance {
        float4 inverse[3];
        uint vertexOffset;
        uint indexOffset;
        uint material;
        uint tag;
    };

    // MARK: The context every scene function gets

    struct Context {
        constant Frame* f;
        float t;       // seconds, starting over every SaverWorld.cycle; 0 while baking
        bool baking;   // in the bake and the sky's ambient light, where sky() need only be roughly right
        float3 eye;
        float pixel;   // radians one pixel spans straight ahead, on this screen
        instance_acceleration_structure world;
        instance_acceleration_structure cutOuts;  // the copies added with cutOut: true; the rest are in world
        texture3d<float> noiseTexture;
        device const Light* lights;
        device const Instance* instances;
        device const packed_float3* positions;
        device const packed_float3* normals;
        device const uint* indices;
        device const float4* ambientLight;
        device const float2* uvs;
        bool jitter = false;  // the bake's: cut-outs pass at random by opacity, so their edges antialias

        float4 param(uint i) thread const { return f->params[i]; }
        // Like noise(), fbm(), noised() and fbmd() below but read from a 3D texture, several
        // times faster. They repeat every 16 units. The gradients cost four lookups each.
        float noise(float3 p) thread const;
        float fbm(float3 p, int octaves = 4) thread const;
        float4 noised(float3 p) thread const;
        float4 fbmd(float3 p, int octaves = 4) thread const;
        // The group's tint at p (groupTint), 0 for a group that doesn't exist.
        float3 tint(uint group, float3 p) thread const;
        // The static world, shadow casters only. Start rays off surfaces with offset().
        bool blocked(float3 origin, float3 dir, float dist) thread const;
        // Distance to the static world along a ray, FAR if it escapes.
        float hitDistance(float3 origin, float3 dir) thread const;
        // Irradiance from the sky's light at its current tint, for a surface facing n.
        float3 ambient(float3 n) thread const;
        // Light leaving a surface toward v (unit, toward the eye): every analytic light at its
        // current tint with a shadow ray, the sky's ambient light and the live lights, on both
        // sides of a translucent surface.
        float3 shade(float3 p, float3 n, float3 v, Surface s) thread const;
        // The live lights alone (what the baked surfaces get on top of their groups).
        float3 liveLight(float3 p, float3 n, float3 v, Surface s) thread const;
        // Light a white, isotropic speck of smoke at p would scatter: every light, no shadows.
        float3 light(float3 p) thread const;
        // light() gathered along a ray, for fog: multiply by the fog's scattering density. Each
        // light's glow fades out `reach` meters off the ray per square root of its intensity, and
        // is dimmed by `extinction` per meter on its way to the ray and along it to the eye.
        float3 inscatter(float3 ro, float3 rd, float dist, uint which = ALL_LIGHTS, float reach = FAR, float3 extinction = 0) thread const;

        bool intersect(ray r, uint mask, thread Hit& h, thread float& t, thread float3& ng) thread const;
        Hit hitAt(uint instance, float3 p, float3 n) thread const;
    };
    typedef thread const Context& Ctx;

    // The scene's functions, defined in its source.
    Surface surface(Hit h, Ctx c);
    float3 sky(float3 dir, Ctx c);
    Emission emission(Hit h, Ctx c);
    float3 groupTint(uint group, float3 p, Ctx c);
    Live live(float3 ro, float3 rd, float maxDist, Ctx c);
    Atmosphere atmosphere(float3 ro, float3 rd, float dist, Ctx c);
    float opacity(Hit h, Ctx c);
    float3 liveNormal(Hit h, Ctx c);

    // MARK: Hashing and noise

    static uint3 pcg3(uint3 v) {
        v = v * 1664525u + 1013904223u;
        v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
        v ^= v >> 16u;
        v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
        return v;
    }

    // Random values 0 to 1 for any point, typically a cell's floor().
    static float3 hash3(float3 p) { return float3(pcg3(as_type<uint3>(p))) * (1.0f / 4294967296.0f); }
    static float hash(float3 p) { return hash3(p).x; }
    static float2 hash2(float2 p) { return hash3(float3(p, 0)).xy; }
    static float hash(float2 p) { return hash3(float3(p, 0)).x; }
    static float hash(float x) { return hash3(float3(x, 0, 0)).x; }

    static float lattice(int3 i) { return float(pcg3(uint3(i)).x) * (1.0f / 4294967296.0f); }
    static float3 fade(float3 f) { return f * f * f * (f * (f * 6 - 15) + 10); }

    // Smooth value noise, 0 to 1.
    static float noise(float3 p) {
        float3 i = floor(p), u = fade(p - i);
        int3 c = int3(i);
        return mix(mix(mix(lattice(c), lattice(c + int3(1, 0, 0)), u.x), mix(lattice(c + int3(0, 1, 0)), lattice(c + int3(1, 1, 0)), u.x), u.y),
                   mix(mix(lattice(c + int3(0, 0, 1)), lattice(c + int3(1, 0, 1)), u.x), mix(lattice(c + int3(0, 1, 1)), lattice(c + int3(1, 1, 1)), u.x), u.y), u.z);
    }
    static float noise(float2 p) { return noise(float3(p, 0.5)); }

    // Value noise and its gradient: (value, d/dx, d/dy, d/dz). For bump().
    static float4 noised(float3 p) {
        float3 i = floor(p), f = p - i, u = fade(f), du = 30 * f * f * (f * (f - 2) + 1);
        int3 c = int3(i);
        float a = lattice(c), b = lattice(c + int3(1, 0, 0)), cc = lattice(c + int3(0, 1, 0)), d = lattice(c + int3(1, 1, 0));
        float e = lattice(c + int3(0, 0, 1)), g = lattice(c + int3(1, 0, 1)), h = lattice(c + int3(0, 1, 1)), k = lattice(c + int3(1, 1, 1));
        float k1 = b - a, k2 = cc - a, k3 = e - a, k4 = a - b - cc + d, k5 = a - cc - e + h, k6 = a - b - e + g, k7 = -a + b + cc - d + e - g - h + k;
        float v = a + k1 * u.x + k2 * u.y + k3 * u.z + k4 * u.x * u.y + k5 * u.y * u.z + k6 * u.z * u.x + k7 * u.x * u.y * u.z;
        return float4(v, du * float3(k1 + k4 * u.y + k6 * u.z + k7 * u.y * u.z, k2 + k5 * u.z + k4 * u.x + k7 * u.z * u.x, k3 + k6 * u.x + k5 * u.y + k7 * u.x * u.y));
    }

    // Octaves of noise(), 0 to about 1.
    static float fbm(float3 p, int octaves = 5) {
        float sum = 0, amplitude = 0.5;
        for (int i = 0; i < octaves; i++) {
            sum += amplitude * noise(p);
            p = p * 2.03f + float3(1.7, 9.2, 3.1);
            amplitude *= 0.5;
        }
        return sum;
    }
    static float fbm(float2 p, int octaves = 5) { return fbm(float3(p, 0.5), octaves); }

    // fbm() with its gradient, as noised().
    static float4 fbmd(float3 p, int octaves = 5) {
        float4 sum = 0;
        float amplitude = 0.5, scale = 1;
        for (int i = 0; i < octaves; i++) {
            float4 n = noised(p);
            sum += amplitude * float4(n.x, n.yzw * scale);
            p = p * 2.03f + float3(1.7, 9.2, 3.1);
            amplitude *= 0.5;
            scale *= 2.03f;
        }
        return sum;
    }

    // Cells: (distance to the nearest point, to the second nearest, the nearest cell's id 0 to 1).
    static float3 voronoi(float3 p) {
        float3 cell = floor(p), f = p - cell;
        float first = 9, second = 9, id = 0;
        for (int x = -1; x <= 1; x++) for (int y = -1; y <= 1; y++) for (int z = -1; z <= 1; z++) {
            float3 o = float3(x, y, z), h = hash3(cell + o);
            float d = length(o + h - f);
            if (d < first) { second = first; first = d; id = hash(cell + o + 17.0f); }
            else if (d < second) { second = d; }
        }
        return float3(first, second, id);
    }

    static float3 voronoi(float2 p) {
        float2 cell = floor(p), f = p - cell;
        float first = 9, second = 9, id = 0;
        for (int x = -1; x <= 1; x++) for (int y = -1; y <= 1; y++) {
            float2 o = float2(x, y), h = hash2(cell + o);
            float d = length(o + h - f);
            if (d < first) { second = first; first = d; id = hash(cell + o + 17.0f); }
            else if (d < second) { second = d; }
        }
        return float3(first, second, id);
    }

    // A random offset into the texture noise's 16-unit period for each copy, so copies differ.
    // Offsetting by the copy's index itself would push noise coordinates past float precision.
    static float3 copyOffset(Hit h) { return hash3(float3(h.instance, 1.3, 7.1)) * 16; }

    // c.fbmd() where the eye sees h; past the first bounce, where detail can't show, a cheap
    // value with no gradient.
    static float4 detail(float3 p, Hit h, Ctx c, int octaves = 4) { return h.bounce == 0 ? c.fbmd(p, octaves) : float4(c.fbm(p, 2), 0, 0, 0); }

    // Coordinates in a face's own plane: along and up a wall, or across a floor or ceiling.
    static float2 planar(float3 p, float3 n) {
        float3 a = abs(n);
        return a.y > max(a.x, a.z) ? p.xz : a.x > a.z ? p.zy : p.xy;
    }

    // A gradient in planar() coordinates, back in the world.
    static float3 unplanar(float2 g, float3 n) {
        float3 a = abs(n);
        return a.y > max(a.x, a.z) ? float3(g.x, 0, g.y) : a.x > a.z ? float3(0, g.y, g.x) : float3(g.x, g.y, 0);
    }

    // Tilts n as if the surface were raised by a height field with this gradient (world units).
    static float3 bump(float3 n, float3 gradient, float strength) {
        return normalize(n - strength * (gradient - n * dot(gradient, n)));
    }

    // MARK: Signed distance functions

    static float sdBox(float3 p, float3 halfSize) {
        float3 q = abs(p) - halfSize;
        return length(max(q, 0.0f)) + min(max(q.x, max(q.y, q.z)), 0.0f);
    }
    static float sdBox(float2 p, float2 halfSize) {
        float2 q = abs(p) - halfSize;
        return length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f);
    }
    static float sdRoundBox(float3 p, float3 halfSize, float r) { return sdBox(p, halfSize - r) - r; }
    static float sdSegment(float2 p, float2 a, float2 b) {
        float2 pa = p - a, ba = b - a;
        return length(pa - ba * saturate(dot(pa, ba) / dot(ba, ba)));
    }
    static float sdCapsule(float3 p, float3 a, float3 b, float r) {
        float3 pa = p - a, ba = b - a;
        return length(pa - ba * saturate(dot(pa, ba) / dot(ba, ba))) - r;
    }
    // Upright, centered on the origin.
    static float sdCylinder(float3 p, float r, float halfHeight) {
        float2 d = abs(float2(length(p.xz), p.y)) - float2(r, halfHeight);
        return min(max(d.x, d.y), 0.0f) + length(max(d, 0.0f));
    }
    // In the xz plane.
    static float sdTorus(float3 p, float major, float minor) { return length(float2(length(p.xz) - major, p.y)) - minor; }
    static float sdEllipsoid(float3 p, float3 r) {
        float k0 = length(p / r), k1 = length(p / (r * r));
        return k0 * (k0 - 1) / k1;
    }
    // A 2D triangle, negative inside.
    static float sdTriangle(float2 p, float2 a, float2 b, float2 c) {
        float2 e0 = b - a, e1 = c - b, e2 = a - c, v0 = p - a, v1 = p - b, v2 = p - c;
        float2 q0 = v0 - e0 * saturate(dot(v0, e0) / dot(e0, e0));
        float2 q1 = v1 - e1 * saturate(dot(v1, e1) / dot(e1, e1));
        float2 q2 = v2 - e2 * saturate(dot(v2, e2) / dot(e2, e2));
        float s = sign(e0.x * e2.y - e0.y * e2.x);
        float2 d = min(min(float2(dot(q0, q0), s * (v0.x * e0.y - v0.y * e0.x)), float2(dot(q1, q1), s * (v1.x * e1.y - v1.y * e1.x))),
                       float2(dot(q2, q2), s * (v2.x * e2.y - v2.y * e2.x)));
        return -sqrt(d.x) * sign(d.y);
    }

    static float smin(float a, float b, float k) {
        float h = max(k - abs(a - b), 0.0f) / k;
        return min(a, b) - h * h * k * 0.25f;
    }
    static float smax(float a, float b, float k) { return -smin(-a, -b, k); }
    static float2x2 rot(float angle) {
        float c = cos(angle), s = sin(angle);
        return float2x2(c, s, -s, c);
    }

    // The normal of any SDF, e.g. sdfNormal([&](float3 q) { return body(q, c); }, p).
    template <typename F> static float3 sdfNormal(F sdf, float3 p, float e = 1e-3f) {
        return normalize(float3(1, -1, -1) * sdf(p + float3(1, -1, -1) * e) + float3(-1, -1, 1) * sdf(p + float3(-1, -1, 1) * e) +
                         float3(-1, 1, -1) * sdf(p + float3(-1, 1, -1) * e) + float3(1, 1, 1) * sdf(p + float3(1, 1, 1) * e));
    }

    // Sphere-traces an SDF from tmin to tmax: the hit distance, or -1.
    template <typename F> static float sdfMarch(F sdf, float3 ro, float3 rd, float tmin, float tmax, int steps = 96) {
        float t = tmin;
        for (int i = 0; i < steps && t < tmax; i++) {
            float d = sdf(ro + rd * t);
            if (d < 1e-4f * t) return t;
            t += d;
        }
        return -1;
    }

    // Where a ray passes nearest the segment from a to b: (how near, how far along the ray, how far
    // along the segment from 0 to 1).
    static float3 nearest(float3 ro, float3 rd, float3 a, float3 b) {
        float3 ab = b - a, w = a - ro;
        float k = dot(ab, rd), s = saturate((k * dot(rd, w) - dot(ab, w)) / max(dot(ab, ab) - k * k, 1e-8f)), t = dot(w + ab * s, rd);
        return float3(length(w + ab * s - rd * t), t, s);
    }

    // Where a ray enters and leaves a box (x > y when it misses).
    static float2 boxInterval(float3 ro, float3 rd, float3 lo, float3 hi) {
        float3 inv = 1 / rd, a = (lo - ro) * inv, b = (hi - ro) * inv;
        float3 near = min(a, b), far = max(a, b);
        return float2(max(max(near.x, near.y), max(near.z, 0.0f)), min(far.x, min(far.y, far.z)));
    }

    // MARK: Fog

    // Optical depth along a ray through fog `density` thick at y = 0, thinning by e every `height` up.
    static float fogDepth(float3 ro, float3 rd, float dist, float density, float height) {
        float x = rd.y * dist / height;
        return density * exp(-ro.y / height) * dist * (abs(x) > 1e-3f ? (1 - exp(-x)) / x : 1 - x * 0.5f);
    }

    // ∫ 1/r² along a ray from ro over [0, dist], r being the distance to q but at least `radius`: the
    // light a source of unit intensity scatters toward ro in fog of unit density. `t` gets where the
    // ray passes nearest.
    static float scatter(float3 q, float radius, float3 ro, float3 rd, float dist, thread float& t) {
        float3 w = q - ro;
        t = dot(w, rd);
        float h = sqrt(max(dot(w, w) - t * t, radius * radius));
        return atan2(dist * h, h * h - t * (dist - t)) / h;
    }

    // The same for a tube from a to b whose unit intensity is spread along it.
    static float scatter(float3 a, float3 b, float radius, float3 ro, float3 rd, float dist, thread float& t) {
        float3 axis = b - a, w = a - ro;
        float len = length(axis);
        axis /= len;
        float ab = dot(axis, rd), s2 = max(1 - ab * ab, 1e-4f), rw = dot(rd, w), l = (rw * ab - dot(axis, w)) / s2;
        t = rw + l * ab;
        float h = max(length(w + axis * l - rd * t), radius), k = sqrt(s2) / h;
        return (asinh((len - l) * k) + asinh(l * k)) / (k * len) * atan2(dist * h, h * h - t * (dist - t)) / h;
    }

    // Henyey-Greenstein: how much of the light fog scatters turns through an angle with this cosine.
    static float phase(float cosine, float g) { return (1 - g * g) / (4 * PI * pow(1 + g * g - 2 * g * cosine, 1.5f)); }

    // MARK: Color and helpers

    static float luminance(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
    // Schlick's Fresnel: the share of light reflected at cosine c to the normal, f0 head on.
    static float3 schlick(float3 f0, float c) { return f0 + (1 - f0) * pow(1 - saturate(c), 5.0f); }
    static float schlick(float f0, float c) { return f0 + (1 - f0) * pow(1 - saturate(c), 5.0f); }
    static float3 hsv(float h, float s, float v) {
        float3 k = saturate(abs(fract(h + float3(0, 2, 1) / 3) * 6 - 3) - 1);
        return v * mix(float3(1), k, s);
    }
    // The color of a glowing body at this temperature, brightest channel 1: about 1000 K is deep
    // red, 1900 K a candle, 6500 K white.
    static float3 blackbody(float kelvin) {
        float3 lambda = float3(610e-9, 550e-9, 465e-9);
        float3 planck = 1 / (pow(lambda, 5.0f) * (exp(0.014388f / (lambda * max(kelvin, 500.0f))) - 1));
        float3 white = 1 / (pow(lambda, 5.0f) * (exp(0.014388f / (lambda * 6500)) - 1));
        float3 c = planck / white;
        return c / max(c.r, max(c.g, c.b));
    }

    // A point lifted off a surface, to start rays from without hitting it.
    static float3 offset(float3 p, float3 n) { return p + n * max(1e-4f, 2e-5f * max(abs(p.x), max(abs(p.y), abs(p.z)))); }

    """#
}
