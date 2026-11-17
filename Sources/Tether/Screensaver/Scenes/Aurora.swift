import simd

extension SaverScene {
    static let aurora = SaverScene(name: "Aurora", symbol: "mountain.2") { Aurora.world() }
}

/// The northern lights over a still mountain lake at night: curtains folding across the sky above
/// snowy peaks and a pine shore, all mirrored in the water.
private enum Aurora {
    enum Group {
        static let moon = 0, sky = 1, cabin = 2
    }

    /// Matches the shader's `enum`.
    enum Material: Int {
        case terrain, water, rock, needles, trunk, logs, roof, window, planks, sedge
    }

    static let eye = SIMD3<Float>(0, 3, 0)
    static let moon = simd_normalize(SIMD3<Float>(0.86, 0.26, 0.3))
    /// Where the cabin stands on the east shore, turned three-quarters to the eye.
    static let cabin = SIMD2<Float>(110, -120)
    static let cabinFrame = simd_float4x4.place([cabin.x, height(cabin) - 0.4, cabin.y], yaw: atan2(-cabin.x, -cabin.y) - 0.5)
    static let chimney = (cabinFrame * SIMD4(1.1, 5.3, -1.6, 1)).xyz

    static func world() -> SaverWorld {
        var world = SaverWorld(camera: .init(eye: eye, target: eye + [0, 0, -100], fieldOfView: 32), shader: shader)
        world.groups = 3
        world.skyGroup = Group.sky
        world.look.exposure = 3
        world.add(fan(columns: 640, rows: 360, near: 2.5, far: 2600) + fan(columns: 1500, rows: 520, near: 2200, far: 24000),
                  material: Material.terrain.rawValue)
        world.add(.grid(size: [16000, 9000], cells: [1, 1]), material: Material.water.rawValue, at: [.translation([0, 0, -4502])], castsShadows: false)
        addForest(&world)
        addBoulders(&world)
        world.lights = [.directional(toward: moon, angle: 0.01, color: [0.12, 0.145, 0.21], group: Group.moon)] + addCabin(&world)
        world.particles = [.init(function: "smoke", count: 36, blend: .alpha)]
        world.update = { time, frame in
            let t = Float(time)
            frame.params[0] = activity(t)
            // The aurora lights the land less than it shows in the sky, so the moon keeps the form.
            frame.tints[Group.sky] = SIMD3(repeating: 0.7)
            frame.tints[Group.cabin] = SIMD3(repeating: 0.85 + 0.12 * Procedural.noise([t * 0.7, 3.5, 0]) + 0.05 * Procedural.noise([t * 3.1, 8.5, 0]))
        }
        return world
    }

    /// How bright the aurora is in the west, middle and east of the sky, and how hard it's surging:
    /// slow swells at unrelated rates, so it never visibly repeats.
    static func activity(_ t: Float) -> SIMD4<Float> {
        let surge = smoothstep(0.45, 0.8, Procedural.noise([t * 0.0117, 0.5, 7.3]))
        let swell = { (k: Float) in 0.45 + 0.9 * Procedural.noise([t * 0.021 + k * 3.7, k * 5.1, 2.9]) + 0.6 * surge }
        return SIMD4(swell(0), swell(1), swell(2), surge)
    }

    // MARK: The land

    /// The ground seen from the eye: a fan of rows stepping out geometrically from `near` to `far`,
    /// so its cells stay about the same size on screen.
    static func fan(columns: Int, rows: Int, near: Float, far: Float) -> Mesh {
        .parametric(columns, rows) { i, j in
            let angle = (Float(i) / Float(columns) - 0.5) * 2.2
            let r = near * pow(far / near, Float(j) / Float(rows))
            let p = SIMD2(r * sin(angle), -r * cos(angle))
            return SIMD3(p.x, height(p), p.y)
        }
    }

    /// How far p is from the water in meters, negative out on the lake: an oval lake, a wooded point
    /// jutting out from the west shore and a bank on the east for the cabin.
    static func shore(_ p: SIMD2<Float>) -> Float {
        func oval(_ center: SIMD2<Float>, _ radii: SIMD2<Float>) -> Float { (simd_length((p - center) / radii) - 1) * min(radii.x, radii.y) }
        let land = max(oval([60, -1900], [1300, 1890]), -oval([-100, -60], [45, 55]), -oval([150, -120], [55, 110]))
        return land + (Procedural.fbm([p.x * 0.004, 2.5, p.y * 0.004], octaves: 4) - 0.5) * min(simd_length(p) * 0.2, 150)
    }

    /// Height above the lake in meters: a shelving lake bed, then banks that rise into forested
    /// slopes and the mountains.
    static func height(_ p: SIMD2<Float>) -> Float {
        let s = shore(p)
        if s < 0 { return max(-6, s * 0.3) }
        let bank = s * 0.08 + 0.4 * (Procedural.fbm([p.x * 0.3, 7.5, p.y * 0.3], octaves: 3) - 0.3) * min(s, 1)
        let slopes = 300 * smoothstep(20, 1500, s) * (0.4 + Procedural.fbm([p.x * 0.002, 6.5, p.y * 0.002], octaves: 4))
        return bank + slopes + mountains(p) * smoothstep(100, 1800, s)
    }

