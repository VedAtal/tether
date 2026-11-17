import simd

extension SaverScene {
    static let campfire = SaverScene(name: "Campfire", symbol: "flame") { Campfire.world() }
}

/// A campfire in a moonlit forest clearing: a teepee of split logs burning on a bed of coals in a
/// ring of granite, and a tent pitched beside it with a lantern glowing inside.
private enum Campfire {
    /// Light groups. `still` holds the moon and the lantern, which never change. The flames are three
    /// lights a little apart, so mixing them moves their center; the coals glow on their own, a beat
    /// behind the flames.
    enum Group {
        static let still = 0, sky = 1, fire = 2, embers = 5
    }

    /// Matches the shader's `enum`.
    enum Material: Int {
        case ground, granite, pebble, coal, bark, split, end, trunk, needles, canvas, cord, enamel, steel, grass, fern, wool, lantern
    }

    static let eye = SIMD3<Float>(0, 1.1, 3.8)
    /// The middle of the flames, in meters above the center of the fire pit.
    static let core = SIMD3<Float>(0, 0.28, 0)
    static let flames: [SIMD3<Float>] = [[-0.12, 0.2, 0.06], [0.12, 0.18, -0.07], [0.01, 0.48, 0]]
    /// The moon hangs low over the valley; its light comes from a little higher, so the clearing
    /// isn't all in the trees' shadow.
    static let moon = simd_normalize(SIMD3<Float>(-0.3, 0.195, -0.934))
    static let moonLight = simd_normalize(SIMD3<Float>(-0.3, 0.42, -0.86))
    /// Toward the valley, where the trees open onto the moon.
    static let valley = simd_normalize(SIMD2<Float>(moon.x, moon.z))
    static let tent = SIMD2<Float>(4.1, -0.9)
    static let woodpile = SIMD2<Float>(1.85, -0.95)
    static let block = SIMD2<Float>(2.9, 1.05)

    static func world() -> SaverWorld {
        var world = SaverWorld(camera: .init(eye: eye, target: [0, 0.5, 0], fieldOfView: 34), shader: shader)
        world.groups = 6
        world.skyGroup = Group.sky
        world.look.exposure = 1.6
        world.look.halation = 0.35
        world.look.bounces = 3
        addGround(&world)
        addFirePit(&world)
        addFire(&world)
        addCamp(&world)
        addTent(&world)
        addFloor(&world)
        addTrees(&world)
        // The moon rims the clearing from behind; a soft cool fill from behind the camera, as the
        // night sky's glow, keeps the shadow side readable.
        world.lights += [.directional(toward: moonLight, angle: 0.01, color: [0.12, 0.15, 0.24], group: Group.still),
                        .directional(toward: [0.15, 0.6, 0.8], angle: 0.4, color: [0.034, 0.045, 0.075], group: Group.sky)]
            + flames.enumerated().map { .sphere($1, radius: 0.13, color: [2.8, 1.25, 0.42], group: Group.fire + $0) }
            + [.sphere([0, 0.06, 0], radius: 0.24, color: [0.9, 0.24, 0.05], group: Group.embers)]
        world.particles = [.init(function: "sparks", count: 130, blend: .additive), .init(function: "smoke", count: 72, blend: .alpha)]
        world.update = { time, frame in update(Float(time), &frame) }
        return world
    }

    // MARK: Motion

    /// How brightly the fire burns: a slow swell, a quicker flutter and a flare when a log settles.
    static func energy(_ t: Float) -> Float {
        0.74 + 0.2 * Procedural.noise([t * 0.8, 0, 0]) + 0.12 * Procedural.noise([t * 2.9, 4, 0]) + 0.06 * Procedural.noise([t * 8.3, 9, 0]) + 0.5 * flare(t)
    }

    /// A log settles every 8 to 14 seconds somewhere on the bed: (when, which, x, z) of the latest
    /// one before t, or the one before that.
    static func settle(before t: Float, back: Int) -> SIMD4<Float> {
        func start(_ k: Int) -> Float { Float(k) * 11 + 6 * Procedural.hash(Int32(k), 5, 5) }
        var k = Int((t / 11).rounded(.down))
        if start(k) > t { k -= 1 }
        k -= back
        let angle = Procedural.hash(Int32(k), 6, 6) * 2 * .pi, r = 0.06 + 0.12 * Procedural.hash(Int32(k), 7, 7)
        return [start(k), Float(k & 1023), r * cos(angle), r * sin(angle)]
    }

    static func flare(_ t: Float) -> Float {
        let age = t - settle(before: t, back: 0).x
        return (1 - exp(-age / 0.08)) * exp(-age / 1.4)
    }

    static func update(_ t: Float, _ frame: inout SaverFrame) {
        let e = energy(t)
        // Each flame light swells and fades on its own, so the fire's center wanders.
        let weights = (0..<3).map { 0.45 + Procedural.noise([t * 1.6, Float($0) * 7.3, 2]) + 0.35 * Procedural.noise([t * 4.7, Float($0) * 3.1, 5]) }
        let mean = weights.reduce(0, +) / 3
        for (i, weight) in weights.enumerated() {
            let level = e * weight / mean
            frame.tints[Group.fire + i] = level * SIMD3(1, 0.9 + 0.1 * level, 0.8 + 0.2 * level)
        }
        // The coals answer the flames a moment late, and breathe slowly on their own.
        let lagged = (0..<8).reduce(Float(0)) { $0 + energy(t - Float($1) * 0.2) * pow(0.8, Float($1)) } / 4.16
        frame.tints[Group.embers] = SIMD3(repeating: lagged * (0.8 + 0.3 * Procedural.noise([t * 0.21, 3, 3])))
        frame.params[0] = SIMD4(e, weights[0] / mean, weights[1] / mean, weights[2] / mean)
        frame.params[1] = settle(before: t, back: 0)
        frame.params[2] = settle(before: t, back: 1)
    }

    // MARK: The clearing

    static func height(_ p: SIMD2<Float>) -> Float {
        let r = simd_length(p)
        let along = simd_dot(p, valley), across = abs(p.x * valley.y - p.y * valley.x)
        let dip = smoothstep(9, 28, along) * smoothstep(0.7 * along + 3, 0.25 * along, across)
        let rolling = 0.12 * (Procedural.fbm([p.x * 0.3, 0, p.y * 0.3], octaves: 4) - 0.5) * smoothstep(1.2, 4, r)
        let rise = 1.2 * smoothstep(8, 26, r) * Procedural.fbm([p.x * 0.1, 3, p.y * 0.1], octaves: 3)
        let lumps = 0.03 * (Procedural.fbm([p.x * 1.5, 7, p.y * 1.5], octaves: 3) - 0.5) * smoothstep(0.6, 1.2, r)
        return rolling + lumps + rise * (1 - dip) - 6 * dip - 0.05 * (1 - smoothstep(0.2, 0.7, r))
    }

    static func ground(_ p: SIMD2<Float>, lift: Float = 0) -> SIMD3<Float> { [p.x, height(p) + lift, p.y] }

    /// Ground 60 m across, its cells a few centimeters wide at the fire and widening outward.
    static func addGround(_ world: inout SaverWorld) {
        let cells = 400
        func spread(_ k: Int) -> Float {
            let u = Float(k) / Float(cells) * 2 - 1
            return 30 * u * abs(u)
        }
        world.add(.parametric(cells, cells) { i, j in ground([spread(j), spread(i)]) }, material: Material.ground.rawValue)
    }

    /// Whether the floor at p is clear of the pit, the camp and the line of sight to the fire.
    static func open(_ p: SIMD2<Float>, view: Bool = false) -> Bool {
        let fromEye = p - SIMD2(eye.x, eye.z)
        if view && abs(atan2(fromEye.x, -fromEye.y)) < 0.42 && simd_length(fromEye) < 4.2 { return false }
        return simd_length(p) > 0.95 && simd_distance(p, tent) > 1.7 && simd_distance(p, woodpile) > 0.5 && simd_distance(p, block) > 0.35
    }

    /// Up to `count` open places within `radius`, kept in proportion to `density` (0 to 1).
    static func strew(_ count: Int, seed: UInt64, within radius: Float, view: Bool = false, density: (SIMD2<Float>) -> Float) -> [SIMD2<Float>] {
        var random = SeededRandom(seed: seed)
        var places: [SIMD2<Float>] = []
        for _ in 0..<count * 30 where places.count < count {
            let p = SIMD2(random.uniform(-radius...radius), random.uniform(-radius...radius))
            if open(p, view: view) && random.uniform(0...1) < density(p) { places.append(p) }
        }
        return places
    }

    /// Each of `variants` at its share of `places`, turned and sized at random, sunk `sink` of its size.
    static func scatter(_ world: inout SaverWorld, _ variants: [Mesh], material: Material, at places: [SIMD2<Float>], size: ClosedRange<Float>, sink: Float = 0, seed: UInt64) {
        var random = SeededRandom(seed: seed)
        var transforms = [[simd_float4x4]](repeating: [], count: variants.count)
        for (k, p) in places.enumerated() {
            let s = random.uniform(size)
            transforms[k % variants.count].append(.place(ground(p, lift: -sink * s), yaw: random.uniform(0...2 * .pi), scale: SIMD3(repeating: s)))
        }
        for (mesh, at) in zip(variants, transforms) { world.add(mesh, material: material.rawValue, at: at) }
    }

