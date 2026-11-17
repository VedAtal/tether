import simd

extension SaverScene {
    static let fireflies = SaverScene(name: "Fireflies", symbol: "ladybug") { Fireflies.world() }
}

/// A meadow at the edge of a forest on a summer night: tall grass gone to seed, wildflowers, ferns
/// and a fallen log under a low moon, mist lying in the grass, and a few hundred fireflies
/// wandering and blinking over it all.
private enum Fireflies {
    enum Group {
        static let moon = 0, sky = 1
    }

    /// Matches the shader's `enum`.
    enum Material: Int {
        case ground, grass, seed, petal, floret, bark, birch, fern, stone, log, heartwood, fungus
    }

    static let eye = SIMD3<Float>(0, 1.05, 0)
    static let moon = simd_normalize(SIMD3<Float>(-0.134, 0.276, -0.952))
    static let moonlight = SIMD3<Float>(0.07, 0.085, 0.12)
    /// The color of a firefly's light.
    static let glow = SIMD3<Float>(0.72, 1, 0.16)
    static let swarm = 520
    /// The fireflies lighting what's around them at any moment: the nearest and brightest.
    static let lamps = 8
    /// The fallen trunk on the right, its broken end toward the eye.
    static let log = (from: SIMD2<Float>(4.3, -3.4), to: SIMD2<Float>(7.9, -8.4), radius: Float(0.34))
    /// Where the old tree on the left stands.
    static let hero = SIMD2<Float>(-8.9, -8.0)
    /// Where fireflies gather: about the log and the old tree.
    static let haunts = [(log.from + log.to) / 2, hero]
    /// Where waves of flashes start from.
    static let waves: [SIMD2<Float>] = [hero, [-6, -70], [14, -14]]

    static func world() -> SaverWorld {
        var world = SaverWorld(camera: .init(eye: eye, target: eye + [0, 0, -10], fieldOfView: 38), shader: shader)
        world.groups = 2
        world.skyGroup = Group.sky
        // One bounce, for the sky's light: what bounces off anything this dark is too faint to see.
        world.look.bounces = 1
        world.look.exposure = 2.9
        world.lights = [.directional(toward: moon, angle: 0.01, color: moonlight, group: Group.moon)]
        addGround(&world)
        addMeadow(&world)
        addFlowers(&world)
        addForest(&world)
        addLog(&world)
        world.particles = [.init(function: "fireflies", count: swarm, blend: .additive)]
        world.update = { time, frame in
            // More sky fill than the sky alone gives, without brightening the sky itself.
            frame.tints[Group.sky] = SIMD3(repeating: 1.7)
            frame.lights = lights(at: Float(time))
        }
        return world
    }

    // MARK: Fireflies

    static func scramble(_ x: UInt32) -> UInt32 {
        var x = x
        x ^= x >> 16
        x &*= 0x7FEB_352D
        x ^= x >> 15
        x &*= 0x846C_A68B
        return x ^ (x >> 16)
    }

    static func random(_ i: UInt32, _ k: UInt32) -> Float { Float(scramble(i &* 0x9E37_79B1 &+ scramble(k)) >> 8) / 16_777_216 }

    /// One flash, `since` seconds after it began.
    static func flash(_ since: Float) -> Float { smoothstep(0, 0.3, since) * (1 - smoothstep(0.5, 1.9, since)) }

    /// Where firefly `i` is at `t` and how brightly it glows, as `firefly` in the shader computes
    /// it: wandering about a home over the meadow, flashing at an uneven pace, and climbing a
    /// little as it flashes.
    static func firefly(_ i: Int, _ t: Float) -> (position: SIMD3<Float>, glow: Float) {
        let n = UInt32(i)
        func r(_ k: UInt32) -> Float { random(n, k) }
        let bearing = -1.05 + 2.15 * r(0), range = 1.8 + 42 * pow(r(1), 1.8)
        var p = SIMD3(range * sin(bearing), 0, -range * cos(bearing))
        // A quarter of them haunt the fallen log and the old tree.
        let haunt = r(15)
        if haunt < 0.25 {
            let spot = haunts[haunt < 0.13 ? 0 : 1] + (SIMD2(r(0), r(1)) - 0.5) * 5
            p.x = spot.x
            p.z = spot.y
        }
        // Those about the old tree rise into its crown.
        p.y = height(p.x, p.z) + 0.3 + (haunt < 0.13 || haunt >= 0.25 ? 1.6 : 5) * r(2) * r(2)
        let slow = SIMD3(r(3), r(4), r(5)) * 0.35 + 0.12, quick = SIMD3(r(6), r(7), r(8)) * 0.6 + 0.3
        let phase = SIMD3(r(9), r(10), r(11)) * 6.2832
        let a = slow * t + phase, b = quick * t + phase * 2.7
        p += SIMD3<Float>(0.7, 0.22, 0.7) * (SIMD3(sin(a.x), sin(a.y), sin(a.z)) * 0.65 + SIMD3(sin(b.x), sin(b.y), sin(b.z)) * 0.35)
        let period = 4 + 4 * r(12), cycle = t / period + r(13), k = cycle.rounded(.down)
        let draw = UInt32(k) * 2, start = 0.05 + 0.4 * random(n ^ 0xB529_7A4D, draw), since = (cycle - k - start) * period
        let on: Float = random(n ^ 0xB529_7A4D, draw + 1) < 0.2 ? 0 : 1
        p.y += on * 0.12 * smoothstep(0, 1.2, since) * (1 - smoothstep(1.2, (1 - start) * period, since))
        // Once every minute and a half, at a random moment, a wave of flashes sweeps the meadow
        // from somewhere along the woods, and most join in as it passes.
        let wave = (t / 90).rounded(.down), origin = waves[Int(random(0, UInt32(wave)) * 3)]
        let swept = t - wave * 90 - 40 * random(1, UInt32(wave)) - simd_distance(SIMD2(p.x, p.z), origin) / 5
        return (p, (0.5 + 0.7 * r(14)) * max(on * flash(since), r(16) < 0.75 ? flash(swept) : 0))
    }

