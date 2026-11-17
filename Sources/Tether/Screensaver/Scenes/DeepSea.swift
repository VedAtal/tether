import simd

extension SaverScene {
    static let deepSea = SaverScene(name: "Deep Sea", symbol: "fish") { DeepSea.world() }
}

/// A reef on the floor of a sunlit sea: rippled sand, boulders crusted with coral and sponges,
/// caustics and shafts of light from the waves overhead, and glowing jellyfish drifting through
/// the snow of the open water.
private enum DeepSea {
    enum Group {
        static let sun = 0, water = 1, glow = 2
    }

    /// Matches the shader's `enum`.
    enum Material: Int {
        case sand, rock, pebble, shell, star, brain, branch, sponge, fan, weed, polyp, anemone
    }

    /// Toward the sun, as bent by the surface.
    static let sun = simd_normalize(SIMD3<Float>(-0.3, 1, -0.45))
    static let sunlight = SIMD3<Float>(0.45, 0.75, 0.78)
    /// The surface's height above the sand.
    static let surface: Float = 12
    static let eye = SIMD3<Float>(0, 1.2, 0)
    static let anemone = SIMD3<Float>(6.4, height([6.4, -4.7]), -4.7)
    static let pink = SIMD3<Float>(1.0, 0.3, 0.72), cyan = SIMD3<Float>(0.25, 0.75, 1.0)

    /// A jellyfish: where it hangs about, its bell's radius, its glow from pink to cyan, and how
    /// often it pulses.
    struct Jelly {
        var home: SIMD3<Float>
        var radius: Float
        var hue: Float
        var rate: Float

        /// Where it is, which way its bell points and how far it's squeezed (0 to 1) at time t: each
        /// quick squeeze and slow release, in a drifting rhythm, drives it on along a wandering path.
        func pose(_ t: Float, seed: Float) -> (position: SIMD3<Float>, axis: SIMD3<Float>, squeeze: Float) {
            let cycle = t * rate + 0.8 * sin(t * 0.043 + seed * 4) + seed, u = cycle - cycle.rounded(.down)
            let squeeze = u < 0.25 ? smoothstep(0, 0.25, u) : 1 - smoothstep(0.25, 1, u)
            let p = t + 0.7 * squeeze, s = seed * 2.3
            let wander = SIMD3<Float>(1.1 * sin(p * 0.071 + s) + 0.3 * sin(p * 0.23 + s * 2), 0.45 * sin(p * 0.053 + s * 3), 0.9 * sin(p * 0.061 + s * 5))
            let heading = SIMD3<Float>(1.1 * 0.071 * cos(p * 0.071 + s), max(0.45 * 0.053 * cos(p * 0.053 + s * 3), 0), 0.3 * 0.061 * cos(p * 0.061 + s * 5))
            return (home + wander, simd_normalize(heading + [0, 0.25, 0]), squeeze)
        }
    }

    static let jellies: [Jelly] = [
        .init(home: [0.9, 2.2, -5.4], radius: 0.34, hue: 0, rate: 0.42), .init(home: [-2.8, 2.9, -10], radius: 0.2, hue: 1, rate: 0.5),
        .init(home: [-7, 4.6, -6.5], radius: 0.22, hue: 0.15, rate: 0.46), .init(home: [9, 2.6, -8.5], radius: 0.2, hue: 0.9, rate: 0.55),
        .init(home: [4.5, 5.5, -15], radius: 0.24, hue: 0.5, rate: 0.45), .init(home: [-1.5, 2.4, -18], radius: 0.18, hue: 1, rate: 0.52),
    ]

    /// The water rocks back and forth along this, and how far it has carried things by t (x) and how
    /// fast it's moving (y).
    static let surgeDirection = SIMD3<Float>(0.944, 0, 0.33)
    static func surge(_ t: Float) -> SIMD2<Float> {
        [0.5 * sin(t * 0.42) + 0.22 * sin(t * 0.97 + 1.3) + 0.1 * sin(t * 1.73 + 4.1),
         0.21 * cos(t * 0.42) + 0.21 * cos(t * 0.97 + 1.3) + 0.17 * cos(t * 1.73 + 4.1)]
    }

    /// The surge over four moments a third apart, from `t` back to `t - span`, for the shader to
    /// fit a curve through.
    static func surges(_ t: Float, span: Float) -> (SIMD4<Float>, SIMD4<Float>) {
        let s = (0..<4).map { surge(t - Float($0) / 3 * span) }
        return (SIMD4(s.map(\.x)), SIMD4(s.map(\.y)))
    }

    /// Where the frame's values sit among the params, after each jellyfish's two.
    enum Param {
        static let sway = 2 * jellies.count, rocking = sway + 2 * kelp.count
    }

    /// Kelp: where each holdfast grips the sand (x, z), and how tall it grows.
    static let kelp: [SIMD3<Float>] = [[-4.6, -5, 11], [-7.5, -8.5, 10.5], [-9.6, -5.6, 11], [-12, -10, 10], [-5.5, -12, 10], [-8, -22, 9.5],
                                       [-10.5, -14, 10], [-16, -13, 9.5],
                                       [7.4, -7, 11], [10.5, -8.5, 10.5], [12, -15, 10], [-1.5, -21, 9], [3, -24, 9.5]]

    static func world() -> SaverWorld {
        var world = SaverWorld(camera: .init(eye: eye, target: [0, 1.6, -10], fieldOfView: 38), shader: shader)
        world.groups = 3
        world.skyGroup = Group.water
        world.look.exposure = 1.45
        world.look.vignette = 0.3
        world.look.bounces = 3
        addSeabed(&world)
        addReefs(&world)
        addLitter(&world)
        addHoldfasts(&world)
        world.lights = [
            .directional(toward: sun, angle: 0.05, color: sunlight, group: Group.sun),
            .sphere(anemone + [0, 0.25, 0], radius: 0.12, color: [0.03, 0.2, 0.15], group: Group.glow),
        ]
        world.particles = [.init(function: "tentacles", count: jellies.count * strands * beads, blend: .additive),
                           .init(function: "snow", count: 9000, blend: .additive)]
        world.update = { time, frame in
            let t = Float(time)
            frame.tints[Group.glow] = SIMD3(repeating: 0.75 + 0.25 * sin(t * 0.7) + 0.15 * Procedural.noise([t * 0.4, 3, 0]))
            // Each kelp sways from its holdfast up, the top a little after the bottom.
            for (i, k) in kelp.enumerated() {
                (frame.params[Param.sway + 2 * i], frame.params[Param.sway + 2 * i + 1]) = surges(t - Float(i) * 3.7, span: k.z * 0.18)
            }
            (frame.params[Param.rocking], frame.params[Param.rocking + 1]) = surges(t, span: 1)
            for (k, jelly) in jellies.enumerated() {
                let pose = jelly.pose(t, seed: Float(k) * 1.37)
                frame.params[2 * k] = SIMD4(pose.position, jelly.radius)
                frame.params[2 * k + 1] = SIMD4(pose.axis.x, pose.axis.z, pose.squeeze, jelly.hue)
                // Its light flares as it squeezes.
                let glow = simd_mix(pink, cyan, SIMD3(repeating: jelly.hue)) * jelly.radius * 8 * (0.7 + 0.6 * pose.squeeze)
                frame.lights.append(.init(position: pose.position + pose.axis * jelly.radius * 0.3, radius: jelly.radius, color: glow, shadows: true, range: jelly.radius * 12))
            }
        }
        return world
    }

    // MARK: The seabed

    static func height(_ p: SIMD2<Float>) -> Float {
        0.6 * Procedural.fbm([p.x * 0.09, 0, p.y * 0.09], octaves: 4) - 0.25
    }

    /// Sand 160 m across in rings round the eye, spaced so that cells look about the same size near and far.
    static func addSeabed(_ world: inout SaverWorld) {
        let (rings, spokes) = (240, 900)
        world.add(.parametric(rings, spokes, wrap: true) { i, j in
            let r = 0.05 * pow(1600, Float(i) / Float(rings)), angle = Float(j) / Float(spokes) * 2 * .pi
            let p = SIMD2(r * cos(angle), -r * sin(angle))
            return SIMD3(p.x, height(p), p.y)
        }, material: Material.sand.rawValue)
    }