    /// Pebbles, sticks, fallen branches and cones over the floor; grass and ferns toward the trees.
    static func addFloor(_ world: inout SaverWorld) {
        let pebbles = (0..<4).map { rock(seed: 200 + Int32($0), subdivisions: 1) }
        scatter(&world, pebbles, material: .pebble, at: strew(2600, seed: 1, within: 11) { simd_length($0) < 3 ? 1 : 0.3 },
                size: 0.015...0.08, sink: 0.3, seed: 2)
        let chips = (0..<4).map { chip(seed: Int32($0)) }
        scatter(&world, chips, material: .bark, at: strew(700, seed: 13, within: 4) { p in
            max(smoothstep(1.2, 0.3, simd_distance(p, block)), smoothstep(1.0, 0.3, simd_distance(p, woodpile)), 0.08 * smoothstep(3.5, 1.2, simd_length(p)))
        }, size: 0.6...1.4, seed: 14)
        let twigs = (0..<4).map { stick(seed: 80 + Int32($0), long: 0.18, thick: 0.004) }
        scatter(&world, twigs, material: .bark, at: strew(500, seed: 15, within: 4) { smoothstep(0.9, 1.4, simd_length($0)) }, size: 0.6...1.4, seed: 16)
        let sticks = (0..<6).map { stick(seed: Int32($0), long: 0.5, thick: 0.007) }
        scatter(&world, sticks, material: .bark, at: strew(420, seed: 3, within: 12) { 0.4 + 0.6 * smoothstep(2, 6, simd_length($0)) },
                size: 0.4...1.1, seed: 4)
        let branches = (0..<3).map { stick(seed: 40 + Int32($0), long: 1.6, thick: 0.022) }
        scatter(&world, branches, material: .bark, at: strew(16, seed: 5, within: 10, view: true) { smoothstep(2.5, 5, simd_length($0)) },
                size: 0.7...1.2, seed: 6)
        let cones = (0..<3).map { cone(seed: Int32($0)) }
        scatter(&world, cones, material: .trunk, at: strew(160, seed: 7, within: 14) { smoothstep(3, 7, simd_length($0)) },
                size: 0.8...1.2, seed: 8)
        func clumps(_ p: SIMD2<Float>, _ seed: Float) -> Float { smoothstep(0.45, 0.65, Procedural.fbm([p.x * 0.5, seed, p.y * 0.5], octaves: 3)) }
        let tufts = (0..<4).map { tuft(seed: Int32($0)) }
        scatter(&world, tufts, material: .grass, at: strew(600, seed: 9, within: 14, view: true) { smoothstep(2.4, 5.5, simd_length($0)) * (0.3 + clumps($0, 1)) },
                size: 0.7...1.4, seed: 10)
        let ferns = (0..<3).map { fern(seed: Int32($0)) }
        let underPine: [SIMD2<Float>] = [[-3.9, 1.4], [-4.3, 0.1], [-3.3, 2.15], [-5.1, 1.7], [-2.75, 2.75], [-4.6, 2.6], [-3.7, -0.3]]
        scatter(&world, ferns, material: .fern, at: underPine + strew(110, seed: 11, within: 14, view: true) { smoothstep(3.2, 6.5, simd_length($0)) * clumps($0, 5) * 1.5 },
                size: 0.8...1.4, seed: 12)
    }

    // MARK: The fire

    /// How hot a point is, as the shader's `heat`.
    static func heat(_ p: SIMD3<Float>) -> Float { smoothstep(0.62, 0.12, simd_length((p - core) * SIMD3(1, 0.65, 1))) }

    /// Granite round the pit, and the bed of coals in it.
    static func addFirePit(_ world: inout SaverWorld) {
        for i in 0..<14 {
            let seed = Int32(i)
            let angle = Float(i) / 14 * 2 * .pi + 0.18 * Procedural.hash(seed, 9, 9)
            let distance = 0.7 + 0.05 * Procedural.hash(seed, 8, 8), size = 0.2 + 0.09 * Procedural.hash(seed, 7, 7)
            let p = SIMD2(distance * cos(angle), distance * sin(angle))
            world.add(rock(seed: seed, facets: 10), material: Material.granite.rawValue,
                      at: [.place(ground(p, lift: 0.01), yaw: -angle + 0.5 * Procedural.hash(seed, 6, 6), scale: [size * 1.15, size, size])])
        }
        let coals = (0..<5).map { rock(seed: 100 + Int32($0), subdivisions: 2, facets: 10) }
        var places = [[simd_float4x4]](repeating: [], count: coals.count)
        var random = SeededRandom(seed: 41)
        for i in 0..<170 {
            let angle = random.uniform(0...2 * .pi), r = 0.44 * pow(random.uniform(0...1), 0.6)
            let size = random.uniform(0.03...0.1) * (1.2 - r)
            let tilt = SIMD3(random.uniform(-0.4...0.4), 1, random.uniform(-0.4...0.4))
            places[i % coals.count].append(.place([r * cos(angle), height([r * cos(angle), r * sin(angle)]) + size * 0.1, r * sin(angle)],
                                                  up: tilt, yaw: random.uniform(0...2 * .pi), scale: [size * 1.3, size, size]))
        }
        for (coal, at) in zip(coals, places) { world.add(coal, material: Material.coal.rawValue, at: at) }
    }

    /// A teepee of split logs leaning together over the coals, two thick ones crossed beneath and
    /// burning through, and kindling caught between them.
    static func addFire(_ world: inout SaverWorld) {
        var random = SeededRandom(seed: 5)
        let wedges: [Float] = [.pi, .pi / 2, 2 * .pi, .pi, .pi / 2, .pi, 2 * .pi, .pi / 2, .pi]
        for (i, wedge) in wedges.enumerated() {
            let angle = Float(i) / Float(wedges.count) * 2 * .pi + 0.3 + random.uniform(-0.2...0.2), reach = random.uniform(0.36...0.46)
            let foot = SIMD3(reach * cos(angle), -0.03, reach * sin(angle))
            let top = SIMD3(0.06 * cos(angle * 3 + 1), random.uniform(0.55...0.72), 0.06 * sin(angle * 3 + 1))
            addLog(&world, from: foot, to: foot + (top - foot) * random.uniform(1.0...1.15), radius: random.uniform(0.055...0.07) * (wedge < 6 ? 1.4 : 1),
                   wedge: wedge, roll: random.uniform(0...2 * .pi), seed: Int32(i), taper: random.uniform(0.4...0.7))
        }
        addLog(&world, from: [-0.46, 0.04, -0.16], to: [0.44, 0.05, 0.21], radius: 0.075, wedge: 2 * .pi, seed: 7)
        addLog(&world, from: [-0.32, 0.04, 0.37], to: [0.35, 0.03, -0.34], radius: 0.085, wedge: .pi, roll: 1.2, seed: 8)
        for i in 0..<9 {
            let angle = random.uniform(0...2 * .pi), r = random.uniform(0.08...0.3)
            let foot = SIMD3(r * cos(angle), 0, r * sin(angle))
            addLog(&world, from: foot, to: foot * 0.2 + SIMD3(random.uniform(-0.05...0.05), random.uniform(0.2...0.4), random.uniform(-0.05...0.05)),
                   radius: random.uniform(0.008...0.016), wedge: 2 * .pi, seed: 30 + Int32(i))
        }
    }

    /// A length of firewood from `a` to `b`, built up its own y axis so the shader's `h.local`
    /// runs with the grain.
    static func addLog(_ world: inout SaverWorld, from a: SIMD3<Float>, to b: SIMD3<Float>, radius: Float, wedge: Float, roll: Float = 0, seed: Int32,
                       splinters: Float = 0, taper: Float = 0, extra: Mesh = Mesh()) {
        let length = simd_length(b - a)
        let place = simd_float4x4.span(from: a, to: b, height: length) * .rotation(roll, axis: [0, 1, 0])
        let log = firewood(place, length: length, radius: radius, wedge: wedge, seed: seed, splinters: splinters, taper: taper)
        world.add(log.bark + extra, material: Material.bark.rawValue, at: [place])
        world.add(log.faces, material: Material.split.rawValue, at: [place])
        world.add(log.ends, material: Material.end.rawValue, at: [place])
    }

    /// A round, or a split `wedge` radians of one: a slight bow, furrowed bark, torn faces and
    /// sawn ends (the far one splintered by `splinters`, or burnt to a point by `taper`), burnt
    /// thinner where `place` puts it in the fire.
    static func firewood(_ place: simd_float4x4, length: Float, radius: Float, wedge: Float, seed: Int32, splinters: Float, taper: Float) -> (bark: Mesh, faces: Mesh, ends: Mesh) {
        let round = wedge > 6.2
        let rings = max(4, Int(length * 32)), around = max(10, Int(wedge * radius * 110))
        func angle(_ j: Int) -> Float { wedge * (Float(j) / Float(around) - 0.5) }
        let bow = SIMD2(Procedural.hash(seed, 3, 3) - 0.5, Procedural.hash(seed, 4, 4) - 0.5) * radius * 0.6
        func axis(_ y: Float) -> SIMD3<Float> { SIMD3(bow.x * sin(y / length * .pi), y, bow.y * sin(y / length * .pi)) }
        func rim(_ a: Float, _ y: Float) -> SIMD3<Float> {
            let furrow = 1 - abs(Procedural.fbm([cos(a) * radius * 25, y * 2.5, sin(a) * radius * 25], octaves: 3, seed: seed) * 2 - 1)
            let burnt = heat((place * SIMD4(axis(y) + SIMD3(cos(a), 0, sin(a)) * radius, 1)).xyz)
            let r = radius * (1 + min(0.1, 0.008 / radius) * furrow - 0.3 * burnt) * (1 - taper * smoothstep(0.65, 1, y / length))
            return SIMD3(r * cos(a), 0, r * sin(a))
        }
        var bark = Mesh.parametric(rings, around, wrap: round) { i, j in
            let y = length * Float(i) / Float(rings)
            return axis(y) + rim(angle(j), y)
        }
        var faces = Mesh(), ends = Mesh()
        if !round {
            for edge in [0, around] {
                let a = angle(edge), normal = SIMD3<Float>(-sin(a), 0, cos(a))
                faces += .parametric(rings, 10) { i, j in
                    let y = length * Float(i) / Float(rings), s = Float(j) / 10
                    let splinters = 1 - abs(Procedural.noise([s * 9, y * 1.5, Float(edge)], seed: seed) * 2 - 1)
                    let tear = radius * (0.12 * (Procedural.fbm([s * 3, y * 2.5, Float(edge)], octaves: 3, seed: seed) - 0.5) + 0.05 * splinters) * sin(s * .pi)
                    return axis(y) + rim(a, y) * s + normal * tear
                }
            }
        }
        for (y, far) in [(Float(0), false), (length, true)] {
            func cut(_ a: Float, _ s: Float) -> SIMD3<Float> {
                let jag = far ? splinters * pow(Procedural.noise([a * 4, s * 3, 1], seed: seed), 2) * s : 0
                return axis(y) + rim(a, y) * s + SIMD3(0, jag, 0)
            }
            ends += .parametric(4, around, wrap: round) { i, j in cut(angle(j), Float(i) / 4 * 0.9) }
            bark += .parametric(1, around, wrap: round) { i, j in cut(angle(j), i == 0 ? 0.9 : 1) }
        }
        return (bark, faces, ends)
    }

