import simd

extension SaverScene {
    static let neonLines = SaverScene(name: "Neon Lines", symbol: "light.strip.2") { NeonLines.world() }
}

/// A concrete gallery at night hung with neon: a tunnel of tilted frames and a ring over a dais and
/// lines down the aisles, breathing in turn, while three trails of light sweep slow arcs through the
/// hall and mirror in its polished floor.
private enum NeonLines {
    /// Light groups: the fill from behind the eye, the portal's three frames, each aisle's lines,
    /// the ring, and one aging tube in the right aisle.
    enum Group {
        static let fill = 0, portal = 1, left = 4, right = 5, ring = 6, aging = 7, count = 8
    }

    /// Matches the shader's `enum`; a tube's tag is its group.
    enum Material: Int {
        case terrazzo, boards, panels, steel, rubber, neon
    }

    static let amber: SIMD3<Float> = [4.0, 1.3, 0.2]
    /// Each group's light: the fill's radiant intensity, and the neon's per meter of tube.
    static let colors: [SIMD3<Float>] = [
        [15, 20, 36],
        [1.1, 0.055, 0.3], [0.9, 0.03, 0.55], [0.55, 0.055, 0.9],
        [0.25, 2.0, 4.0],
        amber,
        [1.6, 1.15, 0.7],
        amber,
    ]

    static let eye = SIMD3<Float>(0, 1.25, 0)
    /// The side walls stand at x = ±width, the colonnades at x = ±aisle, the end wall at z = end.
    static let width: Float = 9, aisle: Float = 5.2, height: Float = 7.6, end: Float = -30, back: Float = 8
    static let beam: Float = 0.85
    /// The colonnades' pillars, placed so the nearest stand on the seams between screens.
    static let pillarLines: [Float] = (0..<7).map { -3 - 4 * Float($0) }
    static let dais = (front: Float(-8.6), breadth: Float(8.8), rise: Float(0.15), tread: Float(0.4), steps: 3)
    static let tube: Float = 0.022
    /// Seconds of flight each trail leaves behind it.
    static let trailLength: Float = 6

    static func world() -> SaverWorld {
        var world = SaverWorld(camera: .init(eye: eye, target: eye + [0, 0, -10], fieldOfView: 34), shader: shader)
        world.groups = Group.count
        world.skyGroup = nil
        world.liveReflections = true
        world.look.bloom = 0.06
        world.look.halation = 0.4
        world.look.clamp = 3
        world.look.liveSamples = 4
        world.look.bounces = 1
        addHall(&world)
        addPortal(&world)
        addLines(&world)
        addRing(&world)
        world.lights.append(.sphere([0, 5, back - 1.5], radius: 1, color: colors[Group.fill], group: Group.fill))
        world.particles = [.init(function: "dust", count: 2500, blend: .additive), .init(function: "glints", count: 450, blend: .additive)]
        world.update = { time, frame in update(Float(time), &frame) }
        return world
    }

    // MARK: Motion

    static func update(_ t: Float, _ frame: inout SaverFrame) {
        for k in 0..<3 {
            let color = hue(t / 80 + Float(k) / 3)
            let brightness = smoothstep(0, 3, t) * (0.85 + 0.3 * Procedural.noise([t * 0.4, Float(k) * 5, 1]))
            for i in 0..<4 {
                frame.params[k * 4 + i] = SIMD4(trail(k, t - trailLength * Float(i) / 3), i < 3 ? color[i] : brightness)
            }
            frame.lights.append(.init(position: trail(k, t), radius: 0.06, color: color * 1.1 * brightness, shadows: true, range: 5))
        }
        for j in 0..<3 {
            let breath = 0.8 + 0.25 * Procedural.noise([t * 0.13, Float(j) * 3.1, 0])
            frame.tints[Group.portal + j] = SIMD3(repeating: breath + 1.2 * wave(t, delay: Float(j) * 0.45) + 0.9 * ignition(t, z: portalZ(j)))
        }
        frame.tints[Group.ring] = SIMD3(repeating: 0.85 + 0.2 * Procedural.noise([t * 0.1, 7, 0]) + 0.8 * wave(t, delay: 1.9))
        frame.tints[Group.left] = SIMD3(repeating: 0.8 + 0.3 * Procedural.noise([t * 0.09, 11, 0]))
        frame.tints[Group.right] = SIMD3(repeating: 0.8 + 0.3 * Procedural.noise([t * 0.09, 17, 0]))
        frame.tints[Group.aging] = frame.tints[Group.right] * flicker(t)
    }