    /// The fireflies that light the grass around them: the brightest for their nearness (all alike
    /// within a few meters, so the light spreads beyond the eye's feet), each fading out as it
    /// drops toward the next one's rank so none switches off with a jump.
    static func lights(at t: Float) -> [SaverFrame.Light] {
        let flies = (0..<swarm).map { firefly($0, t) }
        let scores = flies.map { $0.glow / max(simd_distance_squared($0.position, eye), 9) }
        let order = scores.indices.sorted { scores[$0] > scores[$1] }
        let cutoff = scores[order[lamps]]
        return order.prefix(lamps).compactMap { i in
            guard scores[i] > cutoff else { return nil }
            let fade = min((scores[i] - cutoff) / (0.3 * scores[i]), 1)
            return SaverFrame.Light(position: flies[i].position, radius: 0.03, color: glow * flies[i].glow * fade * 0.05, shadows: true, range: 2)
        }
    }

    // MARK: The land

    /// The lie of the land, as `height` in the shader: gentle swells, rising toward the woods.
    static func height(_ x: Float, _ z: Float) -> Float {
        0.25 * sin(0.12 * x + 0.5) * sin(0.15 * z - 0.3) + 0.1 * sin(0.41 * x - 0.27 * z + 1) + 0.025 * max((x * x + z * z).squareRoot() - 8, 0)
    }

    /// How far the meadow reaches at a bearing (radians right of straight ahead) before the woods:
    /// close on the left, opening far off under the moon, and curving back in on the right.
    static func edge(_ bearing: Float) -> Float {
        let marks: [SIMD2<Float>] = [[-1.6, 20], [-1.0, 22], [-0.7, 25], [-0.5, 36], [-0.32, 80], [-0.15, 135], [0.1, 135], [0.25, 55],
                                     [0.4, 30], [0.7, 21], [1.1, 18], [1.6, 16]]
        let k = min(max(marks.firstIndex { $0.x > bearing } ?? marks.count - 1, 1), marks.count - 1)
        let (a, b) = (marks[k - 1], marks[k])
        return (a.y + (b.y - a.y) * smoothstep(a.x, b.x, bearing)) * (0.88 + 0.24 * Procedural.noise([bearing * 7, 0.5, 0]))
    }

    static func polar(_ p: SIMD2<Float>) -> (bearing: Float, distance: Float) { (atan2(p.x, -p.y), simd_length(p)) }

    /// Ground 280 m across, its cells finest around the eye.
    static func addGround(_ world: inout SaverWorld) {
        let cells = 360
        world.add(.parametric(cells, cells) { i, j in
            let u = Float(j) / Float(cells) * 2 - 1, v = Float(i) / Float(cells) * 1.3 - 0.3
            let x = 140 * u * abs(u), z = -170 * v * abs(v)
            return SIMD3(x, height(x, z) + 0.08 * (Procedural.fbm([x * 0.7, 0, z * 0.7], octaves: 3) - 0.5), z)
        }, material: Material.ground.rawValue)
    }

    // MARK: The meadow

    /// Grass in square tiles on an exact grid, so rays meet few overlapping tiles, scaled up with
    /// distance where single blades are too small to see. It thins into the woods, and tiles
    /// split in four by the log to clear the ground under it.
    static func addMeadow(_ world: inout SaverWorld) {
        let tiles = (0..<8).map { tile(seed: UInt64($0)) }
        var places = [[simd_float4x4]](repeating: [], count: tiles.count)
        var random = SeededRandom(seed: 7)
        func plant(_ p: SIMD2<Float>, size: Float) {
            let clearance = distanceToLog(p) - log.radius
            if size > 1, clearance < size {
                for x: Float in [-0.25, 0.25] {
                    for z: Float in [-0.25, 0.25] { plant(p + [x, z] * size, size: size / 2) }
                }
                return
            }
            let (bearing, distance) = polar(p), inside = edge(bearing) - distance
            guard abs(bearing) < 1.12 + size / max(distance, 1), inside > -size, clearance > size * 0.7,
                  Float.random(in: 0...1, using: &random) < (inside + 2) / 3 else { return }
            let tall = (0.75 + 0.5 * Procedural.noise([p.x * 0.18, 3, p.y * 0.18])) * min(1, 0.55 + inside * 0.1, 0.4 + 0.3 * clearance)
            places[Int.random(in: 0..<tiles.count, using: &random)].append(
                .place([p.x, height(p.x, p.y), p.y], yaw: Float(Int.random(in: 0..<4, using: &random)) * .pi / 2, scale: [size / 2, tall, size / 2]))
        }
        for (size, near, far): (Float, Float, Float) in [(2, 0, 16), (4, 16, 40), (8, 40, 150)] {
            let reach = Int(far / size) + 1
            for gx in -reach..<reach {
                for gz in -reach..<1 {
                    // Offset, so no seam between tiles runs straight away from the eye.
                    let p = (SIMD2(Float(gx), Float(gz)) + [0.31, 0.5]) * size
                    if (near..<far).contains(simd_length(p)) { plant(p, size: size) }
                }
            }
        }
        for (tile, transforms) in zip(tiles, places) {
            world.add(tile.blades, material: Material.grass.rawValue, at: transforms)
            world.add(tile.heads, material: Material.seed.rawValue, at: transforms)
        }
    }

    static func distanceToLog(_ p: SIMD2<Float>) -> Float {
        let axis = log.to - log.from
        return simd_distance(p, log.from + axis * min(max(simd_dot(p - log.from, axis) / simd_length_squared(axis), 0), 1))
    }