    /// Summits placed for the picture, by bearing (radians east of north), distance and height
    /// in meters, and how far their slopes reach.
    static let peaks: [SIMD4<Float>] = [
        [-0.1, 5600, 1500, 2600], [0.2, 6600, 1000, 2400], [0.42, 7600, 1150, 2600], [-0.45, 6800, 950, 1600], [-0.6, 7400, 1050, 1700],
        [-0.34, 7600, 800, 1500], [-0.85, 7000, 900, 2000], [0.72, 6500, 700, 2000], [0.98, 5500, 520, 1800],
        [-0.28, 13500, 2100, 4000], [0.08, 15500, 2300, 4500], [0.6, 14000, 2000, 4000], [-0.75, 12500, 1900, 3800],
    ]

    /// Each summit is a horn with three arêtes, its faces fluted with gullies, joined to its
    /// neighbors by saddles; rougher ridges and rock detail cover the whole range.
    static func mountains(_ p: SIMD2<Float>) -> Float {
        var height: Float = 0
        for (k, peak) in peaks.enumerated() {
            let offset = p - SIMD2(peak.y * sin(peak.x), -peak.y * cos(peak.x)), out = simd_length(offset)
            // Reach is at most 1.2 × 1.2 of peak.w, and past it a horn adds exactly nothing.
            if out >= peak.w * 1.44 { continue }
            let around = atan2(offset.y, offset.x) + Float(k) * 1.9
            let reach = peak.w * (0.7 + 0.5 * pow(abs(cos(1.5 * around)), 3)) * (0.8 + 0.4 * Procedural.noise([cos(around) * 2, sin(around) * 2, Float(k)]))
            let winding = around + 0.5 * (Procedural.noise([out / 500, Float(k) * 3, 5.5]) - 0.5)
            let gully = 1 - abs(Procedural.noise([cos(winding) * 7, sin(winding) * 7, out / 700 + Float(k) * 7]) * 2 - 1)
            let flutes = 1 - 0.12 * gully * gully * smoothstep(0, 0.3, out / reach)
            let horn = peak.z * pow(max(0, 1 - out / reach), 1.7) * flutes
            height = max(height, horn) + 0.15 * min(height, horn)
        }
        let q = p * 0.0009 + SIMD2(Procedural.noise([p.x * 0.0005, 1.5, p.y * 0.0005]), Procedural.noise([p.x * 0.0005, 3.5, p.y * 0.0005]))
        return height * (0.8 + 0.4 * ridged(q, octaves: 5))
    }

    /// Ridged multifractal noise, about 0 to 1: sharp crests along the noise's middle value,
    /// rougher high up them.
    static func ridged(_ p: SIMD2<Float>, octaves: Int) -> Float {
        var sum: Float = 0, amplitude: Float = 0.6, weight: Float = 1, q = p
        for octave in 0..<octaves {
            let crest = 1 - abs(Procedural.noise([q.x, Float(octave) * 3.1, q.y]) * 2 - 1)
            let ridge = crest * crest * weight
            sum += amplitude * ridge
            weight = min(ridge * 2, 1)
            q = SIMD2(q.x * 1.6 - q.y * 1.2, q.x * 1.2 + q.y * 1.6)
            amplitude *= 0.45
        }
        return sum
    }

    // MARK: Forest and boulders

    /// Spruces up from both shores to the tree line, broken by clearings, leaving the near bank open
    /// for the view. Candidates are spread evenly in bearing and log distance, so on screen too.
    static func addForest(_ world: inout SaverWorld) {
        let trunk = Mesh.cylinder(radius: 0.012, height: 0.4, segments: 8, caps: false)
        let kinds = (0..<6).map { spruce(seed: Int32($0), tiers: $0 < 3 ? 10 : 4, segments: $0 < 3 ? 48 : 12) }
        var places = [[simd_float4x4]](repeating: [], count: kinds.count)
        var random = SeededRandom(seed: 7)
        let count = 150_000, span: Float = 2.2 * log(4000 / 14)
        for _ in 0..<count {
            let angle = Float.random(in: -1.1...1.1, using: &random), r = 14 * pow(4000 / 14, Float.random(in: 0...1, using: &random))
            let p = SIMD2(r * sin(angle), -r * cos(angle))
            let s = shore(p)
            let view = abs(angle - atan2(cabin.x, -cabin.y)) < 0.06 && r < simd_length(cabin)
            guard s > 2, r > 30 || abs(angle) > 0.85, simd_distance(p, cabin) > 24, !view else { continue }
            let clearing = smoothstep(0.3, 0.45, Procedural.noise([p.x * 0.006, 4.5, p.y * 0.006]))
            guard Float.random(in: 0...1, using: &random) < 0.04 * clearing * span * r * r / Float(count) else { continue }
            let ground = height(p), steep = simd_length(SIMD2(height(p + [2, 0]) - ground, height(p + [0, 2]) - ground)) / 2
            guard ground < 380 + 160 * Procedural.noise([p.x * 0.004, 9.5, p.y * 0.004]), steep < 0.7 else { continue }
            let tall = 7 + 14 * Float.random(in: 0...1, using: &random) * (1 - ground / 700), wide = tall * Float.random(in: 0.8...1.2, using: &random)
            let kind = (r < 250 ? 0 : 3) + Int.random(in: 0..<3, using: &random)
            places[kind].append(.place([p.x, ground - 0.3, p.y], yaw: Float.random(in: 0...6.3, using: &random), scale: [wide, tall, wide]))
        }
        for (kind, transforms) in zip(kinds, places) { world.add(kind, material: Material.needles.rawValue, at: transforms) }
        world.add(trunk, material: Material.trunk.rawValue, at: places.flatMap { $0 })
    }