    // MARK: The camp

    /// A deadfall dragged up for a seat, a woodpile with an axe in its chopping block, and a kettle
    /// warming by the stones.
    static func addCamp(_ world: inout SaverWorld) {
        let seatA = SIMD2<Float>(-2.0, -1.05), seatB = SIMD2<Float>(-2.15, 1.05)
        let seatLength = simd_distance(seatA, seatB)
        var stubs = Mesh()
        for (y, angle, long) in [(Float(0.45), Float(0.9), Float(0.32)), (1.15, 2.4, 0.18), (1.6, -0.6, 0.42), (1.85, 1.5, 0.14)] {
            let out = simd_normalize(SIMD3(cos(angle), 0.35, sin(angle))), root = SIMD3(0, y * seatLength / 2.1, 0)
            stubs += .tube([root + out * 0.12, root + out * (0.2 + long * 0.5) + [0, long * 0.15, 0], root + out * (0.2 + long) + [0, long * 0.2, 0]],
                           radius: { 0.04 * (1 - 0.7 * $0) }, segments: 8, caps: true)
        }
        addLog(&world, from: ground(seatA, lift: 0.13), to: ground(seatB, lift: 0.15), radius: 0.18, wedge: 2 * .pi, roll: 0.6, seed: 50,
               splinters: 0.12, extra: stubs)

        var random = SeededRandom(seed: 60)
        for (k, row) in [0, 0, 0, 0, 1, 1, 1, 2].enumerated() {
            let slot = Float(k - [0, 4, 7][row]) - Float([3, 2, 0][row]) / 2, yaw = 0.42 + random.uniform(-0.25...0.25)
            let along = SIMD3(sin(yaw), 0, cos(yaw)), across = SIMD3(cos(yaw), 0, -sin(yaw))
            let center = ground(woodpile) + across * slot * 0.15 + along * random.uniform(-0.06...0.06) + SIMD3(0, 0.07 + Float(row) * 0.12, 0)
            let half = along * random.uniform(0.2...0.28)
            addLog(&world, from: center - half, to: center + half + [0, random.uniform(-0.03...0.03), 0], radius: random.uniform(0.055...0.085),
                   wedge: [2 * .pi, .pi, .pi / 2][k % 3], roll: random.uniform(0...2 * .pi), seed: 60 + Int32(k))
        }
        addLog(&world, from: ground(block, lift: -0.05), to: ground(block, lift: 0.4), radius: 0.2, wedge: 2 * .pi, seed: 70)
        let axe = axe()
        let bite = ground(block, lift: 0.4) + SIMD3(0.03, 0, -0.02)
        let handle = simd_normalize(SIMD3<Float>(-0.55, 0.5, 0.6))
        let blade = simd_normalize(SIMD3<Float>(0, -1, 0) + handle * handle.y), side = simd_cross(handle, blade)
        let hold = simd_float4x4(SIMD4(blade, 0), SIMD4(side, 0), SIMD4(handle, 0), SIMD4(bite - blade * 0.085, 1))
        world.add(axe.head, material: Material.steel.rawValue, at: [hold])
        world.add(axe.helve, material: Material.split.rawValue, at: [hold])

        let kettle = kettle(), spot = SIMD2<Float>(0.98, 0.32)
        let at = simd_float4x4.place(ground(spot), yaw: 2.2)
        world.add(kettle.body, material: Material.enamel.rawValue, at: [at])
        world.add(kettle.bail, material: Material.steel.rawValue, at: [at])
    }

    /// An axe head with its blade along +x and its helve up +z from the eye.
    static func axe() -> (head: Mesh, helve: Mesh) {
        let outline: [SIMD2<Float>] = [[-0.035, -0.024], [0.04, -0.019], [0.1, -0.05], [0.115, -0.02], [0.118, 0.02], [0.105, 0.055], [0.04, 0.021], [-0.035, 0.024]]
        var head = Mesh.extrusion(outline, height: 1)
        head.positions = head.positions.map { p in SIMD3(p.x, (p.y - 0.5) * (0.028 - 0.024 * smoothstep(0.02, 0.118, p.x)), p.z) }
        head = head.withSmoothNormals()
        let helve = Mesh.tube((0...8).map { k in
            let s = Float(k) / 8
            return SIMD3(-0.012 + 0.02 * sin(s * 3.1), 0, -0.04 + s * 0.72)
        }, radius: { 0.015 - 0.003 * sin($0 * 3) + 0.004 * pow($0, 8) }, segments: 10, caps: true)
        return (head.transformed(.rotation(-.pi / 2, axis: [1, 0, 0])), helve)
    }

    /// A camp kettle: an enamel body, lid and spout, and a wire bail laid over to one side.
    static func kettle() -> (body: Mesh, bail: Mesh) {
        let body = Mesh.lathe([[0, 0], [0.08, 0], [0.093, 0.012], [0.1, 0.05], [0.095, 0.09], [0.075, 0.118], [0.05, 0.13], [0.05, 0.14]], segments: 48)
        let lid = Mesh.lathe([[0.054, 0.137], [0.046, 0.15], [0.014, 0.156], [0.012, 0.172], [0.018, 0.178], [0, 0.182]], segments: 32)
        let spout = Mesh.tube([[0.085, 0.035, 0], [0.13, 0.07, 0], [0.155, 0.12, 0], [0.165, 0.14, 0]], radius: { 0.02 - 0.009 * $0 }, segments: 12)
        let bail = Mesh.tube((0...16).map { k in
            let a = Float(k) / 16 * .pi
            return SIMD3(-0.03 * sin(a), 0.12 + 0.03 * sin(a), 0.098 * cos(a)) + SIMD3(-0.09 * sin(a), -0.04 * sin(a), 0)
        }, radius: { _ in 0.0025 }, segments: 6, caps: true)
        return (body + lid + spout, bail)
    }

    /// A canvas ridge tent off to the right, its door toward the fire: the walls sag between the
    /// poles and crease toward the pegs, the door flaps tied back, guy lines staked out, and a
    /// lantern hung inside glowing through the canvas.
    static func addTent(_ world: inout SaverWorld) {
        let facing = simd_normalize(SIMD2<Float>(-0.35, 1))
        let place = simd_float4x4.place(ground(tent, lift: -0.02), yaw: atan2(facing.x, facing.y))
        let (half, ridge, depth): (Float, Float, Float) = (0.9, 1.2, 2.2)
        var canvas = Mesh(), cords = Mesh(), wood = Mesh()
        let apex = SIMD3<Float>(0, ridge, depth / 2)
        for side: Float in [-1, 1] {
            let out = simd_normalize(SIMD3(side * ridge, half, 0))
            canvas += .parametric(36, 18) { i, j in
                let u = Float(i) / 36, v = Float(j) / 18
                let top = SIMD3<Float>(0, ridge - 0.05 * sin(u * .pi), (u - 0.5) * depth)
                let hem = SIMD3<Float>(side * half, 0.02 + 0.06 * pow(sin(u * 2 * .pi), 2), (u - 0.5) * depth)
                var crease: Float = 0
                for peg: Float in [0, 0.5, 1] {
                    let du = (u - peg) * depth, dv = (1 - v) * 1.4, reach = (du * du + dv * dv).squareRoot()
                    crease += sin(atan2(du, dv) * 9 + side * 2 + peg * 5) * exp(-reach * 1.6) * min(reach * 4, 1)
                }
                let sag = 0.06 * sin(u * .pi) * sin(v * .pi)
                return top + (hem - top) * v - out * (sag + 0.02 * crease + 0.008 * Procedural.noise([u * 9, v * 6, side]))
            }
            let corner = SIMD3<Float>(side * half, 0.02, depth / 2), middle = SIMD3<Float>(0, 0.02, depth / 2)
            // Folded back flat against the wall outside, gathered into soft pleats.
            let swing = simd_quatf(angle: side * .pi / 2, axis: simd_normalize(corner - apex))
            canvas += .parametric(14, 10) { i, j in
                let row = Float(i) / 14, col = Float(j) / 10
                let pleat = SIMD3<Float>(0, 0, 0.025 * sin(col * 4 * .pi) * row)
                return apex + swing.act((corner - apex + (middle - corner) * col * 0.8) * row + pleat) + out * 0.03
            }
        }
        let left = SIMD3<Float>(-half, 0.02, -depth / 2), right = SIMD3<Float>(half, 0.02, -depth / 2)
        canvas += .parametric(10, 10) { i, j in
            let row = Float(i) / 10, col = Float(j) / 10
            let p = SIMD3(0, ridge, -depth / 2) + (left + (right - left) * col - SIMD3(0, ridge, -depth / 2)) * row
            return p + SIMD3(0, 0, 0.04 * sin(row * .pi) * sin(col * .pi))
        }
        canvas += .box([2 * half - 0.1, 0.01, depth - 0.1], center: [0, 0.01, 0])
        let bedroll = Mesh.tube((0...10).map { k in SIMD3(0.38 + 0.03 * sin(Float(k)), 0.11, -0.85 + 1.35 * Float(k) / 10) },
                                radius: { 0.11 + 0.025 * sin($0 * 17) }, segments: 14, caps: true).transformed(.scale([1, 0.75, 1]))
        func peg(_ p: SIMD3<Float>, leaning out: SIMD3<Float>) {
            wood += .box([0.025, 0.22, 0.014]).transformed(.place(p - [0, 0.07, 0], up: simd_normalize(SIMD3(0, 1, 0) + out * 0.35)))
        }
        func line(_ a: SIMD3<Float>, _ b: SIMD3<Float>) {
            cords += .tube((0...12).map { k in
                let s = Float(k) / 12
                return a + (b - a) * s - SIMD3(0, 0.025 * sin(s * .pi), 0)
            }, radius: { _ in 0.004 }, segments: 5)
            peg(b, leaning: simd_normalize(SIMD3(b.x - a.x, 0, b.z - a.z)))
        }
        for end: Float in [-1, 1] {
            wood += .cylinder(radius: 0.02, height: ridge + 0.1, segments: 10).transformed(.translation([0, 0, end * depth / 2]))
            line([0, ridge + 0.05, end * depth / 2], [0, 0.04, end * (depth / 2 + 1.1)])
            for side: Float in [-1, 1] {
                line([side * half * 0.45, ridge * 0.5, end * depth / 4], [side * (half + 0.65), 0.04, end * depth / 3])
                peg([side * half, 0.04, end * depth / 2], leaning: [side, 0, end])
            }
        }
        let hook = SIMD3<Float>(0, 0.76, 0.2)
        cords += .tube([hook + [0, 0.14, 0], [0, ridge - 0.04, hook.z]], radius: { _ in 0.003 }, segments: 4)
        let globe = Mesh.lathe([[0, 0.02], [0.03, 0.02], [0.042, 0.06], [0.03, 0.11], [0, 0.11]], segments: 16)
        let fount = Mesh.lathe([[0, 0], [0.045, 0], [0.047, 0.02], [0, 0.021]], segments: 16) + .lathe([[0, 0.11], [0.04, 0.11], [0.02, 0.135], [0, 0.14]], segments: 16)
        world.add(globe, material: Material.lantern.rawValue, at: [place * .translation(hook)], castsShadows: false)
        world.add(fount, material: Material.steel.rawValue, at: [place * .translation(hook)])
        world.lights.append(.sphere((place * SIMD4(hook + [0, 0.065, 0], 1)).xyz, radius: 0.03, color: [0.42, 0.24, 0.08], group: Group.still))
        world.add(canvas, material: Material.canvas.rawValue, at: [place])
        world.add(bedroll, material: Material.wool.rawValue, at: [place])
        world.add(cords, material: Material.cord.rawValue, at: [place])
        world.add(wood, material: Material.split.rawValue, at: [place])
    }