    /// A square of meadow 2 m across: tussocks of blades fanning out from their roots, those that
    /// would reach far past its sides leaning back in, and some stalks gone to seed.
    static func tile(seed: UInt64) -> (blades: Mesh, heads: Mesh) {
        var random = SeededRandom(seed: seed)
        func r() -> Float { .random(in: 0..<1, using: &random) }
        var blades = Mesh(), heads = Mesh()
        for _ in 0..<85 {
            let center = SIMD2(r(), r()) * 1.9 - 0.95, size = 0.5 + 0.5 * r()
            for _ in 0..<24 {
                let angle = r() * 2 * .pi, root = center + SIMD2(cos(angle), sin(angle)) * 0.06 * r().squareRoot()
                let shape = blade(height: 0.75 * size * (0.4 + 0.6 * r()), width: 0.006 + 0.006 * r(), lean: 0.08 + 0.45 * r(), droop: 0.2 + r(), twist: (r() - 0.5) * 2)
                var yaw = -angle + (r() - 0.5) * 1.2
                let reach = shape.positions.map(\.x).max() ?? 0, tip = root + SIMD2(cos(yaw), -sin(yaw)) * reach
                if max(abs(tip.x), abs(tip.y)) > 1.2 { yaw += .pi }
                blades += shape.transformed(.translation([root.x, 0, root.y]) * .rotation(yaw, axis: [0, 1, 0]))
            }
            if r() < 0.35 {
                let stalk = seedStalk(height: 0.6 + 0.35 * size + 0.15 * r(), nodding: r() < 0.35, random: &random)
                let place = simd_float4x4.translation([center.x, 0, center.y]) * .rotation(r() * 2 * .pi, axis: [0, 1, 0])
                blades += stalk.stem.transformed(place)
                heads += stalk.head.transformed(place)
            }
        }
        return (blades, heads)
    }

    /// A blade of grass rising from the origin and bowing over toward +x: `lean` its tilt at the
    /// root and `droop` how much further the tip bends, in radians. A crease runs down its middle.
    static func blade(height: Float, width: Float, lean: Float, droop: Float, twist: Float) -> Mesh {
        let segments = 5
        let angles = (0...segments).map { lean + droop * pow(Float($0) / Float(segments), 2) }
        var spine: [SIMD3<Float>] = [[0, -0.04, 0]]
        for k in 1...segments { spine.append(spine[k - 1] + SIMD3(sin(angles[k]), cos(angles[k]), 0) * height / Float(segments)) }
        return .parametric(2, segments) { i, j in
            let t = Float(j) / Float(segments), side = Float(i - 1), half = width * 0.5 * min(1, (1 - t) * 2.5)
            let face = SIMD3(cos(angles[j]), -sin(angles[j]), 0), turn = twist * t
            return spine[j] + (SIMD3(0, 0, cos(turn)) + face * sin(turn)) * side * half + face * (1 - abs(side)) * half * 0.4
        }
    }

    /// A stalk gone to seed, bowing a little: a spike of timothy, or a nodding spray of spikelets.
    static func seedStalk(height: Float, nodding: Bool, random: inout SeededRandom) -> (stem: Mesh, head: Mesh) {
        let bow = Float.random(in: 0.04...0.12, using: &random)
        let path = (0...10).map { k -> SIMD3<Float> in
            let t = Float(k) / 10
            return [bow * t * t, height * t, 0]
        }
        var stem = Mesh.tube(path, radius: { _ in 0.0018 }, segments: 4)
        var head = Mesh()
        let top = path[10]
        if nodding {
            for k in 0..<7 {
                let angle = Float(k) * 2.4, out = SIMD3(cos(angle), 0, sin(angle))
                let bend = (0...4).map { s -> SIMD3<Float> in
                    let f = Float(s) / 4
                    return top + out * 0.035 * f + [0, 0.012 * f - 0.05 * f * f, 0]
                }
                stem += .tube(bend, radius: { _ in 0.0008 }, segments: 3)
                head += .tube([bend[4], bend[4] + out * 0.004 + [0, -0.016, 0]], radius: { 0.0035 * sin(.pi * max($0, 0.1)) }, segments: 5, caps: true)
            }
        } else {
            let spike = (0...6).map { top + SIMD3(0.003, 0.01, 0) * Float($0) }
            head = .tube(spike, radius: { 0.0042 * pow(sin(.pi * max($0, 0.06)), 0.35) }, segments: 7, caps: true)
        }
        return (stem, head)
    }

    /// A leaf `length` long from the origin along +z, its face up, folded a little down its midrib.
    static func leaf(length: Float, width: Float) -> Mesh {
        let widths: [Float] = [0.08, 1, 0.85, 0]
        return .parametric(2, 3) { i, j in
            let side = Float(i - 1), w = widths[j] * width * 0.5
            return [side * w, -abs(side) * w * 0.35 + 0.05 * length * Float(j * j) / 9, Float(j) / 3 * length]
        }
    }

    // MARK: Wildflowers

    /// Ox-eye daisies and umbels of wild carrot standing out of the grass in drifts.
    static func addFlowers(_ world: inout SaverWorld) {
        var random = SeededRandom(seed: 21)
        for (k, flower) in [daisy(), umbel()].enumerated() {
            var places: [simd_float4x4] = []
            for _ in 0..<(k == 0 ? 26 : 18) {
                let drift = SIMD2(Float.random(in: -22...22, using: &random), Float.random(in: -30 ... -2, using: &random))
                guard polar(drift).distance < edge(polar(drift).bearing) - 2 else { continue }
                for _ in 0..<24 {
                    let p = drift + SIMD2(Float.random(in: -1...1, using: &random), Float.random(in: -1...1, using: &random)) * 2.2
                    guard polar(p).distance > 1.2, distanceToLog(p) > 0.5 else { continue }
                    let lean = SIMD3(Float.random(in: -0.15...0.15, using: &random), 1, Float.random(in: -0.15...0.15, using: &random))
                    places.append(.place([p.x, height(p.x, p.y), p.y], up: lean, yaw: .random(in: 0..<2 * .pi, using: &random),
                                         scale: SIMD3(repeating: .random(in: 0.75...1.2, using: &random))))
                }
            }
            world.add(flower.stem, material: Material.grass.rawValue, at: places)
            world.add(flower.petals, material: Material.petal.rawValue, at: places)
            world.add(flower.heart, material: Material.floret.rawValue, at: places)
        }
    }

