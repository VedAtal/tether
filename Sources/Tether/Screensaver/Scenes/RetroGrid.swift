import simd

extension SaverScene {
    static let retroGrid = SaverScene(name: "Retro Grid", symbol: "sun.horizon") { RetroGrid.world() }
}

/// Synthwave at dusk: a glossy black plain inlaid with a neon grid, running toward a huge banded
/// sun that sinks between mountains traced in neon. The eye travels forward without end.
private enum RetroGrid {
    enum Group {
        static let sun = 0, sky = 1, grid = 2, glow = 3
    }

    /// Matches the shader's `enum`.
    enum Material: Int {
        case floor, rock, range
    }

    static let eye = SIMD3<Float>(0, 1.4, 0)
    static let fieldOfView: Float = 40
    static let sun = simd_normalize(SIMD3<Float>(0, 0.07, -1))
    /// Meters a second.
    static let speed = 10.0
    /// Every moving pattern repeats within this many meters of travel, which divides the distance
    /// covered in a SaverWorld.cycle, so the travel loops without a jump.
    static let cycle = 2400.0
    /// Neon posts line the way this far out each side, this far apart.
    static let posts: (x: Float, gap: Float) = (12, 24)

    /// The far range is drawn round the eye: columns of azimuth, each with a crest.
    static let columns = 2400
    static let reach: Float = 1.4

    static func world() -> SaverWorld {
        var world = SaverWorld(camera: .init(eye: eye, target: eye + [0, 0, -100], fieldOfView: fieldOfView), shader: shader)
        world.groups = 4
        world.skyGroup = Group.sky
        world.look.halation = 0.3
        world.look.bloom = 0.05
        world.look.clamp = 40
        world.liveReflections = true
        world.look.liveSamples = 4
        world.particles = [.init(function: "meteor", count: 1, blend: .additive)]
        world.add(.grid(size: [24000, 24000], cells: [1, 1]), material: Material.floor.rawValue, at: [.translation([0, 0, -9000])])
        world.lights = [.directional(toward: sun, angle: 0.05, color: [1.6, 0.55, 0.45], group: Group.sun)] + addRange(&world) + addMesas(&world)
        world.update = { time, frame in
            // The car ahead keeps nearly our pace: it eases away and back and wanders in its lane.
            let t = Float(time)
            let car = SIMD3<Float>(0.5 * sin(t * 0.071 + 1) + 0.2 * sin(t * 0.19), 0.006 * sin(t * 5.3) * sin(t * 0.7),
                                   -26 - 6 * sin(t * 0.043) - 2.5 * sin(t * 0.117 + 2))
            frame.params[0] = SIMD4(car, 0)
            // Its tail lights shine back along the plain, not on the car itself.
            frame.lights.append(.init(position: car + [0, 0.6, 2.2], radius: 0.3, color: [2.8, 0.08, 0.06], range: 36,
                                      spot: .init(direction: [0, -0.5, 1], inner: 0.6, outer: 1.3)))
            // The nearest posts each light the way, fading in far off and out as they pass.
            let phase = Float((time * speed).truncatingRemainder(dividingBy: Double(posts.gap)))
            for n in 0..<6 {
                let z = phase - Float(n) * posts.gap
                let fade = smoothstep(posts.gap, posts.gap * 0.4, z) * smoothstep(-5 * posts.gap, -4 * posts.gap, z)
                // Out to the eye, so its glint on the plain stays whole.
                let range = max(16, simd_length(SIMD2(posts.x, z)))
                for side: Float in [-1, 1] {
                    frame.lights.append(.init(position: [side * posts.x, 2.2, z], radius: 0.3, color: SIMD3(0.1, 0.75, 1.0) * 26 * fade, range: range))
                }
            }
        }
        return world
    }

    // MARK: The far range

    /// Matches the shader's `lattice1`: the same integer hash on both sides, so the crest the
    /// shader traces in neon is the one the mesh has.
    static func lattice(_ i: Int32) -> Float {
        var h = UInt32(bitPattern: i) &* 0x9E37_79B1
        h ^= h >> 15
        h = h &* 0x85EB_CA77
        h ^= h >> 13
        h = h &* 0xC2B2_AE3D
        h ^= h >> 16
        return Float(h >> 8) / 16_777_216
    }

    static func noise(_ x: Float) -> Float {
        let i = x.rounded(.down), f = x - i, u = f * f * (3 - 2 * f)
        return lattice(Int32(i)) + (lattice(Int32(i) + 1) - lattice(Int32(i))) * u
    }

    /// The crest's height and distance at column `i`. Peaks rise away from the gap round the sun.
    static func crest(_ i: Int) -> (height: Float, distance: Float) {
        let a = (Float(i) / Float(columns) * 2 - 1) * reach
        var ridged: Float = 0, amplitude: Float = 0.5, x = a * 7 + 11
        for _ in 0..<7 {
            ridged += amplitude * (1 - abs(noise(x) * 2 - 1))
            x = x * 2.1 + 3.7
            amplitude *= 0.5
        }
        let side = min(max((abs(a) - 0.1) / 0.6, 0), 1)
        let peaks = 700 * exp(-pow((a + 0.88) / 0.12, 2)) + 500 * exp(-pow((a - 0.97) / 0.14, 2))
        let height = (100 + 1100 * side * side * (3 - 2 * side) + peaks) * (0.35 + ridged * 0.9)
        return (height, 5600 + 1200 * noise(a * 3 + 40))
    }