    // MARK: Small things

    /// A stone about a unit across, broken into rough facets and flattened underneath.
    static func rock(seed: Int32, subdivisions: Int = 4, facets: Int = 7) -> Mesh {
        var random = SeededRandom(seed: UInt64(seed) &+ 77)
        let cuts = (0..<facets).map { _ in
            (normal: simd_normalize(SIMD3(random.uniform(-1...1), random.uniform(-0.3...1), random.uniform(-1...1))), distance: random.uniform(0.52...0.8))
        }
        let stretch = SIMD3(random.uniform(0.9...1.25), random.uniform(0.55...0.8), random.uniform(0.8...1.1))
        var mesh = Mesh.sphere(radius: 1, subdivisions: subdivisions)
        mesh.positions = mesh.positions.map { v in
            var p = v * (1 + 0.25 * (Procedural.fbm(v * 1.5, octaves: 3, seed: seed) - 0.5))
            for cut in cuts {
                let over = simd_dot(p, cut.normal) - cut.distance
                if over > 0 { p -= cut.normal * over * 0.9 }
            }
            p += v * 0.05 * (Procedural.fbm(v * 6, octaves: 3, seed: seed &+ 7) - 0.5)
            p *= stretch * 0.5
            p.y = max(p.y, -0.12)
            return p
        }
        return mesh.withSmoothNormals()
    }

    /// A fallen stick about `long` meters, bending as it goes, with a fork or two.
    static func stick(seed: Int32, long: Float, thick: Float) -> Mesh {
        var random = SeededRandom(seed: UInt64(seed) &+ 1300)
        func limb(_ start: SIMD3<Float>, _ heading: SIMD3<Float>, _ length: Float, _ radius: Float) -> (mesh: Mesh, points: [SIMD3<Float>]) {
            var points = [start], d = heading
            for _ in 0..<5 {
                d = simd_normalize(d + SIMD3(random.uniform(-0.25...0.25), random.uniform(-0.04...0.04), random.uniform(-0.25...0.25)))
                points.append(points[points.count - 1] + d * length / 5)
            }
            return (.tube(points, radius: { radius * (1 - 0.6 * $0) }, segments: 6, caps: true), points)
        }
        let main = limb([0, thick, 0], [1, 0, 0], long, thick)
        var mesh = main.mesh
        for _ in 0..<Int(random.uniform(1...3.99)) {
            let from = main.points[Int(random.uniform(1...3.99))]
            let side: Float = random.uniform(0...1) < 0.5 ? -1 : 1
            mesh += limb(from, simd_normalize(SIMD3(1, 0, side * random.uniform(0.5...1.2))), long * random.uniform(0.2...0.45), thick * 0.55).mesh
        }
        return mesh
    }

    /// A chip of bark or wood a few centimeters across, curled and ragged.
    static func chip(seed: Int32) -> Mesh {
        let long = 0.03 + 0.04 * Procedural.hash(seed, 1, 9), wide = long * (0.4 + 0.4 * Procedural.hash(seed, 2, 9))
        return Mesh.parametric(4, 3) { i, j in
            let u = Float(i) / 4 - 0.5, v = Float(j) / 3 - 0.5
            let ragged = 1 + 0.4 * (Procedural.noise([u * 6, v * 6, Float(seed)]) - 0.5)
            return SIMD3(u * long * ragged, 0.004 + 0.012 * v * v * (1 + Procedural.hash(seed, 3, 9)), v * wide * ragged)
        }
    }

    /// A pine cone lying on its side, its scales in a spiral.
    static func cone(seed: Int32) -> Mesh {
        Mesh.lathe((0...10).map { k in
            let s = Float(k) / 10
            return SIMD2(0.022 * sin(s * .pi) * (1 - 0.35 * s) + 0.002, s * 0.075)
        }, segments: 24).displaced { p, _ in
            let a = atan2(p.z, p.x)
            return 0.004 * max(0, sin(a * 8 + p.y * 160 + Float(seed))) * sin(p.y / 0.075 * .pi)
        }.transformed(.translation([0, 0.02, -0.035]) * .rotation(.pi / 2, axis: [1, 0, 0]))
    }

    /// A tuft of grass blades arching out from one root.
    static func tuft(seed: Int32) -> Mesh {
        var random = SeededRandom(seed: UInt64(seed) &+ 500)
        var mesh = Mesh()
        for _ in 0..<24 {
            let angle = random.uniform(0...2 * .pi), tall = random.uniform(0.1...0.32), lean = random.uniform(0.15...0.7), width = random.uniform(0.0025...0.005)
            let out = SIMD3(cos(angle), 0, sin(angle)), across = SIMD3(-sin(angle), 0, cos(angle)), root = out * random.uniform(0...0.04)
            mesh += .parametric(4, 1) { i, j in
                let s = Float(i) / 4
                return root + out * lean * tall * s * s + SIMD3(0, tall * s * (1 - 0.3 * lean * s), 0) + across * width * (1 - s) * (Float(j) * 2 - 1)
            }
        }
        return mesh
    }

    /// A fern: fronds arching out and down from the crown, leaflets in pairs along each.
    static func fern(seed: Int32) -> Mesh {
        var random = SeededRandom(seed: UInt64(seed) &+ 900)
        var mesh = Mesh()
        for k in 0..<8 {
            let angle = Float(k) / 8 * 2 * .pi + random.uniform(-0.3...0.3), long = random.uniform(0.4...0.7), arch = random.uniform(0.5...0.9)
            let out = SIMD3(cos(angle), 0, sin(angle)), across = SIMD3(-sin(angle), 0, cos(angle))
            func spine(_ s: Float) -> SIMD3<Float> { out * long * s + SIMD3(0, long * arch * (s - 1.1 * s * s), 0) }
            mesh += .tube((0...6).map { spine(Float($0) / 6) }, radius: { 0.003 * (1 - $0) + 0.001 }, segments: 3)
            for p in 2..<16 {
                let s = Float(p) / 16, base = spine(s), leaf = 0.13 * long * sin(.pi * min(1, s * 1.1)) + 0.01
                for side: Float in [-1, 1] {
                    let tip = base + (across * side + out * 0.35) * leaf - SIMD3(0, 0.35 * leaf, 0)
                    let width = simd_normalize(simd_cross(tip - base, [0, 1, 0]))
                    mesh += .parametric(3, 1) { i, j in
                        let t = Float(i) / 3
                        return base + (tip - base) * t + width * 0.2 * leaf * sin(.pi * min(t * 1.3 + 0.1, 1)) * (Float(j) - 0.5)
                    }
                }
            }
        }
        return mesh
    }

    // MARK: Trees

    /// Spruces in stands round the clearing, with sky between them and open toward the valley where
    /// the moon is: each its bearing from straight ahead of the eye, its distance from the eye and size.
    static let stands: [SIMD3<Float>] = [[-0.95, 30, 1.0], [-0.74, 27, 1.1], [-0.86, 23, 0.95],
                                         [-0.97, 11.3, 0.27], [1.0, 17, 0.85], [-0.77, 10.3, 0.34], [-0.44, 8.5, 0.3],
                                         [-0.08, 15.2, 1.07], [0.015, 14.8, 1.0], [0.2, 9.8, 1.0], [0.3, 21, 0.55], [0.45, 11.5, 1.05],
                                         [0.55, 17, 0.7], [0.63, 12.5, 0.9], [0.78, 20, 0.6], [0.9, 13, 1.0]]

    /// The stands, and an old pine framing the left edge.
    static func addTrees(_ world: inout SaverWorld) {
        let kinds = (0..<3).map { pine(seed: Int32($0), crown: 0.05) } + [pine(seed: 20, crown: 0.6)]
        func place(_ tree: SIMD3<Float>, yaw: Float) -> simd_float4x4 {
            .place(ground(SIMD2(eye.x, eye.z) + tree.y * SIMD2(sin(tree.x), -cos(tree.x)), lift: -0.1), yaw: yaw, scale: SIMD3(repeating: tree.z))
        }
        var places = [[simd_float4x4]](repeating: [], count: kinds.count)
        places[3] = [place([-0.973, 5.51, 1.2], yaw: 1)]
        for (k, tree) in stands.enumerated() { places[k % 3].append(place(tree, yaw: Float(k) * 2.4)) }
        for (tree, transforms) in zip(kinds, places) {
            world.add(tree.needles, material: Material.needles.rawValue, at: transforms)
            world.add(tree.wood, material: Material.trunk.rawValue, at: transforms)
        }
    }