    /// The aging tube: steady, but every half minute or so it stutters for a second before it
    /// catches again. 1 is fully lit.
    static func flicker(_ t: Float) -> Float {
        let n = (t / 30).rounded(.down), start = 30 * n + 20 * Procedural.hash(Int32(n), 9, 1)
        guard t > start, t < start + 1.4 else { return 1 }
        let chance = Procedural.hash(Int32(t * 15), 4, 4)
        return chance < 0.35 ? 0 : chance < 0.5 ? 0.3 : 1
    }

    /// Where trail `k` is at time `t`. One skims the floor in a figure of eight that swings out past
    /// the nearest pillars, one threads the portal and one circles under the beams, each on sines at
    /// unrelated rates so its path never quite repeats.
    static func trail(_ k: Int, _ t: Float) -> SIMD3<Float> {
        switch k {
        case 0: return [4.1 * sin(0.13 * t + 1) + 0.25 * sin(0.41 * t), 1.05 + 0.3 * sin(0.29 * t + 2) + 0.1 * sin(0.71 * t), -5.2 - 2.1 * cos(0.26 * t + 2) + 0.4 * sin(0.37 * t)]
        case 1: return [0.6 * sin(0.19 * t) + 0.2 * sin(0.47 * t + 1), 2.65 + 0.5 * sin(0.23 * t + 1) + 0.12 * sin(0.61 * t), -13 + 8 * sin(0.11 * t + 2)]
        default: return [-1.2 + 3 * sin(0.15 * t + 4) + 0.4 * sin(0.41 * t), 5.3 + 0.4 * sin(0.27 * t + 3), -10.5 + 4.5 * sin(0.12 * t + 5) + 0.6 * sin(0.33 * t)]
        }
    }

    /// A color off the wheel, as bright to the eye as any other.
    static func hue(_ u: Float) -> SIMD3<Float> {
        let color = 0.5 + 0.5 * cos(2 * .pi * (u + SIMD3(0, 1, 2) / 3))
        return color * 0.45 / simd_dot(color, [0.2126, 0.7152, 0.0722])
    }

    /// A swell that rolls down the hall every 9 to 14 seconds, reaching a piece `delay` seconds in.
    static func wave(_ t: Float, delay: Float) -> Float {
        let n = Int((t / 9).rounded(.down))
        return (n - 1...n).reduce(0) { sum, i in
            let age = t - 9 * Float(i) - 5 * Procedural.hash(Int32(i), 3, 7) - delay
            return sum + (age > 0 ? smoothstep(0, 0.35, age) * exp(-age / 1.3) : 0)
        }
    }

    /// How lit a frame still is from the portal's trail flying through it, fading over seconds.
    static func ignition(_ t: Float, z: Float) -> Float {
        stride(from: Float(0), to: 4, by: 0.1).reduce(0) { most, age in
            max(most, smoothstep(0.5, 0, abs(trail(1, t - age).z - z)) * exp(-age / 1.2))
        }
    }

    // MARK: The hall