    /// A spruce one unit tall: narrow tiers of boughs whose rims break into drooping tips, rising
    /// to a spire.
    static func spruce(seed: Int32, tiers: Int, segments: Int) -> Mesh {
        var needles = Mesh()
        for tier in 0..<tiers {
            let f = Float(tier) / Float(tiers), tall: Float = 1.6 / Float(tiers + 2), lobes = Float(7 + Int(6 * (1 - f)))
            let width = (1 - f) * (0.15 + 0.05 * Procedural.hash(seed, Int32(tier), 1)) + 0.02
            var cone = Mesh.cone(radius: width, height: tall, segments: segments, rings: segments > 20 ? 3 : 2, base: false)
            cone.positions = cone.positions.map { p in
                let around = atan2(p.z, p.x), phase = Float(seed) * 1.7 + Float(tier) * 2.3
                let tips = 0.55 + 0.6 * pow(0.5 + 0.5 * cos(around * lobes + phase), 2.5)
                    * (0.6 + 0.4 * Procedural.noise([cos(around) * 3, sin(around) * 3, phase]))
                let rim = min(max(1 - p.y / tall * 1.6, 0), 1), spread = 1 + (tips - 1) * rim
                return SIMD3(p.x * spread, p.y - tall * 0.55 * rim * tips, p.z * spread)
            }
            needles += cone.withSmoothNormals().transformed(.translation([0, 0.1 + 0.8 * f, 0]))
        }
        return needles
    }

    /// Snow-capped boulders strewn along the near shore, a few standing out of the water, stones
    /// poking through the snow of the bank, and tufts of dry sedge.
    static func addBoulders(_ world: inout SaverWorld) {
        let stones = (0..<5).map { k in
            // Cut by a few planes into flat faces with sharp edges, like split granite.
            var stone = Mesh.stone(seed: Int32(40 + k), roughness: 0.3, subdivisions: 4)
            let cuts = (0..<7).map { i in
                SIMD4(simd_normalize(SIMD3((0..<3).map { Procedural.hash(Int32(k), Int32(i), Int32($0) + 20) * 2 - 1 }) + [0, 0.3, 0]), 0.22 + 0.12 * Procedural.hash(Int32(k), Int32(i), 9))
            }
            stone.positions = stone.positions.map { p in cuts.reduce(p) { p, cut in p - cut.xyz * max(0, simd_dot(p, cut.xyz) - cut.w) } }
            return stone.displaced { p, n in 0.05 * smoothstep(0.4, 0.9, n.y) - 0.03 * (1 - abs(Procedural.noise(p * 4, seed: Int32(k)) * 2 - 1)) }
        }
        var places = [[simd_float4x4]](repeating: [], count: stones.count)
        var random = SeededRandom(seed: 11)
        for i in 0..<400 {
            let angle = Float.random(in: -1.05...1.05, using: &random), r = 5 * pow(14, Float.random(in: 0...1, using: &random))
            let p = SIMD2(r * sin(angle), -r * cos(angle))
            let s = shore(p), size = (s > 4 ? 0.25 : 0.6) + 1.8 * pow(Float.random(in: 0...1, using: &random), 3)
            guard s > -6 + r * 0.06, s < 8 || i % 3 == 0 else { continue }
            places[i % stones.count].append(.place([p.x, max(height(p), -0.4) - 0.15 * size, p.y], yaw: Float.random(in: 0...6.3, using: &random),
                                                   scale: SIMD3(repeating: size)))
        }
        for (stone, transforms) in zip(stones, places) { world.add(stone, material: Material.rock.rawValue, at: transforms) }
        let tuft = (0..<14).map { blade -> Mesh in
            let lean = Procedural.hash(Int32(blade), 3, 1) * 0.5, around = Float(blade) * 2.4
            return Mesh.cone(radius: 0.012, height: 0.3 + 0.35 * Procedural.hash(Int32(blade), 4, 1), segments: 4, base: false)
                .transformed(.rotation(around, axis: [0, 1, 0]) * .rotation(lean, axis: [1, 0, 0]))
        }.reduce(Mesh(), +)
        let tufts = (0..<900).compactMap { _ -> simd_float4x4? in
            let angle = Float.random(in: -1.05...1.05, using: &random), r = 4 * pow(12, Float.random(in: 0...1, using: &random))
            let p = SIMD2(r * sin(angle), -r * cos(angle))
            guard shore(p) > 0.3, Procedural.noise([p.x * 0.4, 6.5, p.y * 0.4]) > 0.45 else { return nil }
            return .place([p.x, height(p) - 0.05, p.y], yaw: Float.random(in: 0...6.3, using: &random), scale: SIMD3(repeating: Float.random(in: 0.6...1.3, using: &random)))
        }
        world.add(tuft, material: Material.sedge.rawValue, at: tufts)
    }

