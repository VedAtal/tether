/// The renderer's own Metal, compiled after the prelude and the scene: the path tracer that bakes
/// the light groups, the live pass, particles, bloom and the film finish.
enum ShaderCore {
    /// The whole program for a world. `#line` marks keep compiler errors pointing at the scene's
    /// own Swift file.
    static func source(for world: SaverWorld) -> String {
        let particles = world.particles.enumerated().map { i, system in
            """
            vertex ParticleOut particles\(i)(uint vid [[vertex_id]], uint iid [[instance_id]], constant View& view [[buffer(0)]], WORLD_ARGS) {
                CONTEXT(view.eye.xyz, view.forward.w);
                return particleVertex(\(system.function)(iid, c), vid, iid, view, c);
            }

            """
        }
        var defines = ["GROUP_COUNT \(world.groups)", "LIVE_SAMPLES \(max(1, world.look.liveSamples))"]
        if world.liveReflections { defines.append("LIVE_REFLECTIONS") }
        if world.hazeMirrors { defines.append("HAZE_MIRRORS") }
        if world.instances.contains(where: \.cutOut) { defines.append("CUT_OUTS") }
        if world.cutOutsSolidToLight { defines.append("CUT_OUTS_SOLID_TO_LIGHT") }
        return "#line 1 \"prelude\"\n" + ShaderPrelude.source
            + "#line \(world.shader.line + 1) \"\(world.shader.file)\"\n" + world.shader.code + "\n"
            + defines.map { "#define \($0)\n" }.joined()
            + "#line 1 \"core\"\n" + core + "#line 1 \"particle systems\"\n" + particles.joined()
    }

    private static let core = #"""
    #ifndef HAS_GROUP_TINT
    float3 groupTint(uint group, float3 p, Ctx c) { return c.f->tint[group].rgb; }
    #endif
    #if defined(CUT_OUTS) && !defined(HAS_OPACITY)
    float opacity(Hit h, Ctx c) { return 1; }
    #endif

    // Roughness past which live() is no longer mirrored.
    #define LIVE_REFLECTION_ROUGHNESS 0.35f
    #define BLOOM_LEVELS \#(ScreenTargets.bloomLevels)

    #define WORLD_ARGS constant Frame& frame [[buffer(1)]], device const Light* lights [[buffer(2)]], \
        device const Instance* instances [[buffer(3)]], device const packed_float3* positions [[buffer(4)]], \
        device const packed_float3* normals [[buffer(5)]], device const uint* indices [[buffer(6)]], \
        device const float4* ambientLight [[buffer(7)]], instance_acceleration_structure world [[buffer(8)]], \
        device const float2* uvs [[buffer(9)]], instance_acceleration_structure cutOuts [[buffer(10)]], texture3d<float> noiseTexture [[texture(8)]]
    #define CONTEXT(eyePosition, pixelAngle) Context c{&frame, frame.time, frame.baking != 0, eyePosition, pixelAngle, world, cutOuts, noiseTexture, lights, instances, positions, normals, indices, ambientLight, uvs}

    // One screen's view, and what a bake dispatch adds.
    struct View {
        float4 eye;      // w: distance to the image plane
        float4 right;
        float4 up;
        float4 forward;  // w: radians a pixel spans straight ahead
        float4 rect;     // this screen on the image plane: min x, min y, max x, max y
        uint2 size;      // pixels
        uint rowOffset;
        uint sample;     // samples already in the bake
        uint count;      // samples this dispatch adds
        uint bounces;
        float clampLimit;
    };

    // MARK: Sampling

    static float rand(thread uint& s) {
        s = s * 747796405u + 2891336453u;
        uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
        return float((w >> 22u) ^ w) * (1.0f / 4294967296.0f);
    }

    static void basis(float3 n, thread float3& t, thread float3& b) {
        float s = n.z >= 0 ? 1.0f : -1.0f, a = -1.0f / (s + n.z), d = n.x * n.y * a;
        t = float3(1 + s * n.x * n.x * a, s * d, -s * n.x);
        b = float3(d, s + n.y * n.y * a, -n.y);
    }

    static float3 cosineSample(float3 n, float2 u) {
        float3 t, b;
        basis(n, t, b);
        float r = sqrt(u.x), phi = TAU * u.y;
        return normalize(t * (r * cos(phi)) + b * (r * sin(phi)) + n * sqrt(max(0.0f, 1 - u.x)));
    }

    static float3 coneSample(float3 axis, float cosMax, float2 u) {
        float cosT = 1 - u.x * (1 - cosMax), sinT = sqrt(max(0.0f, 1 - cosT * cosT)), phi = TAU * u.y;
        float3 t, b;
        basis(axis, t, b);
        return normalize(t * (sinT * cos(phi)) + b * (sinT * sin(phi)) + axis * cosT);
    }

    // A GGX microfacet normal seen from v, both in tangent space (visible normals).
    static float3 sampleGGX(float3 v, float a, float2 u) {
        float3 vh = normalize(float3(a * v.x, a * v.y, v.z));
        float len2 = vh.x * vh.x + vh.y * vh.y;
        float3 t1 = len2 > 0 ? float3(-vh.y, vh.x, 0) * rsqrt(len2) : float3(1, 0, 0), t2 = cross(vh, t1);
        float r = sqrt(u.x), phi = TAU * u.y, p1 = r * cos(phi), p2 = r * sin(phi), s = 0.5f * (1 + vh.z);
        p2 = (1 - s) * sqrt(max(0.0f, 1 - p1 * p1)) + s * p2;
        float3 nh = p1 * t1 + p2 * t2 + sqrt(max(0.0f, 1 - p1 * p1 - p2 * p2)) * vh;
        return normalize(float3(a * nh.x, a * nh.y, max(0.0f, nh.z)));
    }

    // MARK: Materials

    static float smithG1(float c, float a2) { return 2 * c / (c + sqrt(a2 + (1 - a2) * c * c)); }
    static float smithG2(float nv, float nl, float a2) {
        return 2 * nl * nv / (nv * sqrt(a2 + (1 - a2) * nl * nl) + nl * sqrt(a2 + (1 - a2) * nv * nv));
    }

    static float fresnelDielectric(float cosI, float eta) {
        float sin2T = eta * eta * (1 - cosI * cosI);
        if (sin2T >= 1) return 1;
        float cosT = sqrt(1 - sin2T);
        float rs = (eta * cosI - cosT) / (eta * cosI + cosT), rp = (cosI - eta * cosT) / (cosI + eta * cosT);
        return 0.5f * (rs * rs + rp * rp);
    }

    // How much of a highlight the analytic lights give; reflected emission gives the rest. A blend,
    // since lamps are both, so no roughness shows a seam between the two.
    static float glossy(float roughness) { return smoothstep(0.2f, 0.4f, roughness); }
    // How much of a reflection of the sky is drawn live, sharp, rather than baked.
    static float mirrored(float roughness) { return 1 - smoothstep(0.05f, 0.15f, roughness); }

    // Light leaving toward v per unit of irradiance from l, cosine included: reflected, or passed
    // through a translucent surface from behind. `highlight` scales the lights' specular part.
    static float3 bsdf(Surface s, float3 n, float3 v, float3 l, float highlight) {
        float nl = dot(n, l), nv = max(dot(n, v), 1e-4f);
        float3 diffuse = s.albedo * (1 - s.metallic) / PI;
        if (nl <= 0) return diffuse * s.translucency * -nl;
        float3 result = diffuse * (1 - s.translucency);
        if (highlight > 0) {
            // A point light's highlight on a near-mirror would be a single pixel.
            float a = max(s.roughness, 0.1f) * max(s.roughness, 0.1f), a2 = a * a;
            float3 h = normalize(v + l);
            float nh = saturate(dot(n, h)), d = nh * nh * (a2 - 1) + 1;
            result += highlight * schlick(mix(float3(0.04), s.albedo, s.metallic), dot(v, h)) * (a2 / (PI * d * d)) * smithG2(nv, nl, a2) / (4 * nv * nl);
        }
        return result * nl;
    }