    // MARK: Reefs

    /// Outcrops of boulders heaped on each other, crusted with coral, sponges and weed.
    static func addReefs(_ world: inout SaverWorld) {
        let boulders = (0..<6).map(boulder)
        let outcrops: [(center: SIMD2<Float>, size: Float, tall: Float, count: Int, growth: Int)] = [
            ([-1.5, -8.5], 2.1, 2.2, 11, 1700), ([7.2, -6.4], 1.6, 2.3, 8, 600), ([-3.5, -3.4], 1.4, 1.2, 5, 450), ([6.6, -5.3], 0.6, 1.5, 3, 60),
            ([-8.5, -16], 2.8, 1.6, 7, 260), ([7.5, -18], 3, 1.5, 7, 240), ([1, -26], 3.6, 1.8, 7, 120),
            ([-15, -12], 2.6, 1.6, 6, 200), ([14, -11], 2.6, 1.7, 6, 200),
        ]
        var places = [[simd_float4x4]](repeating: [], count: boulders.count)
        var spots: [(position: SIMD3<Float>, normal: SIMD3<Float>)] = []
        for (k, outcrop) in outcrops.enumerated() {
            var random = SeededRandom(seed: UInt64(k + 1))
            var rock = Mesh()
            for i in 0..<outcrop.count {
                // Later boulders are smaller, nearer the middle and higher, so they heap up.
                let f = Float(i) / Float(outcrop.count)
                let angle = Float.random(in: 0..<(2 * .pi), using: &random), reach = outcrop.size * 0.75 * (1 - f) * Float.random(in: 0.3...1, using: &random)
                let p = outcrop.center + SIMD2(cos(angle), sin(angle)) * reach
                let size = outcrop.size * (1.25 - 0.7 * f) * Float.random(in: 0.8...1.1, using: &random)
                let scale = SIMD3<Float>(size * Float.random(in: 0.8...1.2, using: &random), size * outcrop.tall * Float.random(in: 0.7...1.1, using: &random), size)
                let place = simd_float4x4.place([p.x, height(p) + outcrop.size * outcrop.tall * 0.3 * f - 0.08 * size, p.y],
                                                yaw: Float.random(in: 0..<(2 * .pi), using: &random), scale: scale)
                let shape = (k * 3 + i) % boulders.count
                places[shape].append(place)
                rock += boulders[shape].transformed(place)
            }
            spots += rock.scatter(outcrop.growth, seed: UInt64(k + 3))
        }
        for (mesh, transforms) in zip(boulders, places) { world.add(mesh, material: Material.rock.rawValue, at: transforms) }
        addGrowth(&world, on: spots)
    }

    /// A boulder about a unit across: craggy, split by crevices and banded with ledges.
    static func boulder(_ seed: Int) -> Mesh {
        let seed = Int32(seed)
        return Mesh.stone(seed: seed, roughness: 0.5, subdivisions: 6).displaced { p, _ in
            let crag = 1 - abs(Procedural.fbm(p * 3, octaves: 4, seed: seed + 7) * 2 - 1)
            let crack = abs(Procedural.fbm(p * 2.2, octaves: 3, seed: seed + 5) * 2 - 1)
            let ledge = p.y * 9 + 2 * Procedural.fbm(p * 2, octaves: 2, seed: seed + 2)
            return 0.05 * crag * crag - 0.08 * pow(max(0, 1 - crack * 4), 2) + 0.015 * smoothstep(0.3, 0.7, ledge - ledge.rounded(.down))
                + 0.04 * (Procedural.fbm(p * 8, octaves: 3, seed: seed + 9) - 0.5)
        }
    }

    /// Corals on the reef's tops, sponges and weed on its flanks, at its spots.
    static func addGrowth(_ world: inout SaverWorld, on spots: [(position: SIMD3<Float>, normal: SIMD3<Float>)]) {
        let growth: [(meshes: [Mesh], material: Material, size: ClosedRange<Float>, tops: Bool, weight: Float)] = [
            ((0..<3).map { dome(seed: 40 + Int32($0)) }, .brain, 0.25...0.55, true, 2),
            ((0..<3).map { branches(seed: UInt64(10 + $0), length: 0.14, radius: 0.02, forks: 3, spread: 0.5) }, .branch, 0.6...1.2, true, 3),
            ((0..<2).map { branches(seed: UInt64(30 + $0), length: 0.13, radius: 0.007, forks: 7, spread: 0.55, flat: true, segments: 5) }, .fan, 0.9...1.6, true, 1.5),
            ((0..<4).map { spongeCluster(seed: UInt64(20 + $0)) }, .sponge, 0.6...1.1, false, 2),
            ((0..<3).map { branches(seed: UInt64(50 + $0), length: 0.04, radius: 0.006, forks: 4, spread: 0.8, segments: 5) }, .weed, 0.6...1.2, false, 3),
            ([anemoneMesh()], .polyp, 0.8...1.4, false, 1.5),
        ]
        var places = growth.map { [[simd_float4x4]](repeating: [], count: $0.meshes.count) }
        var random = SeededRandom(seed: 7)
        for spot in spots where spot.normal.y > -0.4 {
            let choices = growth.indices.filter { growth[$0].tops == (spot.normal.y > 0.45) }
            var pick = Float.random(in: 0..<choices.reduce(0) { $0 + growth[$1].weight }, using: &random)
            let k = choices.first { pick -= growth[$0].weight; return pick < 0 } ?? choices[0]
            let kind = growth[k], variant = Int.random(in: 0..<kind.meshes.count, using: &random)
            let up = kind.material == .fan ? SIMD3<Float>(0, 1, 0) : simd_normalize(spot.normal * 0.4 + [0, 1, 0])
            // Fans grow across the current, which here runs toward the eye.
            let yaw = kind.material == .fan ? Float.random(in: -0.4...0.4, using: &random) : Float.random(in: 0..<(2 * .pi), using: &random)
            places[k][variant].append(.place(spot.position - up * 0.02, up: up, yaw: yaw, scale: SIMD3(repeating: Float.random(in: kind.size, using: &random))))
        }
        for (kind, transforms) in zip(growth, places) {
            for (mesh, at) in zip(kind.meshes, transforms) { world.add(mesh, material: kind.material.rawValue, at: at) }
        }
        world.add(anemoneMesh(), material: Material.anemone.rawValue, at: [.place(anemone, yaw: 0.3, scale: [2.6, 2.6, 2.6])])
    }

    /// A coral head: a lumpy dome, its lower edge sunk below the origin.
    static func dome(seed: Int32) -> Mesh {
        Mesh.sphere(radius: 0.5, subdivisions: 4).displaced { p, _ in 0.06 * (Procedural.fbm(p * 2.5, octaves: 3, seed: seed) - 0.5) }
            .transformed(.translation([0, -0.12, 0]) * .scale([1, 0.75, 1]))
    }