    /// The far range: slopes falling from each column's crest, fluted into spurs and gullies, lit
    /// from the plain in front by the grid's glow. Returns those lights.
    static func addRange(_ world: inout SaverWorld) -> [SaverWorld.Light] {
        let rows = 96
        let crests = (0...columns).map(crest)
        let mesh = Mesh.parametric(columns, rows) { i, j in
            let a = (Float(i) / Float(columns) * 2 - 1) * reach
            let u = Float(j) / Float(rows) * 2 - 1
            let (height, distance) = crests[i]
            let r = distance + u * (u < 0 ? 2600 : 1400)
            let flutes = Procedural.fbm([a * 45 + 3 * Procedural.fbm([a * 9, u * 1.5, 7], octaves: 3, seed: 8), abs(u) * 3, 0], octaves: 4, seed: 5)
            let fall = pow(abs(u), 0.9) * (1 + 0.4 * flutes) + 0.25 * abs(u) * Procedural.fbm([a * 18, u * 2, 3], octaves: 3, seed: 6)
            let y = height * max(1 - fall, 0) * max(1 - fall, 0)
            return SIMD3(r * sin(a), y - 4, -r * cos(a))
        }
        world.add(mesh, material: Material.range.rawValue)
        return stride(from: -1.3 as Float, through: 1.3, by: 0.26).filter { abs($0) > 0.2 }.map { a in
            let r = crests[Int((a / reach * 0.5 + 0.5) * Float(columns))].distance - 3300
            return .tube(from: [r * sin(a - 0.13), 60, -r * cos(a - 0.13)], to: [r * sin(a + 0.13), 60, -r * cos(a + 0.13)],
                         radius: 30, color: [2e6, 2e5, 1e6], group: Group.glow)
        }
    }

    // MARK: Mesas

    /// A mesa a unit across and a unit tall: a caprock cliff split by vertical joints, softer beds
    /// sloping out below it, scored by gullies, and a talus apron flaring at the foot.
    static func mesa(seed: Int32) -> Mesh {
        let around = 360, down = 80
        let outline = (0...around).map { j -> Float in
            let angle = Float(j) / Float(around) * 2 * .pi
            return 0.7 + 0.45 * Procedural.fbm([cos(angle) * 1.3, sin(angle) * 1.3, Float(seed) * 3], octaves: 5, seed: seed)
        }
        func point(_ j: Int, _ r: Float, _ y: Float) -> SIMD3<Float> {
            let angle = Float(j) / Float(around) * 2 * .pi
            return SIMD3(r * cos(angle), y, r * sin(angle))
        }
        let top = Mesh.parametric(around, 6) { j, i in point(j, outline[j] * 0.99 * Float(i) / 6, 1) }
        let wall = Mesh.parametric(down, around, wrap: true) { i, j in
            let angle = Float(j) / Float(around) * 2 * .pi, y = 1 - Float(i) / Float(down) * 1.05
            let ring = SIMD3(cos(angle), 0, sin(angle))
            let joints = 0.04 * (Procedural.fbm(ring * 16 + [0, y * 0.5, 0], octaves: 4, seed: seed + 9) - 0.5)
            let slope = max(0.62 - y, 0)
            let beds = 0.025 * min(max((y * 9 - (y * 9).rounded(.down) - 0.6) / 0.3, 0), 1) * min(slope * 8, 1)
            let gullies = 0.12 * Procedural.fbm(ring * 9 + [0, y * 2.5, 0], octaves: 3, seed: seed + 4) * min(slope * 4, 1)
            let talus = 0.9 * pow(max(0.25 - y, 0) / 0.25, 2)
            return point(j, outline[j] * (1 + joints + slope * 1.1 + beds + talus - gullies), y)
        }
        return top + wall
    }

    /// Mesas either side of the sun, nearer than the range, each lit at its foot by the grid's glow.
    /// Returns those lights.
    static func addMesas(_ world: inout SaverWorld) -> [SaverWorld.Light] {
        let shapes = (0..<4).map { mesa(seed: Int32(30 + $0)) }
        // Azimuth, distance, radius and height, in meters.
        let places: [(Float, Float, Float, Float)] = [
            (-0.34, 2600, 230, 150), (-0.56, 1700, 170, 200), (-0.8, 2200, 280, 250), (-1.08, 1400, 150, 130),
            (0.38, 2300, 210, 170), (0.6, 1600, 130, 220), (0.86, 2600, 300, 270), (1.12, 1500, 190, 160),
        ]
        var transforms = [[simd_float4x4]](repeating: [], count: shapes.count)
        var lights: [SaverWorld.Light] = []
        for (k, (a, r, radius, height)) in places.enumerated() {
            let center = SIMD3(r * sin(a), -0.03 * height, -r * cos(a))
            transforms[k % shapes.count].append(.place(center, yaw: Float(k) * 1.7, scale: [radius, height, radius]))
            let foot = center * (1 - radius * 3 / r) + [0, 10, 0], across = SIMD3(cos(a), 0, sin(a)) * radius
            lights.append(.tube(from: foot - across, to: foot + across, radius: 5, color: [120_000, 12000, 60000], group: Group.glow))
        }
        for (shape, places) in zip(shapes, transforms) { world.add(shape, material: Material.rock.rawValue, at: places) }
        return lights
    }