    static func daisy() -> (stem: Mesh, petals: Mesh, heart: Mesh) {
        let top = SIMD3<Float>(0.03, 0.74, 0)
        let stem = Mesh.tube((0...8).map { SIMD3(top.x * pow(Float($0) / 8, 2), top.y * Float($0) / 8, 0) }, radius: { _ in 0.0022 }, segments: 4)
        var petals = Mesh()
        for k in 0..<21 {
            petals += leaf(length: 0.026, width: 0.007).transformed(.translation(top) * .rotation(Float(k) / 21 * 2 * .pi, axis: [0, 1, 0]) * .rotation(-0.2, axis: [1, 0, 0]))
        }
        return (stem, petals, Mesh.sphere(radius: 0.008, subdivisions: 2).transformed(.translation(top) * .scale([1, 0.55, 1])))
    }

    static func umbel() -> (stem: Mesh, petals: Mesh, heart: Mesh) {
        let top = SIMD3<Float>(-0.02, 0.86, 0.01)
        var stem = Mesh.tube((0...8).map { SIMD3(top.x * pow(Float($0) / 8, 2), top.y * Float($0) / 8, top.z * Float($0) / 8) }, radius: { _ in 0.0026 }, segments: 4)
        var florets = Mesh()
        let floret = Mesh.sphere(radius: 0.0042, subdivisions: 0)
        for k in 0..<16 {
            let angle = Float(k) * 2.4, reach = 0.06 * (Float(k) / 16).squareRoot() + 0.008
            let end = top + SIMD3(reach * cos(angle), 0.03 - reach * 0.3, reach * sin(angle))
            stem += .tube([top, (top + end) / 2 + [0, 0.006, 0], end], radius: { _ in 0.0009 }, segments: 3)
            for s in 0..<7 {
                let a = Float(s) * 2.4
                florets += floret.transformed(.translation(end + SIMD3(cos(a), 0.4, sin(a)) * 0.007 * Float(s).squareRoot()))
            }
        }
        return (stem, florets, Mesh())
    }

    // MARK: The woods

    /// Broadleaf trees all along the meadow's edge, birches among them on the right, thickets and
    /// ferns at their feet, and stones half sunk among them.
    static func addForest(_ world: inout SaverWorld) {
        var random = SeededRandom(seed: 5)
        func scatter(_ count: Int, depth: ClosedRange<Float>, scale: ClosedRange<Float>, variants: Int, bearings: ClosedRange<Float> = -1.5...1.5) -> [[simd_float4x4]] {
            var places = [[simd_float4x4]](repeating: [], count: variants)
            for k in 0..<count {
                let bearing = Float.random(in: bearings, using: &random), distance = edge(bearing) + .random(in: depth, using: &random)
                let p = SIMD2(distance * sin(bearing), -distance * cos(bearing))
                places[k % variants].append(.place([p.x, height(p.x, p.y) - 0.05, p.y], yaw: .random(in: 0..<2 * .pi, using: &random),
                                                   scale: SIMD3(repeating: .random(in: scale, using: &random))))
            }
            return places
        }
        let trees = (0..<5).map { tree(seed: UInt64($0), tall: 15 + 2 * Float($0)) }
        // The near woods, and the far ones under the moon, dense enough that their crowns run together.
        var groves = zip(scatter(170, depth: 0.5...32, scale: 0.8...1.15, variants: trees.count),
                         scatter(100, depth: 0...40, scale: 0.6...1.2, variants: trees.count, bearings: -0.4...0.3)).map(+)
        // One old tree stands out from the woods on the left, its crown reaching over the meadow.
        groves[3].append(.place([hero.x, height(hero.x, hero.y) - 0.05, hero.y], yaw: 2.2, scale: SIMD3(repeating: 1.1)))
        let birches = (0..<2).map { tree(seed: 30 + UInt64($0), tall: 17, girth: 0.011) }
        let stands = scatter(40, depth: -1...6, scale: 0.85...1.1, variants: birches.count, bearings: 0.35...1.3)
        for (tree, places, bark) in zip(trees, groves).map({ ($0, $1, Material.bark) }) + zip(birches, stands).map({ ($0, $1, Material.birch) }) {
            world.add(tree, material: bark.rawValue, at: places)
        }
        let young = (0..<3).map { tree(seed: 20 + UInt64($0), tall: 5, stems: 6) }
        let thickets = zip(scatter(70, depth: -1.5...3, scale: 0.6...1.2, variants: young.count),
                           scatter(60, depth: -1...6, scale: 0.8...1.5, variants: young.count, bearings: -0.4...0.3)).map(+)
        for (tree, places) in zip(young, thickets) {
            world.add(tree, material: Material.bark.rawValue, at: places)
        }
        let ferns = (0..<3).map { fern(seed: UInt64($0)) }
        var beds = scatter(110, depth: -2.5...4, scale: 0.8...1.4, variants: ferns.count)
        for k in 0..<14 {
            let spot = (k < 8 ? hero : log.to) + SIMD2(cos(Float(k) * 2.4), sin(Float(k) * 2.4)) * (1.2 + 0.25 * Float(k % 5))
            beds[k % ferns.count].append(.place([spot.x, height(spot.x, spot.y), spot.y], yaw: Float(k), scale: SIMD3(repeating: 1 + 0.1 * Float(k % 4))))
        }
        for (fern, places) in zip(ferns, beds) {
            world.add(fern, material: Material.fern.rawValue, at: places)
        }
        let stones = (0..<4).map { Mesh.stone(seed: Int32($0), roughness: 0.35) }
        for (stone, places) in zip(stones, scatter(36, depth: -3...3, scale: 0.3...0.9, variants: stones.count)) {
            world.add(stone, material: Material.stone.rawValue, at: places)
        }
    }

    /// A tree's leaf, a unit long from the origin along +z: rounded at the shoulders and folded down
    /// the midrib.
    static let foldedLeaf = Mesh(positions: [[0, 0, 0], [-0.22, -0.06, 0.32], [-0.16, -0.05, 0.72], [0, 0.03, 1], [0.22, -0.06, 0.32], [0.16, -0.05, 0.72]],
                                 indices: [0, 3, 2, 0, 2, 1, 0, 4, 5, 0, 5, 3]).withSmoothNormals()