    // MARK: The cabin

    /// A log cabin on the east shore turned three-quarters to the eye: snow deep on its roof, a
    /// chimney, two warm windows, and a jetty running out into the lake. Returns the windows' light.
    static func addCabin(_ world: inout SaverWorld) -> [SaverWorld.Light] {
        world.add(.box([4.6, 3, 6.5], center: [0, 1.5, 0], segments: 4) + .box([0.7, 2.6, 0.7], center: [1.1, 3.9, -1.6]),
                  material: Material.logs.rawValue, at: [cabinFrame])
        world.add(.extrusion([[-3.1, 0], [3.1, 0], [0, 2.3]], height: 7.5), material: Material.roof.rawValue,
                  at: [cabinFrame * .translation([0, 2.95, 3.75]) * .rotation(-.pi / 2, axis: [1, 0, 0])])
        let windows: [(center: SIMD3<Float>, size: SIMD3<Float>, out: SIMD3<Float>)] = [([0, 1.4, 3.27], [0.8, 0.9, 0.03], [0, 0, 1]), ([2.32, 1.4, 0.9], [0.03, 0.9, 1.1], [1, 0, 0])]
        world.add(windows.map { Mesh.box($0.size, center: $0.center) }.reduce(Mesh(), +), material: Material.window.rawValue, at: [cabinFrame], castsShadows: false)
        let toward = simd_normalize(SIMD2<Float>(-1, -0.1))
        var shore = cabin
        for _ in 0..<200 where Aurora.shore(shore) > 0 { shore += toward }
        let jetty = simd_float4x4.place([shore.x, 0.45, shore.y] - SIMD3(toward.x, 0, toward.y) * 3, yaw: atan2(toward.x, toward.y))
        world.add(.box([1.5, 0.14, 11], center: [0, 0, 5.5]), material: Material.planks.rawValue, at: [jetty])
        world.add(.cylinder(radius: 0.1, height: 2, segments: 10), material: Material.planks.rawValue,
                  at: [0, 1].flatMap { side in [3.5, 7, 10.6].map { jetty * .translation([side * 1.4 - 0.7, -1.6, Float($0)]) } })
        return windows.map { .sphere((cabinFrame * SIMD4($0.center + $0.out * 0.5, 1)).xyz, radius: 0.35, color: [2.2, 0.95, 0.32], group: Group.cabin) }
    }

    // MARK: Shading