    static func addHall(_ world: inout SaverWorld) {
        let length = back - end, middle = (back + end) / 2
        let concrete = Material.boards.rawValue, panels = Material.panels.rawValue
        world.add(.box([2 * width, 0.2, length]), material: Material.terrazzo.rawValue, at: [.translation([0, -0.1, middle])])
        world.add(.box([0.3, height, length]), material: panels, at: [Float(-1), 1].map { .translation([$0 * (width + 0.15), height / 2, middle]) })
        world.add(.box([2 * width, height, 0.3]), material: panels, at: [.translation([0, height / 2, end - 0.15]), .translation([0, height / 2, back + 0.15])])
        world.add(.box([2 * width, 0.3, length]), material: concrete, at: [.translation([0, height + 0.15, middle])])
        // Beams across the hall at each line of pillars and between them, and along each colonnade.
        let across = simd_float4x4.rotation(-.pi / 2, axis: [0, 0, 1]) * .translation([0, -width, 0])
        world.add(cast([beam, 0.45], height: 2 * width), material: concrete, at: pillarLines.map { .translation([0, height - beam / 2, $0]) * across })
        world.add(cast([beam / 2, 0.25], height: 2 * width), material: concrete, at: pillarLines.map { .translation([0, height - beam / 4, $0 + 2]) * across })
        world.add(cast([0.45, beam], height: length), material: concrete,
                  at: [Float(-1), 1].map { .translation([$0 * aisle, height - beam / 2, back]) * .rotation(-.pi / 2, axis: [1, 0, 0]) })
        world.add(cast([0.8, 0.8], height: height - beam), material: concrete, at: pillarLines.flatMap { z in [Float(-1), 1].map { .translation([$0 * aisle, 0, z]) } })
        // The dais: steps of polished stone, each with a steel nosing.
        for i in 0..<dais.steps {
            let front = dais.front - Float(i) * dais.tread, top = Float(i + 1) * dais.rise
            world.add(.box([dais.breadth, top, front - end]), material: Material.terrazzo.rawValue, at: [.translation([0, top / 2, (front + end) / 2])])
            world.add(.box([dais.breadth, 0.008, 0.05]), material: Material.steel.rawValue, at: [.translation([0, top + 0.004, front - 0.02])])
        }
    }

    /// A length of cast concrete standing up the y axis, its cross-section `size` (x, z) with
    /// chamfered edges, as the formwork leaves them.
    static func cast(_ size: SIMD2<Float>, height: Float) -> Mesh {
        let (h, c) = (size / 2, Float(0.03))
        return .extrusion([[-h.x + c, -h.y], [h.x - c, -h.y], [h.x, -h.y + c], [h.x, h.y - c], [h.x - c, h.y], [-h.x + c, h.y], [-h.x, h.y - c], [-h.x, -h.y + c]],
                          height: height, caps: false)
    }

    // MARK: Neon

    /// Each frame hangs under a beam.
    static func portalZ(_ j: Int) -> Float { -11 - 2 * Float(j) }

    /// Three frames hung in a row over the dais, each a quadrilateral turned and skewed a little
    /// further than the last, like echoes of one shape tumbling away.
    static func addPortal(_ world: inout SaverWorld) {
        var tops: [SIMD3<Float>] = []
        for j in 0..<3 {
            let fj = Float(j)
            let center = SIMD3<Float>(0.15 * sin(fj * 1.7 + 0.4), 2.65, portalZ(j))
            let turn = simd_quatf(angle: 0.28 * fj - 0.2, axis: [0, 1, 0]) * simd_quatf(angle: 0.12 * sin(fj * 2.3 + 1), axis: [1, 0, 0])
            let corners = (0..<4).map { i -> SIMD3<Float> in
                let fi = Float(i)
                let angle = Float.pi / 4 + fi * .pi / 2 + 0.32 * fj + 0.12 * sin(2.7 * fi + 1.3 * fj)
                let r = 2.0 * (0.86 + 0.14 * sin(1.9 * fi + 2.3 * fj + 0.5))
                return center + turn.act([r * cos(angle), r * sin(angle), 0])
            }
            // Lit from its lowest and highest sides only, each giving half the frame's light.
            let sides = zip(corners, corners.dropFirst() + [corners[0]]).sorted { $0.0.y + $0.1.y < $1.0.y + $1.1.y }
            let perimeter = sides.reduce(0) { $0 + simd_distance($1.0, $1.1) }
            addNeon(&world, rounded(corners), group: Group.portal + j, runs: [sides[0], sides[3]], scale: perimeter / 2)
            tops += corners.sorted(by: { $0.y > $1.y }).prefix(2)
        }
        addHangers(&world, from: tops)
    }

    /// Steel wires from each point straight up to the ceiling.
    static func addHangers(_ world: inout SaverWorld, from points: [SIMD3<Float>]) {
        world.add(.cylinder(radius: 0.004, height: 1, segments: 6, caps: false), material: Material.steel.rawValue,
                  at: points.map { .span(from: $0, to: [$0.x, height, $0.z]) })
    }