    /// A broadleaf tree about `tall` meters high, a trunk forking into limbs, branches and twigs; or
    /// with `stems`, a bush of that many rising from the ground. Leaves crowd the twigs, and are the
    /// part without uvs, so one copy of the tree is one instance for rays to cross.
    static func tree(seed: UInt64, tall: Float, stems: Int = 0, girth: Float = 0.022) -> Mesh {
        var random = SeededRandom(seed: seed)
        func r() -> Float { .random(in: 0..<1, using: &random) }
        var mesh = Mesh()
        func grow(_ start: SIMD3<Float>, _ heading: SIMD3<Float>, length: Float, radius: Float, depth: Int) {
            let steps = max(2, Int(length * 1.5))
            var points = [start], direction = heading
            for _ in 0..<steps {
                direction = simd_normalize(direction + SIMD3(r() - 0.5, r() - (depth < 3 ? 0.38 : 0.55), r() - 0.5) * (depth == 0 ? 0.1 : 0.35))
                points.append(points[points.count - 1] + direction * length / Float(steps))
            }
            // Trunks flare into roots where they meet the ground; trunks and limbs are furrowed and lumpy.
            var limb = Mesh.tube(depth < 2 ? refined(points, by: 4) : points, radius: { radius * (1 - 0.55 * $0) * (depth == 0 ? 1 + 0.7 * exp(-$0 * 30) : 1) },
                                 segments: [28, 14, 6, 4, 3][depth])
            if depth < 2 {
                limb = limb.displaced { p, _ in
                    let roots = depth == 0 ? 0.7 * exp(-(p.y + 0.3) * 2.5) * pow(max(sin(atan2(p.z, p.x) * 5 + Float(seed)), 0), 2) : 0
                    return radius * (0.1 * (Procedural.fbm(p * [5, 0.5, 5], octaves: 3) - 0.5) + 0.25 * (Procedural.noise(p * 0.8) - 0.5) + roots)
                }
            }
            mesh += limb
            if depth == 4 {
                for _ in 0..<90 {
                    let along = points[1 + Int(r() * Float(steps - 1))] + SIMD3(r() - 0.5, r() - 0.35, r() - 0.5) * 0.55
                    mesh += foldedLeaf.transformed(.place(along, up: SIMD3(r() - 0.5, 0.7, r() - 0.5), yaw: r() * 2 * .pi,
                                                            scale: SIMD3(repeating: 0.2 + 0.08 * r())))
                }
                return
            }
            let children = depth == 0 ? 5 : 4
            for k in 0..<children {
                // The last carries on from the end, so no branch ends blunt.
                let leader = k == children - 1
                let f = leader ? 1 : depth == 0 ? 0.5 + 0.5 * Float(k) / Float(children) : 0.3 + 0.7 * r()
                let at = points[min(Int(f * Float(steps)), steps)]
                let side = simd_normalize(simd_cross(direction, abs(direction.y) < 0.9 ? [0, 1, 0] : [1, 0, 0]))
                let around = simd_quatf(angle: Float(k) * 2.4 + r(), axis: direction).act(side), tilt = leader ? 0.1 + 0.25 * r() : 0.45 + 0.5 * r()
                grow(at, simd_normalize(direction * cos(tilt) + around * sin(tilt)), length: length * (0.55 + 0.2 * r()),
                     radius: radius * (1 - 0.55 * f) * (leader ? 0.95 : 0.66), depth: depth + 1)
            }
        }
        if stems == 0 {
            grow([0, -0.3, 0], [0, 1, 0], length: tall * 0.42, radius: tall * girth, depth: 0)
        }
        for k in 0..<stems {
            let angle = Float(k) * 2.4, tilt = 0.25 + 0.35 * r()
            grow([0, -0.1, 0], [sin(tilt) * cos(angle), cos(tilt), sin(tilt) * sin(angle)], length: tall * 0.5, radius: tall * 0.008, depth: 2)
        }
        return mesh
    }

    /// The path with `k` points to each of its segments, for detail to displace.
    static func refined(_ points: [SIMD3<Float>], by k: Int) -> [SIMD3<Float>] {
        zip(points, points.dropFirst()).flatMap { a, b in (0..<k).map { a + (b - a) * Float($0) / Float(k) } } + [points[points.count - 1]]
    }

    /// A fern: fronds arching out of one crown, each a stem with leaflets in pairs that shorten
    /// toward its tip.
    static func fern(seed: UInt64) -> Mesh {
        var random = SeededRandom(seed: seed)
        func r() -> Float { .random(in: 0..<1, using: &random) }
        var mesh = Mesh()
        for k in 0..<11 {
            let length = 0.55 + 0.35 * r(), rise = 0.9 + 0.5 * r()
            var spine: [SIMD3<Float>] = [.zero]
            for s in 1...12 {
                let angle = rise - (rise + 0.5) * pow(Float(s) / 12, 1.4)
                spine.append(spine[s - 1] + SIMD3(cos(angle), sin(angle), 0) * length / 12)
            }
            var frond = Mesh.tube(spine, radius: { 0.004 * (1 - 0.7 * $0) }, segments: 4)
            for s in 1..<12 {
                let along = simd_normalize(spine[s + 1] - spine[s - 1]), up = simd_normalize(simd_cross([0, 0, 1], along))
                for sign: Float in [-1, 1] {
                    let out = simd_normalize(SIMD3(0, 0, sign) + along * 0.5)
                    let size = 0.2 * length * pow(sin(.pi * (Float(s) + 1) / 13), 0.7)
                    let frame = simd_float4x4(columns: (SIMD4(simd_cross(up, out), 0), SIMD4(up, 0), SIMD4(out, 0), SIMD4(spine[s], 1)))
                    frond += leaf(length: size, width: size * 0.28).transformed(frame)
                }
            }
            mesh += frond.transformed(.rotation(Float(k) * 2.4 + r(), axis: [0, 1, 0]))
        }
        return mesh
    }