    /// Branches forking as they grow up from the origin, for coral, a sea fan or a tuft of weed.
    /// `flat` keeps them in the xy plane, as a fan's are.
    static func branches(seed: UInt64, length: Float, radius: Float, forks: Int, spread: Float, flat: Bool = false, segments: Int = 8) -> Mesh {
        var random = SeededRandom(seed: seed)
        var mesh = Mesh()
        func grow(_ start: SIMD3<Float>, _ heading: SIMD3<Float>, _ length: Float, _ radius: Float, _ level: Int) {
            var points = [start], dir = heading
            for _ in 0..<5 {
                var turn = SIMD3<Float>(Float.random(in: -0.2...0.2, using: &random), 0.06, Float.random(in: -0.2...0.2, using: &random))
                if flat { turn.z = 0 }
                dir = simd_normalize(dir + turn)
                points.append(points.last! + dir * length / 5)
            }
            let taper: Float = level == forks ? 0.5 : 0.82
            mesh += .tube(points, radius: { radius * (1 - (1 - taper) * $0) }, segments: segments, caps: level == forks)
            guard level < forks else { return }
            let children = flat || Float.random(in: 0..<1, using: &random) < 0.6 ? 2 : 3
            for c in 0..<children {
                let side = (Float(c) - Float(children - 1) / 2) * spread * Float.random(in: 0.7...1.3, using: &random)
                let axis = flat ? SIMD3<Float>(0, 0, 1) : simd_normalize(simd_cross(dir, [Float.random(in: -1...1, using: &random), 0.2, Float.random(in: -1...1, using: &random)]))
                grow(points.last!, simd_quatf(angle: side, axis: axis).act(dir), length * Float.random(in: 0.7...0.9, using: &random), radius * taper, level + 1)
            }
        }
        grow(.zero, [0, 1, 0], length, radius, 0)
        return mesh
    }

    /// Three to five tube sponges leaning out from one root, each hollow down its middle.
    static func spongeCluster(seed: UInt64) -> Mesh {
        var random = SeededRandom(seed: seed)
        var mesh = Mesh()
        for _ in 0..<Int.random(in: 3...5, using: &random) {
            let (r, h) = (Float.random(in: 0.03...0.05, using: &random), Float.random(in: 0.18...0.5, using: &random))
            let wall = r * 0.18
            let tube = Mesh.lathe([[r * 0.7, 0], [r, h * 0.3], [r * 1.1, h * 0.85], [r * 1.15, h], [r * 1.15 - wall * 0.5, h + wall * 0.4],
                                   [r * 1.15 - wall, h], [r - wall, h * 0.4]], segments: 24).subdivided()
            let lean = SIMD3<Float>(Float.random(in: -0.3...0.3, using: &random), 1, Float.random(in: -0.3...0.3, using: &random))
            let lumpy = tube.displaced { p, _ in 0.012 * (Procedural.fbm(p * 30, octaves: 3, seed: Int32(seed)) - 0.5) * min(p.y * 8, 1) }
            mesh += lumpy.transformed(.place([lean.x, 0, lean.z] * 0.05, up: lean))
        }
        return mesh
    }

    /// An anemone: a squat column and a crown of tentacles curling out from its mouth.
    static func anemoneMesh() -> Mesh {
        var mesh = Mesh.cylinder(radius: 0.04, height: 0.06, segments: 16)
        for k in 0..<36 {
            let angle = Float(k) * 2.39996, ring = 0.008 + 0.03 * (Float(k) / 36).squareRoot()
            let out = SIMD3<Float>(cos(angle), 0, sin(angle))
            let points = (0...5).map { s -> SIMD3<Float> in
                let f = Float(s) / 5
                return [0, 0.06 + 0.07 * f - 0.03 * f * f, 0] + out * (ring + 0.05 * f)
            }
            mesh += .tube(points, radius: { 0.005 * (1 - 0.6 * $0) }, segments: 6, caps: true)
        }
        return mesh
    }

    /// A tangle of root at the foot of each kelp, gripping a few stones.
    static func addHoldfasts(_ world: inout SaverWorld) {
        let clump = (0..<5).reduce(Mesh()) { mesh, i in
            let angle = Float(i) * 1.3
            return mesh + Mesh.stone(seed: 80 + Int32(i), roughness: 0.4, subdivisions: 3).transformed(.place([0.08 * cos(angle), 0, 0.08 * sin(angle)], scale: [0.22, 0.3, 0.22]))
        }
        world.add(clump, material: Material.weed.rawValue, at: kelp.enumerated().map { .place([$1.x, height([$1.x, $1.y]) - 0.02, $1.y], yaw: Float($0) * 2.3) })
    }

    // MARK: Litter on the sand

    /// Shells and pebbles strewn over the sand, thickest near the eye where they can be seen.
    static func addLitter(_ world: inout SaverWorld) {
        let pebbles = (0..<4).map { Mesh.stone(seed: 60 + Int32($0), roughness: 0.25, subdivisions: 2) }
        let shells = [conch(), scallop()]
        var pebblePlaces = [[simd_float4x4]](repeating: [], count: pebbles.count), shellPlaces = [[simd_float4x4]](repeating: [], count: shells.count)
        var random = SeededRandom(seed: 11)
        for i in 0..<700 {
            let angle = Float.random(in: -1.2...1.2, using: &random) - .pi / 2, r = 2.5 + 16 * pow(Float.random(in: 0..<1, using: &random), 2)
            let p = SIMD2(r * cos(angle), r * sin(angle))
            let tilt = SIMD3<Float>(Float.random(in: -0.3...0.3, using: &random), 1, Float.random(in: -0.3...0.3, using: &random))
            let yaw = Float.random(in: 0..<(2 * .pi), using: &random)
            if i % 5 == 0 {
                shellPlaces[i / 5 % shells.count].append(.place([p.x, height(p), p.y], up: tilt, yaw: yaw, scale: SIMD3(repeating: Float.random(in: 0.8...1.6, using: &random))))
            } else {
                let size = Float.random(in: 0.03...0.14, using: &random)
                pebblePlaces[i % pebbles.count].append(.place([p.x, height(p) - 0.02 * size, p.y], up: tilt, yaw: yaw, scale: SIMD3(repeating: size)))
            }
        }
        for (mesh, at) in zip(pebbles, pebblePlaces) { world.add(mesh, material: Material.pebble.rawValue, at: at) }
        for (mesh, at) in zip(shells, shellPlaces) { world.add(mesh, material: Material.shell.rawValue, at: at) }
        let stars: [SIMD2<Float>] = [[0.8, -5], [-0.7, -4.4], [2.3, -5.9], [-3.1, -2.7], [4.4, -4.1], [-1.9, -6.6]]
        world.add(seaStar(), material: Material.star.rawValue,
                  at: stars.enumerated().map { .place([$1.x, height($1) + 0.004, $1.y], yaw: Float($0) * 2.1, scale: SIMD3(repeating: 0.9 + 0.2 * Float($0 % 3))) })
    }

    /// A spiral shell lying on its side, its whorls widening from the tip.
    static func conch() -> Mesh {
        Mesh.parametric(72, 12, wrap: true) { i, j in
            let u = Float(i) / 72 * 4.5 * .pi, v = Float(j) / 12 * 2 * .pi
            let r = 0.0035 * exp(0.17 * u)
            let out = SIMD3<Float>(cos(u), 0, sin(u))
            return out * r * 1.1 + [0, -r * 1.7, 0] + (out * cos(v) + [0, sin(v), 0]) * r * 0.8
        }.transformed(.translation([0, 0.02, 0]) * .rotation(.pi / 2, axis: [1, 0, 0.3]))
    }

    /// A sea star: five plump arms, domed along their middles.
    static func seaStar() -> Mesh {
        Mesh.parametric(10, 90, wrap: true) { i, j in
            let f = Float(i) / 10, angle = Float(j) / 90 * 2 * .pi
            let reach = 0.025 + 0.085 * pow(abs(cos(angle * 2.5)), 2.5)
            return [reach * f * cos(angle), 0.018 * (1 - f * f) * (0.5 + reach * 6), -reach * f * sin(angle)]
        }
    }

    /// A ribbed scallop valve, domed a little.
    static func scallop() -> Mesh {
        Mesh.parametric(14, 36) { i, j in
            let f = Float(i) / 14, a = (Float(j) / 36 - 0.5) * 2.3, r = 0.04 * f
            return [r * sin(a), 0.012 * (1 - f * f) + 0.0015 * f * cos(Float(j) * .pi / 2), r * cos(a)]
        }
    }

    /// Each jellyfish trails this many strands (four oral arms, the rest tentacles), of this many beads.
    static let strands = 14, beads = 150

    // MARK: Shading