    // A direction off an opaque surface, chosen by its BSDF; weight is bsdf × cosine / pdf.
    static bool sampleBSDF(Surface s, float3 n, float3 v, thread uint& rng, thread float3& dir, thread float3& weight, thread bool& specular) {
        float nv = max(dot(n, v), 1e-4f);
        float3 f0 = mix(float3(0.04), s.albedo, s.metallic), fv = schlick(f0, nv), diffuse = s.albedo * (1 - s.metallic);
        float ws = luminance(fv), wd = luminance(diffuse) * (1 - ws), pSpecular = ws / max(ws + wd, 1e-6f);
        specular = rand(rng) < pSpecular;
        if (!specular) {
            bool through = s.translucency > 0 && rand(rng) < s.translucency;
            dir = cosineSample(through ? -n : n, float2(rand(rng), rand(rng)));
            weight = diffuse / (1 - pSpecular);
            return true;
        }
        if (s.roughness < 0.02f) {
            dir = reflect(-v, n);
            weight = fv / pSpecular;
            return true;
        }
        float a = s.roughness * s.roughness, a2 = a * a;
        float3 t, b;
        basis(n, t, b);
        float3 lv = float3(dot(v, t), dot(v, b), nv), m = sampleGGX(lv, a, float2(rand(rng), rand(rng))), l = reflect(-lv, m);
        if (l.z <= 0) return false;
        dir = t * l.x + b * l.y + n * l.z;
        weight = schlick(f0, dot(lv, m)) * smithG2(nv, l.z, a2) / smithG1(nv, a2) / pSpecular;
        return true;
    }

    static float3 faceViewer(float3 n, float3 v) {
        float d = dot(n, v);
        return d < 0.05f ? normalize(n + v * (0.05f - d)) : n;
    }

    // MARK: Lights

    struct LightRay {
        float3 dir;
        float dist;
        float3 e;  // what to multiply the BRDF by
    };

    // A random point on the light, for the bake.
    static LightRay sampleLight(Light l, float3 p, float2 u) {
        uint kind = uint(l.b.w);
        float r = l.a.w;
        if (kind == 2) return {coneSample(l.a.xyz, cos(r), u), INFINITY, l.color.rgb};
        if (kind == 0) {
            float3 toC = l.a.xyz - p;
            float d2 = dot(toC, toC), d = sqrt(d2);
            if (d2 <= r * r) return {toC / max(d, 1e-6f), 0, l.color.rgb / max(r * r, 1e-8f)};
            float cosMax = sqrt(1 - r * r / d2);
            float3 dir = coneSample(toC / d, cosMax, u);
            float b = dot(toC, dir);
            return {dir, b - sqrt(max(b * b - d2 + r * r, 0.0f)), l.color.rgb * (2 * (1 - cosMax) / (r * r))};
        }
        // Along a tube in proportion to the angle each part spans from p, which is about what each
        // part gives p, so samples near a long tube hardly differ.
        float3 axis = l.b.xyz - l.a.xyz, t, b;
        float len = length(axis);
        axis /= len;
        basis(axis, t, b);
        float along = dot(p - l.a.xyz, axis), h = max(length(p - l.a.xyz - axis * along), r);
        float lo = atan(-along / h), hi = atan((len - along) / h), angle = mix(lo, hi, u.x), phi = TAU * u.y;
        float3 toQ = l.a.xyz + axis * (along + h * tan(angle)) + (t * cos(phi) + b * sin(phi)) * r - p;
        float d2 = dot(toQ, toQ), d = sqrt(d2), cosine = cos(angle);
        return {toQ / d, d, l.color.rgb * (hi - lo) * h / (cosine * cosine * len * max(d2, r * r))};
    }

    // The light's center (a tube's nearest point) and the irradiance it gives, for live shading.
    static LightRay lightToward(Light l, float3 p) {
        uint kind = uint(l.b.w);
        float r = l.a.w;
        if (kind == 2) return {l.a.xyz, INFINITY, l.color.rgb};
        if (kind == 0) {
            float3 toC = l.a.xyz - p;
            float d = length(toC);
            return {toC / max(d, 1e-6f), max(d - r, 0.0f), l.color.rgb / max(d * d, r * r)};
        }
        float3 axis = l.b.xyz - l.a.xyz;
        float len = length(axis);
        axis /= len;
        float along = dot(p - l.a.xyz, axis);
        float3 toQ = l.a.xyz + axis * clamp(along, 0.0f, len) - p;
        float d = length(toQ), h = max(length(p - l.a.xyz - axis * along), r);
        float spread = (atan((len - along) / h) + atan(along / h)) / (h * len);
        return {toQ / max(d, 1e-6f), max(d - r, 0.0f), l.color.rgb * spread};
    }

    // Whether a live light has a range or a cone, and how much of them reaches d from it in
    // direction `away`.
    static bool shaped(LiveLight l) { return isfinite(l.falloff.x) || any(l.spot.xyz != 0); }
    static float liveRange(LiveLight l, float d2) {
        float x = d2 / (l.falloff.x * l.falloff.x), w = saturate(1 - x * x);
        return w * w;
    }
    static float liveCone(LiveLight l, float3 away) { return smoothstep(l.spot.w, l.falloff.y, dot(away, l.spot.xyz)); }

    static LightRay liveLightToward(LiveLight l, float3 p) {
        float3 toL = l.position.xyz - p;
        float d = length(toL);
        float3 dir = toL / max(d, 1e-6f), e = l.color.rgb / max(d * d, l.position.w * l.position.w);
        return {dir, max(d - l.position.w, 0.0f), shaped(l) ? e * liveRange(l, d * d) * liveCone(l, -dir) : e};
    }

    // Where a ray from 0 to dist is inside a cone from q around axis, under 90° wide. The cone is
    // convex, so that's one stretch, bounded by 0, dist or the roots of its quadratic.
    static float2 coneInterval(float3 q, float3 axis, float cosine, float3 ro, float3 rd, float dist) {
        float3 w = ro - q;
        float wa = dot(w, axis), da = dot(rd, axis), k = cosine * cosine;
        float a = da * da - k, b = wa * da - k * dot(w, rd), root = sqrt(max(b * b - a * (wa * wa - k * dot(w, w)), 0.0f));
        float2 r = clamp(float2(-b - root, -b + root) / (abs(a) > 1e-6f ? a : 1e-6f), 0.0f, dist);
        float edge[4] = {0, min(r.x, r.y), max(r.x, r.y), dist};
        float2 span = float2(dist, 0);
        for (int i = 0; i < 3; i++) {
            float3 x = w + rd * (edge[i] + edge[i + 1]) * 0.5f;
            if (edge[i + 1] > edge[i] && dot(x, axis) > cosine * length(x)) span = float2(min(span.x, edge[i]), edge[i + 1]);
        }
        return span;
    }

    // Roughly how much a light gives a surface at p facing n: its intensity over the distance² to
    // its nearest point, or for an opaque surface none where all of it is behind. Not a cosine,
    // which would favor lights high overhead even where they are blocked.
    static float lightWeight(Light l, float3 p, float3 n, float translucency) {
        uint kind = uint(l.b.w);
        float lum = luminance(l.color.rgb), r = l.a.w;
        if (kind == 2) return lum * (dot(n, l.a.xyz) + r > 0 ? 1 : translucency);
        float3 a = l.a.xyz - p, b = kind == 1 ? l.b.xyz - p : a, axis = b - a, q = a;
        if (kind == 1) q += axis * saturate(-dot(a, axis) / dot(axis, axis));
        return lum / max(dot(q, q), r * r) * (max(dot(n, a), dot(n, b)) + r > 0 ? 1 : translucency);
    }