    // MARK: Shading

    static let shader = MetalSource(#"""
    #define HAS_EMISSION
    #define HAS_GROUP_TINT
    #define HAS_LIVE
    #define HAS_ATMOSPHERE

    enum : uint { FLOOR, ROCK, RANGE };
    constant uint SUNLIGHT = \#(Group.sun), SKY = \#(Group.sky), GRID = \#(Group.grid);
    constant float3 SUN = \#(sun.metal);
    constant float EYE_Y = \#(eye.y);
    constant float SPEED = \#(Float(speed));
    // How far the ground travels while the shutter is open.
    constant float SMEAR = SPEED * SHUTTER;
    constant float GRID_GAP = 8, CYCLE = \#(Float(cycle));
    constant int COLUMNS = \#(columns);
    constant float REACH = \#(reach);
    constant float POST_X = \#(posts.x), POST_GAP = \#(posts.gap);

    constant float3 MAGENTA = float3(1.0, 0.1, 0.5);
    constant float3 CYAN = float3(0.1, 0.75, 1.0);

    // MARK: Lines

    // How much of a box `width` wide round u covers bands of half-width w, one every period.
    static float bands(float u, float w, float width, float period) {
        auto covered = [&](float x) {
            float y = x + w, k = floor(y / period);
            return k * 2 * w + min(y - k * period, 2 * w);
        };
        width = max(width, 1e-4f);
        return (covered(u + width * 0.5f) - covered(u - width * 0.5f)) / width;
    }

    // How far the eye has come, wrapped where every moving pattern repeats.
    static float travel(Ctx c) { return fmod(c.t * SPEED, CYCLE); }

    // MARK: The crest, as the mesh has it

    static float lattice1(int i) {
        uint h = uint(i) * 0x9E3779B1u;
        h ^= h >> 15; h *= 0x85EBCA77u; h ^= h >> 13; h *= 0xC2B2AE3Du; h ^= h >> 16;
        return float(h >> 8) * (1.0f / 16777216.0f);
    }

    static float noise1(float x) {
        float i = floor(x), f = x - i, u = f * f * (3 - 2 * f);
        return lattice1(int(i)) + (lattice1(int(i) + 1) - lattice1(int(i))) * u;
    }

    static float2 crestAt(int i) {
        float a = (float(i) / COLUMNS * 2 - 1) * REACH;
        float ridged = 0, amplitude = 0.5, x = a * 7 + 11;
        for (int k = 0; k < 7; k++) {
            ridged += amplitude * (1 - abs(noise1(x) * 2 - 1));
            x = x * 2.1f + 3.7f;
            amplitude *= 0.5f;
        }
        float side = saturate((abs(a) - 0.1f) / 0.6f);
        float peaks = 700 * exp(-pow((a + 0.88f) / 0.12f, 2.0f)) + 500 * exp(-pow((a - 0.97f) / 0.14f, 2.0f));
        return float2((100 + 1100 * side * side * (3 - 2 * side) + peaks) * (0.35f + ridged * 0.9f), 5600 + 1200 * noise1(a * 3 + 40));
    }

    // The crest's (height, distance) at azimuth a, between columns as the mesh joins them.
    static float2 crest(float a) {
        float x = (a / REACH * 0.5f + 0.5f) * COLUMNS, i = floor(x);
        return mix(crestAt(int(i)), crestAt(int(i) + 1), x - i);
    }

    static float azimuth(float3 d) { return atan2(d.x, -d.z); }

    // Slow swells of light running out along the neon crest from the sun.
    static float crestPulse(float a, Ctx c) {
        float x = abs(a) * 9 - c.t * 0.3f;
        return 0.75f + 0.15f * sin(x * 2.3f + 0.7f) + 0.6f * pow(0.5f + 0.5f * sin(x), 16.0f) * (0.6f + 0.4f * sin(x * 0.27f));
    }

    // MARK: Surfaces

    // Polished black stone in lanes of sheen, varying only across the way of travel so nothing on it stands still.
    static Surface ground(Hit h, Ctx c) {
        float streak = c.fbm(float3(h.p.x * 3.1f, 0.5, 3.5), 3);
        Surface s = material(float3(0.012, 0.01, 0.014), 0.15 + 0.4 * saturate(streak - 0.25f), h.n);
        // Past the posts, what passes is too dark to show in it.
        s.reflectsLive = abs(h.p.x) < POST_X + 1;
        if (h.bounce == 0) {
            float slope = (c.fbm(float3(h.p.x * 5.3f + 0.02f, 0.5, 7.5), 3) - c.fbm(float3(h.p.x * 5.3f, 0.5, 7.5), 3)) / 0.02f;
            s.normal = normalize(float3(-slope * 0.0015f, 1, 0));
        }
        return s;
    }

    // Sandstone in wavering beds, streaked with desert varnish; beds finer than a pixel fade out.
    static Surface rock(Hit h, Ctx c) {
        float3 p = h.p;
        float size = distance(p, c.eye) * c.pixel, fine = saturate(1.6f - size * 0.35f);
        float bed = p.y * 0.09f + 1.5f * c.noise(float3(p.xz * 0.003f, 0.5));
        float beds = mix(0.5f, c.noise(float3(bed, 3.5, 0.5)) * 0.7f + c.noise(float3(bed * 3.1f, 7.5, 0.5)) * 0.3f, fine);
        float varnish = smoothstep(0.45, 0.75, c.fbm(float3(p.x * 0.04f, p.y * 0.004f, p.z * 0.04f), 3));
        float4 n = detail(p * 0.035f, h, c);
        float3 color = mix(float3(0.085, 0.05, 0.05), float3(0.22, 0.13, 0.11), beds * 0.5f + n.x * 0.5f) * (1 - 0.55f * varnish);
        Surface s = material(color, 0.9, h.n);
        if (h.bounce == 0) s.normal = bump(h.n, n.yzw * 0.035f + float3(0, (beds - 0.5f) * 0.5f * fine, 0), 18);
        return s;
    }

    Surface surface(Hit h, Ctx c) {
        switch (h.material) {
        case FLOOR: return ground(h, c);
        default: return rock(h, c);
        }
    }

    // MARK: Glow

    // The ground one pixel covers round p, in x and z: a slanting view stretches it.
    static float2 footprint(float3 p, Ctx c) {
        float3 v = p - c.eye;
        float d = length(v), flat = max(length(v.xz), 1e-3f), rise = max(abs(v.y), 0.02f);
        return c.pixel * d * float2(abs(v.z) / flat + abs(v.x) / rise, abs(v.x) / flat + abs(v.z) / rise);
    }

    // A glow falling off from lines `period` apart, blurred to its average where a pixel spans it.
    static float glowAround(float u, float radius, float width, float period) {
        float near = abs(fract(u / period + 0.5f) - 0.5f) * period;
        return mix(exp(-near / radius), 2 * radius / period, saturate(width / radius - 0.3f));
    }

    // Neon strips along and across the plain, filtered to the pixel; those across ride toward the eye.
    static float3 grid(Hit h, Ctx c) {
        const float w = 0.03;
        float2 f = footprint(h.p, c);
        float x = h.p.x + GRID_GAP / 2, z = h.p.z - travel(c);
        // Baked reflections are made once, so they see the moving lines' average.
        float moving = h.bounce == 0 ? f.y * 1.5f + SMEAR : GRID_GAP;
        float lines = bands(x, w, f.x * 2, GRID_GAP) + bands(z, w, moving, GRID_GAP);
        float glow = glowAround(x, 0.25, f.x, GRID_GAP) + glowAround(z, 0.25, moving, GRID_GAP);
        return MAGENTA * (lines * 12 + glow * 0.06);
    }

    // The neon traced along the far range's crest, and its glow on the rock below.
    static float3 ridgeLine(Hit h, Ctx c) {
        float2 top = crest(azimuth(h.p));
        float below = top.x - 4 - h.p.y, size = distance(h.p, c.eye) * c.pixel;
        float line = bands(below - size, size, size * 1.5f, 1e6);
        return CYAN * crestPulse(azimuth(h.p), c) * (line * 6 + 0.35f * exp(-max(below, 0.0f) / (size * 6)));
    }

    // How much of the low sun the car keeps from the plain at p: its profile, cast long toward the eye.
    static float carShadow(float3 p, Ctx c) {
        float3 q = p - c.param(0).xyz;
        float behind = max(q.z - 2.15f, 0.0f), soft = 0.05f * behind + 0.03f, rise = behind * SUN.y / -SUN.z;
        float top = mix(1.05f, 0.85f, smoothstep(0.4f, 0.7f, abs(q.x)));
        return smoothstep(top + soft, top - soft, rise) * smoothstep(0.93f + soft, 0.93f - soft, abs(q.x)) * step(-2.3f, q.z);
    }

    // Patches of gloss ride along with the plain, so its reflection of the sun moves as the grid does.
    float3 groupTint(uint group, float3 p, Ctx c) {
        float3 tint = c.f->tint[group].rgb;
        if (p.y > 0.01f) return tint;
        if (group == SUNLIGHT) return tint * (1 - carShadow(p, c));
        if (group != SKY) return tint;
        // Octaves at whole multiples, so the pattern meets itself where the travel wraps.
        float3 q = float3(p.x * 0.11f, (p.z - travel(c)) * 0.04f, 4.5);
        return tint * (0.55f + 0.75f * (c.noise(q) * 0.55f + c.noise(q * 2) * 0.3f + c.noise(q * 4) * 0.15f));
    }

    Emission emission(Hit h, Ctx c) {
        return {h.material == FLOOR ? grid(h, c) : h.material == RANGE ? ridgeLine(h, c) : float3(0), GRID};
    }

    // MARK: Sky

    // The glow low round the horizon, hottest under the sun; the haze shares it so the plain melts into the sky.
    static float3 horizon(float3 d) {
        float mu = saturate(dot(d, SUN));
        return float3(0.14, 0.022, 0.1) + float3(0.5, 0.08, 0.12) * pow(mu, 6.0f) + float3(0.5, 0.22, 0.05) * pow(mu, 40.0f);
    }

    static float3 sunDisc(float3 d, float3 color, Ctx c) {
        float3 right = float3(1, 0, 0), up = normalize(float3(0, 1, 0) - SUN * SUN.y);
        const float radius = 0.22;
        float2 q = float2(dot(d, right), dot(d, up)) / radius;
        // The air near the ground shimmers its lower edge.
        q.x += 0.005f * sin(q.y * 47 + c.t * 2.1f) * smoothstep(0.1, -0.9, q.y);
        float r = length(q), edge = c.pixel / radius;
        if (dot(d, SUN) < 0 || r > 1 + 4 * edge) return color;
        // Gaps cut across its lower half, wider toward the bottom, drifting slowly down.
        float y = q.y * 9 + c.t * 0.05f, gap = 0.12f + 0.68f * saturate((0.3f - q.y) / 1.3f);
        float bar = mix(1.0f, smoothstep(gap - edge * 9, gap + edge * 9, abs(fract(y) - 0.5f) * 2), smoothstep(0.34, 0.2, q.y));
        float3 face = mix(float3(1.4, 0.06, 0.42), float3(1.9, 0.42, 0.07), smoothstep(-0.95, 0.15, q.y));
        face = mix(face, float3(2.2, 1.3, 0.2), smoothstep(0.05, 0.95, q.y));
        float cover = smoothstep(1 + edge, 1 - edge, r) * bar;
        return mix(color, face, cover);
    }

    // Thin bands of cloud lying across the low sky, lit from behind by the sun.
    static float3 stratus(float3 d, float3 color, Ctx c) {
        float e = asin(saturate(d.y)), a = azimuth(d);
        float band = smoothstep(0.02, 0.06, e) * smoothstep(0.3, 0.12, e);
        if (band <= 0) return color;
        float n = c.fbm(float3(a * 1.3f + c.t * 0.0015f, e * 30, 2.5), 5);
        float density = saturate((n - 0.5f) * 4) * band;
        float mu = saturate(dot(d, SUN));
        float3 lit = float3(0.02, 0.006, 0.04) + horizon(d) * 0.25f + float3(1.8, 0.6, 0.3) * pow(mu, 24.0f) * exp(-density * 2.5f);
        return mix(color, lit, 1 - exp(-density * 3.5f));
    }

    // High cirrus on a layer overhead, closing up toward the horizon, its underside catching the sunset.
    static float3 cirrus(float3 d, float3 color, Ctx c) {
        if (d.y < 0.04f) return color;
        float2 uv = d.xz / d.y * 0.3f + float2(c.t * 0.003f, 0);
        float2 streak = float2(uv.x * 0.8f + uv.y * 0.5f, uv.y * 0.8f - uv.x * 0.5f) * float2(0.35, 3.2);
        float n = c.fbm(float3(streak, 6.5), 5) + 0.25f * c.fbm(float3(uv * 2.5f, 9.5), 3);
        float density = saturate((n - 0.6f) * 2.5f) * smoothstep(0.04, 0.25, d.y) * smoothstep(1.0, 0.6, d.y);
        float mu = saturate(dot(d, SUN)), side = saturate(dot(normalize(d.xz), normalize(SUN.xz)));
        float3 lit = mix(float3(0.08, 0.025, 0.12), float3(0.45, 0.08, 0.2), side * side) + float3(0.9, 0.35, 0.12) * pow(mu, 6.0f);
        return color * (1 - 0.4f * density) + lit * density;
    }

    // The sky's glow without its details, which is all the car's paint needs to mirror.
    static float3 dome(float3 d) {
        if (d.y < 0) return float3(0.02, 0.004, 0.012);
        float e = d.y, mu = saturate(dot(d, SUN));
        float3 color = mix(horizon(d), float3(0.06, 0.012, 0.085), smoothstep(0.0, 0.14, e));
        color = mix(color, float3(0.014, 0.008, 0.05), smoothstep(0.08, 0.38, e));
        color = mix(color, float3(0.002, 0.004, 0.02), smoothstep(0.3, 0.95, e));
        return color + float3(0.45, 0.12, 0.08) * pow(mu, 10.0f) * smoothstep(0.45, 0.0, e);
    }

    float3 sky(float3 d, Ctx c) {
        float3 color = dome(d);
        if (d.y < 0) return color;
        float e = d.y;
        // The bake sees the sky only blurred, so it skips the stars and high cloud.
        if (!c.baking) {
            float3 q = d * 330, cell = floor(q), at = hash3(cell + 0.7f);
            float star = step(0.972, hash(cell)) * smoothstep(0.15, 0.5, e);
            float twinkle = 0.75f + 0.25f * sin(c.t * (0.5f + 1.5f * at.y) + at.z * 30);
            color += mix(float3(0.65, 0.75, 1.0), float3(1.0, 0.82, 0.7), at.x) * star * twinkle
                     * exp(-length_squared(q - cell - at) * 10) * (0.12f + 3 * pow(at.z, 8.0f));
            color = cirrus(d, color, c);
        }
        color = sunDisc(d, color, c);
        color = stratus(d, color, c);
        // The far range's neon, glowing in the air just above the crest.
        float a = azimuth(d);
        if (abs(a) < REACH && e < 0.3f) {
            float2 top = crest(a);
            float above = asin(e) - atan2(top.x - 4 - EYE_Y, top.y);
            if (above > 0) color += CYAN * crestPulse(a, c) * (2 * exp(-above / (c.pixel * 1.1f)) + 0.06f * exp(-above / (c.pixel * 14)));
        }
        return color;
    }

    // The direction at (azimuth, elevation).
    static float3 direction(float2 a) { return float3(sin(a.x) * cos(a.y), sin(a.y), -cos(a.x) * cos(a.y)); }

    // Now and then a meteor streaks down the high sky, its tail fading behind it.
    Particle meteor(uint i, Ctx c) {
        const float every = 13, life = 0.8, streak = 0.12, far = 9000;
        float slot = floor(c.t / every), age = c.t - slot * every;
        float3 r = hash3(float3(slot, 4.2, 9.1));
        float2 way = normalize(float2(r.x < 0.5f ? 1 : -1, -0.45f)), head = float2(r.x * 1.6f - 1, 0.22f + 0.2f * r.y) + way * age * 0.5f;
        float3 front = direction(head), back = direction(head - way * streak);
        // Bright enough to stay so once spread along its streak.
        float3 color = float3(0.85, 0.9, 1.0) * 3 * sin(PI * age / life) * (1 + 0.5f * streak / c.pixel);
        return {c.eye + (front + back) * far * 0.5f, (front - back) * far / SHUTTER, c.pixel * far, color, float(age < life && r.z > 0.45f), 0, 0.3, 4, 1};
    }

    // MARK: Passing by

    // 1 as a line across the grid passes under z (measured from the lines), so feet brighten with each.
    static float gridPulse(float z) {
        return exp(-abs(fract(z / GRID_GAP + 0.5f) - 0.5f) * GRID_GAP * 0.8f);
    }

    // Neon posts lining the way: thin enough to draw as strips where the ray crosses their row.
    static Live posts(float3 ro, float3 rd, float maxDist, Ctx c) {
        float t = (sign(rd.x) * POST_X - ro.x) / rd.x;
        if (!(t > 0 && t < maxDist)) return nothing();
        float3 p = ro + rd * t;
        // Seen aslant, a round post spans more of its row.
        float across = abs(fract((p.z - travel(c)) / POST_GAP + 0.5f) - 0.5f) * POST_GAP * abs(rd.x) / length(rd.xz);
        // Softened by half a pixel: four samples alone leave the far ones' edges grainy.
        float size = t * c.pixel * 0.5f, cover = smoothstep(0.08f + size, 0.08f - size, across);
        if (p.y < 0 || p.y > 3.6f || cover <= 0) return nothing();
        // A dark frame round a strip of neon facing the way.
        float neon = smoothstep(0.035f + size, 0.035f - size, across) * step(1.0f, p.y) * step(p.y, 3.35f);
        float3 frame = float3(0.008, 0.007, 0.012) + MAGENTA * 0.08f * exp(-p.y * 2) + CYAN * 0.12f * smoothstep(0.8, 1.6, p.y) * smoothstep(3.6, 3.2, p.y);
        return Live{frame * (cover - neon) + CYAN * (5 + 1.5f * p.y / 3.35f) * neon, cover, t};
    }

    // How much of a pixel a palm in profile covers at q, meters from its foot; its fronds turn with the view.
    static float palm(float2 q, float size, float seed, float turn, float sway, thread float& leaf, thread float& round) {
        float3 r = hash3(float3(seed, 3.1, 7.7));
        float height = 8.5f + 4.5f * r.x, lean = (r.y - 0.5f) * 3.2f + sway, s = saturate(q.y / height);
        float width = mix(0.22f, 0.13f, s) + 0.12f * exp(-q.y / 0.4f) + 0.012f * smoothstep(0.55, 0.95, fract(q.y * 3.3f));
        float across = (q.x - lean * s * s) / width, trunk = smoothstep(size, -size, max((abs(across) - 1) * width, max(-q.y, q.y - height)));
        round = sqrt(saturate(1 - across * across));
        leaf = 0;
        float2 rel = q - float2(lean, height);
        if (length_squared(rel) > 30) return trunk;
        float fronds = smoothstep(size, -size, length(rel + float2(0, 0.3)) - 0.38f);
        for (int i = 0; i < 18; i++) {
            float3 f = hash3(float3(seed, i, 1.7));
            float around = i * 2.39996f + f.x + turn, rise = mix(-1.0f, 1.15f, f.y) + 0.05f * sway * sin(i * 1.3f);
            float extent = 3.2f + 1.4f * f.z, droop = 0.06f + 0.08f * f.x, run = 0;
            float2 dir = float2(cos(rise) * sin(around), sin(rise)), from = 0, tip = dir * extent - float2(0, droop * extent * extent);
            // Its arch and fringe stay within 1.8 m of the chord to its tip.
            if (length(rel - tip * saturate(dot(rel, tip) / dot(tip, tip))) > 1.8f + size) continue;
            for (int j = 1; j <= 4; j++) {
                float reach = extent * j / 4;
                float2 to = dir * reach - float2(0, droop * reach * reach), axis = to - from;
                float span = length(axis);
                axis /= span;
                float2 down = float2(axis.y, -axis.x) * (axis.x < 0 ? -1 : 1);
                float a = dot(rel - from, axis), o = dot(rel - from, down);
                if (a >= 0 && a <= span) {
                    float at = (run + a) / extent, hang = 0.95f * pow(sin(PI * min(at * 1.1f, 1.0f)), 0.6f) * (0.35f + 0.65f * abs(dir.x));
                    float fringe = smoothstep(size, -size, max(o - hang, -o - 0.3f * hang)) * smoothstep(0.03, 0.12, at);
                    float w = (run + a - abs(o) * 0.8f) / 0.11f, ragged = 0.6f + 0.4f * hash(float3(floor(w), i, seed));
                    fringe *= smoothstep(size, -size, abs(o) - hang * ragged);
                    float leaflets = bands(w, 0.3f, size * 1.4f / 0.11f, 1);
                    fronds = 1 - (1 - fronds) * (1 - max(smoothstep(size + 0.035f, 0.035f - size, abs(o)), fringe * leaflets));
                }
                run += span;
                from = to;
            }
        }
        leaf = fronds;
        return 1 - (1 - trunk) * (1 - fronds);
    }

    // Rows of palms drawn on cards turned to the eye.
    static Live palms(float3 ro, float3 rd, float maxDist, Ctx c) {
        const float row = 27, gap = 40, reach = 9, cells = CYCLE / gap;
        float side = sign(rd.x);
        float2 span = float2((side * (row - reach) - ro.x) / rd.x, (side * (row + reach) - ro.x) / rd.x);
        span = float2(max(span.x, 0.0f), min(span.y, min(maxDist, 600.0f)));
        if (span.x >= span.y || min(ro.y + rd.y * span.x, ro.y + rd.y * span.y) > 15) return nothing();
        float shift = travel(c), first = floor((ro.z + rd.z * span.x - shift) / gap + 0.5f), last = floor((ro.z + rd.z * span.y - shift) / gap + 0.5f);
        float step = last < first ? -1 : 1, depth = FAR;
        float4 color = 0;
        for (float k = first, count = 0; count < 6 && color.a < 0.99f; k += step, count++) {
            float seed = k - floor(k / cells) * cells + side * 1000;
            float3 jitter = hash3(float3(seed, 5.3, 2.9));
            float3 foot = float3(side * (row + (jitter.x - 0.5f) * 3), 0, k * gap + (jitter.y - 0.5f) * 14 + shift);
            float2 toward = normalize(c.eye.xz - foot.xz);
            float3 across = float3(toward.y, 0, -toward.x);
            float t = dot(foot.xz - ro.xz, toward) / dot(rd.xz, toward);
            if (!(t > 0 && t < maxDist)) continue;
            float3 p = ro + rd * t;
            float sway = 0.25f * sin(c.t * 0.5f + seed * 1.7f) + 0.1f * sin(c.t * 1.3f + seed), leaf, round;
            float cover = palm(float2(dot(p - foot, across), p.y), t * c.pixel * 0.75f, seed, atan2(toward.x, toward.y), sway, leaf, round);
            if (cover <= 0) continue;
            float backlit = pow(saturate(dot(rd, SUN)), 60.0f), under = exp(-p.y * 0.4f) * (0.5f + gridPulse(foot.z - shift));
            float3 bark = (float3(0.006, 0.004, 0.006) + MAGENTA * 0.05f * under) * (0.3f + 0.7f * round);
            float3 shade = mix(bark, float3(0.004, 0.003, 0.006) + float3(0.9, 0.35, 0.2) * backlit * 0.12f, leaf / cover);
            color += float4(shade, 1) * cover * (1 - color.a);
            depth = min(depth, t);
        }
        return Live{color.rgb, color.a, depth};
    }

    // MARK: The car ahead

    // A low wedge of a sports car about its middle, tail toward the eye; `part` is 0 paint, 1 glass, 2 tire.
    static float car(float3 p, thread int& part) {
        float hips = (0.93f + 0.07f * smoothstep(-0.4, 1.3, p.z)) * (1 - 0.1f * saturate((p.y - 0.5f) / 0.35f));
        float body = sdRoundBox(p - float3(0, 0.55, 0), float3(hips, 0.29, 2.15), 0.17);
        body = smax(body, dot(p - float3(0, 0.5, -2.3), normalize(float3(0, 1, -0.55))), 0.25);
        float3 g = p - float3(0, 0.98, 0.15);
        g.x *= 1 + saturate(g.y + 0.2f) * 1.1f;
        float glass = sdRoundBox(g, float3(0.6, 0.19, 0.95), 0.17);
        glass = smax(glass, dot(g, normalize(float3(0, 1, 0.9))) - 0.12f, 0.1);
        float wing = min(sdRoundBox(p - float3(0, 0.98, 1.98), float3(0.88, 0.02, 0.17), 0.015),
                         sdBox(float3(abs(p.x) - 0.6f, p.y - 0.9f, p.z - 1.98f), float3(0.03, 0.08, 0.1)));
        float2 hub = float2(p.y - 0.33f, abs(p.z) - 1.38f);
        float tire = max(length(hub) - 0.33f, abs(abs(p.x) - 0.8f) - 0.15f);
        float shell = smin(body, glass, 0.08);
        part = glass < body - 0.01f ? 1 : tire < min(shell, wing) ? 2 : 0;
        return min(min(shell, wing), tire);
    }

    // The car's soft shadow where it sits on the plain, which nothing baked knows of.
    static Live shadow(float3 ro, float3 rd, float maxDist, float3 at) {
        float3 p = ro + rd * maxDist - at;
        if (maxDist >= FAR || abs(p.y) > 0.05f) return nothing();
        float dark = 0.85f * smoothstep(0.7, -0.2, sdBox(p.xz, float2(0.75, 1.9)));
        return Live{float3(0), dark, maxDist};
    }

    // Glossy black paint and glass mirroring the sky.
    static Live carAhead(float3 ro, float3 rd, float maxDist, Ctx c) {
        float3 at = c.param(0).xyz;
        // Wide enough to hold its shadow.
        float2 span = boxInterval(ro, rd, at - float3(1.5, 0.1, 2.7), at + float3(1.5, 1.3, 2.7));
        span.y = min(span.y, maxDist);
        if (span.x >= span.y) return nothing();
        auto body = [&](float3 q) { int part; return car(q - at, part); };
        float t = sdfMarch(body, ro, rd, span.x, span.y);
        if (t < 0) return shadow(ro, rd, maxDist, at);
        int part;
        float3 world = ro + rd * t, p = world - at, n = sdfNormal(body, world, 0.01f), v = -rd;
        car(p, part);
        float fresnel = schlick(0.04f, dot(n, v));
        float3 mirror = reflect(rd, n), seen = mirror.y > 0 ? dome(mirror) : MAGENTA * 0.04f + float3(0.004, 0.002, 0.006);
        Surface paint = material(part == 2 ? float3(0.02) : float3(0.012, 0.01, 0.014), part == 2 ? 0.8 : 0.25, n);
        float3 color = c.shade(world, n, v, paint) + seen * (part == 2 ? 0.02f : part == 1 ? fresnel * 0.9f + 0.05f : fresnel * 0.8f);
        color += MAGENTA * 0.05f * saturate(-n.y);
        // The tail lights: one red panel the width of the car, behind dark louvers.
        float panel = smoothstep(0.012, 0.0, abs(p.y - 0.63f) - 0.075f) * smoothstep(0.86, 0.82, abs(p.x)) * step(2.08f, p.z);
        float louvers = smoothstep(0.25, 0.45, abs(fract((p.y - 0.555f) / 0.05f) - 0.5f) * 2);
        color = mix(color, float3(6, 0.15, 0.1) * (0.25f + 0.75f * louvers), panel);
        return Live{color, 1, t};
    }

    Live live(float3 ro, float3 rd, float maxDist, Ctx c) {
        Live post = posts(ro, rd, maxDist, c), palm = palms(ro, rd, maxDist, c), ahead = carAhead(ro, rd, maxDist, c);
        Live side = post.depth < palm.depth ? over(post, palm) : over(palm, post);
        return ahead.depth < side.depth ? over(ahead, side) : over(side, ahead);
    }

    // MARK: Air

    // Haze in the horizon's colors, and a low mist glowing with the grid and haloing the lights in it.
    Atmosphere atmosphere(float3 ro, float3 rd, float dist, Ctx c) {
        float d = min(dist, 20000.0f), near = min(dist, 3000.0f);
        float3 haze = exp(-fogDepth(ro, rd, d, 0.00016, 200) * float3(0.85, 1.0, 0.92));
        float mist = exp(-fogDepth(ro, rd, near, 0.0012, 1.8));
        float3 inscatter = (MAGENTA * 0.12f + float3(0.02, 0.01, 0.04)) * (1 - mist) + c.inscatter(ro, rd, near, LIVE_LIGHTS, 6) * 0.0035f;
        return {horizon(rd) * (1 - haze) + inscatter * haze, haze * mist};
    }
    """#)
}