    /// A conifer: a trunk flaring into its roots, dead stubs below the `crown` (a fraction of its
    /// height), then whorls of drooping branches, each a bough of needled branchlets, up to a leader.
    static func pine(seed: Int32, crown: Float) -> (needles: Mesh, wood: Mesh) {
        var random = SeededRandom(seed: UInt64(seed) &* 7919 &+ 3)
        let tall = random.uniform(11...16), radius = random.uniform(0.2...0.3), reach = tall * random.uniform(0.15...0.19)
        let base = tall * crown, lean = SIMD2(random.uniform(-0.3...0.3), random.uniform(-0.3...0.3))
        func axis(_ y: Float) -> SIMD3<Float> { SIMD3(lean.x * y * y / (tall * tall), y, lean.y * y * y / (tall * tall)) }
        var wood = Mesh.tube((0...28).map { axis(tall * Float($0) / 28 - 0.4) }, radius: { t in
            radius * (1 - 0.95 * t) * (1 + 0.7 * pow(max(0, 1 - t * 12), 2))
        }, segments: 18).displaced { p, n in
            let a = atan2(n.z, n.x)
            return 0.015 * (Procedural.fbm([cos(a) * 4, p.y * 1.5, sin(a) * 4], octaves: 3, seed: seed) - 0.5) + 0.08 * max(0, 0.45 - p.y) * max(0, cos(a * 5 + Float(seed)))
        }
        for _ in 0..<Int(max(0, base - 1.2) * 4) {
            let y = random.uniform(0.8...base), angle = random.uniform(0...2 * .pi)
            let out = SIMD3(cos(angle), random.uniform(-0.5...0.1), sin(angle)) * random.uniform(0.15...0.8)
            wood += .tube([axis(y), axis(y) + out * 0.5, axis(y) + out + [0, -0.05, 0]], radius: { 0.016 * (1 - 0.8 * $0) }, segments: 4)
        }
        var needles = bough(along: { axis(tall - 0.9 + $0) }, length: 0.9, random: &random)
        var y = max(base, 0.6)
        while y < tall - 0.3 {
            let f = (y - base) / (tall - base)
            let length = reach * pow(1 - f, 0.95) * random.uniform(0.75...1.1) + 0.2
            let count = Int(random.uniform(5...6.99)), turn = random.uniform(0...2 * .pi)
            for b in 0..<count {
                let angle = turn + Float(b) / Float(count) * 2 * .pi + random.uniform(-0.3...0.3)
                let out = SIMD3<Float>(cos(angle), 0, sin(angle)), start = axis(y), sag = random.uniform(0.3...0.5) * (1.3 - f)
                func point(_ s: Float) -> SIMD3<Float> { start + out * length * s + SIMD3(0, length * (0.1 * s - sag * s * s + 0.7 * sag * pow(s, 4)), 0) }
                if f < 0.15 { wood += .tube((0...4).map { point(Float($0) / 4) }, radius: { 0.008 + 0.03 * length / reach * (1 - $0) }, segments: 5) }
                needles += bough(along: point, length: length, random: &random)
            }
            y += random.uniform(0.45...0.6) * (1 - 0.35 * f)
        }
        return (needles, wood)
    }

    /// The needles on a branch `length` long: a brush down the twig, and branchlets off both sides
    /// slanting out toward the tip, longest midway, some lying flat and some hanging like a comb.
    static func bough(along point: (Float) -> SIMD3<Float>, length: Float, random: inout SeededRandom) -> Mesh {
        let tangent = simd_normalize(point(1) - point(0))
        let flat = simd_normalize(simd_cross(tangent, abs(tangent.y) > 0.95 ? [1, 0, 0] : [0, 1, 0])), down = simd_cross(tangent, flat)
        var mesh = Mesh.parametric(1, 6) { i, j in point(0.1 + 0.9 * Float(j) / 6) + flat * length * 0.03 * (Float(i) - 0.5) * (1.2 - Float(j) / 6) }
        let count = max(4, Int(length / 0.06))
        for k in 0..<count {
            let s = 0.08 + 0.9 * (Float(k) + random.uniform(0.2...0.8)) / Float(count)
            let reach = min(0.4, length * 0.3) * sin(.pi * pow(s, 0.7)).squareRoot() * random.uniform(0.6...1.1)
            for side: Float in [-1, 1] {
                let hang = random.uniform(-0.3...1.4)
                let out = simd_normalize(tangent * 0.8 + flat * side * cos(hang) + down * sin(hang))
                let across = simd_normalize(tangent - out * simd_dot(tangent, out)), root = point(s)
                // Notched edges read as tufts of needles.
                mesh += .parametric(1, 6) { i, j in
                    let t = Float(j) / 6, tuft: Float = j % 2 == 0 ? 1 : 0.6
                    return root + (out * t + SIMD3(0, -0.15 * t * t, 0)) * reach + across * reach * 0.3 * (Float(i) - 0.5) * (1 - 0.65 * t * t) * tuft
                }
            }
        }
        return mesh
    }

    // MARK: Shading