    // One light, chosen in proportion to roughly how much it gives the surface, by one random
    // number rescaled after each light's turn.
    static int pickLight(Ctx c, float3 p, float3 n, float translucency, thread uint& rng, thread float& chance) {
        float total = 0, picked = 0, u = rand(rng);
        int chosen = -1;
        for (uint i = 0; i < c.f->lightCount; i++) {
            float w = lightWeight(c.lights[i], p, n, translucency);
            if (w <= 0) continue;
            total += w;
            float share = w / total;
            if (u < share) {
                chosen = int(i);
                picked = w;
                u /= share;
            } else {
                u = (u - share) / (1 - share);
            }
        }
        chance = picked / max(total, 1e-20f);
        return chosen;
    }

    // MARK: Context

    float Context::noise(float3 p) thread const {
        constexpr sampler s(filter::linear, address::repeat);
        return noiseTexture.sample(s, p * (1.0f / 16.0f)).x;
    }

    float Context::fbm(float3 p, int octaves) thread const {
        float sum = 0, amplitude = 0.5;
        for (int i = 0; i < octaves; i++) {
            sum += amplitude * noise(p);
            p = p * 2.03f + float3(1.7, 9.2, 3.1);
            amplitude *= 0.5;
        }
        return sum;
    }

    // By differences, which beat a texture holding the gradient: that one filters at half speed.
    float4 Context::noised(float3 p) thread const {
        const float e = 0.02;
        float f = noise(p);
        return float4(f, float3(noise(p + float3(e, 0, 0)) - f, noise(p + float3(0, e, 0)) - f, noise(p + float3(0, 0, e)) - f) / e);
    }

    float4 Context::fbmd(float3 p, int octaves) thread const {
        const float e = 0.02;
        float f = fbm(p, octaves);
        return float4(f, float3(fbm(p + float3(e, 0, 0), octaves) - f, fbm(p + float3(0, e, 0), octaves) - f, fbm(p + float3(0, 0, e), octaves) - f) / e);
    }

    float3 Context::tint(uint group, float3 p) thread const { return group < GROUP_COUNT ? groupTint(group, p, *this) : float3(0); }

    // What a ray found: how far, which copy, which triangle and where on it.
    struct Found {
        float distance;
        uint instance;
        uint primitive;
        float2 bary;
    };

    // A vector in a copy's own space, in the world's: the inverse of its rows' transpose.
    static float3 toWorld(Instance in, float3 v) {
        float3 a = in.inverse[0].xyz, b = in.inverse[1].xyz, d = in.inverse[2].xyz, bd = cross(b, d);
        return (v.x * bd + v.y * cross(d, a) + v.z * cross(a, b)) / dot(a, bd);
    }

    // What a hit is without its geometry: all opacity() gets, so cut-out candidates stay cheap.
    // `v` and `w` get its triangle's vertices and their weights.
    static Hit bareHit(Ctx c, ray r, Found f, uint bounce, thread uint3& v, thread float3& w) {
        Instance in = c.instances[f.instance];
        uint k = in.indexOffset + f.primitive * 3;
        v = uint3(c.indices[k], c.indices[k + 1], c.indices[k + 2]) + in.vertexOffset;
        w = float3(1 - f.bary.x - f.bary.y, f.bary);
        Hit h;
        h.material = in.material;
        h.tag = in.tag;
        h.instance = f.instance;
        h.bounce = bounce;
        h.p = r.origin + r.direction * f.distance;
        h.n = 0;
        h.local = 0;
        h.uv = c.uvs[v.x] * w.x + c.uvs[v.y] * w.y + c.uvs[v.z] * w.z;
        return h;
    }

    // The hit a scene function sees, and the geometric normal. `lift` gets how far the point lies
    // under the curve its vertex normals describe, along h.n: shadow rays leave from there, so a
    // coarse mesh doesn't shadow itself in facets along its terminator. One number, not a point,
    // since the path tracer holds it for the whole path.
    static Hit hitOn(Ctx c, ray r, Found f, uint bounce, thread float3& ng, thread float& lift) {
        uint3 v;
        float3 w;
        Hit h = bareHit(c, r, f, bounce, v, w);
        Instance in = c.instances[f.instance];
        float3 p0 = c.positions[v.x], p1 = c.positions[v.y], p2 = c.positions[v.z];
        float3 n0 = c.normals[v.x], n1 = c.normals[v.y], n2 = c.normals[v.z], n = n0 * w.x + n1 * w.y + n2 * w.z, g = cross(p1 - p0, p2 - p0);
        h.local = p0 * w.x + p1 * w.y + p2 * w.z;
        h.n = normalize(in.inverse[0].xyz * n.x + in.inverse[1].xyz * n.y + in.inverse[2].xyz * n.z);
        ng = normalize(in.inverse[0].xyz * g.x + in.inverse[1].xyz * g.y + in.inverse[2].xyz * g.z);
        float3 q0 = h.local - min(dot(h.local - p0, n0), 0.0f) * n0, q1 = h.local - min(dot(h.local - p1, n1), 0.0f) * n1;
        float3 q2 = h.local - min(dot(h.local - p2, n2), 0.0f) * n2;
        lift = dot(toWorld(in, q0 * w.x + q1 * w.y + q2 * w.z - h.local), h.n);
        return h;
    }

    // Whether a ray stops at a cut-out candidate: where opacity() beats 0.5 live, and a random
    // threshold in the bake.
    static bool stops(Ctx c, ray r, Found f, uint bounce) {
        uint3 v;
        float3 w;
        return opacity(bareHit(c, r, f, bounce, v, w), c) > (c.jitter ? hash(r.origin + r.direction * f.distance) : 0.5f);
    }

    // The nearest hit along r, or with `any` whichever is found first. Cut-outs, kept apart, take
    // the fast path too, which finds the nearest one in the way (any one, for `any`); only a ray
    // that meets a hole there pays for a query, which goes on past it.
    static bool find(Ctx c, ray r, uint mask, bool any, uint bounce, thread Found& found) {
        intersector<triangle_data, instancing> i;
        i.assume_geometry_type(geometry_type::triangle);
        i.force_opacity(forced_opacity::opaque);
        i.accept_any_intersection(any);
        auto x = i.intersect(r, c.world, mask);
        bool hit = x.type != intersection_type::none;
        if (hit) found = {x.distance, x.user_instance_id, x.primitive_id, x.triangle_barycentric_coord};
    #ifdef CUT_OUTS
        if (hit && any) return true;
        if (hit) r.max_distance = x.distance;
        x = i.intersect(r, c.cutOuts, mask);
        if (x.type == intersection_type::none) return hit;
        Found f{x.distance, x.user_instance_id, x.primitive_id, x.triangle_barycentric_coord};
    #ifdef CUT_OUTS_SOLID_TO_LIGHT
        bool solid = any || bounce > 0;
    #else
        bool solid = false;
    #endif
        if (solid || stops(c, r, f, bounce)) {
            found = f;
            return true;
        }
        if (!any) r.min_distance = f.distance;
        intersection_params params;
        params.assume_geometry_type(geometry_type::triangle);
        params.accept_any_intersection(any);
        intersection_query<triangle_data, instancing> q(r, c.cutOuts, mask, params);
        while (q.next()) {
            f = {q.get_candidate_triangle_distance(), q.get_candidate_user_instance_id(), q.get_candidate_primitive_id(), q.get_candidate_triangle_barycentric_coord()};
            if (!stops(c, r, f, bounce)) continue;
            if (any) {
                found = f;
                return true;
            }
            q.commit_triangle_intersection();
        }
        if (q.get_committed_intersection_type() == intersection_type::none) return hit;
        found = {q.get_committed_distance(), q.get_committed_user_instance_id(), q.get_committed_primitive_id(), q.get_committed_triangle_barycentric_coord()};
        return true;
    #else
        return hit;
    #endif
    }