    /// A diagonal line on the wall of the bays down both aisles that the screens see, at a different
    /// slant in each, and one long line high along the left wall for the tall screen on that side.
    /// Each is held off the wall by clips and capped by its electrodes' black boots. The right
    /// aisle's first is aging.
    static func addLines(_ world: inout SaverWorld) {
        let wall = width - 0.1
        // The high line is long, so it gives the light of only part of its length to keep the aisle dim.
        var lines: [(a: SIMD3<Float>, b: SIMD3<Float>, group: Int, scale: Float?)] = [([-wall, 5.7, -6], [-wall, 5.7, -21], Group.left, 6)]
        for side: Float in [-1, 1] {
            for (i, bay) in zip(pillarLines, pillarLines.dropFirst()).dropFirst().prefix(3).enumerated() {
                let seed = Int32(i) + (side < 0 ? 0 : 10)
                let middle = SIMD3<Float>(side * wall, 2.4 + 0.7 * Procedural.hash(seed, 1, 0), (bay.0 + bay.1) / 2 + 0.6 * (Procedural.hash(seed, 2, 0) - 0.5))
                let slant = (0.3 + 0.9 * Procedural.hash(seed, 3, 0)) * (i % 2 == 0 ? 1 : -1)
                let along = SIMD3<Float>(0, sin(slant), cos(slant)) * (1.3 + 0.35 * Procedural.hash(seed, 4, 0))
                lines.append((middle - along, middle + along, side < 0 ? Group.left : i == 0 ? Group.aging : Group.right, nil))
            }
        }
        var clips: [simd_float4x4] = [], boots: [simd_float4x4] = []
        for (a, b, group, scale) in lines {
            addNeon(&world, [a, b], group: group, runs: [(a, b)], scale: scale)
            let count = max(2, Int(simd_distance(a, b) / 1.2))
            clips += (0..<count).map { k in
                let p = a + (b - a) * (Float(k) + 0.5) / Float(count)
                return .span(from: p, to: [a.x < 0 ? -width : width, p.y, p.z])
            }
            let direction = simd_normalize(b - a)
            boots += [.span(from: a, to: a - direction * 0.11), .span(from: b, to: b + direction * 0.11)]
        }
        world.add(.cylinder(radius: 0.006, height: 1, segments: 8), material: Material.steel.rawValue, at: clips)
        world.add(.cylinder(radius: 0.03, height: 1, segments: 16), material: Material.rubber.rawValue, at: boots)
    }

    /// A ring of warm white hung at the back of the dais, down the middle of the hall.
    static func addRing(_ world: inout SaverWorld) {
        let (center, radius) = (SIMD3<Float>(0, 2.9, -25), Float(2.2))
        func point(_ angle: Float) -> SIMD3<Float> { center + [radius * cos(angle), radius * sin(angle), 0] }
        addNeon(&world, (0...120).map { point(Float($0) / 120 * 2 * .pi) }, group: Group.ring, runs: [], radius: 0.04)
        // One sphere as wide as the ring gives its light, where tubes around it would cost a light each.
        world.lights.append(.sphere(center, radius: radius, color: colors[Group.ring] * 2 * .pi * radius, group: Group.ring))
        addHangers(&world, from: [point(.pi / 4), point(3 * .pi / 4)])
    }

    /// A tube of neon along `path` in `group`'s color, with a tube light along each straight run
    /// giving the light of `scale` meters of tube, or of the run's own length.
    static func addNeon(_ world: inout SaverWorld, _ path: [SIMD3<Float>], group: Int, runs: [(SIMD3<Float>, SIMD3<Float>)], scale: Float? = nil,
                        radius: Float = tube) {
        world.add(.tube(path, radius: { _ in radius }, segments: 12, caps: path.first != path.last), material: Material.neon.rawValue, castsShadows: false, tag: group)
        world.lights += runs.map { .tube(from: $0.0, to: $0.1, radius: radius, color: colors[group] * (scale ?? simd_distance($0.0, $0.1)), group: group) }
    }

    /// A closed path through `corners`, rounded at each as the glass is bent.
    static func rounded(_ corners: [SIMD3<Float>], radius: Float = 0.08) -> [SIMD3<Float>] {
        let n = corners.count
        let path = corners.indices.flatMap { i -> [SIMD3<Float>] in
            let corner = corners[i]
            let a = corner + simd_normalize(corners[(i + n - 1) % n] - corner) * radius, b = corner + simd_normalize(corners[(i + 1) % n] - corner) * radius
            return (0...6).map { k in
                let s = Float(k) / 6
                return (1 - s) * (1 - s) * a + 2 * s * (1 - s) * corner + s * s * b
            }
        }
        return path + [path[0]]
    }