    static let shader = MetalSource(#"""
    #define HAS_EMISSION
    #define HAS_LIVE
    #define HAS_ATMOSPHERE

    enum : uint { GROUND, GRANITE, PEBBLE, COAL, BARK, SPLIT, END, TRUNK, NEEDLES, CANVAS, CORD, ENAMEL, STEEL, GRASS, FERN, WOOL, LANTERN };
    #define STILL 0u
    #define FIRE 2u
    #define EMBERS 5u
    constant float3 CORE = \#(core.metal);
    constant float3 MOON = \#(moon.metal);
    constant float3 FLAMES[3] = \#(flames.metal);

    // How hot a point is: 1 in the heart of the fire, 0 a little way out of it.
    static float heat(float3 p) { return smoothstep(0.62f, 0.12f, length((p - CORE) * float3(1, 0.65, 1))); }

    // The flame light nearest p, so the glow there flickers with it.
    static uint flameGroup(float3 p) {
        float a = distance_squared(p, FLAMES[0]), b = distance_squared(p, FLAMES[1]), d = distance_squared(p, FLAMES[2]);
        return FIRE + (a < b ? (a < d ? 0 : 2) : (b < d ? 1 : 2));
    }

    // What something glowing at this temperature gives off, brightening steeply as it heats.
    static float3 incandescence(float kelvin) { return blackbody(kelvin) * pow(kelvin / 1000.0f, 6.0f); }

    // A gradient taken in the mesh's own space, turned into the world's.
    static float3 toWorld(float3 g, Hit h, Ctx c) {
        device const float4* m = c.instances[h.instance].inverse;
        return m[0].xyz * g.x + m[1].xyz * g.y + m[2].xyz * g.z;
    }

    // Charcoal crazed into blocks across and along the grain: (F1, F2, block id).
    static float3 crazing(float3 q) { return voronoi(q * float3(55, 32, 55)); }

    // Charred by the flames, and from below wherever wood lies in the bed of coals.
    static float charred(Hit h, Ctx c) { return smoothstep(0.2, 0.55, heat(h.p) + 0.3 * smoothstep(0.55, 0.3, length(h.p.xz)) + 0.35 * (c.fbm(h.local * 7, 2) - 0.5)); }

    // Black char in blocks, dark in the cracks, greyed with ash where it faces up.
    static float3 charcoal(float3 v, float shade, float3 n) {
        float3 block = mix(float3(0.012, 0.011, 0.01), float3(0.08, 0.075, 0.07), v.z * 0.6 + shade * 0.4);
        block = mix(block, float3(0.12, 0.115, 0.11) * (0.6 + 0.6 * v.z), smoothstep(0.55, 0.95, n.y) * smoothstep(0.55, 0.8, v.z) * 0.6);
        return block * (1 - 0.85 * smoothstep(0.08, 0.0, v.y - v.x));
    }

    // MARK: Ground

    // Fallen needles, short strokes strewn every which way: the distance to the nearest, in cells.
    static float needles(float2 p) {
        float2 cell = floor(p);
        float nearest = 1;
        for (int x = -1; x <= 1; x++) for (int y = -1; y <= 1; y++) {
            float2 o = cell + float2(x, y);
            float3 r = hash3(float3(o, 7.1));
            float2 dir = float2(cos(r.z * TAU), sin(r.z * TAU)), d = p - o - r.xy;
            nearest = min(nearest, length(d - dir * clamp(dot(d, dir), -0.8f, 0.8f)));
        }
        return nearest;
    }

    // Dirt under a mat of fallen needles, trodden bare round the fire, scorched near it, then ash.
    static Surface ground(Hit h, Ctx c) {
        float2 g = h.p.xz;
        float r = length(g), broad = c.fbm(float3(g * 0.45f, 0.5), 3);
        float bare = smoothstep(3.0, 1.2, r + 1.2 * (broad - 0.5)), ash = smoothstep(0.62, 0.45, r + 0.12 * (broad - 0.5));
        float3 matted = float3(0.1, 0.06, 0.034), dirt = float3(0.06, 0.045, 0.032);
        if (h.bounce > 0) return material(mix(mix(matted, dirt, bare), float3(0.1, 0.095, 0.09), ash), 0.95, h.n);
        float4 fine = c.fbmd(float3(g * 16, 3.5), 3);
        float cover = saturate(0.9 - 0.8 * bare + 0.6 * (broad - 0.5));
        float4 scuffs = c.fbmd(float3(g * 4, 6.5), 2);
        dirt *= mix(0.55, 1.4, smoothstep(0.25, 0.75, c.fbm(float3(g * 2.2f, 9.5), 3))) * (0.85 + 0.3 * scuffs.x);
        float3 color = mix(dirt * (0.7 + 0.6 * fine.x), matted * (0.6 + 0.8 * c.noise(float3(g * 9, 1.5))), cover * 0.85);
        float nearest = min(needles(g * 22), needles(g * 15 + 17.3f) * 1.4f), litter = saturate(cover + 0.55) * smoothstep(0.75, 1.1, r);
        color *= 1 - 0.4 * smoothstep(0.16, 0.06, nearest) * litter;
        color = mix(color, float3(0.24, 0.13, 0.06) * (0.6 + 0.7 * fine.x), smoothstep(0.07, 0.025, nearest) * litter);
        float moss = smoothstep(0.55, 0.72, c.fbm(float3(g * 0.9f, 7.5), 3)) * smoothstep(4.0, 6.5, r);
        color = mix(color, float3(0.035, 0.065, 0.022) * (0.6 + 0.8 * fine.x), moss * 0.8);
        float3 grit = voronoi(g * 70);
        float speck = smoothstep(0.22, 0.12, grit.x);
        color = mix(color, float3(0.24, 0.22, 0.2) * (0.6 + 0.8 * grit.z), speck * step(0.78, grit.z) * (0.3 + 0.7 * bare));
        color = mix(color, float3(0.012), speck * step(grit.z, 0.3) * smoothstep(2.4, 0.8, r));
        color *= 1 - 0.65 * smoothstep(1.2, 0.6, r + 0.25 * (fine.x - 0.5));
        float3 soft = mix(float3(0.02, 0.019, 0.018), float3(0.13, 0.125, 0.12), smoothstep(0.3, 0.75, c.fbm(float3(g * 7, 2.5), 3))) * (0.8 + 0.4 * fine.x) * mix(0.4, 1.0, smoothstep(0.2, 0.5, r));
        color = mix(color, soft, ash);
        Surface s = material(color, 0.95, h.n);
        s.normal = bump(h.n, float3(fine.y, 0, fine.z) * 16 * 0.004 + float3(scuffs.y, 0, scuffs.z) * 4 * 0.012 * bare, 1);
        return s;
    }

    // MARK: Stone

    // Speckled granite: crusts of lichen on top, moss low on the shaded side, soot facing the fire.
    static Surface granite(Hit h, Ctx c) {
        float sooted = smoothstep(0.9, 0.55, length(h.p.xz)) * saturate(0.25 - 1.2 * dot(normalize(float3(h.p.x, 0, h.p.z)), h.n));
        if (h.bounce > 0) return material(float3(0.24, 0.23, 0.22) * (1 - 0.8 * sooted), 0.8, h.n);
        float4 n = c.fbmd(h.p * 9, 4);
        float3 color = mix(float3(0.3, 0.29, 0.28), float3(0.47, 0.43, 0.41), smoothstep(0.55, 0.75, noise(h.p * 90 + 3.1)));
        color = mix(color, float3(0.04, 0.04, 0.045), smoothstep(0.62, 0.72, noise(h.p * 190)));
        color *= 0.6 + 0.65 * n.x;
        float3 cells = voronoi(h.p * 22);
        float lichen = smoothstep(0.5, 0.25, cells.x) * step(0.45, cells.z) * smoothstep(0.45, 0.6, c.fbm(h.p * 3 + 7, 3)) * smoothstep(0.0, 0.7, h.n.y);
        color = mix(color, mix(float3(0.42, 0.44, 0.33), float3(0.5, 0.28, 0.08), step(0.93, cells.z)), lichen * 0.85);
        float moss = smoothstep(0.55, 0.7, c.fbm(h.p * 5 + 2, 3)) * smoothstep(0.3, -0.2, h.n.y) * (1 - sooted);
        color = mix(color, float3(0.035, 0.06, 0.02), moss * 0.8);
        color *= 1 - 0.9 * sooted * (0.6 + 0.4 * c.noise(h.p * 25));
        Surface s = material(color, mix(0.6, 0.9, max(lichen, moss)), h.n);
        s.normal = bump(h.n, n.yzw * 9, 0.004);
        return s;
    }

    // Charcoal, greyed with ash on top and out toward the edge of the bed.
    static Surface coal(Hit h, Ctx c) {
        if (h.bounce > 0) return material(float3(0.04), 0.9, h.n);
        float3 v = voronoi(h.p * 45);
        float ashen = smoothstep(0.2, 0.9, h.n.y) * smoothstep(0.4, 0.7, c.noise(h.p * 30)) * smoothstep(0.1, 0.45, length(h.p.xz));
        return material(mix(charcoal(v, 0.3, h.n), float3(0.09, 0.087, 0.084), ashen), 0.85, h.n);
    }

    // MARK: Wood

    // A crack (or crevice, or fissure) `width` meters across where noise `n` (value and gradient,
    // sampled at q * scale) crosses its middle value. x: 1 in the crack, 0 clear of it; yzw: the
    // slope, in the mesh's space, of a surface `depth` meters deep there.
    static float4 crack(float4 n, float3 scale, float width, float depth) {
        float3 g = n.yzw * scale;
        float t = saturate(abs(n.x - 0.5f) / max(length(g), 1e-4f) / width);
        return float4(1 - t * t * (3 - 2 * t), sign(n.x - 0.5f) * g / max(length(g), 1e-4f) * depth * 6 * t * (1 - t) / width);
    }

    // Bark in deep furrows along the grain, charring to black where it burns; on the old seat log,
    // greyed and grown with moss on top.
    static Surface bark(Hit h, Ctx c) {
        float3 q = h.local + copyOffset(h);
        float burnt = charred(h, c), old = smoothstep(0.1, 0.15, length(h.local.xz));
        if (h.bounce > 0) return material(mix(float3(0.08, 0.062, 0.046), float3(0.03), burnt), 0.9, h.n);
        const float3 coarse = float3(40, 0.9, 40), fine = float3(95, 2, 95);
        float4 deep = crack(c.noised(q * coarse + c.noise(q * float3(6, 0.8, 6)) * 0.8f), coarse, 0.004, 0.007);
        float4 shallow = crack(c.noised(q * fine + 5.1f), fine, 0.0015, 0.0025);
        float4 furrow = float4(max(deep.x, shallow.x * 0.7f), deep.yzw + shallow.yzw);
        float3 plate = mix(float3(0.12, 0.09, 0.068), float3(0.13, 0.12, 0.11), old) * (0.6 + 0.7 * c.fbm(q * float3(30, 4, 30), 3));
        float3 color = mix(plate, float3(0.008, 0.006, 0.005), furrow.x);
        color = mix(color, float3(0.24, 0.25, 0.2), smoothstep(0.72, 0.8, c.noise(q * 14 + 5)) * 0.4 * (1 - old));
        float moss = old * smoothstep(0.35, 0.85, h.n.y) * smoothstep(0.42, 0.62, c.fbm(q * 6, 4));
        color = mix(color, float3(0.045, 0.075, 0.02) * (0.5 + 0.9 * c.noise(q * 90)), moss);
        color = mix(color, charcoal(crazing(h.local), 1 - furrow.x, h.n), burnt);
        Surface s = material(color, mix(0.85, 0.7, burnt), h.n);
        s.normal = bump(h.n, toWorld(furrow.yzw * (1 - moss), h, c), 1);
        return s;
    }

    // Split faces: pale, torn wood, cracked along the grain and greying where it's weathered.
    static Surface split(Hit h, Ctx c) {
        float3 q = h.local + copyOffset(h);
        float burnt = charred(h, c);
        if (h.bounce > 0) return material(mix(float3(0.3, 0.22, 0.14), float3(0.03), burnt), 0.85, h.n);
        const float3 scale = float3(30, 1.2, 30);
        float4 split = crack(c.noised(q * scale), scale, 0.0015, 0.004);
        float fibre = c.noise(q * float3(150, 3, 150));
        float3 color = mix(float3(0.22, 0.15, 0.085), float3(0.42, 0.31, 0.19), fibre) * (0.8 + 0.4 * c.noise(q * float3(20, 1, 20)));
        color = mix(color, color * float3(0.6, 0.6, 0.65), smoothstep(0.4, 0.8, c.fbm(q * 6, 2)));
        color = mix(color, float3(0.02, 0.014, 0.01), split.x);
        color = mix(color, charcoal(crazing(h.local), fibre, h.n), burnt);
        Surface s = material(color, 0.8, h.n);
        s.normal = bump(h.n, toWorld(split.yzw, h, c), 1);
        return s;
    }

    // Sawn ends: growth rings round the heart, split by checks, charred where they burn.
    static Surface end(Hit h, Ctx c) {
        float3 q = h.local;
        float r = length(q.xz), burnt = charred(h, c);
        if (h.bounce > 0) return material(mix(float3(0.32, 0.23, 0.14), float3(0.025), burnt), 0.85, h.n);
        float rings = 0.5 + 0.5 * sin(r * 1400 + 4 * c.noise(q * 30));
        float3 color = mix(float3(0.45, 0.33, 0.2), float3(0.3, 0.2, 0.11), rings) * mix(0.6, 1.0, smoothstep(0.0, 0.02, r));
        float check = smoothstep(0.06, 0.0, abs(c.noise(float3(atan2(q.z, q.x) * 2.5f, copyOffset(h).x, 0.5)) - 0.5)) * smoothstep(0.01, 0.05, r);
        color *= (1 - 0.85 * check) * (0.75 + 0.3 * c.noise(q * 60));
        return material(mix(color, charcoal(crazing(q), 0.2, h.n), burnt), 0.85, h.n);
    }

    // Pine bark: long plates between deep fissures that run mostly up the trunk and break across
    // here and there; lichen low down.
    static Surface trunk(Hit h, Ctx c) {
        if (h.bounce > 0) return material(float3(0.07, 0.052, 0.04), 0.9, h.n);
        float3 q = h.local;
        const float3 along = float3(24, 2.2, 24), across = float3(5, 9, 5);
        float4 wide = crack(c.noised(q * along + c.noise(q * float3(5, 1.2, 5)) - 0.5f), along, 0.02, 0.025);
        float4 thin = crack(c.noised(q * along * 2.2f + 3.7f), along * 2.2f, 0.007, 0.01);
        float4 fissure = float4(max(wide.x, thin.x), wide.yzw + thin.yzw);
        float4 parting = crack(c.noised(q * across + 7.3f), across, 0.006, 0.015) * step(0.5, c.noise(q * 3 + 1.1f));
        float3 plate = mix(float3(0.1, 0.065, 0.045), float3(0.2, 0.15, 0.12), c.noise(q * float3(12, 3, 12))) * (0.6 + 0.6 * c.fbm(q * float3(34, 9, 34), 3));
        float gap = max(fissure.x, parting.x);
        float3 color = mix(plate, float3(0.012, 0.009, 0.007), gap);
        color = mix(color, float3(0.2, 0.23, 0.17), smoothstep(0.62, 0.72, c.fbm(q * 2.5 + 3, 3)) * smoothstep(3.0, 0.4, q.y) * (1 - gap) * 0.6);
        Surface s = material(color, 0.9, h.n);
        s.normal = bump(h.n, toWorld(fissure.yzw + parting.yzw, h, c), 1);
        return s;
    }

    // MARK: Cloth and metal

    // Cotton canvas: a fine weave, seams, weather stains and dirt splashed up the hem.
    static Surface canvas(Hit h, Ctx c) {
        float3 q = h.local, color = float3(0.22, 0.2, 0.13);
        if (h.bounce == 0) {
            float weave = 0.5 + 0.25 * (sin(q.x * 1300 + q.y * 300) + sin((q.y + q.z) * 1300));
            float stain = c.fbm(q * 2.5, 4);
            color = float3(0.25, 0.23, 0.15) * (0.8 + 0.35 * stain) * (0.93 + 0.07 * weave);
            color *= 1 - 0.45 * smoothstep(0.3, 0.0, q.y + 0.1 * (stain - 0.5));
            color *= 1 - 0.3 * smoothstep(0.012, 0.004, min(abs(q.z - 0.35), abs(q.z + 0.35)));
        }
        Surface s = material(color, 0.92, h.n);
        s.translucency = 0.3;
        return s;
    }

    // Speckled enamel, sooted black from the bottom up and chipped.
    static Surface enamel(Hit h, Ctx c) {
        float3 q = h.local;
        float soot = smoothstep(0.07, 0.02, q.y + 0.03 * (c.noise(q * 40) - 0.5));
        if (h.bounce > 0) return material(mix(float3(0.05, 0.07, 0.11), float3(0.02), soot), 0.4, h.n);
        float chip = smoothstep(0.64, 0.66, c.fbm(q * 30, 3));
        float3 color = mix(float3(0.03, 0.05, 0.095), float3(0.45, 0.47, 0.5), step(0.82, noise(q * 600)) * 0.7);
        return material(mix(color, float3(0.02), max(soot, chip)), mix(0.32, 0.8, max(soot, chip)), h.n);
    }

    // Worn steel, bright at the edge, rusting elsewhere.
    static Surface steel(Hit h, Ctx c) {
        float rust = smoothstep(0.5, 0.7, c.fbm(h.local * 40, 3));
        Surface s = material(mix(float3(0.22, 0.21, 0.2), float3(0.1, 0.045, 0.022), rust), mix(0.45, 0.85, rust), h.n);
        s.metallic = 1 - rust;
        return s;
    }

    Surface surface(Hit h, Ctx c) {
        switch (h.material) {
        case GROUND: return ground(h, c);
        case GRANITE: return granite(h, c);
        case PEBBLE: {
            Surface s = granite(h, c);
            s.albedo *= float3(0.45, 0.4, 0.36) * (0.6 + 0.8 * hash(float(h.instance)));
            return s;
        }
        case COAL: return coal(h, c);
        case BARK: return bark(h, c);
        case SPLIT: return split(h, c);
        case END: return end(h, c);
        case TRUNK: return trunk(h, c);
        case NEEDLES: {
            float shade = c.noise(h.local * 1.7 + copyOffset(h));
            Surface s = material(mix(float3(0.022, 0.04, 0.024), float3(0.05, 0.08, 0.035), shade), 0.6, h.n);
            // Light through the needles shows only where the eye sees them; deeper in, it costs bake time.
            s.translucency = h.bounce == 0 ? 0.3 : 0;
            return s;
        }
        case CANVAS: return canvas(h, c);
        case CORD: return material(float3(0.4, 0.35, 0.26) * (0.8 + 0.2 * noise(h.local * 300)), 0.85, h.n);
        case ENAMEL: return enamel(h, c);
        case STEEL: return steel(h, c);
        case GRASS: {
            float tip = saturate(h.local.y / 0.3);
            Surface s = material(mix(float3(0.03, 0.045, 0.02), mix(float3(0.11, 0.13, 0.05), float3(0.24, 0.19, 0.09), hash(float(h.instance))), tip), 0.7, h.n);
            s.translucency = 0.35;
            return s;
        }
        case WOOL: return material(float3(0.16, 0.035, 0.025) * (0.75 + 0.5 * c.noise(h.local * 60)) * (1 - 0.3 * step(0.5, fract(h.local.z * 9))), 0.95, h.n);
        default: {
            float brown = smoothstep(0.55, 0.85, hash(float(h.instance)));
            Surface s = material(mix(float3(0.03, 0.075, 0.022), float3(0.17, 0.1, 0.04), brown) * (0.8 + 0.4 * saturate(length(h.local.xz) * 2)), 0.65, h.n);
            s.translucency = 0.35 * (1 - brown);
            return s;
        }
        }
    }

    // MARK: Glow

    // Glowing cracks in the coals and the ash between them, breathing with the bed; embers crazing
    // the char of the logs, flickering with the flame light nearest them.
    Emission emission(Hit h, Ctx c) {
        if (h.material == LANTERN) return {blackbody(1900) * 12 * (0.3 + smoothstep(0.035, 0.0, abs(h.local.y - 0.065))), STILL};
        if (h.material == COAL) {
            float3 v = voronoi(h.p * 45);
            float hot = smoothstep(0.5, 0.0, length(h.p.xz)), breathe = c.noise(float3(v.z * 40, c.t * 0.45f, 1.3));
            float lit = smoothstep(0.12, 0.0, v.y - v.x) * 0.9 + 0.12;
            return {incandescence(880 + 260 * hot * breathe) * lit * hot * (1 - 0.6 * smoothstep(0.3, 0.9, h.n.y)), EMBERS};
        }
        if (h.material == GROUND) {
            float r = length(h.p.xz);
            if (r > 0.45) return {0, NO_GROUP};
            float3 cells = voronoi(h.p.xz * 30);
            float breathe = c.noise(float3(cells.z * 50, c.t * 0.5f, 7.7));
            return {incandescence(870 + 200 * breathe) * smoothstep(0.25, 0.0, cells.x) * step(0.6, cells.z) * smoothstep(0.45, 0.05, r) * 0.8, EMBERS};
        }
        if (h.material != BARK && h.material != SPLIT && h.material != END) return {0, NO_GROUP};
        float hot = heat(h.p);
        if (hot < 0.55) return {0, NO_GROUP};
        float3 v = crazing(h.local);
        float ember = smoothstep(0.55, 0.95, hot) * (h.material == END ? 1 : charred(h, c));
        float breathe = c.noise(float3(v.z * 37, c.t * 0.6f, 4.1));
        float lit = smoothstep(0.07, 0.0, v.y - v.x) * 1.2 + 0.25 * smoothstep(0.85, 1.0, hot) * c.noise(h.local * 25 + c.t * 0.3f);
        float inward = 0.35 + 0.65 * saturate(dot(h.n, normalize(float3(0, 0.12, 0) - h.p)) + 0.15);
        float patches = smoothstep(0.35, 0.7, c.noise(h.local * 9 + float3(0, c.t * 0.04f, 0)));
        return {incandescence(900 + 330 * ember * breathe) * lit * ember * inward * (0.15 + 0.85 * patches), flameGroup(h.p)};
    }

    // MARK: Sky

    // Stars, the Milky Way, thin cloud drifting past the moon, and the far ridge fringed with pines.
    float3 sky(float3 d, Ctx c) {
        float m = dot(d, MOON), lon = atan2(d.x, -d.z);
        float3 color = mix(float3(0.03, 0.042, 0.075), float3(0.004, 0.006, 0.016), smoothstep(-0.05, 0.6, d.y));
        // The bake needs only the sky's broad light, the forest a dark band.
        if (c.baking) return color * mix(0.15, 1.0, max(smoothstep(0.5, 0.25, abs(lon - atan2(MOON.x, -MOON.z))), smoothstep(0.1, 0.35, d.y)));
        color += float3(0.02, 0.024, 0.032) * pow(saturate(m), 6.0f);
        float band = exp(-pow(dot(d, normalize(float3(0.7, 0.15, -0.65))) / 0.18f, 2.0f));
        color += band * float3(0.08, 0.075, 0.1) * c.fbm(d * 3.5 + 4, 4) * 1.5 * (1 - 0.75 * smoothstep(0.5, 0.7, c.fbm(d * 7 + 9, 4)));
        float3 q = d * 420, cell = floor(q), point = hash3(cell + 1.3);
        float lit = step(0.955 - 0.04 * band, hash(cell));
        float twinkle = 0.7 + 0.3 * c.noise(float3(hash(cell) * 90, c.t * (0.5 + 2 * hash(cell + 2.0f)), 3.3));
        float3 tint = mix(float3(0.7, 0.8, 1.0), float3(1.0, 0.85, 0.7), hash(cell + 5.0f));
        color += tint * smoothstep(0.4, 0.0, length(q - cell - point)) * lit * (0.25 + 3 * pow(hash(cell + 11.0f), 4.0f)) * twinkle * smoothstep(0.0, 0.15, d.y) * (1 - smoothstep(0.97, 0.995, m));
        float2 uv = d.xz / (d.y + 0.12) * 1.4 + float2(c.t * 0.004, c.t * 0.0015);
        float wisp = smoothstep(0.45, 0.85, c.fbm(float3(uv * float2(1, 2.5), 0.3 + c.t * 0.002), 5)) * smoothstep(0.03, 0.2, d.y);
        color = mix(color, float3(0.015, 0.018, 0.026) + float3(0.25, 0.26, 0.3) * pow(saturate(m), 30.0f), wisp * 0.75);
        float3 right = normalize(cross(MOON, float3(0, 1, 0))), up = cross(right, MOON);
        float2 disc = float2(dot(d, right), dot(d, up)) / 0.009f;
        float r2 = dot(disc, disc);
        if (m > 0 && r2 < 1.2) {
            float maria = c.fbm(float3(disc * 1.6, 2.7), 4);
            float3 face = float3(1.0, 0.96, 0.88) * 1.6 * (0.7 + 0.4 * smoothstep(0.35, 0.65, maria)) * pow(saturate(1 - r2), 0.25f);
            color = mix(color, face * (1 - 0.6 * wisp), smoothstep(1.0, 0.9, r2));
        }
        color += float3(0.45, 0.5, 0.65) * (pow(saturate(m), 3000.0f) * 0.25 + pow(saturate(m), 300.0f) * 0.05) * (1 + wisp);
        float crest = 0.03 + 0.06 * c.fbm(float3(lon * 1.3, 0, 3), 4) + 0.006 * (1 - 2 * abs(fract(lon * 80 + 2 * c.noise(float3(lon * 20, 1, 1))) - 0.5)) * c.noise(float3(lon * 40, 2, 2));
        float3 hills = mix(float3(0.005, 0.007, 0.012), float3(0.01, 0.013, 0.022), smoothstep(crest - 0.08, crest, d.y));
        return mix(color, hills, smoothstep(crest + 0.0015, crest - 0.0015, d.y));
    }

    // MARK: Flames

    // The wind: a slow drift that turns and gusts, carrying flames, sparks and smoke alike.
    static float2 wind(float t, Ctx c) {
        return float2(-0.2, 0.05) + (float2(c.noise(float3(t * 0.043f, 1.5, 7.3)), c.noise(float3(t * 0.037f, 4.1, 2.2))) - 0.5f) * float2(0.5, 0.3);
    }

    // Tongues of flame rising between the logs: where each starts (x, z), how tall it can reach
    // and the flame light it burns with.
    constant float4 TONGUES[9] = {
        float4(-0.13, 0.04, 1.2, 0), float4(-0.06, -0.13, 1.0, 0), float4(-0.16, -0.06, 0.85, 0),
        float4(0.12, -0.07, 1.25, 1), float4(0.07, 0.12, 1.0, 1), float4(0.17, 0.05, 0.85, 1),
        float4(0.0, 0.0, 1.4, 2), float4(0.03, -0.05, 1.2, 2), float4(-0.04, 0.07, 1.05, 2)
    };

    // How hot the flames are at p: tongues narrowing as they rise and lean in to the middle, each
    // wavering with a ripple that runs up it, all torn at the edges by turbulence racing upward.
    static float flame(float3 p, thread const float* tall, float2 lean, Ctx c) {
        float y = p.y;
        float2 q = p.xz - lean * y * y;
        float3 w = float3(q.x * 3.5f, y * 2.2f - c.t * 1.9f, q.y * 3.5f);
        q += (float2(c.noise(w), c.noise(w + 17.3f)) - 0.5f) * (0.03f + 0.1f * y);
        float2 ripple = float2(c.noise(float3(1.5, y * 3 - c.t * 2.6f, 0.5)), c.noise(float3(7.5, y * 3 - c.t * 2.6f, 4.5))) - 0.5f;
        float body = -1;
        for (int k = 0; k < 9; k++) {
            float f = y / tall[k];
            if (f > 1.2f) continue;
            float2 axis = TONGUES[k].xy * (1 - 0.75f * saturate(f)) + rot(k * 2.4f) * ripple * 0.16f * f;
            float width = 0.095f * sqrt(tall[k]) * pow(saturate(1 - f), 0.55f) * smoothstep(-0.05f, 0.1f, y) + 0.004f;
            body = max(body, 1 - length(q - axis) / width);
        }
        if (body < -0.7f) return 0;
        float licks = c.fbm(float3(q.x * 9, y * 3.6f - c.t * 3.8f, q.y * 9), 3);
        return saturate(body + (licks - 0.5f) * (0.8f + 1.1f * y) - 0.3f * y);
    }

    // The flames, marched through a box round the fire: they glow by their heat and dim a little
    // what's behind them.
    Live live(float3 ro, float3 rd, float maxDist, Ctx c) {
        float2 span = boxInterval(ro, rd, float3(-0.65, -0.05, -0.5), float3(0.5, 1.7, 0.5));
        span.y = min(span.y, maxDist);
        if (span.x >= span.y) return nothing();
        float4 weights = c.param(0);
        float tall[9];
        for (int k = 0; k < 9; k++) {
            tall[k] = TONGUES[k].z * (0.55f + 0.45f * weights[1 + int(TONGUES[k].w)]) * (0.8f + 0.25f * weights.x)
                      * (0.75f + 0.5f * c.noise(float3(c.t * 1.3f + k * 3.7f, k * 1.9f, 0.5)));
        }
        float2 lean = wind(c.t, c) * 0.4f;
        float glow = 0.6f + 0.4f * weights.x;
        const int steps = 64;
        float dt = (span.y - span.x) / steps, t = span.x + dt * hash(rd * 917.3f);
        Live result = nothing();
        float transmittance = 1;
        for (int i = 0; i < steps && t < span.y; i++, t += dt) {
            float hot = flame(ro + rd * t, tall, lean, c);
            if (hot <= 0.01f) continue;
            if (result.depth == FAR) result.depth = t;
            result.color += transmittance * blackbody(900 + 1100 * hot) * 320 * hot * hot * glow * dt;
            transmittance *= exp(-hot * 2.5f * dt);
        }
        result.alpha = 1 - transmittance;
        // The flames go unhazed, so what's behind them hazes at its own depth.
        result.hazed = true;
        return result;
    }

    // MARK: Sparks and smoke

    // How far the wind carries something over `age` seconds since `born`.
    static float2 drift(float born, float age, Ctx c) {
        float2 sum = 0;
        for (int k = 0; k < 4; k++) sum += wind(born + age * (k + 0.5f) / 4, c);
        return sum * age / 4;
    }

    // Sparks lift off the coals, ride the updraft in widening spirals and cool from yellow to red
    // as they die; the last few are thrown out together whenever a log settles.
    Particle sparks(uint i, Ctx c) {
        const uint count = 130, thrown = 48;
        bool burst = i >= count - thrown;
        float4 settle = c.param(1 + (i & 1));
        float life, age, seed;
        if (burst) {
            seed = settle.y * 7.31f + float(i);
            life = 0.8 + 2.2 * hash(seed + 0.3f);
            age = c.t - settle.x;
        } else {
            life = 1.3 + 2.4 * hash(float(i) + 0.5f);
            float phase = c.t / life + hash(float(i) + 7.3f), cycle = floor(phase);
            age = (phase - cycle) * life;
            seed = float(i) * 3.7f + cycle * 11.3f;
        }
        Particle s = {0, 0, 0, 0, 0, 0};
        if (age < 0 || age > life) return s;
        float f = age / life;
        float3 a = hash3(float3(seed, 3.7, 1.1)), b = hash3(float3(seed, 11.1, 5.3));
        float3 from = burst ? float3(settle.z, 0.12, settle.w) + (a - 0.5f) * 0.1f : float3((a.x - 0.5) * 0.4, 0.1 + 0.25 * a.y, (a.z - 0.5) * 0.4);
        float3 toss = burst ? float3((b.x - 0.5) * 2.2, 1.0 + 2.4 * b.y, (b.z - 0.5) * 2.2) : float3((b.x - 0.5) * 0.4, 0.5 + 1.3 * b.y, (b.z - 0.5) * 0.4);
        float3 lift = float3(0, (burst ? 0.3 : 0.75) * (0.7 + 0.6 * a.x), 0);
        float slowed = exp(-1.6 * age), spin = TAU * a.z + age * (2 + 3 * b.z);
        float3 fall = burst && b.x > 0.6 ? float3(0, -0.5 * age * age, 0) : float3(0);
        s.position = from + lift * age + (toss - lift) * (1 - slowed) / 1.6f + fall;
        s.position.xz += drift(c.t - age, age, c) + float2(cos(spin), sin(spin)) * 0.06f * age;
        s.velocity = lift + (toss - lift) * slowed + float3(wind(c.t, c).x, 0, wind(c.t, c).y) + fall * 2 / max(age, 1e-3f);
        s.size = (0.0035 + 0.004 * a.y) * (burst ? 1.4 : 1);
        s.color = blackbody(2000 - 1050 * f) * 10 * pow(1 - f, 1.5f) * (0.6 + 0.4 * c.noise(float3(seed, age * 9, 0.5))) * (0.7 + 0.3 * c.param(0).x);
        s.alpha = smoothstep(0.0, 0.03, f);
        s.glow = 0.15;
        s.halo = 5;
        s.tail = 1;
        return s;
    }

    // Smoke rolls up off the flames, lit orange from below by them, then greys, spreads and leans
    // away on the wind.
    Particle smoke(uint i, Ctx c) {
        const float life = 9;
        float phase = c.t / life + hash(float(i) + 0.3f), cycle = floor(phase), f = phase - cycle, age = f * life;
        float3 a = hash3(float3(i, cycle, 5.1));
        Particle s;
        s.position = float3((a.x - 0.5) * 0.22, 0.8 + 0.15 * a.y + 0.42 * age * (1 - 0.25 * f), (a.z - 0.5) * 0.22);
        s.position.xz += drift(c.t - age, age, c) * smoothstep(0.0, 3.0, age) + 0.25 * f * (float2(c.noise(float3(a.x * 30, age * 0.25f, 0.5)), c.noise(float3(a.z * 30, age * 0.25f, 4.5))) - 0.5f);
        s.velocity = float3(wind(c.t, c).x, 0.4, wind(c.t, c).y);
        s.size = (0.12 + 0.9 * pow(f, 0.8f)) * (0.7 + 0.6 * a.y);
        s.color = float3(0.2, 0.19, 0.18) * c.light(s.position);
        s.alpha = 0.075 * smoothstep(0.0, 0.1, f) * pow(1 - f, 1.5f);
        s.puff = 1;
        return s;
    }

    // MARK: Air

    // A thin haze over everything, mist lying low in the clearing and filling the valley, drifting.
    static float mist(float3 p, Ctx c) {
        float wisps = c.fbm(float3(p.x * 0.3f + c.t * 0.02f, p.y * 1.2f, p.z * 0.3f - c.t * 0.008f), 2);
        return 0.009 + 0.045 * smoothstep(0.9, -0.5, p.y) * (0.35 + 1.3 * wisps);
    }

    // The mist along a ray in four stretches, each twice as long as the last, lit by the fire, the
    // moon and the sky.
    Atmosphere atmosphere(float3 ro, float3 rd, float dist, Ctx c) {
        float d = min(dist, 70.0f), start = 0;
        float3 light = 0, through = 1;
        for (int k = 1; k <= 4; k++) {
            float end = d * (exp2(float(k)) - 1) / 15, density = mist(ro + rd * (start + end) * 0.5f, c);
            light += through * c.inscatter(ro + rd * start, rd, end - start) * density * 0.8f;
            through *= exp(-density * (end - start));
            start = end;
        }
        return {light, through};
    }
    """#)
}

private extension SeededRandom {
    mutating func uniform(_ range: ClosedRange<Float>) -> Float { Float.random(in: range, using: &self) }
}