    bool Context::blocked(float3 origin, float3 dir, float dist) thread const {
        Found f;
        return dist > 0 && find(*this, ray(origin, dir, 0, dist), SHADOW_MASK, true, 1, f);
    }

    float Context::hitDistance(float3 origin, float3 dir) thread const {
        Found f;
        return find(*this, ray(origin, dir, 0, INFINITY), CAMERA_MASK, false, 1, f) ? f.distance : FAR;
    }

    // The sky's tint where it lights live shading, 0 where it doesn't.
    static float3 skyTint(Ctx c) { return c.f->skyGroup < MAX_GROUPS ? c.f->tint[c.f->skyGroup].rgb : 0; }

    // Real spherical harmonics up to second order, x y z being the world's axes.
    static void harmonics(float3 d, thread float* y) {
        y[0] = 0.282095f;
        y[1] = 0.488603f * d.y;
        y[2] = 0.488603f * d.z;
        y[3] = 0.488603f * d.x;
        y[4] = 1.092548f * d.x * d.y;
        y[5] = 1.092548f * d.y * d.z;
        y[6] = 0.315392f * (3 * d.z * d.z - 1);
        y[7] = 1.092548f * d.x * d.z;
        y[8] = 0.546274f * (d.x * d.x - d.y * d.y);
    }

    // The sky's irradiance facing n, mixed by `through` with that from behind, which needs no second
    // evaluation: only the first band changes sign with the direction. ambientLight holds the
    // harmonics already convolved with a cosine (see ambientKernel).
    static float3 skyIrradiance(Ctx c, float3 n, float through) {
        float y[9];
        harmonics(n, y);
        float3 even = 0, odd = 0;
        for (int k = 0; k < 9; k++) {
            float3 term = c.ambientLight[k].rgb * y[k];
            if (k >= 1 && k <= 3) odd += term;
            else even += term;
        }
        return mix(max(even + odd, 0.0f), max(even - odd, 0.0f), through) * skyTint(c);
    }

    float3 Context::ambient(float3 n) thread const { return skyIrradiance(*this, n, 0); }

    // The sky's light arriving from every direction at once: 4π times its mean radiance.
    static float3 skyFluence(Ctx c) { return c.ambientLight[0].rgb * (2 / sqrt(PI)) * skyTint(c); }

    float3 Context::liveLight(float3 p, float3 n, float3 v, Surface s) thread const {
        float3 sum = 0;
        for (uint i = 0; i < f->liveLightCount; i++) {
            LiveLight l = f->liveLights[i];
            LightRay lr = liveLightToward(l, p);
            if (all(lr.e <= 0)) continue;
            float3 fr = bsdf(s, n, v, lr.dir, 1);
            if (all(fr <= 0) || (l.color.w > 0 && blocked(offset(p, dot(lr.dir, n) > 0 ? n : -n), lr.dir, lr.dist))) continue;
            sum += fr * lr.e;
        }
        return sum;
    }

    float3 Context::shade(float3 p, float3 n, float3 v, Surface s) thread const {
        float3 sum = skyIrradiance(*this, n, s.translucency) * s.albedo * (1 - s.metallic) / PI + liveLight(p, n, v, s);
        for (uint i = 0; i < f->lightCount; i++) {
            Light l = lights[i];
            LightRay lr = lightToward(l, p);
            float3 fr = bsdf(s, n, v, lr.dir, 1);
            if (any(fr > 0) && !blocked(offset(p, dot(lr.dir, n) > 0 ? n : -n), lr.dir, lr.dist)) sum += fr * lr.e * tint(uint(l.color.w), p);
        }
        return sum;
    }

    float3 Context::light(float3 p) thread const {
        float3 sum = skyFluence(*this);
        for (uint i = 0; i < f->lightCount; i++) sum += lightToward(lights[i], p).e * tint(uint(lights[i].color.w), p);
        for (uint i = 0; i < f->liveLightCount; i++) sum += liveLightToward(f->liveLights[i], p).e;
        return sum / (4 * PI);
    }

    // How much of a light's glow along a ray survives `reach` (see Context::inscatter), the ray
    // passing `off` from its center; 0 to skip it.
    static float glowFade(float off, float halfLength, float3 color, float reach) {
        if (reach >= FAR) return 1;
        float far = reach * sqrt(luminance(color)) + halfLength;
        return smoothstep(far, far * 0.5f, off);
    }

    // What extinction leaves of the light from q that scatters toward the eye t along the ray.
    static float3 extinguished(float3 extinction, float3 q, float3 ro, float3 rd, float t) { return exp(-extinction * (t + distance(ro + rd * t, q))); }

    float3 Context::inscatter(float3 ro, float3 rd, float dist, uint which, float reach, float3 extinction) thread const {
        float3 sum = 0;
        float t;
        // How much of a light from afar is left to scatter, over the ray's length.
        float3 along = select(float3(dist), (1 - exp(-extinction * dist)) / extinction, extinction > 1e-6f);
        for (uint i = 0; i < (which & (DISTANT_LIGHTS | LOCAL_LIGHTS) ? f->lightCount : 0); i++) {
            Light l = lights[i];
            uint kind = uint(l.b.w), group = uint(l.color.w);
            // Not groupTint, which would sample a pattern at the eye and flicker the whole fog.
            if (kind == 2) {
                if (which & DISTANT_LIGHTS) sum += l.color.rgb * f->tint[group].rgb * along;
                continue;
            }
            float3 center = kind == 1 ? (l.a.xyz + l.b.xyz) * 0.5f : l.a.xyz, axis = l.b.xyz - l.a.xyz, to = center - ro;
            float off = sqrt(max(dot(to, to) - dot(to, rd) * dot(to, rd), 0.0f));
            float fade = which & LOCAL_LIGHTS ? glowFade(off, kind == 1 ? length(axis) * 0.5f : 0, l.color.rgb * f->tint[group].rgb, reach) : 0;
            if (fade <= 0) continue;
            float s = kind == 1 ? scatter(l.a.xyz, l.b.xyz, l.a.w, ro, rd, dist, t) : scatter(center, l.a.w, ro, rd, dist, t);
            t = clamp(t, 0.0f, dist);
            float3 q = kind == 1 ? l.a.xyz + axis * saturate(dot(ro + rd * t - l.a.xyz, axis) / dot(axis, axis)) : center;
            sum += l.color.rgb * tint(group, center) * s * fade * extinguished(extinction, q, ro, rd, t);
        }
        for (uint i = 0; i < (which & LIVE_LIGHTS ? f->liveLightCount : 0); i++) {
            LiveLight l = f->liveLights[i];
            // A ray that misses the sphere round its range and cone (falloff.w) gets none of its glow.
            float3 w = l.position.xyz - ro, bounds = w + l.spot.xyz * l.falloff.w, color = l.color.rgb * l.falloff.z;
            float bound = l.falloff.w > 0 ? l.falloff.w : l.falloff.x;
            if (l.falloff.z <= 0 || distance_squared(bounds, rd * clamp(dot(bounds, rd), 0.0f, dist)) >= bound * bound) continue;
            // Where the ray passes nearest it, and how near, serve its reach, its range and its glow.
            float near = dot(w, rd), off2 = max(dot(w, w) - near * near, 0.0f), off = sqrt(off2);
            float fade = glowFade(off, 0, color, reach);
            if (fade <= 0) continue;
            // Only the stretch of the ray within its range and cone glows.
            float2 span = float2(0, dist);
            if (shaped(l)) span = clamp(near + float2(-1, 1) * sqrt(max(l.falloff.x * l.falloff.x - off2, 0.0f)), 0.0f, dist);
            bool spot = any(l.spot.xyz != 0);
            if (spot) {
                float2 cone = coneInterval(l.position.xyz, l.spot.xyz, l.spot.w, ro, rd, dist);
                span = float2(max(span.x, cone.x), min(span.y, cone.y));
            }
            if (span.x >= span.y) continue;
            // scatter() over the span; the range where the ray passes nearest, and the cone halfway along.
            float h = max(off, l.position.w), at = clamp(near, span.x, span.y);
            float s = atan2((span.y - span.x) * h, h * h + (span.x - near) * (span.y - near)) / h;
            if (shaped(l)) fade *= liveRange(l, off2 + (at - near) * (at - near));
            if (spot) {
                float3 middle = ro + rd * (span.x + span.y) * 0.5f - l.position.xyz;
                fade *= liveCone(l, middle / max(length(middle), 1e-6f));
            }
            sum += color * s * fade * extinguished(extinction, l.position.xyz, ro, rd, at);
        }
        if (which & DISTANT_LIGHTS) sum += skyFluence(*this) * along;
        return sum / (4 * PI);
    }