    // MARK: The log

    /// A fallen trunk lying in the grass, mossy along its top, broken off at the end toward the eye,
    /// with brackets of fungus along its side.
    static func addLog(_ world: inout SaverWorld) {
        let r = log.radius
        let a = SIMD3(log.from.x, height(log.from.x, log.from.y) + r * 0.8, log.from.y), b = SIMD3(log.to.x, height(log.to.x, log.to.y) + r * 0.6, log.to.y)
        let length = simd_distance(a, b), place = simd_float4x4.span(from: a, to: b, height: length)
        let bark = Mesh.cylinder(radius: r, height: length, segments: 56, rings: Int(length * 14), caps: false).displaced { p, _ in
            let angle = atan2(p.z, p.x)
            return r * 0.14 * (Procedural.fbm([cos(angle) * 3, p.y * 1.4, sin(angle) * 3], octaves: 4) - 0.5) - r * 0.08 * p.y / length
        }
        // A crown of splinters round the rim, broken back to a sunken heart.
        let broken = Mesh.parametric(6, 72, wrap: true) { i, j in
            let angle = Float(j) / 72 * 2 * .pi
            let splinter = r * (1.6 * pow(Procedural.noise([angle * 6, 1, 0]), 3) + 0.5 * Procedural.noise([angle * 19, 2, 0]))
            let reach: [Float] = [1, 0.9, 0.78, 0.6, 0.4, 0.2, 0], depth = [0, -splinter, -0.3 * splinter, 0.1 * r, 0.25 * r, 0.35 * r, 0.4 * r]
            return [r * reach[i] * cos(angle), depth[i], r * reach[i] * sin(angle)]
        }
        let end = Mesh.lathe([[0, length], [r * 0.95, length]], segments: 40)
        world.add(bark, material: Material.log.rawValue, at: [place])
        world.add(broken + end, material: Material.heartwood.rawValue, at: [place])
        let shelf = Mesh.sphere(radius: 1, subdivisions: 2).transformed(.scale([0.07, 0.016, 0.05]))
        let across = simd_normalize(simd_cross(b - a, [0, 1, 0])), side = simd_dot(across, eye - a) > 0 ? across : -across
        let brackets = (0..<6).map { k -> simd_float4x4 in
            .place(a + (b - a) * (0.3 + 0.08 * Float(k)) + side * r * 0.93 + [0, r * (0.12 * Float(k % 3) - 0.15), 0], yaw: Float(k) * 0.7)
        }
        world.add(shelf, material: Material.fungus.rawValue, at: brackets)
    }

    // MARK: Shading