    static let shader = MetalSource(#"""
    #define HAS_EMISSION
    #define HAS_GROUP_TINT
    #define HAS_ATMOSPHERE
    #define HAS_LIVE

    enum : uint { SAND, ROCK, PEBBLE, SHELL, STAR, BRAIN, BRANCH, SPONGE, FAN, WEED, POLYP, ANEMONE };
    #define SUN_GROUP \#(Group.sun)u
    #define GLOW_GROUP \#(Group.glow)u
    #define SWAY \#(Param.sway)u
    #define ROCKING \#(Param.rocking)u
    constant float3 SUN = \#(sun.metal);
    constant float3 SUNLIGHT = \#(sunlight.metal);
    constant float SURFACE = \#(surface);
    constant float EYE_DEPTH = \#(surface - eye.y);
    constant float3 PINK = \#(pink.metal), CYAN = \#(cyan.metal);
    #define JELLIES \#(jellies.count)u
    #define STRANDS \#(strands)u
    #define BEADS \#(beads)u
    constant float4 KELP[] = \#(kelp.map { SIMD4($0.x, height([$0.x, $0.y]), $0.y, $0.z) }.metal);
    #define KELP_COUNT \#(kelp.count)u
    // Per meter of clear water: red is gone first, blue last. Silt thickens it near the floor.
    constant float3 EXTINCTION = float3(0.12, 0.052, 0.042);
    constant float SILT = 1.2, SILT_HEIGHT = 1.2;

    // MARK: Surfaces

    // Rippled sand, its troughs collecting dark grit, with patches of silt and broken shell.
    static Surface sand(Hit h, Ctx c) {
        float2 g = h.p.xz;
        float4 grain = detail(h.p * 24, h, c, 2);
        float broad = c.fbm(float3(g * 0.2, 4.5), 4), silt = smoothstep(0.45, 0.7, c.fbm(float3(g * 0.35, 8.5), 3));
        float3 color = mix(float3(0.26, 0.24, 0.19), float3(0.46, 0.43, 0.35), grain.x) * (0.75 + 0.5 * broad);
        color = mix(color, float3(0.15, 0.15, 0.11) * (0.8 + 0.4 * grain.x), silt * 0.7);
        Surface s = material(color, 0.92, h.n);
        if (h.bounce > 0) return s;
        // Crests wander and fork where the long and short warps disagree; the lee faces are steep.
        float4 drift = c.fbmd(float3(g * 0.35, 2.5), 3);
        float2 across = normalize(float2(0.25, 1.0)) * 24;
        float phase = dot(g, across) + 12 * drift.x + 5 * c.fbm(float3(g * 1.6, 6.5), 2), skew = phase + 0.7 * sin(phase);
        float ripple = 0.5 + 0.5 * sin(skew), strength = 0.024 * smoothstep(0.25, 0.55, broad) * (1 - 0.6 * silt);
        float2 slope = 0.5 * cos(skew) * (1 + 0.7 * cos(phase)) * (across + 12 * 0.35 * drift.yw);
        float fleck = smoothstep(0.8, 0.92, c.noise(h.p * 55));
        s.albedo = mix(s.albedo * mix(1.0, 0.55 + 0.45 * ripple, strength / 0.024), float3(0.62, 0.6, 0.55), fleck * 0.45);
        s.normal = bump(h.n, float3(slope.x, 0, slope.y) * strength + grain.yzw * 24 * 0.0015, 1);
        return s;
    }

    // Pitted reef rock crusted with pink coralline algae and orange sponge, a turf of weed on its tops.
    static Surface rock(Hit h, Ctx c) {
        float4 n = detail(h.p * 3, h, c, 5);
        float crust = c.fbm(h.p * 0.9 + 3, 3), turf = smoothstep(0.35, 0.85, h.n.y) * smoothstep(0.42, 0.58, c.fbm(h.p * 1.7 + 11, 3));
        float3 color = float3(0.24, 0.21, 0.17) * (0.35 + 1.3 * n.x);
        color = mix(color, float3(0.6, 0.24, 0.36) * (0.55 + 0.9 * n.x), smoothstep(0.48, 0.58, crust));
        color = mix(color, float3(0.72, 0.2, 0.06) * (0.6 + 0.8 * n.x), smoothstep(0.66, 0.7, c.fbm(h.p * 2.3 + 5, 3)));
        color = mix(color, float3(0.16, 0.18, 0.05) * (0.5 + 1.0 * n.x), turf * 0.9);
        Surface s = material(color, 0.85, h.n);
        if (h.bounce > 0) return s;
        // Mats of little polyps, packed like cobbles.
        float3 polyps = voronoi(h.p * 32);
        float4 grit = c.fbmd(h.p * 25, 2);
        float mat = smoothstep(0.58, 0.64, c.fbm(h.p * 1.3 + 17, 3)) * smoothstep(0.32, 0.2, polyps.x);
        float pore = smoothstep(0.12, 0.04, polyps.x) * step(0.5, polyps.z);
        s.albedo = mix(s.albedo * (0.7 + 0.6 * grit.x) * (1 - 0.6 * pore), mix(float3(0.2, 0.42, 0.14), float3(0.75, 0.42, 0.1), polyps.z) * (0.5 + 0.7 * smoothstep(0.2, 0.0, polyps.x)), mat);
        s.normal = bump(h.n, n.yzw * 3 * 0.05 + grit.yzw * 25 * 0.008, 1);
        return s;
    }

    // Brain coral: parallel ridges wandering into a labyrinth, dark grooves between.
    static Surface brain(Hit h, Ctx c) {
        float4 f = detail(h.local * 3 + copyOffset(h), h, c, 3);
        float phase = (h.local.x + h.local.z) * 200 + 90 * f.x, ridge = sin(phase), tint = hash(float(h.instance) + 0.9f);
        float3 ridges = tint < 0.5 ? float3(0.55, 0.42, 0.22) : float3(0.4, 0.42, 0.22);
        float3 color = ridges * mix(0.5f, 1.0f, smoothstep(-0.5f, 0.5f, ridge));
        Surface s = material(color, 0.75, h.n);
        s.normal = bump(h.n, (float3(200, 0, 200) + 90 * 3 * f.yzw) * cos(phase), 0.0012);
        return s;
    }

    // Branching coral, pale at its growing tips.
    static Surface branch(Hit h, Ctx c) {
        float tint = hash(float(h.instance)), tips = smoothstep(0.25, 0.6, h.local.y);
        float3 base = mix(float3(0.62, 0.45, 0.3), float3(0.45, 0.22, 0.42), step(0.6, tint));
        float3 color = mix(base, float3(0.85, 0.78, 0.65), tips * 0.6) * (0.75 + 0.35 * c.noise(h.local * 90));
        return material(color, 0.7, h.n);
    }

    // Tube sponges, porous outside and dark down their throats.
    static Surface sponge(Hit h, Ctx c) {
        float tint = hash(float(h.instance) + 0.5);
        float3 color = tint < 0.35 ? float3(0.4, 0.28, 0.48) : tint < 0.6 ? float3(0.58, 0.24, 0.08) : tint < 0.8 ? float3(0.52, 0.42, 0.2) : float3(0.34, 0.07, 0.42);
        float4 pores = detail(h.local * 70, h, c, 2);
        Surface s = material(color * (0.7 + 0.5 * pores.x), 0.8, h.n);
        s.normal = bump(h.n, pores.yzw * 70, 0.0012);
        return s;
    }

    Surface surface(Hit h, Ctx c) {
        switch (h.material) {
        case SAND: return sand(h, c);
        case ROCK: return rock(h, c);
        case PEBBLE: return material(mix(float3(0.16, 0.15, 0.14), float3(0.45, 0.4, 0.34), hash(float(h.instance))) * (0.7 + 0.5 * c.noise(h.local * 30)), 0.7, h.n);
        case SHELL: {
            float bands = 0.5 + 0.5 * sin(atan2(h.local.z, h.local.x) * 9 + length(h.local) * 300);
            return material(mix(float3(0.8, 0.72, 0.6), float3(0.55, 0.3, 0.2), bands * 0.6), 0.4, h.n);
        }
        case STAR: {
            // Knobbly, in orange, red or violet.
            float tint = hash(float(h.instance) + 0.4f);
            float3 knobs = voronoi(h.local * 140);
            float3 color = tint < 0.45 ? float3(0.8, 0.28, 0.06) : tint < 0.8 ? float3(0.62, 0.08, 0.1) : float3(0.45, 0.18, 0.5);
            return material(color * (0.6 + 0.5 * smoothstep(0.5, 0.1, knobs.x)), 0.6, h.n);
        }
        case BRAIN: return brain(h, c);
        case BRANCH: return branch(h, c);
        case SPONGE: return sponge(h, c);
        case FAN: {
            float tint = hash(float(h.instance));
            return material(tint < 0.5 ? float3(0.42, 0.04, 0.3) : tint < 0.8 ? float3(0.6, 0.07, 0.08) : float3(0.7, 0.42, 0.05), 0.8, h.n);
        }
        case WEED: return material(hash(float(h.instance)) < 0.5 ? float3(0.42, 0.06, 0.08) : float3(0.15, 0.32, 0.06), 0.85, h.n);
        case POLYP: {
            float tint = hash(float(h.instance) + 0.2f);
            float3 crown = tint < 0.4 ? float3(0.75, 0.3, 0.45) : tint < 0.75 ? float3(0.8, 0.45, 0.12) : float3(0.45, 0.28, 0.65);
            return material(mix(float3(0.3, 0.2, 0.15), crown, smoothstep(0.05, 0.08, h.local.y)) * (0.8 + 0.4 * smoothstep(0.1, 0.13, h.local.y)), 0.6, h.n);
        }
        default: return material(mix(float3(0.5, 0.42, 0.35), float3(0.75, 0.9, 0.85), smoothstep(0.06, 0.12, h.local.y)), 0.6, h.n);
        }
    }

    // MARK: Glow

    // The anemone's tentacle tips glow, and breathe with its light.
    Emission emission(Hit h, Ctx c) {
        if (h.material != ANEMONE) return {0, GLOW_GROUP};
        float tip = smoothstep(0.06, 0.1, length(h.local.xz)) + smoothstep(0.1, 0.12, h.local.y);
        return {float3(0.15, 1.0, 0.7) * saturate(tip) * 2.5, GLOW_GROUP};
    }

    // MARK: Water

    // The water's own glow along d: an abyss below, brightening to teal toward the surface.
    static float3 water(float3 d) {
        float3 color = mix(float3(0.0, 0.002, 0.006), float3(0.001, 0.015, 0.03), smoothstep(-0.7, 0.0, d.y));
        color = mix(color, float3(0.006, 0.065, 0.1), smoothstep(0.0, 0.9, d.y));
        return color * (1 + 1.2 * pow(saturate(dot(d, SUN)), 6.0f));
    }

    // How much of what lies `d` along a ray shows through the water.
    static float3 clarity(float3 ro, float3 rd, float d) {
        if (d >= FAR) return 1;
        d = min(d, 80.0f);
        return exp(-EXTINCTION * (d + fogDepth(ro, rd, d, SILT, SILT_HEIGHT)));
    }

    // Overhead, the surface: Snell's window onto the bright sky, and outside it the waves' underside
    // mirroring the deep, catching glints and brightening toward the window's rim.
    float3 sky(float3 d, Ctx c) {
        float3 color = water(d);
        if (d.y < 0.2) return color;
        float reach = EYE_DEPTH / d.y;
        float2 q = d.xz * reach + c.t * float2(0.05, 0.03);
        float waves = c.fbm(float3(q * 0.35, c.t * 0.1), 3), glints = pow(1 - abs(2 * c.fbm(float3(q * 1.3, c.t * 0.3), 2) - 1), 12.0f);
        float edge = d.y + 0.05 * (waves - 0.5), window = smoothstep(0.64, 0.68, edge);
        float3 above = float3(0.5, 0.85, 1.0) * (1.6 + 2.5 * waves * waves) + float3(1.0, 0.95, 0.8) * 4 * pow(saturate(dot(d, SUN)), 200.0f);
        float3 below = water(float3(d.x, -d.y, d.z)) * 3 + float3(0.1, 0.35, 0.4) * (glints + 2.5 * smoothstep(0.45, 0.66, edge) * waves) * smoothstep(0.3f, 0.55f, d.y);
        return color + mix(below, above, window) * clarity(float3(0, SURFACE - EYE_DEPTH, 0), d, reach);
    }

    // MARK: Caustics

    // Surface waves, as direction times wavenumber, height and how fast each runs.
    constant float4 WAVES[8] = {
        float4(5.6, 2.1, 0.0025, 2.6), float4(-2.4, 6.2, 0.0021, 2.8), float4(4.1, -6.8, 0.0014, 3.1), float4(-8.3, -1.8, 0.0012, 3.2),
        float4(9.1, 5.4, 0.0008, 3.6), float4(1.4, -11.2, 0.0007, 3.7), float4(-11.6, 5.9, 0.0005, 4.0), float4(3.0, 3.6, 0.004, 2.1)
    };

    // Sunlight under the waves: their curvature bends it together toward some points and apart from
    // others, so the floor shows the bright net where it gathers.
    static float caustics(float3 p, Ctx c) {
        float depth = max(SURFACE - p.y, 0.0f), focus = 0.3f * depth;
        float2 q = p.xz + SUN.xz / SUN.y * depth;
        float3 curve = 0;
        for (int i = 0; i < 8; i++) {
            float4 w = WAVES[i];
            curve -= w.z * sin(dot(w.xy, q) - w.w * c.t + i * 1.7f) * float3(w.x * w.x, w.y * w.y, w.x * w.y);
        }
        float spread = (1 + focus * curve.x) * (1 + focus * curve.y) - focus * focus * curve.z * curve.z;
        return 1 / max(abs(spread), 0.1f);
    }

    // The sun's light dances with the caustics wherever it reaches directly, under broad patches
    // of brighter and dimmer water drifting overhead.
    float3 groupTint(uint group, float3 p, Ctx c) {
        float3 tint = c.f->tint[group].rgb;
        if (group != SUN_GROUP) return tint;
        float2 q = p.xz + SUN.xz / SUN.y * (SURFACE - p.y);
        tint *= 0.35f + 1.3f * smoothstep(0.3f, 0.7f, c.fbm(float3(q * 0.06f + c.t * float2(0.004f, 0.003f), c.t * 0.004f), 2));
        float near = smoothstep(45.0f, 10.0f, distance(p, c.eye));
        if (near <= 0 || c.blocked(p + SUN * 0.03f, SUN, SURFACE)) return tint;
        return tint * mix(1.0f, caustics(p, c) * 0.7f, near);
    }

    // MARK: Light shafts

    // Shafts of light hanging from where the waves gather the sun, soft and slowly shifting.
    static float shafts(float3 p, Ctx c) {
        float2 q = p.xz + SUN.xz / SUN.y * (SURFACE - p.y) + c.t * float2(0.06, 0.04);
        float n = 0.65 * c.noise(float3(q * 0.45, c.t * 0.05)) + 0.35 * c.noise(float3(q * 1.4, c.t * 0.09 + 7));
        return pow(n, 7.0f) * 60;
    }

    // Depth haze turning everything blue-green with distance, and light shafts through it.
    Atmosphere atmosphere(float3 ro, float3 rd, float dist, Ctx c) {
        float3 through = clarity(ro, rd, dist);
        float3 inscatter = dist >= FAR ? float3(0) : water(rd) * (1 - through);
        const int steps = 12;
        float reach = min(dist, 35.0f), dt = reach / steps, t = dt * hash(rd * 917.3f);
        float3 beams = 0, fade = pow(clarity(ro, rd, reach), float3(t / reach)), step = pow(clarity(ro, rd, reach), float3(1.0f / steps));
        for (int i = 0; i < steps; i++, t += dt, fade *= step) {
            float3 p = ro + rd * t;
            beams += shafts(p, c) * fade * smoothstep(0.0f, 5.0f, p.y);
        }
        inscatter += beams * dt * SUNLIGHT * phase(dot(rd, SUN), 0.6f) * 0.05f;
        // Each jellyfish's glow, caught by the water round it.
        for (uint i = 0; i < c.f->liveLightCount; i++) {
            LiveLight l = c.f->liveLights[i];
            float s = scatter(l.position.xyz, l.position.w, ro, rd, min(dist, 60.0f), t);
            inscatter += l.color.rgb * s * exp(-EXTINCTION * 1.4f * max(t, 0.0f)) * 0.012f;
        }
        return {inscatter, through};
    }

    // MARK: Live layers

    // What live() finds along a ray: how far, how much it covers, the light it gives on top of its
    // shading, and the surface shaded there.
    struct Layer {
        float t, cover;
        float3 glow;
        Surface s;
    };

    static bool misses(float3 ro, float3 rd, float3 center, float radius) {
        float3 oc = ro - center;
        float b = dot(oc, rd);
        return b * b - dot(oc, oc) + radius * radius <= 0 || b > radius;
    }

    // MARK: Jellyfish

    struct Jelly {
        float3 position, axis, across, along, glow;
        float radius, squeeze;
    };

    static Jelly jelly(uint k, Ctx c) {
        float4 a = c.param(2 * k), b = c.param(2 * k + 1);
        Jelly j;
        j.position = a.xyz;
        j.radius = a.w;
        j.axis = float3(b.x, sqrt(saturate(1 - b.x * b.x - b.y * b.y)), b.y);
        j.across = normalize(cross(j.axis, float3(0, 0, 1)));
        j.along = cross(j.across, j.axis);
        j.squeeze = b.z;
        j.glow = mix(PINK, CYAN, b.w) * (0.75 + 0.5 * b.z);
        return j;
    }

    // The bell's glow at q (its own frame, scaled to its radius, 0 at the rim) and in w how much it
    // hides: a dome thinning to a bright rim, radial canals, and four gonads in its hollow.
    static float4 bell(float3 q, Jelly j) {
        float s = j.squeeze, pinch = 1 - 0.25 * s * (1 - saturate(q.y));
        float2 e = float2(length(q.xz) / ((1 - 0.15 * s) * pinch), q.y / (0.8 + 0.1 * s));
        float angle = atan2(q.z, q.x), lip = -0.05 + 0.03 * sin(angle * 16);
        float shell = smoothstep(1.0, 0.95, length(e)) * smoothstep(0.9, 0.97, length(float2(e.x / 0.93, e.y / 0.78))) * smoothstep(lip - 0.03, lip, e.y);
        float rim = smoothstep(0.2, 0.0, e.y), canals = pow(saturate(cos(angle * 8)), 30.0f) * step(0.05, e.y);
        float spots = smoothstep(0.6, 1.0, cos(angle * 32)) * rim;
        float gonads = smoothstep(0.08, 0.0, abs(e.x - 0.3 - 0.08 * cos(angle * 4))) * smoothstep(0.12, 0.0, abs(e.y - 0.55)) * (0.4 + 0.6 * cos(angle * 4) * cos(angle * 4));
        return float4(j.glow * (shell * (0.08 + 1.6 * rim + 2.5 * spots + 1.5 * canals + 0.25 * e.y) + gonads * 2), shell * 0.15 + gonads * 0.4);
    }

    // A jellyfish's bell, marched through the sphere round it: its glow, and a milky membrane the
    // sun shines through.
    static Layer jellyBell(Jelly j, float3 ro, float3 rd, float maxDist) {
        float3 center = j.position + j.axis * j.radius * 0.35, oc = ro - center;
        float r = j.radius * 1.15, b = dot(oc, rd), disc = b * b - dot(oc, oc) + r * r;
        if (disc <= 0) return {FAR};
        float t0 = max(-b - sqrt(disc), 0.0f), t1 = min(-b + sqrt(disc), maxDist);
        if (t0 >= t1) return {FAR};
        const int steps = 24;
        float dt = (t1 - t0) / steps, t = t0 + dt * hash(rd * 731.7f), through = 1, first = FAR;
        float3 glow = 0;
        for (int i = 0; i < steps; i++, t += dt) {
            float3 p = ro + rd * t - j.position;
            float4 g = bell(float3(dot(p, j.across), dot(p, j.axis), dot(p, j.along)) / j.radius, j);
            if (g.w <= 0.001f) continue;
            first = min(first, t);
            glow += through * g.rgb * dt / j.radius * 5;
            through *= exp(-g.w * dt / j.radius * 3);
        }
        if (first == FAR) return {FAR};
        float3 q = ro + rd * first - j.position, n = normalize(q + j.axis * dot(q, j.axis) * 0.56f);
        Surface s = material(float3(0.75, 0.85, 0.9), 0.3, dot(n, rd) > 0 ? -n : n);
        s.translucency = 0.6;
        return {first, 1 - through, glow, s};
    }

    // MARK: The surge

    constant float3 SURGE = \#(surgeDirection.metal);

    // The curve through four values at 0, 1/3, 2/3 and 1, at f.
    static float cubic(float4 v, float f) {
        float x = f * 3;
        return dot(v, float4(-(x - 1) * (x - 2) * (x - 3) / 6, x * (x - 2) * (x - 3) / 2, -x * (x - 1) * (x - 3) / 2, x * (x - 1) * (x - 2) / 6));
    }

    // How far the surge had carried things (x) and how fast it moved (y), `ago` (0 to 1) of the way
    // back over the moments `surges` gave this param.
    static float2 surge(uint param, float ago, Ctx c) { return float2(cubic(c.param(param), ago), cubic(c.param(param + 1), ago)); }

    // MARK: Kelp

    constant float NODE = 0.4, BLADE = 0.7;

    // Where kelp i's stalk passes at height y: it leans downstream and swings with the surge.
    static float3 stalk(float4 k, uint i, float y, float3 drift, Ctx c) {
        float f = y / k.w;
        return float3(k.x, k.y + y, k.z) + SURGE * f * (0.9f * sqrt(f) * surge(SWAY + 2 * i, f, c).x + 0.8f * f) + drift * f;
    }

    struct Strike {
        float t, cover;
        float3 normal;
        float3 blade;  // for a blade, 1 and where on it (0 to 1 along, -1 to 1 across); 0 for a stalk or bladder
    };

    static void keep(thread Strike& best, float t, float cover, float3 normal, float3 blade = 0) {
        if (cover > 0 && t > 0 && t < best.t) best = {t, cover, normal, blade};
    }

    // The nearest kelp along a ray: a stalk threading gas bladders, each bladder holding up a
    // ruffled blade that streams with the flow and flutters; edges softened over a pixel.
    static Layer kelp(float3 ro, float3 rd, float maxDist, Ctx c) {
        Strike best = {maxDist, 0, 0, 0};
        for (uint i = 0; i < KELP_COUNT; i++) {
            float4 k = KELP[i];
            float seed = float(i) * 3.7f;
            float2 span = boxInterval(ro, rd, float3(k.x - 2.0, k.y, k.z - 1.9), float3(k.x + 2.7, k.y + k.w + 0.8, k.z + 2.2));
            span.y = min(span.y, best.t);
            if (span.x >= span.y) continue;
            // Narrow it to where the ray passes within a blade's reach, plus the stalk's bow, of the
            // line from its holdfast to its top.
            float3 drift = float3(-0.3, 0, 0.4) * sin(c.t * 0.13f + seed);
            float3 axis = normalize(stalk(k, i, k.w, drift, c) - k.xyz);
            float3 lateral = rd - axis * dot(rd, axis), from = ro - k.xyz - axis * dot(ro - k.xyz, axis);
            float a = dot(lateral, lateral), b = dot(from, lateral), disc = b * b - a * (dot(from, from) - 1.45f * 1.45f);
            if (disc <= 0) continue;
            span = float2(max(span.x, (-b - sqrt(disc)) / a), min(span.y, (-b + sqrt(disc)) / a));
            if (span.x >= span.y) continue;
            float y0 = ro.y + rd.y * span.x - k.y, y1 = ro.y + rd.y * span.y - k.y;
            int first = max(int(floor((min(y0, y1) - 0.5f - BLADE * 1.3f) / NODE)), 0), last = min(int(ceil((max(y0, y1) - 0.5f) / NODE)), int((k.w - 0.5f) / NODE));
            for (int n = first; n <= last; n++) {
                float y = 0.5f + n * NODE;
                float3 node = stalk(k, i, y, drift, c), toRoot = node - ro;
                float along = dot(toRoot, rd), off = dot(toRoot, toRoot) - along * along;
                if (off < (NODE + 0.05f) * (NODE + 0.05f)) {
                    float3 a = nearest(ro, rd, node, stalk(k, i, y + NODE, drift, c));
                    keep(best, a.y, saturate((0.009f - a.x) / (a.y * c.pixel) + 0.5f), float3(0));
                }
                if (off > BLADE * BLADE * 1.7f) continue;
                float3 h = hash3(float3(n, seed, 1.3));
                float angle = n * 2.39996f + seed + h.y, extent = BLADE * (0.45f + 0.9f * h.x);
                float3 out = float3(cos(angle), 0, sin(angle));
                float3 up = normalize(out * (0.5f + 0.4f * h.z) + float3(0, 0.95f - 0.9f * h.z * h.z, 0) + SURGE * (0.9f * surge(SWAY + 2 * i, y / k.w, c).y + 0.25f));
                float3 toBladder = toRoot + up * 0.03f;
                float reach = dot(toBladder, rd);
                keep(best, reach, saturate((0.017f - length(toBladder - rd * reach)) / (reach * c.pixel) + 0.5f), normalize(rd * reach - toBladder));
                float3 center = toRoot + up * extent * 0.5f;
                float m = dot(center, rd), bound = extent * 0.5f + 0.11f;
                if (dot(center, center) - m * m > bound * bound) continue;
                float twist = h.x * 6 + 0.5f * sin(c.t * 0.8f + h.x * 20);
                float3 side = normalize(cross(up, out)), across = side * cos(twist) + cross(up, side) * sin(twist), normal = cross(up, across);
                float facing = dot(rd, normal), t = dot(toRoot, normal) / facing;
                float3 q = ro + rd * t - node;
                float u = dot(q, up) / extent, width = (0.05f + 0.04f * h.y) * sin(PI * pow(saturate(u), 0.55f)) * (1 + 0.12f * sin(u * 26 + n));
                float v = dot(q, across);
                if (abs(facing) > 1e-4f) keep(best, t, saturate((width - abs(v)) / (t * c.pixel) + 0.5f) * step(0.0f, u) * step(u, 1.0f), normal, float3(1, u, v / max(width, 1e-4f)));
            }
        }
        if (best.cover <= 0) return {FAR};
        float3 p = ro + rd * best.t, n = all(best.normal == 0) ? -rd : best.normal * -sign(dot(best.normal, rd));
        // Blades darken toward their roots and pucker into ripples across; sunlight through them
        // turns them gold, most at their thin edges.
        float2 on = best.blade.yz;
        float3 color = mix(float3(0.3, 0.18, 0.05), float3(0.95, 0.68, 0.18), on.x) * (0.7 + 0.6 * c.noise(p * 6)) * (0.92 + 0.08 * sin(on.x * 60 + on.y * 2));
        Surface s = material(color, 0.6, n);
        s.translucency = best.blade.x * (0.65f + 0.25f * abs(on.y));
        return {best.t, best.cover, 0, s};
    }

    // MARK: Fish

    // The school swims in ranks a second apart, each following the path the rank ahead took, so
    // every turn sweeps back through it.
    #define RANKS 8u
    #define FILE 7u

    // The school's path: wide, slow loops back and forth through the reef that never quite repeat.
    static float3 school(float t, thread float3& velocity) {
        velocity = float3(11 * 0.029f * cos(t * 0.029f) + 3 * 0.071f * cos(t * 0.071f + 1), 0.8f * 0.047f * cos(t * 0.047f + 2), 2.5f * 0.037f * cos(t * 0.037f + 0.5f));
        return float3(11 * sin(t * 0.029f) + 3 * sin(t * 0.071f + 1), 2.4 + 0.8 * sin(t * 0.047f + 2), -8.5 + 2.5 * sin(t * 0.037f + 0.5f));
    }

    struct Fish {
        float3 position, forward, side, up;
        float length, swim;
    };

    // A rank's place and heading, as a fish at its middle.
    static Fish rank(uint r, float t) {
        Fish f;
        float3 velocity;
        f.position = school(t - float(r), velocity);
        f.forward = normalize(velocity);
        f.side = normalize(cross(f.forward, float3(0, 1, 0)));
        f.up = cross(f.side, f.forward);
        return f;
    }

    // Fish i of a rank, holding its slot in it but weaving a little, and rolling so that its flank
    // now and then mirrors the bright surface.
    static Fish fish(Fish r, uint i, float t) {
        float3 slot = (hash3(float3(i, 2.1, 7.7)) - 0.5f) * float3(0.8, 1.1, 1.8);
        float3 weave = sin(t * float3(0.37, 0.29, 0.31) + float(i) * float3(1, 1.7, 2.3));
        Fish f = r;
        f.position += r.forward * (slot.x + 0.12f * weave.x) + r.up * (slot.y + 0.1f * weave.y) + r.side * (slot.z + 0.15f * weave.z);
        f.forward = normalize(r.forward + r.side * 0.12f * sin(t * 0.6f + float(i) * 2.1f) + r.up * 0.06f * weave.y);
        float roll = 0.35f * sin(t * 0.9f + float(i) * 2.7f);
        f.side = normalize(cross(f.forward, float3(0, 1, 0)));
        f.side = f.side * cos(roll) + cross(f.side, f.forward) * sin(roll);
        f.up = cross(f.side, f.forward);
        f.length = 0.17f + 0.08f * hash(float(i) + 0.3f);
        f.swim = t * (6 + 2 * hash(float(i) + 0.7f)) + float(i);
        return f;
    }

    // A fish's shape in its own frame (x forward, y up, z to its side): deepest behind the head,
    // narrowing to the tail, which sweeps; a forked tail fin and a low dorsal fin.
    static float fishShape(float3 q, Fish f) {
        float x = q.x / f.length;
        q.z -= f.length * 0.12f * (0.5f - x) * (0.5f - x) * sin(f.swim - x * 5);
        float taper = mix(0.3f, 1.0f, smoothstep(-0.48f, 0.1f, x));
        float body = sdEllipsoid(q, f.length * float3(0.5, 0.13 * taper, 0.055 * taper));
        float2 fin = q.xy / f.length + float2(0.44, 0);
        float tail = max(max(sdTriangle(fin, float2(0.06, 0), float2(-0.18, 0.13), float2(-0.18, -0.13)), 0.08f - length(fin + float2(0.22, 0))) * f.length, abs(q.z) - 0.002f);
        float dorsal = max(sdTriangle(q.xy / f.length, float2(0.12, 0.08), float2(-0.2, 0.06), float2(-0.08, 0.17)) * f.length, abs(q.z) - 0.0015f);
        return smin(smin(body, tail, 0.01f * f.length), dorsal, 0.008f * f.length) * 0.8f;
    }

    static float fishAt(float3 p, Fish f) {
        float3 q = p - f.position;
        return fishShape(float3(dot(q, f.forward), dot(q, f.up), dot(q, f.side)), f);
    }

    // The nearest fish of the school along a ray, edges softened over a pixel; countershaded blue
    // over silver, with a yellow stripe, and flashing as its flank turns to the light.
    static Layer fishes(float3 ro, float3 rd, float maxDist, Ctx c) {
        float3 velocity;
        // The whole school lies within a few meters of where it was halfway down the ranks.
        if (misses(ro, rd, school(c.t - (RANKS - 1) * 0.5f, velocity), 3.3f)) return {FAR};
        float bestT = maxDist, cover = 0;
        Fish hit;
        for (uint r = 0; r < RANKS; r++) {
            // The ellipsoid the rank's slots spread over: wide across, shallow along it.
            Fish ranked = rank(r, c.t);
            float3 oc = ro - ranked.position, frame[3] = {ranked.forward / 0.7f, ranked.up / 0.72f, ranked.side / 1.12f};
            float3 o = float3(dot(oc, frame[0]), dot(oc, frame[1]), dot(oc, frame[2])), d = float3(dot(rd, frame[0]), dot(rd, frame[1]), dot(rd, frame[2]));
            float a = dot(d, d), b = dot(o, d);
            if (b * b - a * (dot(o, o) - 1) <= 0 || -b > (bestT + 1.2f) * a) continue;
            for (uint i = r * FILE; i < (r + 1) * FILE; i++) {
                Fish f = fish(ranked, i, c.t);
                oc = ro - f.position;
                float b = dot(oc, rd), radius = f.length * 0.6f, disc = b * b - dot(oc, oc) + radius * radius;
                if (disc <= 0) continue;
                float t = max(-b - sqrt(disc), 0.0f), end = min(-b + sqrt(disc), bestT);
                for (int s = 0; s < 32 && t < end; s++) {
                    float d = fishAt(ro + rd * t, f), edge = d < 1e-4f * t ? 1 : saturate(1 - d / (t * c.pixel));
                    if (edge >= cover && edge > 0) {
                        cover = edge;
                        bestT = t;
                        hit = f;
                        if (edge == 1) break;
                    }
                    t += max(d, 0.002f);
                }
            }
        }
        if (cover <= 0) return {FAR};
        float3 p = ro + rd * bestT;
        float3 n = sdfNormal([&](float3 x) { return fishAt(x, hit); }, p, 0.002f), q = p - hit.position;
        float x = dot(q, hit.forward) / hit.length, y = dot(q, hit.up) / hit.length;
        float back = smoothstep(-0.01f, 0.05f, y);
        float3 color = mix(float3(0.8, 0.84, 0.88), float3(0.06, 0.14, 0.36), back);
        color = mix(color, float3(0.85, 0.65, 0.08), max(smoothstep(0.02f, 0.0f, abs(y - 0.045f)), 0.5f * smoothstep(-0.42f, -0.48f, x)));
        color *= 1 - 0.9f * smoothstep(0.03f, 0.02f, length(float2(x - 0.38f, y - 0.015f)));
        Surface s = material(color, 0.25, n);
        s.metallic = 0.85 * (1 - back);
        // The silver flanks mirror the water round them.
        return {bestT, cover, c.ambient(reflect(rd, n)) / PI * (1 - back) * mix(float3(0.04), color, s.metallic) * cover, s};
    }

    // MARK: All that moves

    // Kelp, the school and each jellyfish, shaded and hazed at its own depth one at a time, so that
    // little is held at once.
    Live live(float3 ro, float3 rd, float maxDist, Ctx c) {
        Live found[JELLIES + 2];
        uint count = 0;
        for (uint kind = 0; kind < JELLIES + 2; kind++) {
            uint k = kind - 2;
            Layer l = kind == 0 ? kelp(ro, rd, maxDist, c) : kind == 1 ? fishes(ro, rd, maxDist, c)
                    : misses(ro, rd, c.param(2 * k).xyz, c.param(2 * k).w * 1.5f) ? Layer{FAR} : jellyBell(jelly(k, c), ro, rd, maxDist);
            if (l.cover <= 0) continue;
            Atmosphere a = atmosphere(ro, rd, l.t, c);
            found[count++] = {(c.shade(ro + rd * l.t, l.s.normal, -rd, l.s) * l.cover + l.glow) * a.transmittance + l.cover * a.inscatter, l.cover, l.t, true};
        }
        if (count == 0) return nothing();
        for (uint i = 1; i < count; i++) {
            for (uint j = i; j > 0 && found[j].depth < found[j - 1].depth; j--) {
                Live l = found[j];
                found[j] = found[j - 1];
                found[j - 1] = l;
            }
        }
        Live result = found[0];
        for (uint i = 1; i < count; i++) result = over(result, found[i]);
        return result;
    }

    // MARK: Particles

    // Where a jellyfish's strand hangs at f (0 root, 1 tip): four frilled oral arms from the middle,
    // then long tentacles from the rim, rippling as waves run down them.
    static float3 strand(Jelly j, uint strand, float f, float seed, Ctx c) {
        bool arm = strand < 4;
        float angle = (float(arm ? strand : strand - 4) + 0.4 * hash(seed)) / (arm ? 4 : STRANDS - 4) * TAU;
        float reach = j.radius * (arm ? 0.1 : 0.92 * (1 - 0.18 * j.squeeze) * (1 - 0.3 * f));
        float length = j.radius * (arm ? 1.6 + 0.6 * hash(seed + 3) : 3 + 4 * hash(seed + 3));
        float3 down = normalize(mix(j.axis, float3(0, 1, 0), f * 0.7));
        float wave = c.t * 1.1 - f * 6 + seed;
        float2 sway = float2(sin(wave), cos(wave * 0.8 + 1.3)) * j.radius * 0.35 * pow(f, 1.3f) + float2(cos(angle), sin(angle)) * reach;
        if (arm) sway += float2(cos(f * 22 + seed - c.t * 0.7), sin(f * 22 + seed - c.t * 0.7)) * j.radius * 0.08 * (0.4 + f);
        return j.position + j.across * sway.x + j.along * sway.y - down * f * length;
    }

    // The strands as beads, each streaked over the shutter to reach the next, so they join into
    // fine glowing threads.
    Particle tentacles(uint i, Ctx c) {
        uint k = i / (STRANDS * BEADS), which = i / BEADS % STRANDS;
        Jelly j = jelly(k, c);
        float f = float(i % BEADS) / BEADS, seed = float(k * STRANDS + which);
        float3 p = strand(j, which, f, seed, c), next = strand(j, which, f + 1.0f / BEADS, seed, c);
        bool arm = which < 4;
        Particle s;
        s.position = (p + next) * 0.5f;
        s.velocity = (next - p) / SHUTTER;
        float fine = arm ? j.radius * 0.03 : 0.0018, size = max(fine, distance(s.position, c.eye) * c.pixel * 0.65f);
        s.size = size;
        s.color = j.glow * (arm ? 0.35 : 1.4) * (1 - 0.85 * f);
        s.alpha = fine / size;
        s.glow = 0.1;
        s.halo = 5;
        return s;
    }

    // Marine snow drifting down, rocking with the surge; denser near the eye.
    Particle snow(uint i, Ctx c) {
        float3 a = hash3(float3(i, 1.7, 3.1)), b = hash3(float3(i, 5.3, 7.9));
        uint layer = i % 3;
        float3 box = layer == 0 ? float3(9, 5, 7) : layer == 1 ? float3(22, 9, 12) : float3(48, 13, 22);
        float3 corner = layer == 0 ? float3(-4.5, 0, -8) : layer == 1 ? float3(-11, 0, -18) : float3(-24, 0, -38);
        float3 sink = float3(0.02, -0.025 - 0.02 * b.x, 0.015);
        float2 rock = surge(ROCKING, b.y, c) * 0.4f;
        float3 cell = fract(a + (sink * c.t + SURGE * rock.x) / box);
        float3 edge = smoothstep(0.0, 0.08, cell) * smoothstep(1.0, 0.92, cell);
        Particle s;
        s.position = corner + cell * box;
        s.velocity = sink + SURGE * rock.y;
        float fine = 0.0025 + 0.006 * b.z * b.z * b.z, size = max(fine, distance(s.position, c.eye) * c.pixel * 0.8f);
        s.size = size;
        s.color = c.light(s.position) * 2.5;
        s.alpha = edge.x * edge.y * edge.z * fine / size * (0.35 + 0.65 * b.y);
        s.glow = 0.15;
        s.halo = 4;
        return s;
    }
    """#)
}