    bool Context::intersect(ray r, uint mask, thread Hit& h, thread float& t, thread float3& ng) thread const {
        Found f;
        float lift;
        if (!find(*this, r, mask, false, h.bounce, f)) return false;
        h = hitOn(*this, r, f, h.bounce, ng, lift);
        t = f.distance;
        return true;
    }

    Hit Context::hitAt(uint instance, float3 p, float3 n) thread const {
        Instance in = instances[instance];
        Hit h;
        h.material = in.material;
        h.tag = in.tag;
        h.instance = instance;
        h.bounce = 0;
        h.p = p;
        h.n = n;
        h.local = float3(dot(in.inverse[0].xyz, p) + in.inverse[0].w, dot(in.inverse[1].xyz, p) + in.inverse[1].w, dot(in.inverse[2].xyz, p) + in.inverse[2].w);
        h.uv = 0;
        return h;
    }

    // MARK: Baking

    static ray cameraRay(constant View& view, float2 pixel) {
        float2 q = float2(mix(view.rect.x, view.rect.z, pixel.x / view.size.x), mix(view.rect.w, view.rect.y, pixel.y / view.size.y));
        return ray(view.eye.xyz, normalize(view.right.xyz * q.x + view.up.xyz * q.y + view.forward.xyz * view.eye.w), 0, INFINITY);
    }

    struct Path {
        float3 groups[GROUP_COUNT];
        float3 mirror;  // smooth reflections that escaped to the sky, drawn live
        float clear;    // sky seen directly or through smooth glass, drawn live
    };

    static float3 limit(float3 v, float most) {
        float l = luminance(v);
        return l > most ? v * (most / l) : v;
    }

    // `count` paths from the eye along r. They share the first hit, whose surface is the costliest
    // to work out; the camera ray is jittered per pass instead. Analytic lights are reached only
    // by sampling them at each bounce; emission counts only where a smooth reflection or
    // refraction sees it.
    static void trace(ray first, uint count, Ctx c, constant View& view, thread uint& rng, thread Path& path) {
        Found found;
        float3 seenNg;
        float seenLift;
        if (!find(c, first, CAMERA_MASK, false, 0, found)) {
            path.clear += count;
            return;
        }
        Hit seen = hitOn(c, first, found, 0, seenNg, seenLift);
        bool seenEntering = dot(seen.n, -first.direction) > 0;
        if (!seenEntering) seen.n = -seen.n;
        if (dot(seenNg, first.direction) > 0) seenNg = -seenNg;
        Surface seenSurface = surface(seen, c);
        for (uint i = 0; i < count; i++) {
            Hit h = seen;
            Surface s = seenSurface;
            float3 ng = seenNg, v = -first.direction, throughput = 1;
            float lift = seenLift;
            bool entering = seenEntering, clear = true;
            // The shares of what the path meets next that are drawn live (the sky, in mirrors) and
            // whose emission counts.
            float mirror = 1, emissive = 0;
            for (uint bounce = 0;;) {
                float most = bounce == 0 ? INFINITY : view.clampLimit;
                float3 n = faceViewer(s.normal, v), dir;
                if (s.transmission > 0 && rand(rng) < s.transmission) {
                    float eta = entering ? 1 / s.ior : s.ior;
                    bool reflected = rand(rng) < fresnelDielectric(saturate(dot(n, v)), eta);
                    dir = reflected ? reflect(-v, n) : refract(-v, n, eta);
                    if (all(dir == 0)) {
                        dir = reflect(-v, n);
                        reflected = true;
                    }
                    if (reflected) clear = false;
                    else {
                        mirror = 0;
                        throughput *= s.albedo;
                    }
                    emissive = 1;
                } else {
                    clear = false;
                    float gloss = glossy(s.roughness), chance;
                    int chosen = pickLight(c, h.p, n, s.translucency, rng, chance);
                    if (chosen >= 0) {
                        Light l = c.lights[chosen];
                        LightRay lr = sampleLight(l, h.p, float2(rand(rng), rand(rng)));
                        float3 fr = bsdf(s, n, v, lr.dir, gloss);
                        // The smooth normal, unbumped, says which side a light is on, and the
                        // shadow ray whether it gets there: from the lifted point in front, through
                        // the back of a translucent surface.
                        float side = dot(lr.dir, h.n);
                        if (side * dot(lr.dir, n) > 0 && any(fr > 0) && !c.blocked(offset(h.p + h.n * (side > 0 && entering ? lift : 0), side > 0 ? ng : -ng), lr.dir, lr.dist))
                            path.groups[uint(l.color.w)] += limit(throughput * fr * lr.e / chance, most);
                    }
                    float3 weight;
                    bool lobe;
                    if (!sampleBSDF(s, n, v, rng, dir, weight, lobe) || dot(dir, ng) * dot(dir, n) <= 0) break;
                    throughput *= weight;
                    emissive = lobe ? 1 - gloss : 0;
                    mirror *= lobe ? mirrored(s.roughness) : 0;
                    if (bounce >= 1) {
                        float keep = clamp(max(throughput.x, max(throughput.y, throughput.z)), 0.05f, 0.95f);
                        if (rand(rng) > keep) break;
                        throughput /= keep;
                    }
                }
                if (++bounce > view.bounces) break;
                ray r(offset(h.p, dot(dir, ng) > 0 ? ng : -ng), dir, 0, INFINITY);
                if (!find(c, r, CAMERA_MASK, false, bounce, found)) {
                    if (clear) path.clear += luminance(throughput);
                    else {
                        path.mirror += throughput * mirror;
                        if (mirror < 1 && c.f->skyGroup < GROUP_COUNT) path.groups[c.f->skyGroup] += limit(throughput * (1 - mirror) * sky(dir, c), view.clampLimit);
                    }
                    break;
                }
                h = hitOn(c, r, found, bounce, ng, lift);
                v = -dir;
                entering = dot(h.n, v) > 0;
                if (!entering) h.n = -h.n;
                if (dot(ng, v) < 0) ng = -ng;
                s = surface(h, c);
    #ifdef HAS_EMISSION
                if (emissive > 0) {
                    Emission e = emission(h, c);
                    if (e.group < GROUP_COUNT) path.groups[e.group] += limit(throughput * e.color * emissive, view.clampLimit);
                }
    #endif
            }
        }
    }