    // MARK: Shading

    static let shader = MetalSource(#"""
    #define HAS_EMISSION
    #define HAS_LIVE
    #define HAS_ATMOSPHERE

    enum : uint { TERRAZZO, BOARDS, PANELS, STEEL, RUBBER, NEON };
    constant float3 NEON_COLOR[] = \#(colors.metal);
    #define TRAILS 3
    #define SEGMENTS 12

    // MARK: Surfaces

    // Black terrazzo in large slabs, its aggregate glinting, polished to a mirror where it's waxed.
    static Surface terrazzo(Hit h, Ctx c) {
        float2 g = planar(h.p, h.n), slab = floor(g / 2.4f), e = abs(g - (slab + 0.5f) * 2.4f);
        float seam = smoothstep(0.005, 0.0015, 1.2f - max(e.x, e.y));
        int octaves = h.bounce == 0 ? 4 : 1;
        float broad = c.fbm(float3(g * 0.35f, 1.5), octaves), wax = c.fbm(float3(g * 0.6f, 7.5), octaves);
        float3 color = float3(0.075, 0.074, 0.078) * (0.85 + 0.3 * hash(slab)) * (0.75 + 0.5 * broad);
        Surface s = material(color, mix(0.03, 0.4, smoothstep(0.5, 0.85, wax)), h.n);
        if (h.bounce == 0) {
            float3 v = voronoi(g * 55);
            float chip = smoothstep(0.32, 0.18, v.x) * step(0.45, v.z);
            s.albedo = mix(s.albedo, float3(0.04, 0.039, 0.037) + float3(0.3, 0.29, 0.27) * v.z * v.z, chip * 0.6);
            float4 w = c.fbmd(float3(g * 0.45f, 3.3), 3);
            s.normal = bump(h.n, unplanar(w.yz * 0.45f, h.n), 0.006);
        }
        s.albedo *= 1 - 0.75 * seam;
        s.roughness = mix(s.roughness, 0.6, seam);
        return s;
    }

    // Board-formed concrete: each plank's grain printed in it, ridges where the boards met, damp.
    static Surface boards(Hit h, Ctx c) {
        float2 q = planar(h.p, h.n);
        float row = floor(q.y / 0.15f), f = q.y - row * 0.15f;
        float plank = hash(float2(row, floor(q.x / 2.4f + hash(row))));
        float3 at = float3(q.x * 1.2f, q.y * 20, row * 1.7f);
        float4 grain = h.bounce == 0 ? c.fbmd(at, 3) : float4(c.fbm(at, 1), 0, 0, 0);
        float damp = c.fbm(float3(q.x * 2.5f, q.y * 0.2f, 4.4), h.bounce == 0 ? 3 : 1);
        float ridge = smoothstep(0.005, 0.0, min(f, 0.15f - f));
        float3 color = float3(0.2, 0.192, 0.182) * (0.82 + 0.3 * plank) * (0.8 + 0.4 * grain.x) * (0.7 + 0.45 * damp) * (1 + 0.25 * ridge);
        color *= mix(0.55, 1.0, smoothstep(0.0, 0.6, h.p.y + 0.3 * damp));
        Surface s = material(color, 0.88, h.n);
        if (h.bounce == 0) s.normal = bump(h.n, unplanar(grain.yz * float2(1.2, 20), h.n), 0.0008);
        return s;
    }

    // Smooth precast panels with a faint sheen: V-grooved joints, six tie holes in each, some
    // weeping rust, and grime gathered along the foot of the wall.
    static Surface panels(Hit h, Ctx c) {
        float2 q = planar(h.p, h.n), size = float2(1.8, 0.9), cell = floor(q / size), f = q - cell * size, e = min(f, size - f);
        float seam = smoothstep(0.007, 0.002, min(e.x, e.y));
        float2 tie = float2(fmod(f.x, 0.6f), fmod(f.y, 0.45f)) - float2(0.3, 0.225);
        float mottle = c.fbm(float3(q * 1.3f, 9.1), h.bounce == 0 ? 4 : 1);
        float3 color = float3(0.24, 0.235, 0.225) * (0.88 + 0.2 * hash(cell)) * (0.8 + 0.35 * mottle);
        if (h.bounce == 0 && tie.y < 0) {
            float2 id = cell * float2(3, 2) + floor(f / float2(0.6, 0.45));
            float weep = step(0.6, hash(id)) * smoothstep(0.012, 0.004, abs(tie.x + 0.006 * (c.noise(float3(q * 25, 1)) - 0.5)));
            color = mix(color, float3(0.15, 0.1, 0.065), weep * exp(tie.y / (0.06 + 0.2 * hash(id + 3.0f))) * 0.6);
        }
        color *= (1 - 0.55 * seam - 0.6 * smoothstep(0.018, 0.012, length(tie))) * mix(0.55, 1.0, smoothstep(0.0, 0.5, h.p.y + 0.25 * mottle));
        Surface s = material(color, 0.6 + 0.2 * mottle, h.n);
        if (h.bounce == 0) s.normal = bump(h.n, unplanar(c.fbmd(float3(q * 9, 2.2), 3).yz * 9, h.n), 0.0015);
        return s;
    }

    static Surface surfaceOf(Hit h, Ctx c) {
        switch (h.material) {
        case TERRAZZO: return terrazzo(h, c);
        case BOARDS: return boards(h, c);
        case PANELS: return panels(h, c);
        case STEEL: {
            Surface s = material(float3(0.42, 0.42, 0.44) * (0.85 + 0.15 * noise(h.local * float3(3, 3, 300))), 0.3, h.n);
            s.metallic = 1;
            return s;
        }
        case RUBBER: return material(float3(0.012), 0.5, h.n);
        default: return material(NEON_COLOR[h.tag] * 0.2 + 0.04, 0.12, h.n);
        }
    }

    // Only one bounce is baked, so what it reaches gives back the light of the bounces past it too.
    Surface surface(Hit h, Ctx c) {
        Surface s = surfaceOf(h, c);
        if (h.bounce > 0) s.albedo *= 1.25f;
        return s;
    }

    // MARK: Neon

    // A tube glows most down its middle, where the eye looks through the most gas.
    Emission emission(Hit h, Ctx c) {
        if (h.material != NEON) return {float3(0), 0};
        float through = h.bounce == 0 ? abs(dot(h.n, normalize(c.eye - h.p))) : 0.7f;
        float3 color = NEON_COLOR[h.tag];
        // Bright enough at its heart to bleach toward white, as film sees it.
        return {color / max(color.r, max(color.g, color.b)) * (2 + 4 * through) + 2 * pow(through, 4.0f), h.tag};
    }

    float3 sky(float3 d, Ctx c) { return 0; }

    // MARK: Trails

    // A trail as the app passes it: four knots from its head back along its flight, a third of its
    // length apart, in params 4k to 4k + 3, with its color in the first three w and its brightness
    // in the last.
    struct Trail {
        float4 knot[4];

        static Trail of(uint k, Ctx c) { return {{c.param(k * 4), c.param(k * 4 + 1), c.param(k * 4 + 2), c.param(k * 4 + 3)}}; }

        // Where it was, from its head (u = 0) back to its tail (u = 1): the cubic through the knots.
        float3 at(float u) const {
            float x = u * 3;
            return (-(x - 1) * (x - 2) * (x - 3) * knot[0].xyz + 3 * x * (x - 2) * (x - 3) * knot[1].xyz
                    - 3 * x * (x - 1) * (x - 3) * knot[2].xyz + x * (x - 1) * (x - 2) * knot[3].xyz) / 6;
        }

        float3 color() const { return float3(knot[0].w, knot[1].w, knot[2].w) * knot[3].w; }
    };

    // Three trails of light: a bright head, and where it flew in the last few seconds as a wisp that
    // widens and fades as it ages, keeping the head's flicker.
    Live live(float3 ro, float3 rd, float maxDist, Ctx c) {
        Live result = nothing();
        // Sliding the curve along itself by this sample's moment in the shutter blurs its flight.
        float shift = (c.f->time - c.t) / \#(trailLength);
        for (uint k = 0; k < TRAILS; k++) {
            Trail trail = Trail::of(k, c);
            float3 lo = min(min(trail.knot[0].xyz, trail.knot[1].xyz), min(trail.knot[2].xyz, trail.knot[3].xyz)) - 1;
            float3 hi = max(max(trail.knot[0].xyz, trail.knot[1].xyz), max(trail.knot[2].xyz, trail.knot[3].xyz)) + 1;
            float2 span = boxInterval(ro, rd, lo, hi);
            if (trail.knot[3].w <= 0 || span.x >= min(span.y, maxDist)) continue;
            float core = 0, glow = 0, depth = FAR;
            float3 head = trail.at(shift), prev = head;
            for (int i = 1; i <= SEGMENTS; i++) {
                float3 next = trail.at(float(i) / SEGMENTS + shift), near = nearest(ro, rd, prev, next);
                float dist = near.x, t = near.y, u = (float(i - 1) + near.z) / SEGMENTS, spread = mix(0.03f, 0.22f, u);
                prev = next;
                if (t <= 0 || t >= maxDist || dist > 7 * spread) continue;
                float life = (1 - u) * sqrt(1 - u) * (0.75f + 0.25f * sin((c.t - u * \#(trailLength)) * 6 + k * 2));
                float radius = 0.025f * saturate(1 - u * 3), px = c.pixel * t;
                float cover = saturate((radius + px - dist) / (2 * px)) * min(1.0f, 2 * radius / px) * life;
                if (cover > core) {
                    core = cover;
                    depth = t;
                }
                glow = max(glow, life * sqrt(0.03f / spread) * smoothstep(7 * spread, 3 * spread, dist) / (1 + dist * dist / (spread * spread)));
            }
            float3 toHead = head - ro;
            float along = dot(toHead, rd), flare = along > 0 && along < maxDist ? 0.25f / (1 + length_squared(toHead - rd * along) * 40) : 0;
            result.color += trail.color() * (core * 8 + glow * 1.6f + flare * 2);
            result.alpha = max(result.alpha, core);
            if (core > 0.5) result.depth = min(result.depth, depth);
        }
        return result;
    }

    // MARK: Haze

    // Haze thin through the hall and thicker toward the floor, lit by every light at the haze's
    // mean along the ray, drifting in slow billows.
    Atmosphere atmosphere(float3 ro, float3 rd, float dist, Ctx c) {
        float d = min(dist, 80.0f), optical = 0.003f * d + fogDepth(ro, rd, d, 0.01f, 0.9f);
        float billow = 0.5 + c.noise(ro * 0.45f + rd * min(d, 7.0f) * 0.45f + float3(0.05, 0.012, -0.03) * c.t);
        return {c.inscatter(ro, rd, d) * optical / d * billow, float3(exp(-optical))};
    }

    // MARK: Motes

    // Dust adrift in the near half of the hall, showing where the light is. A slow draft carries it
    // across and up, and it fades out at the far side to come round again.
    Particle dust(uint i, Ctx c) {
        float3 a = hash3(float3(i, 1.3, 7.1)), b = hash3(float3(i, 4.2, 2.7)), f = fract(a + float3(0.003, 0.001, 0) * c.t);
        Particle p;
        p.position = float3(-4.5, 0.1, -12) + f * float3(9, 4.4, 10.5) + 0.25f * sin(c.t * (0.06f + 0.08f * b) + b.yzx * 9);
        p.size = 0.002 + 0.003 * b.x;
        p.color = c.light(p.position) * 2;
        p.alpha = 0.6 * smoothstep(-0.2, 0.6, sin(c.t * (0.2f + 0.3f * a.y) + b.z * 20)) * smoothstep(0.0, 0.05, min(min(f.x, 1 - f.x), min(f.y, 1 - f.y)));
        p.glow = 0.3;
        p.halo = 4;
        return p;
    }

    // Glints each trail sheds, hanging where they were dropped and spreading as they fade.
    Particle glints(uint i, Ctx c) {
        Trail trail = Trail::of(i % TRAILS, c);
        float u = fract(hash(float(i) + 0.5f) + c.t / \#(trailLength));
        Particle p;
        p.position = trail.at(u) + (hash3(float3(i, 3.3, 1.1)) - float3(0.5, 0.8, 0.5)) * 0.35f * u;
        p.size = 0.005;
        p.color = trail.color() * 20 * (1 - u) * (1 - u);
        p.alpha = smoothstep(0.0, 0.03, u) * (0.5 + 0.5 * sin(c.t * 9 + float(i)));
        p.glow = 0.15;
        return p;
    }
    """#)
}