    static let shader = MetalSource(#"""
    #define HAS_EMISSION
    #define HAS_GROUP_TINT
    #define HAS_LIVE_NORMAL
    #define HAS_ATMOSPHERE

    enum : uint { TERRAIN, WATER, ROCK, NEEDLES, TRUNK, LOGS, ROOF, WINDOW, PLANKS, SEDGE };
    #define MOON 0u
    #define SKY 1u
    #define CABIN 2u
    #define EARTH 6371.0f
    // How much of the sky the still water mirrors straight down; more toward the horizon.
    constant float REFLECTANCE = 0.16f;
    constant float3 CHIMNEY = \#(chimney.metal);
    // The aurora as the sky's light was baked, at t = 0.
    constant float4 BAKED_ACTIVITY = \#(activity(0).metal);

    // MARK: Surfaces

    // Snow wherever it can lie: in couloirs between ribs of banded rock and on every ledge, thinner
    // on the windward faces.
    static Surface terrain(Hit h, Ctx c) {
        float dist = length(h.p - c.eye), scale = clamp(dist * 0.006f, 0.04f, 40.0f);
        float4 fine = detail(h.p / scale, h, c);
        float3 n = h.bounce == 0 ? bump(h.n, fine.yzw / scale, scale * 0.2f) : h.n;
        if (h.bounce == 0 && dist < 80) {
            // Close by, the snow is carved by the wind into long low ridges.
            float2 along = float2(0.94, 0.34), across = float2(-0.34, 0.94);
            float4 drift = c.fbmd(float3(dot(h.p.xz, along) * 0.7f, h.p.y, dot(h.p.xz, across) * 2.6f), 3);
            float3 slope = float3(drift.y * 0.7f * along.x + drift.w * 2.6f * across.x, 0, drift.y * 0.7f * along.y + drift.w * 2.6f * across.y);
            n = bump(n, slope, 0.06f * smoothstep(80.0f, 20.0f, dist));
        }
        float couloirs = c.fbm(float3(h.p.x * 0.014f, h.p.y * 0.0016f, h.p.z * 0.014f), 3);
        float broad = c.fbm(h.p * 0.0021f, 3);
        float bands = smoothstep(0.2f, 0.8f, 0.5f + 0.5f * sin(h.p.y * 0.05f + 10 * broad));
        float3 rock = float3(0.06, 0.056, 0.052) * mix(0.6f, 1.4f, bands) * (0.4f + 1.2f * fine.x);
        float lee = dot(normalize(n.xz + 1e-4f), normalize(float2(1, -0.3)));
        float crags = 1 - abs(c.noise(h.p / (scale * 3)) * 2 - 1);
        float snow = smoothstep(0.53f, 0.6f, mix(h.n.y, n.y, 0.5f) + 0.3f * (couloirs - 0.45f) + 0.22f * (fine.x - 0.5f) - 0.12f * crags * crags + 0.04f * lee);
        float3 color = mix(rock, float3(0.78, 0.82, 0.88) * (0.93f + 0.07f * fine.x), snow);
        // A dark wet line where the snow meets the water.
        float wet = smoothstep(0.25f, 0.02f, h.p.y + 0.1f * fine.x);
        color = mix(color, float3(0.05, 0.055, 0.06), wet);
        // Far off, the forest below the tree line: dark crowns with snow between.
        float forest = smoothstep(0.5f, 0.68f, h.n.y) * smoothstep(520.0f, 400.0f, h.p.y + 140 * c.noise(h.p * 0.004f)) * smoothstep(900.0f, 1600.0f, dist);
        if (forest > 0) {
            float crowns = h.bounce == 0 ? smoothstep(0.95f, 0.4f, voronoi(h.p.xz * 0.22f).x) : 0.85f;
            color = mix(color, mix(color, float3(0.02, 0.03, 0.022), crowns), forest);
        }
        return material(color, mix(mix(0.85f, 0.55f, snow), 0.35f, wet), n);
    }

    // Dark lichened rock under a cap of snow.
    static Surface rock(Hit h, Ctx c) {
        float4 n = detail(h.local * 9, h, c);
        float3 color = float3(0.09, 0.085, 0.08) * (0.6f + 0.8f * n.x) * mix(0.7f, 1.2f, noise(h.local * 60));
        float snow = smoothstep(0.5f, 0.62f, h.n.y + 0.3f * (n.x - 0.5f));
        Surface s = material(mix(color, float3(0.8, 0.83, 0.88), snow), mix(0.8f, 0.55f, snow), h.n);
        if (h.bounce == 0) s.normal = bump(h.n, n.yzw * 9, 0.012f * (1 - 0.7f * snow));
        return s;
    }

    // Spruce needles, near black, laden with snow on every upturned bough.
    static Surface needles(Hit h, Ctx c) {
        float3 q = h.local * 50 + copyOffset(h);
        float4 n = detail(q, h, c, 3);
        float snow = smoothstep(0.45f, 0.62f, h.n.y + 0.4f * (n.x - 0.5f) + 0.25f * (hash(float(h.instance)) - 0.5f));
        Surface s = material(mix(float3(0.02, 0.035, 0.025) * (0.6f + 0.8f * n.x), float3(0.7, 0.74, 0.8), snow), 0.85f, h.n);
        if (h.bounce == 0) s.normal = bump(h.n, n.yzw, 0.25f);
        return s;
    }

    Surface surface(Hit h, Ctx c) {
        switch (h.material) {
        case TERRAIN: return terrain(h, c);
        case ROCK: return rock(h, c);
        case NEEDLES: return needles(h, c);
        case TRUNK: return material(float3(0.05, 0.04, 0.03), 0.9, h.n);
        case SEDGE: return material(float3(0.26, 0.19, 0.1) * (0.5f + 0.7f * noise(h.local * 40 + float(h.instance))) * (0.4f + 0.6f * saturate(h.local.y * 3)), 0.8, h.n);
        case LOGS: {
            float log = fract(h.local.y * 3.3f), grain = c.fbm(h.local * float3(1, 6, 1) * 4, 3);
            float3 color = float3(0.16, 0.1, 0.06) * (0.55f + 0.6f * grain) * mix(0.35f, 1.0f, smoothstep(0.0f, 0.18f, log) * smoothstep(1.0f, 0.82f, log));
            return material(color, 0.85, h.n);
        }
        case ROOF: return material(h.n.y > 0.2f ? float3(0.8, 0.83, 0.88) * (0.9f + 0.1f * c.noise(h.p * 4)) : float3(0.06, 0.045, 0.03), 0.6, h.n);
        case WINDOW: return material(float3(0.3, 0.2, 0.1), 0.4, h.n);
        case PLANKS: {
            float3 wood = float3(0.12, 0.085, 0.055) * (0.6f + 0.6f * c.fbm(h.local * float3(1, 1, 0.3) * 12, 3));
            return material(mix(wood, float3(0.8, 0.83, 0.88), smoothstep(0.5f, 0.8f, h.n.y) * smoothstep(0.3f, 0.5f, c.noise(h.p * 2))), 0.75, h.n);
        }
        default: {
            Surface s = material(float3(REFLECTANCE), 0, h.n);
            s.metallic = 1;
            return s;
        }
        }
    }

    // The cabin's windows glowing from a stove inside, and the moonlit snow close by glittering.
    Emission emission(Hit h, Ctx c) {
        if (h.material == WINDOW) return {float3(1.0, 0.5, 0.18) * (3 + 1.5f * c.noise(h.local * 4)), CABIN};
        float dist = length(h.p - c.eye);
        if (h.material != TERRAIN || dist > 40 || h.n.y < 0.75f) return {float3(0), MOON};
        float3 glint = hash3(floor(h.p / (dist * c.pixel * 1.2f)));
        if (glint.x < 0.998f) return {float3(0), MOON};
        return {float3(0.8, 0.9, 1.0) * smoothstep(0.5f, 1.0f, sin(c.t * (0.4f + glint.y) + glint.z * 40)), MOON};
    }

    // MARK: Sky

    // How strong the aurora is toward x, the sine of the azimuth from -1 west to 1 east.
    static float strength(float x, float4 a) { return mix(mix(a.x, a.y, smoothstep(-0.9f, 0.0f, x)), a.z, smoothstep(0.0f, 0.9f, x)); }

    // How far north curtain k hangs (km) at x km east, winding and drifting. Curtain 0 is the main
    // one, 1 a fainter one nearly overhead, 2 low in the north.
    static float line(int k, float x, float t, Ctx c) {
        const float north[3] = {250, 140, 620}, lean[3] = {0.4, 0.15, 0.3}, bend[3] = {70, 50, 120};
        float fk = float(k);
        return north[k] + lean[k] * x + bend[k] * sin(x * (0.005f + 0.0013f * fk) + t * 0.007f + fk * 2.1f + 0.4f)
             + 35 * sin(x * 0.013f - t * 0.011f + fk * 4.7f) + 70 * (c.noise(float3(x * 0.006f + t * 0.002f, fk * 5.3f, t * 0.0015f)) - 0.5f);
    }

    // How far a ground point g (km) is north of curtain k.
    static float curtain(int k, float2 g, float t, Ctx c) { return -g.y - line(k, g.x, t, c); }

    // Small folds that pleat curtain k where they turn edge-on: what they add to its slope at x.
    static float folds(int k, float x, float t, Ctx c) {
        float fk = float(k), sum = 0;
        for (int i = 0; i < 3; i++) {
            float w = 0.05f * pow(2.1f, float(i));
            sum += (0.9f - 0.25f * i) * cos(x * w + t * (0.03f + 0.02f * i) * (i % 2 ? -1 : 1) + fk * 3.7f + i * 1.3f);
        }
        return sum * (0.4f + 1.2f * c.noise(float3(x * 0.012f, fk * 8.3f + 2.5f, t * 0.01f)));
    }

    // How squarely a ray along track (flat: its horizontal share) meets a curtain of this slope.
    static float facing(float2 track, float flat, float slope) { return flat * abs(track.x * slope + track.y) / sqrt(1 + slope * slope); }

    // Curtains hanging 95 to 400 km up along winding lines: where a ray's ground track crosses one it
    // gains that curtain's light at the height it crosses, green low down and red high up.
    static float3 aurora(float3 d, int steps, Ctx c) {
        float flat = length(d.xz);
        if (d.y <= 0.0f || flat < 1e-4f) return 0;
        float2 track = d.xz / flat;
        float rise = d.y / flat, t = c.t;
        // Ground distances where the ray is 95 and 400 km up, over the curved Earth.
        float near = EARTH * (sqrt(rise * rise + 190 / EARTH) - rise), far = min(EARTH * (sqrt(rise * rise + 800 / EARTH) - rise), near + 1500);
        float ds = (far - near) / steps;
        float4 a = c.param(0);
        float3 sum = 0;
        float last[3];
        for (int i = 0; i <= steps; i++) {
            float s = near + ds * i;
            for (int k = 0; k < 3; k++) {
                float f = curtain(k, track * s, t, c), f0 = i > 0 ? last[k] : f;
                last[k] = f;
                if ((f > 0) == (f0 > 0)) continue;
                // The crossing, found closer by one secant step.
                float s0 = s - ds, s1 = s, f1 = f, sm = s1 - (s1 - s0) * f1 / (f1 - f0), fm = curtain(k, track * sm, t, c);
                if ((fm > 0) == (f0 > 0)) { s0 = sm; f0 = fm; } else { s1 = sm; f1 = fm; }
                float sx = s1 - (s1 - s0) * f1 / (f1 - f0);
                float2 x = track * sx;
                float height = sx * rise + sx * sx / (2 * EARTH), fk = float(k);
                float above = height - 100 - 16 * (c.noise(float3(x.x * 0.02f, fk * 3.3f + 0.5f, t * 0.01f)) - 0.5f)
                            - 5 * (c.noise(float3(x.x * 0.11f - t * 0.05f, fk * 1.7f + 6.5f, t * 0.03f)) - 0.5f);
                if (above <= 0) continue;
                float u = x.x + t * (0.35f + 0.2f * fk);
                float rays = 0.2f + 0.8f * c.noise(float3(u * 0.07f, fk * 7.1f, t * 0.03f)) * (0.3f + 0.7f * c.noise(float3(u * 0.4f, fk * 2.3f + 9.5f, t * 0.07f)));
                float tall = 12 + 70 * pow(c.noise(float3(u * 0.04f, fk * 4.1f + 3.5f, t * 0.02f)), 2.0f);
                float patch = (k == 0 ? 0.4f : 0.0f) + smoothstep(0.25f, 0.6f, c.noise(float3(x.x * 0.004f + t * 0.0013f, fk * 6.7f + 1.5f, t * 0.004f)));
                // Where the curtain's line turns to run along the ray, its two crossings merge and the
                // march can miss them, so they fade there; the pleats only brighten it.
                float slope = (line(k, x.x + 1, t, c) - line(k, x.x - 1, t, c)) / 2;
                float across = max(facing(track, flat, slope + folds(k, x.x, t, c)), 0.18f), merging = smoothstep(0.08f, 0.35f, facing(track, flat, slope));
                float3 green = float3(0.12, 1.0, 0.36) * smoothstep(0.0f, 2.5f, above) * (exp(-above / tall) + exp(-above / 5));
                float3 red = float3(0.7, 0.1, 0.38) * smoothstep(30.0f, 140.0f, above) * exp(-max(above - 140, 0.0f) / 80) * 0.2f * sqrt(across);
                float3 fringe = float3(1.0, 0.12, 0.5) * exp(-above / 3.0f) * a.w * 0.6f;
                float fade = smoothstep(400.0f, 300.0f, height) * (k == 1 ? 0.45f : 1.0f);
                sum += (green + red + fringe) * rays * patch * strength(x.x / length(x), a) * fade * merging / across;
            }
        }
        // Thicker air toward the horizon dims it.
        return sum * 0.12f * exp(-0.08f / max(d.y, 0.02f));
    }

    // Stars of every brightness and the Milky Way, wheeling slowly about the pole.
    static float3 stars(float3 d, Ctx c) {
        const float3 pole = float3(0, 0.94, -0.342), band = normalize(float3(0.62, 0.3, -0.72));
        float turn = c.t * 1.5e-4f;
        d = d * cos(turn) + cross(pole, d) * sin(turn) + pole * dot(pole, d) * (1 - cos(turn));
        float across = dot(d, band), milky = exp(-across * across / 0.03f);
        float3 color = float3(0.9, 0.88, 1.0) * milky * 0.03f * c.fbm(d * 6 + 2, 4) * (1 - 0.8f * smoothstep(0.5f, 0.7f, c.fbm(d * 14 + 7, 3)));
        float3 q = d * 700, cell = floor(q), h = hash3(cell);
        if (h.x < 0.965f - 0.03f * milky) return color;
        float3 spot = cell + 0.2f + 0.6f * hash3(cell + 7.1f);
        float glow = smoothstep(0.5f, 0.0f, length(q - spot)) * (0.03f + 4.0f * pow(h.y, 14.0f));
        float twinkle = 0.8f + 0.2f * sin(c.t * (2 + 5 * h.z) + h.y * 50);
        return color + mix(float3(0.75, 0.85, 1.0), float3(1.0, 0.85, 0.65), h.z) * glow * twinkle;
    }

    // Now and then a meteor streaks down the sky.
    static float3 meteor(float3 d, Ctx c) {
        const float every = 23;
        float slot = floor(c.t / every), age = c.t - slot * every - 8 * hash(slot + 0.5f);
        float3 h = hash3(float3(slot, 8.3, 2.9));
        if (age < 0 || age > 0.9f || h.z < 0.45f) return 0;
        float3 start = normalize(float3(h.x * 2.4f - 1.2f, 0.3f + 0.5f * h.y, -1)), path = normalize(float3(0.6f - 1.2f * hash(slot + 3.1f), -0.5f, 0.1f));
        float3 head = normalize(start + path * age * 0.3f), tail = normalize(start + path * max(age - 0.3f, 0.0f) * 0.3f), along = head - tail;
        float k = saturate(dot(d - tail, along) / max(dot(along, along), 1e-8f));
        float near = length(d - tail - along * k);
        return float3(0.8, 0.92, 1.0) * 5 * exp(-near * near / 4e-7f) * k * k * smoothstep(0.0f, 0.1f, age) * smoothstep(0.9f, 0.5f, age);
    }

    float3 sky(float3 d, Ctx c) {
        if (d.y < 0) return float3(0.002, 0.0025, 0.003);
        float3 color = mix(float3(0.005, 0.008, 0.014), float3(0.0008, 0.0014, 0.0035), smoothstep(0.0f, 0.5f, d.y));
        // The aurora's light scattered low in the northern sky.
        color += float3(0.01, 0.03, 0.018) * strength(d.x, c.param(0)) * exp(-d.y * 7) * smoothstep(0.3f, -0.6f, d.z);
        // The bake needs only the sky's light: a coarse march will do.
        if (c.baking) return color + aurora(d, 8, c);
        return color + (stars(d, c) + meteor(d, c)) * exp(-0.1f / max(d.y, 0.02f)) + aurora(d, 24, c);
    }

    // The sky's light follows the aurora above each point as it swells and fades, pinker as it surges.
    float3 groupTint(uint group, float3 p, Ctx c) {
        float3 tint = c.f->tint[group].rgb;
        if (group != SKY) return tint;
        float2 to = p.xz - c.eye.xz;
        float x = to.x / max(length(to), 1e-3f);
        float3 hue = 1 + float3(0.25, -0.12, 0.2) * (c.param(0).w - BAKED_ACTIVITY.w);
        return tint * hue * strength(x, c.param(0)) / strength(x, BAKED_ACTIVITY);
    }

    // MARK: Ripples and smoke

    // Rings on the still water, kept close in where it mirrors sky, since baked reflections can't ripple.
    float3 liveNormal(Hit h, Ctx c) {
        float2 slope = 0;
        for (int k = 0; k < 3; k++) {
            float period = 5.3f + 2.9f * k, time = c.t + 13.0f * k, slot = floor(time / period), age = time - slot * period;
            float3 seed = hash3(float3(slot, k, 4.1));
            float bearing = (seed.x - 0.5f) * 1.3f, reach = 12 + 12 * seed.y;
            float2 to = h.p.xz - float2(sin(bearing), -cos(bearing)) * reach;
            float r = length(to), x = r - age * 0.32f;
            if (abs(x) > 0.5f) continue;
            float envelope = exp(-x * x * 12), wave = 0.0025f * exp(-age * 0.3f) / sqrt(1 + r);
            slope += to / max(r, 1e-3f) * wave * (-22 * sin(x * 22) - 24 * x * cos(x * 22)) * envelope;
        }
        return normalize(float3(-slope.x, 1, -slope.y));
    }

    // Smoke from the cabin's chimney, rising, spreading and leaning off on the night air.
    Particle smoke(uint i, Ctx c) {
        const float life = 16;
        float phase = c.t / life + hash(float(i) + 0.3f), f = fract(phase), age = f * life;
        float3 a = hash3(float3(i, floor(phase), 5.1)), wind = float3(0.35, 0, -0.12);
        Particle s;
        s.position = CHIMNEY + float3(0, 2.4f * (1 - exp(-age / 3)), 0) * 1.6f + wind * age + (a - 0.5f) * float3(0.4, 0.2, 0.4) * (0.3f + age * 0.3f);
        s.velocity = float3(0, 1.3f * exp(-age / 3), 0) + wind;
        s.size = 0.35f + 2.2f * f;
        s.color = float3(0.8, 0.81, 0.85) * c.light(s.position);
        s.alpha = 0.45f * smoothstep(0.0f, 0.06f, f) * (1 - f) * (1 - f);
        s.puff = 1;
        return s;
    }

    // MARK: Air

    // Haze, and mist on the water drifting in long banks, sampled where the path crosses the
    // middle of the mist.
    static float thickness(float3 o, float3 d, float dist, Ctx c) {
        float through = (1.5f - o.y) / (abs(d.y) > 1e-5f ? d.y : 1e-5f);
        float3 p = o + d * (through > 0 ? min(through, dist) : dist);
        float2 q = float2(p.x * 0.0025f, p.z * 0.007f) + float2(c.t * 0.0019f, c.t * -0.0004f);
        float banks = smoothstep(0.44f, 0.66f, c.fbm(float3(q + 0.6f * c.fbm(float3(q * 2, c.t * 0.003f), 2), c.t * 0.001f), 3));
        return fogDepth(o, d, dist, 5e-5f, 1400) + fogDepth(o, d, dist, 5e-3f, 4) * banks;
    }

    // The share of light the water mirrors along a ray coming down onto it.
    static float reflectance(float3 rd) { return schlick(REFLECTANCE, -rd.y); }

    // Haze over the whole valley and mist lying on the water. A ray ending on the lake carries on
    // along its reflection, so mirrored mountains haze like the real ones.
    Atmosphere atmosphere(float3 ro, float3 rd, float dist, Ctx c) {
        float d1 = min(dist, 40000.0f);
        float depth = thickness(ro, rd, d1, c);
        float3 inscatter = c.inscatter(ro, rd, d1) / d1 * (1 - exp(-depth));
        float3 p = ro + rd * dist;
        if (dist < FAR && rd.y < 0 && p.y < 0.02f) {
            float3 r = float3(rd.x, -rd.y, rd.z), o = float3(p.x, 0.01, p.z);
            float d2 = min(c.hitDistance(o, r), 40000.0f), more = thickness(o, r, d2, c);
            inscatter += exp(-depth) * reflectance(rd) * c.inscatter(o, r, d2) / d2 * (1 - exp(-more));
            depth += more;
        }
        return {inscatter * 3, float3(exp(-depth))};
    }
    """#)
}