    // Rounds up or down at random in proportion, so a running mean in half precision doesn't
    // lose small additions.
    static half4 toHalf(float4 v, float u) {
        v = select(clamp(v, -60000.0f, 60000.0f), float4(0), !isfinite(v));
        return half4(v + (u - 0.5f) * exp2(floor(log2(max(abs(v), 6.2e-5f))) - 10));
    }

    kernel void bakeKernel(constant View& view [[buffer(0)]], WORLD_ARGS,
                           texture2d_array<half, access::read_write> groups [[texture(0)]],
                           texture2d<half, access::read_write> skyLight [[texture(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
        uint2 px = uint2(gid.x, gid.y + view.rowOffset);
        if (px.x >= view.size.x || px.y >= view.size.y) return;
        CONTEXT(view.eye.xyz, view.forward.w);
        c.jitter = true;
        Path path;
        for (uint g = 0; g < GROUP_COUNT; g++) path.groups[g] = 0;
        path.mirror = 0;
        path.clear = 0;
        uint rng = pcg3(uint3(px, view.sample)).x;
        trace(cameraRay(view, float2(px) + float2(rand(rng), rand(rng))), view.count, c, view, rng, path);
        float weight = float(view.count) / float(view.sample + view.count), scale = 1.0f / float(view.count);
        for (uint g = 0; g < GROUP_COUNT; g++) {
            float3 old = view.sample == 0 ? float3(0) : float3(groups.read(px, g).rgb);
            groups.write(toHalf(float4(mix(old, path.groups[g] * scale, weight), 1), rand(rng)), px, g);
        }
        float4 old = view.sample == 0 ? float4(0) : float4(skyLight.read(px));
        skyLight.write(toHalf(mix(old, float4(path.mirror, path.clear) * scale, weight), rand(rng)), px);
    }

    kernel void compactKernel(texture2d_array<half, access::read> groups [[texture(0)]], texture2d_array<half, access::write> compacted [[texture(1)]],
                              uint3 gid [[thread_position_in_grid]]) {
        if (gid.x >= groups.get_width() || gid.y >= groups.get_height()) return;
        float3 v = float3(groups.read(gid.xy, gid.z).rgb);
        // Six bits of mantissa in red and green, five in blue.
        float3 step = exp2(floor(log2(max(v, 6.2e-5f))) - float3(6, 6, 5));
        compacted.write(half4(half3(max(v + (hash(float3(gid)) - 0.5f) * step, 0.0f)), 1), gid.xy, gid.z);
    }

    static float2 octEncode(float3 n) {
        n /= abs(n.x) + abs(n.y) + abs(n.z);
        return n.z >= 0 ? n.xy : (1 - abs(n.yx)) * select(float2(-1), float2(1), n.xy >= 0);
    }

    static float3 octDecode(float2 e) {
        float3 n = float3(e, 1 - abs(e.x) - abs(e.y));
        float t = saturate(-n.z);
        n.xy += select(float2(t), float2(-t), n.xy >= 0);
        return normalize(n);
    }

    // What the eye sees first through each pixel's center, for shading live light over the bake:
    // distance; copy and metallic; normal (12 bits a component), translucency and whether it
    // reflects live(); albedo and roughness. Glass keeps only its reflection.
    kernel void surfaceKernel(constant View& view [[buffer(0)]], WORLD_ARGS, texture2d<uint, access::write> out [[texture(0)]],
                              uint2 px [[thread_position_in_grid]]) {
        if (px.x >= view.size.x || px.y >= view.size.y) return;
        CONTEXT(view.eye.xyz, view.forward.w);
        ray r = cameraRay(view, float2(px) + 0.5f);
        Hit h;
        float t;
        float3 ng;
        h.bounce = 0;
        if (!c.intersect(r, CAMERA_MASK, h, t, ng)) {
            out.write(uint4(as_type<uint>(INFINITY), 0, 0, 0), px);
            return;
        }
        float3 v = -r.direction;
        if (dot(h.n, v) < 0) h.n = -h.n;
        Surface s = surface(h, c);
        uint2 n = uint2(round((octEncode(faceViewer(s.normal, v)) * 0.5f + 0.5f) * 4095));
        out.write(uint4(as_type<uint>(t), (h.instance & 0xFFFFFFu) | (uint(saturate(s.metallic) * 255) << 24),
                        n.x | (n.y << 12) | (uint(saturate(s.translucency) * 127 + 0.5f) << 24) | (s.reflectsLive ? 1u << 31 : 0),
                        pack_float_to_unorm4x8(float4(saturate(s.albedo * (1 - s.transmission)), saturate(s.roughness)))), px);
    }

    // MARK: Each frame

    #ifdef HAS_ATMOSPHERE
    static float3 hazed(float3 color, float3 ro, float3 rd, float dist, Ctx c) {
        Atmosphere a = atmosphere(ro, rd, dist, c);
        return color * a.transmittance + a.inscatter;
    }
    #endif

    #ifdef HAS_LIVE
    static float3 reflectLive(float3 color, float3 p, float3 n, float3 v, Surface s, Ctx c) {
        float3 dir = reflect(-v, n), o = offset(p, n);
        Live l = live(o, dir, c.hitDistance(o, dir), c);
        float3 f = schlick(mix(float3(0.04), s.albedo, s.metallic), dot(n, v)) * (1 - smoothstep(0.0f, LIVE_REFLECTION_ROUGHNESS, s.roughness));
        return color * (1 - f * l.alpha) + f * l.color;
    }

    // live() through a pixel: at its center, or averaged over LIVE_SAMPLES points spread across the
    // pixel and the shutter, at the depth of those that hit. One call, since a scene's live() can
    // be big enough that a second inlined copy slows the whole pass.
    static Live liveThrough(uint2 px, float maxDist, constant View& view, Ctx c) {
        Live sum = {0, 0, 0};
        float3 shift = LIVE_SAMPLES == 1 ? float3(0.5f, 0.5f, 0.5f) : hash3(float3(px.x, px.y, 0.5f));
        for (uint k = 0; k < LIVE_SAMPLES; k++) {
            ray r = cameraRay(view, float2(px) + fract(shift.xy + float2(0.7548777f, 0.5698403f) * k));
            Context at = c;
            at.t += ((k + shift.z) / LIVE_SAMPLES - 0.5f) * SHUTTER;
            Live l = live(r.origin, r.direction, maxDist, at);
            sum.color += l.color;
            sum.alpha += l.alpha;
            sum.depth += l.alpha * min(l.depth, FAR);
            sum.hazed = sum.hazed || l.hazed;
        }
        sum.depth = sum.alpha > 0 ? sum.depth / sum.alpha : FAR;
        sum.color /= LIVE_SAMPLES;
        sum.alpha /= LIVE_SAMPLES;
        return sum;
    }
    #endif

    kernel void liveKernel(constant View& view [[buffer(0)]], WORLD_ARGS,
                           texture2d_array<half, access::read> groups [[texture(0)]],
                           texture2d<half, access::read> skyLight [[texture(1)]],
                           texture2d<uint, access::read> surfaces [[texture(2)]],
                           texture2d<half, access::write> color [[texture(3)]],
                           texture2d<float, access::write> depth [[texture(4)]],
                           uint2 px [[thread_position_in_grid]]) {
        if (px.x >= view.size.x || px.y >= view.size.y) return;
        CONTEXT(view.eye.xyz, view.forward.w);
        ray r = cameraRay(view, float2(px) + 0.5f);
        uint4 g = surfaces.read(px);
        float dist = as_type<float>(g.x);
        float4 sl = float4(skyLight.read(px));
        float3 result = 0;
        if (isfinite(dist)) {
            float3 p = r.origin + r.direction * dist, v = -r.direction;
            float4 albedo = unpack_unorm4x8_to_float(g.w);
            Surface s = material(albedo.rgb, albedo.a, octDecode(float2(g.z & 0xFFFu, (g.z >> 12) & 0xFFFu) / 4095 * 2 - 1));
            s.metallic = float(g.y >> 24) / 255;
            s.translucency = float((g.z >> 24) & 127u) / 127;
            s.reflectsLive = g.z >> 31;
            for (uint i = 0; i < GROUP_COUNT; i++) result += c.tint(i, p) * float3(groups.read(px, i).rgb);
            Hit h = c.hitAt(g.y & 0xFFFFFFu, p, s.normal);
    #ifdef HAS_EMISSION
            Emission e = emission(h, c);
            result += e.color * c.tint(e.group, p);
    #endif
            result += c.liveLight(p, s.normal, v, s);
    #ifdef LIVE_REFLECTIONS
            bool reflects = s.reflectsLive && s.roughness < LIVE_REFLECTION_ROUGHNESS;
    #else
            bool reflects = false;
    #endif
            float3 n = s.normal;
    #ifdef HAS_LIVE_NORMAL
            if (reflects || any(sl.rgb > 0)) n = liveNormal(h, c);
    #endif
            if (any(sl.rgb > 0)) {
                float3 dir = reflect(r.direction, n), mirrored = sky(dir, c);
    #if defined(HAS_ATMOSPHERE) && defined(HAZE_MIRRORS)
                mirrored = hazed(mirrored, p, dir, FAR, c);
    #endif
                result += sl.rgb * mirrored;
            }
    #ifdef HAS_LIVE
            if (reflects) result = reflectLive(result, p, n, v, s, c);
    #endif
        }
        if (sl.a > 0) result += sl.a * sky(r.direction, c);
        float d = isfinite(dist) ? dist : FAR;
    #ifdef HAS_LIVE
        Live l = liveThrough(px, d, view, c);
        float behind = d;
        if (l.alpha > 0.5f) d = min(d, l.depth);
    #ifdef HAS_ATMOSPHERE
        // Hazed live() goes over what's behind it, hazed at its own depth; the rest is hazed with it.
        Atmosphere a = atmosphere(r.origin, r.direction, l.hazed ? behind : d, c);
        result = l.hazed ? l.color + (1 - l.alpha) * (result * a.transmittance + a.inscatter)
                         : (l.color + (1 - l.alpha) * result) * a.transmittance + a.inscatter;
    #else
        result = l.color + (1 - l.alpha) * result;
    #endif
    #elif defined(HAS_ATMOSPHERE)
        result = hazed(result, r.origin, r.direction, d, c);
    #endif
        result = select(clamp(result, 0.0f, 60000.0f), float3(0), !isfinite(result));
        color.write(half4(half3(result), 1), px);
        depth.write(float4(d), px);
    }

    // MARK: Particles

    struct ParticleOut {
        float4 position [[position]];
        float3 color;
        float alpha;
        float2 local;       // across the quad, in units of size
        float halfLength;   // of the streak, in units of size
        float dist;
        float size;
        float puff;
        float seed;
        float glow;
        float halo;
        float tail;
    };

    static ParticleOut particleVertex(Particle p, uint corner, uint index, constant View& view, Ctx c) {
        ParticleOut o;
        o.position = float4(0, 0, -1, 1);
        o.color = 0;
        o.alpha = 0;
        o.local = 0;
        o.halfLength = 0;
        o.dist = 0;
        o.size = 1;
        o.puff = 0;
        o.seed = 0;
        o.glow = 0;
        o.halo = 1;
        o.tail = 0;
        float3 toP = p.position - view.eye.xyz;
        if (p.alpha <= 0 || p.size <= 0 || dot(toP, view.forward.xyz) <= p.size) return o;
        float dist = length(toP);
        float3 look = toP / dist, streak = p.velocity * SHUTTER;
        streak -= look * dot(streak, look);
        float len = length(streak), h = 0.5f * len / p.size, reach = p.glow > 0 ? max(p.halo, 1.0f) : 1;
        float3 along = len > 1e-6f ? streak / len : view.right.xyz, across = normalize(cross(along, look));
        float2 q = float2((corner & 1) ? 1 : -1, (corner & 2) ? 1 : -1) * float2(reach + h, reach);
        float3 e = p.position + (along * q.x + across * q.y) * p.size - view.eye.xyz;
        float z = dot(e, view.forward.xyz);
        float2 plane = float2(dot(e, view.right.xyz), dot(e, view.up.xyz)) * view.eye.w;
        float2 center = (view.rect.xy + view.rect.zw) * 0.5f, extent = (view.rect.zw - view.rect.xy) * 0.5f;
        o.position = float4((plane - center * z) / extent, 0.5f * z, z);
        o.color = p.color;
    #ifdef HAS_ATMOSPHERE
        o.color *= atmosphere(view.eye.xyz, look, dist, c).transmittance;
    #endif
        o.alpha = p.alpha / (1 + h);
        o.local = q;
        o.halfLength = h;
        o.dist = dist;
        o.size = p.size;
        o.puff = p.puff;
        o.seed = float(index % 1024);
        o.glow = p.glow;
        o.halo = reach;
        o.tail = p.tail;
        return o;
    }

    fragment float4 particleFragment(ParticleOut in [[stage_in]], texture2d<float, access::read> depth [[texture(0)]],
                                     texture3d<float> noiseTexture [[texture(1)]]) {
        float2 q = float2(max(abs(in.local.x) - in.halfLength, 0.0f), in.local.y);
        float r2 = dot(q, q), shape = r2 < 1 ? (1 - r2) * (1 - r2) : 0;
        if (in.glow > 0) {
            float x2 = r2 / (in.halo * in.halo);
            shape += x2 < 1 ? in.glow * (1 - x2) * (1 - x2) / (1 + 16 * x2) : 0;
        }
        if (shape <= 0) discard_fragment();
        if (in.tail > 0 && in.halfLength > 0) shape *= 1 - in.tail * (1 - saturate((in.halfLength + in.local.x) / (2 * in.halfLength)));
        if (in.puff > 0) {
            constexpr sampler s(filter::linear, address::repeat);
            float3 uvw = float3(in.local * 0.09f, 0) + in.seed * float3(0.137f, 0.291f, 0.0611f);
            float n = noiseTexture.sample(s, uvw).x * 0.65f + noiseTexture.sample(s, uvw * 2.03f + 0.31f).x * 0.35f;
            shape *= mix(1.0f, smoothstep(0.35f, 0.75f, n + 0.3f * (1 - r2)), in.puff);
        }
        float a = in.alpha * shape * saturate((depth.read(uint2(in.position.xy)).x - in.dist) / in.size);
        return float4(in.color * a, a);
    }

    // MARK: Bloom (13-tap down, tent up) and the finish

    kernel void bloomDown(texture2d<float, access::sample> src [[texture(0)]], texture2d<half, access::write> dst [[texture(1)]],
                          constant uint& first [[buffer(0)]], uint2 px [[thread_position_in_grid]]) {
        if (px.x >= dst.get_width() || px.y >= dst.get_height()) return;
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = (float2(px) + 0.5f) / float2(dst.get_width(), dst.get_height()), t = 1.0f / float2(src.get_width(), src.get_height());
        auto at = [&](float x, float y) { return src.sample(s, uv + t * float2(x, y)).rgb; };
        float3 a = at(-2, 2), b = at(0, 2), cc = at(2, 2), d = at(-2, 0), e = at(0, 0), f = at(2, 0), g = at(-2, -2), h = at(0, -2), i = at(2, -2);
        float3 j = at(-1, 1), k = at(1, 1), l = at(-1, -1), m = at(1, -1), result;
        if (first) {
            // Each 2×2 group weighed by 1/(1 + luma), so a lone bright pixel can't flare.
            float3 quads[5] = {(j + k + l + m) * 0.25f, (a + b + d + e) * 0.25f, (b + cc + e + f) * 0.25f, (d + e + g + h) * 0.25f, (e + f + h + i) * 0.25f};
            float total = 0;
            result = 0;
            for (int n = 0; n < 5; n++) {
                float w = (n == 0 ? 0.5f : 0.125f) / (1 + luminance(quads[n]));
                result += quads[n] * w;
                total += w;
            }
            result /= total;
        } else {
            result = e * 0.125f + (a + cc + g + i) * 0.03125f + (b + d + f + h) * 0.0625f + (j + k + l + m) * 0.125f;
        }
        dst.write(half4(half3(result), 1), px);
    }

    kernel void bloomUp(texture2d<float, access::sample> coarse [[texture(0)]], texture2d<float, access::read> fine [[texture(1)]],
                        texture2d<half, access::write> dst [[texture(2)]], uint2 px [[thread_position_in_grid]]) {
        if (px.x >= dst.get_width() || px.y >= dst.get_height()) return;
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = (float2(px) + 0.5f) / float2(dst.get_width(), dst.get_height()), t = 1.0f / float2(coarse.get_width(), coarse.get_height());
        auto at = [&](float x, float y) { return coarse.sample(s, uv + t * float2(x, y)).rgb; };
        float3 tent = (at(0, 0) * 4 + (at(-1, 0) + at(1, 0) + at(0, -1) + at(0, 1)) * 2 + at(-1, -1) + at(1, -1) + at(-1, 1) + at(1, 1)) / 16;
        dst.write(half4(half3(fine.read(px).rgb + tent), 1), px);
    }

    struct Finish {
        float4 rect;   // this screen on the image plane
        float4 plane;  // the image plane's center, and the distance to its farthest corner
        float2 size;   // output pixels
        float exposure;
        float bloom;
        float halation;
        float grain;
        float vignette;
        uint frame;
    };

    struct FullscreenOut {
        float4 position [[position]];
    };

    vertex FullscreenOut fullscreen(uint id [[vertex_id]]) {
        FullscreenOut o;
        o.position = float4(float2((id << 1) & 2, id & 2) * 2 - 1, 0, 1);
        return o;
    }

    // AgX: into a log space with the primaries pulled in, a sigmoid, and back out.
    static float3 agx(float3 c) {
        const float3x3 inset = float3x3(float3(0.842479062253094, 0.0423282422610123, 0.0423756549057051),
                                        float3(0.0784335999999992, 0.878468636469772, 0.0784336),
                                        float3(0.0792237451477643, 0.0791661274605434, 0.879142973793104));
        const float3x3 outset = float3x3(float3(1.19687900512017, -0.0528968517574562, -0.0529716355144438),
                                         float3(-0.0980208811401368, 1.15190312990417, -0.0980434501171241),
                                         float3(-0.0990297440797205, -0.0989611768448433, 1.15107367264116));
        const float lo = -12.47393f, hi = 4.026069f;
        float3 x = saturate((clamp(log2(max(inset * c, 1e-10f)), lo, hi) - lo) / (hi - lo)), x2 = x * x, x4 = x2 * x2;
        float3 curve = 15.5f * x4 * x2 - 40.14f * x4 * x + 31.96f * x4 - 6.868f * x2 * x + 0.4298f * x2 + 0.1191f * x - 0.00232f;
        return pow(max(outset * curve, 0.0f), 2.2f);
    }

    static float3 encodeSRGB(float3 c) { return select(1.055f * pow(c, 1 / 2.4f) - 0.055f, c * 12.92f, c <= 0.0031308f); }

    fragment float4 finishFragment(FullscreenOut in [[stage_in]], constant Finish& a [[buffer(0)]], texture2d<float> hdr [[texture(0)]],
                                   texture2d<float> bloom [[texture(1)]], texture2d<float> halo [[texture(2)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = in.position.xy / a.size;
        float3 c = mix(hdr.sample(s, uv).rgb, bloom.sample(s, uv).rgb / BLOOM_LEVELS, a.bloom), glow = halo.sample(s, uv).rgb;
        c += a.halation * glow * float3(1, 0.3f, 0.1f) * smoothstep(1.0f, 6.0f, luminance(glow) * a.exposure);
        // The vignette is one across every screen, centered on the image plane.
        float2 p = mix(a.rect.xy, a.rect.zw, float2(uv.x, 1 - uv.y));
        float r = length(p - a.plane.xy) / a.plane.z;
        c = encodeSRGB(saturate(agx(c * a.exposure * (1 - a.vignette * smoothstep(0.0f, 1.0f, r * r)))));
        float l = luminance(c);
        float2 cell = in.position.xy / 1.5f + float2(a.frame * 37 % 101, a.frame * 59 % 103) * 17.0f;
        c += (noise(cell) - 0.5f) * 8 * a.grain * l * (1 - l);
        c += (hash(in.position.xy + a.frame * 0.618f) + hash(in.position.xy + 31.7f + a.frame * 0.381f) - 1) / 255;
        return float4(c, 1);
    }

    // MARK: Setup

    // Value noise that repeats every 16 cells, 8 texels to a cell.
    kernel void noiseKernel(texture3d<half, access::write> out [[texture(0)]], uint3 gid [[thread_position_in_grid]]) {
        float3 p = float3(gid) / 8, i = floor(p), u = fade(p - i);
        int3 c = int3(i);
        auto at = [&](int x, int y, int z) { return lattice((c + int3(x, y, z)) & 15); };
        float v = mix(mix(mix(at(0, 0, 0), at(1, 0, 0), u.x), mix(at(0, 1, 0), at(1, 1, 0), u.x), u.y),
                      mix(mix(at(0, 0, 1), at(1, 0, 1), u.x), mix(at(0, 1, 1), at(1, 1, 1), u.x), u.y), u.z);
        out.write(half4(v), gid);
    }

    // The sky's light at t = 0 as second-order spherical harmonics, each band already convolved
    // with a cosine, so that Context::ambient only sums them.
    kernel void ambientKernel(WORLD_ARGS, device float4* out [[buffer(11)]], uint tid [[thread_index_in_threadgroup]],
                              uint threads [[threads_per_threadgroup]], uint lane [[thread_index_in_simdgroup]],
                              uint simdgroup [[simdgroup_index_in_threadgroup]]) {
        const uint count = 4096;
        // Each direction stands for its share of the sphere.
        CONTEXT(float3(0), sqrt(4 * PI / count));
        threadgroup float3 sums[9][32];
        float3 sh[9] = {};
        for (uint i = tid; i < count; i += threads) {
            float z = 1 - (2 * i + 1) / float(count), r = sqrt(1 - z * z), phi = i * 2.39996323f, y[9];
            float3 d = float3(r * cos(phi), z, r * sin(phi)), light = sky(d, c);
            harmonics(d, y);
            for (int k = 0; k < 9; k++) sh[k] += light * y[k];
        }
        for (int k = 0; k < 9; k++) {
            float3 sum = simd_sum(sh[k]);
            if (lane == 0) sums[k][simdgroup] = sum;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (tid >= 9) return;
        float3 total = 0;
        for (uint g = 0; g < (threads + 31) / 32; g++) total += sums[tid][g];
        // A cosine keeps π of band 0, 2π/3 of band 1 and π/4 of band 2.
        out[tid] = float4(total * (4 * PI / count) * (tid == 0 ? PI : tid < 4 ? 2 * PI / 3 : PI / 4), 0);
    }

    """#
}