    static let shader = MetalSource(#"""
    #define HAS_ATMOSPHERE

    enum : uint { GROUND, GRASS, SEED, PETAL, FLORET, BARK, BIRCH, FERN, STONE, LOG, HEARTWOOD, FUNGUS };
    constant float3 MOON = \#(moon.metal);
    constant float3 MOONLIGHT = \#(moonlight.metal);
    constant float3 GLOW = \#(glow.metal);
    constant float2 WAVES[] = \#(waves.metal);
    constant float2 HAUNTS[] = \#(haunts.metal);

    // As Fireflies.height.
    static float height(float2 p) {
        return 0.25f * sin(0.12f * p.x + 0.5f) * sin(0.15f * p.y - 0.3f) + 0.1f * sin(0.41f * p.x - 0.27f * p.y + 1) + 0.025f * max(length(p) - 8, 0.0f);
    }

    // MARK: Surfaces

    // A blade or leaf as dark as `front` lit from the front, glowing with its light from behind.
    static Surface thin(float3 front, float roughness, float translucency, float3 n) {
        Surface s = material(front / (1 - translucency), roughness, n);
        s.translucency = translucency;
        return s;
    }

    // Dark soil under moss and last year's leaves.
    static Surface ground(Hit h, Ctx c) {
        float4 n = detail(float3(h.p.xz * 5, 1.5), h, c, 3);
        float patches = c.fbm(float3(h.p.xz * 0.4f, 6.5), 3);
        float3 color = mix(float3(0.03, 0.025, 0.018), float3(0.07, 0.05, 0.03), n.x);
        color = mix(color, float3(0.03, 0.05, 0.018) * (0.7 + 0.6 * n.x), smoothstep(0.45, 0.6, patches));
        Surface s = material(color, 0.92, h.n);
        s.normal = bump(h.n, float3(n.y, 0, n.z) * 5, 0.012);
        return s;
    }

    // Green at the root, drying to straw toward the tips in drifts across the meadow.
    static Surface grass(Hit h, Ctx c) {
        float tip = saturate(h.local.y / 0.75f);
        float dry = smoothstep(0.35, 0.75, c.noise(float3(h.p.xz * 0.13f, 3.3)) + 0.25f * tip) * smoothstep(0.1, 0.8, tip);
        float3 green = mix(float3(0.03, 0.055, 0.016), float3(0.055, 0.075, 0.02), c.noise(float3(h.p.xz * 0.4f, 7.1)));
        float3 color = mix(green, float3(0.12, 0.1, 0.05), dry) * (0.7 + 0.6 * c.noise(h.local * 41 + copyOffset(h)));
        return thin(color, 0.5, 0.75, h.n);
    }

    static Surface bark(Hit h, Ctx c) {
        float4 n = detail(h.local * float3(7, 1.2, 7), h, c, 3);
        float ridges = 1 - abs(n.x * 2 - 1);
        float3 color = mix(float3(0.012, 0.011, 0.01), float3(0.11, 0.1, 0.085), smoothstep(0.3, 0.85, ridges));
        color = mix(color, float3(0.1, 0.11, 0.08), smoothstep(0.62, 0.72, c.fbm(h.local * 1.5f + 4, 3)) * 0.6);
        Surface s = material(color, 0.88, h.n);
        s.normal = bump(h.n, n.yzw * float3(7, 1.2, 7), 0.025);
        return s;
    }

    // White bark ringed with dark lenticels, black and fissured toward the foot.
    static Surface birch(Hit h, Ctx c) {
        float4 n = detail(h.local * float3(6, 30, 6), h, c, 3);
        float marks = smoothstep(0.62, 0.7, n.x) + smoothstep(1.5, 0.3, h.local.y) * smoothstep(0.35, 0.6, c.noise(h.local * float3(3, 1, 3)));
        float3 color = mix(float3(0.55, 0.53, 0.49) * (0.85 + 0.2 * c.noise(h.local * 9)), float3(0.03, 0.028, 0.026), saturate(marks));
        Surface s = material(color, 0.7, h.n);
        s.normal = bump(h.n, n.yzw * float3(6, 30, 6), 0.002);
        return s;
    }

    // Long fallen: bark sloughed off in patches to silver-grey wood split along the grain, moss along the top.
    static Surface fallen(Hit h, Ctx c) {
        Surface s = bark(h, c);
        float4 grain = detail(h.local * float3(28, 1.5, 28), h, c, 3);
        float bare = smoothstep(0.45, 0.55, c.fbm(h.local * float3(2.5, 0.7, 2.5) + 3, 3));
        float3 wood = float3(0.22, 0.21, 0.19) * (0.55 + 0.7 * grain.x) * (1 - 0.8 * smoothstep(0.62, 0.72, grain.x));
        s.albedo = mix(s.albedo, wood, bare);
        s.normal = mix(s.normal, bump(h.n, grain.yzw * float3(28, 1.5, 28), 0.004), bare);
        float moss = smoothstep(0.35, 0.7, h.n.y + 0.4 * (c.fbm(h.p * 3, 3) - 0.5));
        s.albedo = mix(s.albedo, float3(0.05, 0.08, 0.02) * (0.6 + 0.8 * c.noise(h.p * 40)), moss);
        return s;
    }

    static Surface stone(Hit h, Ctx c) {
        float4 n = detail(h.p * 5, h, c, 3);
        float3 color = float3(0.17, 0.165, 0.155) * (0.6 + 0.7 * n.x) * mix(0.6, 1.3, c.noise(h.p * 60));
        float moss = smoothstep(0.55, 0.7, c.fbm(h.p * 3 + 7, 3) + 0.3 * h.n.y);
        color = mix(color, float3(0.05, 0.08, 0.02), moss);
        Surface s = material(color, mix(0.7, 0.92, moss), h.n);
        s.normal = bump(h.n, n.yzw * 5, 0.008);
        return s;
    }

    Surface surface(Hit h, Ctx c) {
        // Black past the first hit, which spares a shadow ray there (see look.bounces).
        if (h.bounce > 0) return material(0, 0.1, h.n);
        // A tree's leaves are the part of its mesh without uvs.
        if ((h.material == BARK || h.material == BIRCH) && all(h.uv == 0)) return material(float3(0.025, 0.045, 0.018) * (0.6 + 0.8 * c.noise(h.p * 2.3f)), 0.45, h.n);
        switch (h.material) {
        case GROUND: return ground(h, c);
        case GRASS: return grass(h, c);
        case SEED: {
            float4 n = detail(h.local * 900, h, c, 3);
            Surface s = thin(float3(0.3, 0.27, 0.2) * (0.5 + 0.9 * n.x), 0.7, 0.5, h.n);
            s.normal = bump(h.n, n.yzw * 900, 0.0006);
            return s;
        }
        case PETAL: return thin(mix(float3(0.5, 0.5, 0.47), float3(0.44, 0.36, 0.48), step(0.8, hash(float(h.instance)))), 0.55, 0.4, h.n);
        case FLORET: return material(float3(0.55, 0.38, 0.05), 0.7, h.n);
        case BARK: return bark(h, c);
        case BIRCH: return birch(h, c);
        case FERN: return thin(float3(0.03, 0.065, 0.02) * (0.7 + 0.6 * c.noise(h.p * 3)), 0.55, 0.7, h.n);
        case STONE: return stone(h, c);
        case LOG: return fallen(h, c);
        case HEARTWOOD: return material(float3(0.24, 0.17, 0.1) * (0.6 + 0.6 * c.noise(h.local * float3(40, 4, 40))), 0.85, h.n);
        default: return material(float3(0.45, 0.38, 0.27) * (0.8 + 0.3 * c.noise(h.p * 80)), 0.6, h.n);
        }
    }

    // MARK: Sky

    // A clear summer night: deep blue overhead, paler toward the horizon and the moon, stars, and
    // thin streaks of cloud drifting past the moon, silvered near it.
    float3 sky(float3 d, Ctx c) {
        float m = dot(d, MOON), glow = pow(saturate(m * 0.5f + 0.5f), 10.0f);
        float3 color = mix(float3(0.04, 0.062, 0.1), float3(0.004, 0.008, 0.028), smoothstep(-0.02, 0.6, d.y)) + float3(0.05, 0.06, 0.075) * glow;
        float3 q = d * 380, cell = floor(q), at = hash3(cell + 1.3f);
        float lit = step(0.955, hash(cell)) * smoothstep(0.03, 0.25, d.y) * smoothstep(0.985, 0.9, m);
        float twinkle = 0.7 + 0.3 * sin(c.t * (1 + 3 * hash(cell + 2.0f)) + hash(cell) * 40);
        color += mix(float3(0.7, 0.8, 1.0), float3(1.0, 0.88, 0.75), hash(cell + 5.0f)) * smoothstep(0.35, 0.0, length(q - cell - at)) * lit
                 * (0.15 + 2.5 * pow(hash(cell + 11.0f), 5.0f)) * twinkle;
        color = mix(color, float3(1.0, 0.97, 0.9) * (0.8 + 0.2 * c.fbm((d - MOON) * 900, 3)) * 2.2, smoothstep(0.9999, 0.99993, m));
        float2 deck = d.xz / max(d.y + 0.06f, 0.02f);
        float cloud = smoothstep(0.5, 0.75, c.fbm(float3(deck.x * 0.3f + c.t * 0.004f, 1.7, deck.y * 1.2f), 4)) * smoothstep(0.03, 0.15, d.y);
        color = mix(color, float3(0.02, 0.025, 0.035) + float3(0.3, 0.31, 0.33) * (pow(saturate(m), 80.0f) + 0.2 * glow), cloud * 0.85);
        color += float3(0.5, 0.55, 0.62) * (pow(saturate(m), 3000.0f) * 0.5 + pow(saturate(m), 250.0f) * 0.12 + pow(saturate(m), 30.0f) * 0.03);
        return mix(color, float3(0.004, 0.006, 0.01), smoothstep(0.0, -0.03, d.y));
    }

    // MARK: Fireflies

    static uint scramble(uint x) {
        x ^= x >> 16;
        x *= 0x7FEB352Du;
        x ^= x >> 15;
        x *= 0x846CA68Bu;
        return x ^ (x >> 16);
    }

    static float random(uint i, uint k) { return float(scramble(i * 0x9E3779B1u + scramble(k)) >> 8) / 16777216.0f; }

    struct Firefly {
        float3 position;
        float glow;
    };

    static float flash(float since) { return smoothstep(0.0f, 0.3f, since) * (1 - smoothstep(0.5f, 1.9f, since)); }

    // As Fireflies.firefly, which picks the ones that light the grass.
    static Firefly firefly(uint i, float t) {
        auto r = [&](uint k) { return random(i, k); };
        float bearing = -1.05f + 2.15f * r(0), range = 1.8f + 42 * pow(r(1), 1.8f);
        float3 p = float3(range * sin(bearing), 0, -range * cos(bearing));
        float haunt = r(15);
        if (haunt < 0.25f) p.xz = HAUNTS[haunt < 0.13f ? 0 : 1] + (float2(r(0), r(1)) - 0.5f) * 5;
        p.y = height(p.xz) + 0.3f + (haunt < 0.13f || haunt >= 0.25f ? 1.6f : 5.0f) * r(2) * r(2);
        float3 slow = float3(r(3), r(4), r(5)) * 0.35f + 0.12f, quick = float3(r(6), r(7), r(8)) * 0.6f + 0.3f;
        float3 phase = float3(r(9), r(10), r(11)) * 6.2832f;
        p += float3(0.7, 0.22, 0.7) * (sin(slow * t + phase) * 0.65f + sin(quick * t + phase * 2.7f) * 0.35f);
        float period = 4 + 4 * r(12), cycle = t / period + r(13), k = floor(cycle);
        uint draw = uint(k) * 2;
        float start = 0.05f + 0.4f * random(i ^ 0xB5297A4Du, draw), since = (cycle - k - start) * period;
        float on = random(i ^ 0xB5297A4Du, draw + 1) < 0.2f ? 0 : 1;
        p.y += on * 0.12f * smoothstep(0.0f, 1.2f, since) * (1 - smoothstep(1.2f, (1 - start) * period, since));
        float wave = floor(t / 90);
        float swept = t - wave * 90 - 40 * random(1, uint(wave)) - distance(p.xz, WAVES[int(random(0, uint(wave)) * 3)]) / 5;
        return {p, (0.5f + 0.7f * r(14)) * max(on * flash(since), r(16) < 0.75f ? flash(swept) : 0)};
    }

    // A lantern a few millimeters across, spread over a few pixels at least so far ones keep their
    // light, in a faint haze as wide in the picture however near it is.
    Particle fireflies(uint i, Ctx c) {
        const float size = 0.004f;
        Firefly f = firefly(i, c.t);
        float pixel = distance(f.position, c.eye) * c.pixel, drawn = max(size, 3 * pixel);
        Particle s;
        s.position = f.position;
        s.velocity = (firefly(i, c.t + 0.04f).position - f.position) / 0.04f;
        s.size = drawn;
        s.color = GLOW * f.glow * 24 * (size * size) / (drawn * drawn);
        s.alpha = step(0.001f, f.glow);
        s.halo = 45 * pixel / drawn;
        // The same share of its light in the haze, near or far.
        s.glow = 2.25f / (s.halo * s.halo);
        return s;
    }

    // MARK: Air

    // Mist lying in the grass, thickest low down, in banks that drift slowly across the meadow.
    static float mist(float3 p, Ctx c) {
        float above = p.y - height(p.xz);
        float banks = c.fbm(float3(p.xz * 0.09f + float2(c.t * 0.012f, c.t * 0.004f), p.y * 0.3f + c.t * 0.01f), 2);
        return 0.12f * exp(-max(above, 0.0f) * 2.2f) * smoothstep(0.38f, 0.68f, banks);
    }

    // The mist marched below the top of its layer, and haze thinning with height beyond it.
    Atmosphere atmosphere(float3 ro, float3 rd, float dist, Ctx c) {
        float d = min(dist, 400.0f);
        float3 ambient = (c.ambient(float3(0, 1, 0)) + c.ambient(float3(0, -1, 0))) / (4 * PI);
        float3 lit = MOONLIGHT * mix(1 / (4 * PI), phase(dot(rd, MOON), 0.7f), 0.75f) + ambient;
        const float top = 3.0f;
        float span = rd.y < 0 ? d : (ro.y < top ? min(d, (top - ro.y) / max(rd.y, 1e-4f)) : 0.0f);
        const int steps = 5;
        float jitter = hash(rd * 917.3f), transmittance = 1, glow = 0;
        for (int k = 0; k < steps && span > 0; k++) {
            float u0 = float(k) / steps, u1 = float(k + 1) / steps, s = span * pow((k + jitter) / steps, 2.0f);
            float density = mist(ro + rd * s, c), a = exp(-density * span * (u1 * u1 - u0 * u0));
            glow += transmittance * (1 - a);
            transmittance *= a;
        }
        // Thick enough to set the woods back in layers.
        float haze = exp(-fogDepth(ro, rd, d, 0.009f, 2.86f));
        float3 inscatter = lit * (glow + transmittance * (1 - haze));
        return {inscatter, float3(transmittance * haze)};
    }
    """#)
}
