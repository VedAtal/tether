import simd

extension SaverScene {
    static let lavaLamp = SaverScene(name: "Lava Lamp", symbol: "lamp.table") { LavaLamp.world() }
}

/// A lava lamp on a desk in a dim room on a rainy night: wax rises, stretches and sinks in the
/// bottle, the room breathes with its light, and the city blurs behind the rain on the window.
private enum LavaLamp {
    /// Light groups. The lamp is two lights, low and high in the bottle, so its glow follows the wax.
    enum Group {
        static let window = 0, lampLow = 1, lampHigh = 2, screen = 3, candle = 4
    }

    /// Matches the shader's `enum`.
    enum Material: Int {
        case desk, wall, paint, glass, metal, glow, ceramic, glaze, tea, book, terracotta, soil, leaf, vine, pothos, plastic, shell, leather,
             paper, cover, pen, pencil, aluminium, key, screen, cable, fabric, outlet, print, candle, succulent, cork, note, pin
    }

    static let eye = SIMD3<Float>(0, 1.06, 1.0)
    static let desk: Float = 0.75
    static let wall: Float = -0.45
    static let shelf: Float = 1.325
    /// Where the lamp's base stands; the bottle's bottom sits `bottleBase` above it.
    static let lamp = SIMD3<Float>(0, desk, -0.2)
    static let bottleBase: Float = 0.12, bottleHeight: Float = 0.24
    static let mug = SIMD3<Float>(-0.24, desk, 0.0)
    /// The window's opening in the back wall (min x, min y, max x, max y) and its glass's depth.
    static let window = SIMD4<Float>(-1.72, 0.9, -0.86, 1.98)
    static let glass: Float = -0.53
    static let street = simd_normalize(SIMD3<Float>(-0.4, 0.55, -0.75))
    static let laptop = simd_float4x4.translation([0.86, desk, -0.12]) * .rotation(-0.55, axis: [0, 1, 0])
    /// The laptop's open lid, in the laptop's frame: hinged at the back, tilted a little away.
    static let lid = simd_float4x4.translation([0, 0.013, -0.205]) * .rotation(-0.28, axis: [1, 0, 0])
    /// The candle on the sill, and its flame just above the wick.
    static let candle = SIMD3<Float>(-1.52, window.y + 0.002, wall - 0.01)
    static let flame = candle + [0, 0.08, 0]
    static let blobCount = 9

    static func world() -> SaverWorld {
        var world = SaverWorld(camera: .init(eye: eye, target: lamp + [0, 0.2, 0], fieldOfView: 28), shader: shader)
        world.groups = 5
        world.skyGroup = nil
        world.look.bounces = 3
        world.look.bloom = 0.06
        world.look.liveSamples = 4
        addRoom(&world)
        addWindow(&world)
        addLamp(&world)
        addMug(&world)
        addBooks(&world)
        addPlants(&world)
        addLaptop(&world)
        addNotebook(&world)
        addHeadphones(&world)
        addPens(&world)
        addCables(&world)
        addDecor(&world)
        addGlasses(&world)
        let bottle = lamp + [0, bottleBase, 0]
        let screen = laptop * lid
        world.lights = [
            .directional(toward: street, angle: 0.06, color: [0.9, 1.1, 1.7], group: Group.window),
            .sphere([-1.25, 1.9, -1.5], radius: 0.5, color: [1.3, 1.2, 1.5], group: Group.window),
            .tube(from: bottle + [0, 0.035, 0], to: bottle + [0, 0.115, 0], radius: 0.034, color: [0.16, 0.07, 0.03], group: Group.lampLow),
            .tube(from: bottle + [0, 0.115, 0], to: bottle + [0, 0.21, 0], radius: 0.03, color: [0.11, 0.03, 0.05], group: Group.lampHigh),
            .tube(from: (screen * SIMD4(-0.1, 0.1, 0.07, 1)).xyz, to: (screen * SIMD4(0.1, 0.1, 0.07, 1)).xyz, radius: 0.05,
                  color: [0.05, 0.065, 0.1], group: Group.screen),
            .sphere(flame, radius: 0.006, color: [0.045, 0.022, 0.007], group: Group.candle),
        ]
        world.particles = [.init(function: "steam", count: 36, blend: .alpha), .init(function: "dust", count: 140, blend: .additive)]
        world.update = { time, frame in
            let t = Float(time)
            // The lamp's light swells where the wax gathers: low while it pools, high as it rises.
            var low: Float = 0, high: Float = 0
            for i in 0..<blobCount {
                let blob = blob(i, t)
                frame.params[i] = blob
                frame.params[blobCount + i / 4][i % 4] = (self.blob(i, t + 0.1).y - self.blob(i, t - 0.1).y) * 5
                let volume = pow(blob.w / 0.02, 3)
                high += volume * smoothstep(0.08, 0.18, blob.y)
                low += volume * smoothstep(0.03, 0.06, blob.y) * smoothstep(0.16, 0.08, blob.y)
            }
            frame.tints[Group.lampLow] = SIMD3(1 + 0.1 * low, 1 + 0.06 * low, 1) * 0.9
            frame.tints[Group.lampHigh] = SIMD3(1 + 0.12 * high, 1 + 0.05 * high, 1 + 0.1 * high) * 0.8
            frame.tints[Group.screen] = SIMD3(repeating: 0.94 + 0.06 * Procedural.noise([t * 0.3, 7, 7]))
            // Now and then lightning far off in the cloud: a flicker that lights the sky and the room.
            let slot = (t / 43).rounded(.down), since = t - 43 * slot - 30 * Procedural.hash(Int32(slot), 9, 9)
            let flash = Procedural.hash(Int32(slot), 8, 8) < 0.5 && since > 0 ? min(since / 0.06, 1) * exp(-since * 3.5) * (0.6 + 0.4 * cos(since * 29)) : 0
            frame.tints[Group.window] = SIMD3(repeating: 1 + 2.5 * flash)
            // The candle gutters in a draught from the window: its flame leans and stretches, its light wavers.
            let lean = SIMD2(Procedural.noise([t * 0.5, 3, 1]) - 0.5, Procedural.noise([t * 0.4, 5, 1]) - 0.5) * 1.4
                + SIMD2(Procedural.noise([t * 3.1, 3, 2]) - 0.5, Procedural.noise([t * 2.7, 5, 2]) - 0.5) * 0.5
            let stretch = 0.85 + 0.3 * Procedural.noise([t * 1.9, 1, 9]) + 0.1 * Procedural.noise([t * 7, 2, 9])
            frame.params[15] = SIMD4(flash, lean.x, lean.y, stretch)
            frame.tints[Group.candle] = SIMD3(repeating: 0.55 + 0.5 * stretch - 0.25 * simd_length(lean))
        }
        return world
    }

    // MARK: Wax

    /// One blob of wax at time t: its offset from the bottle's axis as a fraction of the room it has
    /// there (x, z), its height in the bottle (y) and its radius (w). Each climbs slowly out of the
    /// pool, rests under the cap, sinks a little faster, at a pace that drifts so no two keep time.
    static func blob(_ i: Int, _ t: Float) -> SIMD4<Float> {
        let seed = Int32(i), f = Float(i)
        let size = Procedural.hash(seed, 1, 0)
        let r = 0.0075 + 0.0145 * size * size
        let period = 45 + 50 * Procedural.hash(seed, 2, 0) + 35 * size
        let phase = t / period + Procedural.hash(seed, 3, 0) + 0.4 * Procedural.noise([t * 0.009, f * 3.7, 0])
        let u = phase - phase.rounded(.down), climb = min(u / 0.58, (1 - u) / 0.42)
        let level = min(max((climb - 0.04) / 0.92, 0), 1), height = level * 0.65 + 0.35 * smoothstep(0, 1, level)
        let y = 0.012 + height * (0.2 - r)
        let angle = Procedural.hash(seed, 4, 0) * 2 * .pi + 3 * Procedural.noise([t * 0.012, f * 5.1, 1])
        let reach = 0.35 + 0.65 * Procedural.noise([t * 0.015, f * 2.3, 2])
        return SIMD4(reach * cos(angle), y, reach * sin(angle), r)
    }

    // MARK: The room

    /// Plaster walls round a long walnut desk and a shelf, the back wall open for the window.
    static func addRoom(_ world: inout SaverWorld) {
        let (x0, y0, x1, y1) = (window.x, window.y, window.z, window.w)
        let back = wall - 0.16
        func slab(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> simd_float4x4 { .translation((lo + hi) / 2) * .scale(hi - lo) }
        world.add(.box([1, 1, 1], segments: 4), material: Material.wall.rawValue, at: [
            slab([-3, 0, back], [x0, 2.7, wall]), slab([x1, 0, back], [3, 2.7, wall]), slab([x0, 0, back], [x1, y0, wall]),
            slab([x0, y1, back], [x1, 2.7, wall]), slab([-3, -0.1, -1], [3, 0, 2.5]), slab([-3, 2.7, -1], [3, 2.8, 2.5]),
            slab([-3.1, 0, -1], [-3, 2.7, 2.5]), slab([3, 0, -1], [3.1, 2.7, 2.5]), slab([-3, 0, 2.5], [3, 2.7, 2.6]),
        ])
        world.add(roundedBox([6, 0.04, 0.95], radius: 0.008), material: Material.desk.rawValue, at: [.translation([0, desk - 0.02, wall + 0.475])])
        world.add(roundedBox([1.26, 0.025, 0.2], radius: 0.004), material: Material.desk.rawValue, at: [.translation([0.11, shelf - 0.0125, wall + 0.1])])
        let bracket = Mesh.extrusion([[0, 0], [0.004, 0], [0.004, 0.13], [0.12, 0.13], [0.12, 0.134], [0, 0.134]], height: 0.02)
        world.add(bracket.transformed(.rotation(.pi / 2, axis: [0, 0, 1]) * .rotation(.pi / 2, axis: [1, 0, 0])), material: Material.plastic.rawValue,
                  at: [-0.35, 0.58].map { .translation([$0, shelf - 0.025, wall]) })
        world.add(roundedBox([0.075, 0.115, 0.01], radius: 0.004), material: Material.outlet.rawValue, at: [.translation([0.22, 0.87, wall + 0.005])])
        world.add(roundedBox([0.034, 0.042, 0.024], radius: 0.005), material: Material.plastic.rawValue,
                  at: [.translation([0.22, 0.895, wall + 0.022]), .translation([0.22, 0.845, wall + 0.022])])
    }

    /// A painted frame with a cross of glazing bars, a deep sill, the glass and a curtain.
    static func addWindow(_ world: inout SaverWorld) {
        let (x0, y0, x1, y1) = (window.x, window.y, window.z, window.w)
        let frame: Float = 0.05, bar: Float = 0.032, mid = (x0 + x1) / 2, transom = y0 + 0.62 * (y1 - y0)
        var bars = Mesh()
        func member(_ a: SIMD3<Float>, _ b: SIMD3<Float>, width: Float) {
            bars += beam([width, 0.06], length: simd_length(b - a), chamfer: 0.006).transformed(.span(from: a, to: b, height: simd_length(b - a)))
        }
        member([x0 + frame / 2, y0, glass], [x0 + frame / 2, y1, glass], width: frame)
        member([x1 - frame / 2, y0, glass], [x1 - frame / 2, y1, glass], width: frame)
        member([x0, y0 + frame / 2, glass], [x1, y0 + frame / 2, glass], width: frame)
        member([x0, y1 - frame / 2, glass], [x1, y1 - frame / 2, glass], width: frame)
        member([mid, y0, glass], [mid, y1, glass], width: bar)
        member([x0, transom, glass], [x1, transom, glass], width: bar)
        bars += roundedBox([x1 - x0 + 0.12, 0.028, 0.15], radius: 0.006).transformed(.translation([mid, y0 - 0.012, wall + 0.02]))
        world.add(bars, material: Material.paint.rawValue)
        world.add(.box([x1 - x0, y1 - y0, 0.006]), material: Material.glass.rawValue, at: [.translation([mid, (y0 + y1) / 2, glass])], castsShadows: false)
        world.add(.parametric(120, 40) { i, j in
            let u = Float(i) / 120, v = Float(j) / 40
            let fold = sin(u * 2 * .pi * 6.5 + 0.8 * sin(v * 3)) * (0.022 + 0.018 * (1 - v)) + 0.01 * Procedural.noise([u * 9, v * 4, 3])
            return SIMD3(-1.92 + 0.42 * u, 0.77 + 1.75 * (1 - v), wall + 0.07 + fold)
        }, material: Material.fabric.rawValue)
    }

    /// The lamp's turned metal base and cap, and a glowing stand-in for the bottle that the glossy
    /// things around reflect. The bottle, liquid and wax themselves are drawn live.
    static func addLamp(_ world: inout SaverWorld) {
        let base: [SIMD2<Float>] = [[0, 0], [0.071, 0], [0.075, 0.003], [0.0755, 0.009], [0.073, 0.014], [0.064, 0.04], [0.055, 0.075],
                                    [0.049, 0.105], [0.0465, 0.118], [0.0475, 0.124], [0.047, 0.13], [0.0415, 0.131], [0.04, 0.122]]
        let cap: [SIMD2<Float>] = [[0.031, -0.008], [0.0345, -0.004], [0.0352, 0.003], [0.03, 0.02], [0.022, 0.042], [0.018, 0.052],
                                   [0.012, 0.056], [0, 0.057]]
        world.add(.lathe(base, segments: 96), material: Material.metal.rawValue, at: [.translation(lamp)])
        world.add(.lathe(cap, segments: 96), material: Material.metal.rawValue, at: [.translation(lamp + [0, bottleBase + bottleHeight, 0])])
        let glow: [SIMD2<Float>] = [[0.03, 0.01], [0.05, 0.05], [0.046, 0.1], [0.036, 0.17], [0.024, 0.23]]
        world.add(.lathe(glow, segments: 32), material: Material.glow.rawValue, at: [.translation(lamp + [0, bottleBase, 0])], castsShadows: false)
    }

    /// A stoneware mug of tea beside the lamp.
    static func addMug(_ world: inout SaverWorld) {
        let place = simd_float4x4.translation(mug) * .rotation(0.5, axis: [0, 1, 0])
        let body: [SIMD2<Float>] = [[0, 0.004], [0.03, 0.0], [0.036, 0.002], [0.039, 0.01], [0.041, 0.05], [0.042, 0.09], [0.0425, 0.095],
                                    [0.04, 0.096], [0.0385, 0.09], [0.0375, 0.05], [0.035, 0.012], [0, 0.01]]
        let handle = Mesh.tube((0...16).map { k in
            let a = Float(k) / 16 * .pi
            return SIMD3(0.041 + 0.026 * sin(a), 0.05 + 0.028 * cos(a), 0)
        }, radius: { _ in 0.0055 }, segments: 10)
        world.add(Mesh.lathe(body, segments: 64) + handle, material: Material.ceramic.rawValue, at: [place])
        world.add(.lathe([[0, 0.078], [0.0378, 0.078]], segments: 48), material: Material.tea.rawValue, at: [place])
    }

    /// Cloth-bound books, each a unit box the shader dresses as covers, spine and pages: a stack on
    /// the desk, a row on the shelf, and a pile by the speaker.
    static func addBooks(_ world: inout SaverWorld) {
        var random = SeededRandom(seed: 11)
        func size() -> SIMD3<Float> {
            [Float.random(in: 0.016...0.04, using: &random), Float.random(in: 0.18...0.25, using: &random), Float.random(in: 0.13...0.17, using: &random)]
        }
        var places: [simd_float4x4] = []
        for (base, count) in [(SIMD3<Float>(-0.47, desk, -0.25), 3), (SIMD3<Float>(1.62, desk, -0.28), 3)] {
            var y = base.y
            for k in 0..<count {
                let s = size()
                places.append(.translation([base.x, y + s.x / 2, base.z]) * .rotation(Float.random(in: -0.15...0.15, using: &random) + Float(k) * 0.05, axis: [0, 1, 0])
                              * .rotation(.pi / 2, axis: [0, 0, 1]) * .scale(s))
                y += s.x
            }
        }
        var x: Float = -0.49
        while x < 0.22 {
            var s = size()
            s.y = min(s.y, 0.23)
            if x > 0.15 {
                // the last one leans on the rest
                places.append(.translation([x, shelf, wall + 0.012 + s.z / 2]) * .rotation(-0.35, axis: [0, 0, 1]) * .translation([s.x / 2, s.y / 2, 0]) * .scale(s))
                break
            }
            places.append(.translation([x + s.x / 2, shelf + s.y / 2, wall + 0.012 + s.z / 2]) * .scale(s))
            x += s.x + 0.001
        }
        world.add(.box([1, 1, 1]), material: Material.book.rawValue, at: places)
    }

    /// A snake plant in terracotta under the window, and a pothos on the shelf trailing its vines.
    static func addPlants(_ world: inout SaverWorld) {
        let pot: [SIMD2<Float>] = [[0, 0], [0.055, 0], [0.058, 0.004], [0.07, 0.1], [0.079, 0.101], [0.08, 0.125], [0.075, 0.127], [0.068, 0.11], [0.066, 0.1]]
        let snake = SIMD3<Float>(-1.08, desk, -0.3)
        world.add(.lathe(pot, segments: 64), material: Material.terracotta.rawValue, at: [.translation(snake)])
        let soil = Mesh.grid(size: [0.14, 0.14], cells: [24, 24]) { p in 0.004 * Procedural.noise([p.x * 120, 0, p.y * 120]) }
        world.add(soil.transformed(.translation([0, 0.104, 0])), material: Material.soil.rawValue, at: [.translation(snake)])
        // Sword leaves, cupped and twisting a little as they rise.
        let blade = Mesh.parametric(28, 6) { i, j in
            let s = Float(i) / 28, u = Float(j) / 3 - 1
            let width = 0.075 * (0.55 + 1.3 * s) * pow(1 - s, 0.85)
            let twist = s * 0.7
            let x = u * width / 2, z = -0.22 * width * (1 - u * u) + 0.05 * s * s
            return SIMD3(x * cos(twist) - z * sin(twist), 0.42 * s, x * sin(twist) + z * cos(twist))
        }
        world.add(blade, material: Material.leaf.rawValue, at: (0..<9).map { k in
            let seed = Int32(k)
            let yaw = Float(k) * 2.4 + Procedural.hash(seed, 1, 5)
            let lean = 0.08 + 0.22 * Procedural.hash(seed, 2, 5)
            let up = SIMD3<Float>(sin(yaw) * lean, 1, cos(yaw) * lean)
            return .place(snake + [0.02 * sin(yaw), 0.1, 0.02 * cos(yaw)], up: up, yaw: yaw * 1.7, scale: SIMD3(repeating: 0.75 + 0.45 * Procedural.hash(seed, 3, 5)))
        })
        let potHome = SIMD3<Float>(0.45, shelf, wall + 0.1)
        world.add(.lathe([[0, 0], [0.045, 0], [0.05, 0.01], [0.055, 0.085], [0.058, 0.09], [0.052, 0.09], [0.048, 0.07]], segments: 48),
                  material: Material.glaze.rawValue, at: [.translation(potHome)])
        var vines = Mesh()
        var leaves: [simd_float4x4] = []
        for k in 0..<5 {
            let seed = Int32(k + 20)
            let side = (Float(k) - 2) * 0.05 + 0.02 * Procedural.hash(seed, 1, 1)
            let drop = 0.12 + 0.28 * Procedural.hash(seed, 2, 1)
            let points = (0...24).map { n -> SIMD3<Float> in
                let f = Float(n) / 24
                let over = min(f * 3, 1), hang = max(f * 3 - 1, 0) / 2
                let x = potHome.x + side * (0.6 + over) + 0.03 * sin(hang * 5 + Float(k))
                let y = potHome.y + 0.085 + 0.03 * sin(over * .pi) - 0.08 * over * over - drop * hang
                let z = potHome.z + 0.03 + 0.09 * over + 0.025 * hang * sin(Float(k) * 2)
                return SIMD3(x, y, z)
            }
            vines += .tube(points, radius: { _ in 0.002 }, segments: 6)
            for n in stride(from: 2, to: 25, by: 2) {
                let side: Float = n % 4 == 0 ? 1 : -1, jitter = Procedural.hash(seed, Int32(n), 4) - 0.5
                let blade = simd_normalize(SIMD3<Float>(side * 0.7 + jitter, n < 9 ? 0.1 : -1, 0.7))
                let right = simd_normalize(simd_cross(blade, simd_normalize(SIMD3<Float>(jitter, 0.4, 1))))
                let face = simd_cross(right, blade), size = 0.8 + 0.5 * Procedural.hash(seed, Int32(n), 3)
                leaves.append(simd_float4x4(columns: (SIMD4(right * size, 0), SIMD4(blade * size, 0), SIMD4(face * size, 0), SIMD4(points[n], 1))))
            }
        }
        world.add(vines, material: Material.vine.rawValue)
        let heart = Mesh.parametric(10, 6) { i, j in
            let s = Float(i) / 10, u = Float(j) / 3 - 1
            let width = 0.05 * pow(sin(.pi * min(s * 1.12, 1)), 0.75) * (1.2 - 0.45 * s)
            return SIMD3(u * width / 2, 0.075 * s, 0.008 * abs(u) + 0.006 * sin(s * .pi))
        }
        world.add(heart, material: Material.pothos.rawValue, at: leaves)
    }

    /// An aluminium laptop, open, its lid turned toward the chair.
    static func addLaptop(_ world: inout SaverWorld) {
        world.add(roundedBox([0.3, 0.012, 0.21], radius: 0.004), material: Material.aluminium.rawValue, at: [laptop * .translation([0, 0.006, -0.105])])
        var keys: [simd_float4x4] = []
        for row in 0..<6 {
            let z = -0.172 + Float(row) * 0.0185, height: Float = row == 0 ? 0.008 : 0.0155
            if row == 5 {
                keys.append(.translation([0, 0.0118, z]) * .scale([0.09, 1, 1]))
                for x in [-0.12, -0.1, -0.08, 0.075, 0.095, 0.115] as [Float] { keys.append(.translation([x, 0.0118, z])) }
                continue
            }
            for col in 0..<14 { keys.append(.translation([-0.1235 + Float(col) * 0.019, 0.0118, z]) * .scale([1, 1, height / 0.0155])) }
        }
        world.add(roundedBox([0.0158, 0.0016, 0.0155], radius: 0.0007), material: Material.key.rawValue, at: keys.map { laptop * $0 })
        world.add(roundedBox([0.3, 0.205, 0.005], radius: 0.003), material: Material.aluminium.rawValue, at: [laptop * lid * .translation([0, 0.1025, 0])])
        world.add(panel([0.28, 0.175]), material: Material.screen.rawValue,
                  at: [laptop * lid * .translation([0, 0.106, 0.0026])], castsShadows: false)
    }

    /// An open notebook in the foreground with a fountain pen across it.
    static func addNotebook(_ world: inout SaverWorld) {
        let place = simd_float4x4.translation([0.17, desk, 0.12]) * .rotation(0.22, axis: [0, 1, 0])
        world.add(roundedBox([0.31, 0.003, 0.215], radius: 0.0012), material: Material.cover.rawValue, at: [place * .translation([0, 0.0015, 0])])
        world.add(.box([0.142, 0.006, 0.205]), material: Material.paper.rawValue, at: [-0.077, 0.077].map { place * .translation([$0, 0.006, 0]) })
        let pages = Mesh.parametric(40, 8) { i, j in
            let u = Float(i) / 20 - 1, x = 0.148 * u * abs(u).squareRoot()
            let y = 0.0098 - 0.0065 * exp(-abs(x) / 0.012) + 0.0015 * pow(abs(x) / 0.148, 3)
            return SIMD3(x, y, (Float(j) / 8 - 0.5) * 0.205)
        }
        world.add(pages, material: Material.paper.rawValue, at: [place])
        world.add(pen, material: Material.pen.rawValue, at: [place * .span(from: [0.02, 0.0145, 0.07], to: [0.135, 0.0135, -0.04], height: 0.142)])
    }

    /// A fountain pen built up its y axis, 14 cm long: barrel, tapered section and nib.
    static let pen = Mesh.lathe([[0, 0], [0.0045, 0.001], [0.0055, 0.006], [0.0055, 0.1], [0.0058, 0.102], [0.0058, 0.106], [0.005, 0.11],
                                 [0.0042, 0.125], [0.0025, 0.133], [0.0008, 0.142], [0, 0.142]], segments: 24)

    /// Over-ear headphones set down on their pads, the band arching over.
    static func addHeadphones(_ world: inout SaverWorld) {
        let place = simd_float4x4.translation([0.37, desk, -0.12]) * .rotation(0.45, axis: [0, 1, 0])
        let shell = Mesh.lathe([[0, 0.02], [0.038, 0.02], [0.044, 0.026], [0.045, 0.04], [0.04, 0.052], [0.028, 0.057], [0, 0.058]], segments: 48)
        let cushion = Mesh.lathe((0...16).map { k in
            let a = Float(k) / 16 * 2 * .pi
            return SIMD2(0.033 + 0.012 * cos(a), 0.012 + 0.011 * sin(a))
        }, segments: 48)
        let cups: [simd_float4x4] = [-1, 1].map { .translation([$0 * 0.095, 0, 0.04]) }
        world.add(shell, material: Material.shell.rawValue, at: cups.map { place * $0 })
        world.add(cushion, material: Material.leather.rawValue, at: cups.map { place * $0 })
        world.add(.lathe((0...12).map { k in
            let a = Float(k) / 12 * 2 * .pi
            return SIMD2(0.0435 + 0.0015 * cos(a), 0.047 + 0.0015 * sin(a))
        }, segments: 48), material: Material.metal.rawValue, at: cups.map { place * $0 })
        let band = Mesh.tube((0...30).map { k in
            let a = Float(k) / 30 * .pi
            return SIMD3(0.138 * cos(a), 0.032 + 0.14 * pow(sin(a), 0.7), 0.04)
        }, radius: { _ in 0.011 }, segments: 16).transformed(.translation([0, 0, 0.04]) * .scale([1, 1, 0.45]) * .translation([0, 0, -0.04]))
        world.add(band, material: Material.leather.rawValue, at: [place])
    }

    /// A glazed cup of pencils and pens by the wall.
    static func addPens(_ world: inout SaverWorld) {
        let home = SIMD3<Float>(0.4, desk, -0.37)
        world.add(.lathe([[0, 0], [0.033, 0], [0.035, 0.004], [0.036, 0.1], [0.032, 0.1], [0.031, 0.006], [0, 0.006]], segments: 48),
                  material: Material.glaze.rawValue, at: [.translation(home)])
        let hexagon = (0..<6).map { k in SIMD2<Float>(0.0038 * cos(Float(k) * .pi / 3), 0.0038 * sin(Float(k) * .pi / 3)) }
        let pencil = Mesh.extrusion(hexagon, height: 0.16) + Mesh.cone(radius: 0.0038, height: 0.022, segments: 6).transformed(.translation([0, 0.16, 0]))
        let tips: [SIMD3<Float>] = [[-0.03, 0.175, 0.01], [0.025, 0.18, -0.02], [0.0, 0.19, 0.035], [0.04, 0.16, 0.02]]
        world.add(pencil, material: Material.pencil.rawValue, at: tips.map { .span(from: home + [0, 0.008, 0], to: home + $0, height: 0.182) })
        world.add(pen, material: Material.pen.rawValue, at: [.span(from: home + [0.005, 0.008, 0], to: home + [-0.045, 0.145, -0.015], height: 0.142)])
    }

    /// The lamp's flex down the wall from the socket, with its switch, and the laptop's charger lead.
    static func addCables(_ world: inout SaverWorld) {
        let flex = spline([[0.22, 0.89, wall + 0.035], [0.215, 0.85, wall + 0.03], [0.205, 0.77, wall + 0.012], [0.19, desk + 0.004, wall + 0.03],
                           [0.12, desk + 0.004, -0.36], [0.06, desk + 0.004, -0.33], [0.02, desk + 0.006, -0.27]])
        let charger = spline([[0.22, 0.84, wall + 0.035], [0.23, 0.8, wall + 0.02], [0.27, desk + 0.004, wall + 0.04], [0.45, desk + 0.004, -0.31],
                              [0.62, desk + 0.004, -0.33], [0.72, desk + 0.005, -0.24]])
        world.add(.tube(flex, radius: { _ in 0.0028 }, segments: 8) + .tube(charger, radius: { _ in 0.0025 }, segments: 8), material: Material.cable.rawValue)
        world.add(roundedBox([0.022, 0.012, 0.045], radius: 0.004), material: Material.plastic.rawValue,
                  at: [.translation([0.1, desk + 0.006, -0.355]) * .rotation(0.45, axis: [0, 1, 0])])
    }

    /// A framed print and a speaker by the laptop, a cork board of notes, and a candle and a succulent
    /// on the sill.
    static func addDecor(_ world: inout SaverWorld) {
        let board = simd_float4x4.translation([-0.56, 1.08, wall])
        world.add(roundedBox([0.42, 0.3, 0.018], radius: 0.004), material: Material.desk.rawValue, at: [board * .translation([0, 0, 0.009])])
        world.add(panel([0.39, 0.27]), material: Material.cork.rawValue, at: [board * .translation([0, 0, 0.0185])])
        let notes: [(SIMD2<Float>, SIMD2<Float>, Float)] = [([-0.12, 0.04], [0.076, 0.076], 0.08), ([-0.02, -0.05], [0.125, 0.076], -0.05),
                                                            ([0.11, 0.02], [0.088, 0.107], 0.12), ([-0.14, -0.07], [0.076, 0.076], -0.14),
                                                            ([0.02, 0.07], [0.06, 0.09], -0.03)]
        world.add(.box([1, 1, 1]), material: Material.note.rawValue, at: notes.map { at, size, turn in
            board * .translation([at.x, at.y, 0.0195]) * .rotation(turn, axis: [0, 0, 1]) * .scale([size.x, size.y, 0.0004])
        })
        world.add(.sphere(radius: 0.004, subdivisions: 2), material: Material.pin.rawValue, at: notes.map { at, size, turn in
            board * .translation([at.x - sin(turn) * size.y * 0.42, at.y + cos(turn) * size.y * 0.42, 0.022])
        })
        let print = simd_float4x4.translation([1.3, 1.08, wall])
        world.add(roundedBox([0.44, 0.34, 0.02], radius: 0.003), material: Material.plastic.rawValue, at: [print * .translation([0, 0, 0.01])])
        world.add(panel([0.41, 0.31]), material: Material.print.rawValue,
                  at: [print * .translation([0, 0, 0.0202])])
        let speaker = simd_float4x4.translation([1.3, desk, -0.34]) * .rotation(-0.3, axis: [0, 1, 0])
        world.add(roundedBox([0.13, 0.21, 0.15], radius: 0.01), material: Material.shell.rawValue, at: [speaker * .translation([0, 0.105, 0])])
        world.add(roundedBox([0.112, 0.19, 0.004], radius: 0.002), material: Material.fabric.rawValue, at: [speaker * .translation([0, 0.105, 0.075])])
        let sill = candle.y
        let pillar: [SIMD2<Float>] = [[0, 0], [0.032, 0], [0.032, 0.072], [0.03, 0.075], [0.02, 0.073], [0, 0.071]]
        world.add(.lathe(pillar, segments: 48), material: Material.candle.rawValue, at: [.translation(candle)])
        world.add(.tube([candle + [0, 0.07, 0], candle + [0.0005, 0.077, 0], candle + [0.0015, 0.082, 0]], radius: { _ in 0.0007 }, segments: 6),
                  material: Material.cable.rawValue)
        // A bright core that the window glass behind can reflect; the flame itself is drawn live.
        world.add(.sphere(radius: 0.002, subdivisions: 2), material: Material.glow.rawValue, at: [.translation(flame + [0, 0.008, 0]) * .scale([1, 2, 1])],
                  castsShadows: false, tag: Group.candle)
        let pot: [SIMD2<Float>] = [[0, 0], [0.028, 0], [0.03, 0.002], [0.036, 0.05], [0.04, 0.051], [0.04, 0.062], [0.034, 0.055]]
        world.add(.lathe(pot, segments: 40), material: Material.terracotta.rawValue, at: [.translation([-1.36, sill, wall - 0.03])])
        // An echeveria: rings of plump leaves opening outward.
        world.add(.sphere(radius: 1, subdivisions: 2), material: Material.succulent.rawValue, at: (0..<22).map { k in
            let ring = Float(k / 8), angle = Float(k) * 2.4
            let out = SIMD3<Float>(cos(angle), 0.9 - 0.3 * ring, sin(angle))
            return .place([-1.36 + 0.012 * cos(angle) * ring, sill + 0.062, wall - 0.03 + 0.012 * sin(angle) * ring], up: out, yaw: 0,
                          scale: SIMD3(0.009, 0.022 - 0.004 * ring, 0.004) * (1.1 - 0.25 * ring)) * .translation([0, 0.8, 0])
        })
    }

    /// Wire reading glasses set down folded, leaning back on their temples.
    static func addGlasses(_ world: inout SaverWorld) {
        let place = simd_float4x4.translation([-0.98, desk, 0.12]) * .rotation(0.35, axis: [0, 1, 0]) * .rotation(-1.1, axis: [1, 0, 0])
        func rim(_ x: Float) -> [SIMD3<Float>] {
            (0...36).map { k in SIMD3(x + 0.025 * cos(Float(k) / 36 * 2 * .pi), 0.02 + 0.017 * sin(Float(k) / 36 * 2 * .pi), 0) }
        }
        var wire = Mesh.tube(rim(-0.031), radius: { _ in 0.0011 }, segments: 6) + .tube(rim(0.031), radius: { _ in 0.0011 }, segments: 6)
        wire += .tube([[-0.007, 0.03, 0], [0, 0.033, 0.002], [0.007, 0.03, 0]], radius: { _ in 0.001 }, segments: 6)
        for side: Float in [-1, 1] {
            wire += .tube([[side * 0.056, 0.027, 0], [side * 0.058, 0.027, -0.007], [side * 0.03, 0.026 - 0.002 * side, -0.011], [-side * 0.04, 0.025 - 0.002 * side, -0.012]],
                          radius: { _ in 0.001 }, segments: 6)
        }
        world.add(wire, material: Material.metal.rawValue, at: [place])
        world.add(.sphere(radius: 1, subdivisions: 3), material: Material.glass.rawValue,
                  at: [-0.031, 0.031].map { place * .translation([$0, 0.02, 0]) * .scale([0.0245, 0.0165, 0.0015]) }, castsShadows: false)
    }

    // MARK: Shapes

    /// A smooth path through `points` (Catmull-Rom), eight steps between each.
    static func spline(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        let ends = [points[0]] + points + [points[points.count - 1]]
        return (1..<ends.count - 2).flatMap { i in
            (0..<8).map { k -> SIMD3<Float> in
                let t = Float(k) / 8, (a, b, c, d) = (ends[i - 1], ends[i], ends[i + 1], ends[i + 2])
                return 0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (3 * b - a - 3 * c + d) * t * t * t)
            }
        } + [points[points.count - 1]]
    }

    /// A flat rectangle facing +z, for a picture or a display.
    static func panel(_ size: SIMD2<Float>) -> Mesh { Mesh.grid(size: size, cells: [1, 1]).transformed(.rotation(.pi / 2, axis: [1, 0, 0])) }

    /// A bar with chamfered edges, `size` across, standing `length` up the y axis.
    static func beam(_ size: SIMD2<Float>, length: Float, chamfer k: Float) -> Mesh {
        let (w, d) = (size.x / 2, size.y / 2)
        return .extrusion([[-w + k, -d], [w - k, -d], [w, -d + k], [w, d - k], [w - k, d], [-w + k, d], [-w, d - k], [-w, -d + k]], height: length)
    }

    /// A box centered on the origin with its edges rounded to `radius`.
    static func roundedBox(_ size: SIMD3<Float>, radius r: Float) -> Mesh {
        let half = size / 2
        func ticks(_ h: Float) -> [Float] { [-h, -h + r / 3, -h + r, h - r, h - r / 3, h] }
        var mesh = Mesh()
        for axis in 0..<3 {
            for sign: Float in [-1, 1] {
                var (u, v) = ((axis + 1) % 3, (axis + 2) % 3)
                if sign < 0 { swap(&u, &v) }
                let (tu, tv) = (ticks(half[u]), ticks(half[v]))
                mesh += .parametric(tu.count - 1, tv.count - 1) { i, j in
                    var p = SIMD3<Float>.zero
                    p[axis] = sign * half[axis]
                    p[u] = tu[i]
                    p[v] = tv[j]
                    return p
                }
            }
        }
        mesh = mesh.welded()
        let inner = half - r
        mesh.positions = mesh.positions.map { p in
            let core = simd_clamp(p, -inner, inner)
            return core + simd_normalize(p - core) * r
        }
        return mesh.withSmoothNormals()
    }

    // MARK: Shading

    static let shader = MetalSource(#"""
    #define HAS_EMISSION
    #define HAS_GROUP_TINT
    #define HAS_LIVE
    #define HAS_ATMOSPHERE

    enum : uint { DESK, WALL, PAINT, GLASS, METAL, GLOW, CERAMIC, GLAZE, TEA, BOOK, TERRACOTTA, SOIL, LEAF, VINE, POTHOS, PLASTIC, SHELL, LEATHER,
                  PAPER, COVER, PEN, PENCIL, ALUMINIUM, KEY, SCREEN, CABLE, FABRIC, OUTLET, PRINT, CANDLE, SUCCULENT, CORK, NOTE, PIN };
    #define WINDOW_LIGHT 0u
    #define LOW 1u
    #define HIGH 2u
    #define SCREEN_LIGHT 3u
    #define CANDLE_LIGHT 4u
    #define BLOBS \#(blobCount)

    constant float3 EYE = \#(eye.metal);
    constant float3 BOTTLE = \#((lamp + [0, bottleBase, 0]).metal);
    constant float3 MUG = \#(mug.metal);
    constant float3 FLAME = \#(flame.metal);
    constant float H = \#(bottleHeight);
    constant float4 WINDOW = \#(window.metal);
    constant float GLASS_Z = \#(glass);
    constant float3 STREET = \#(street.metal);
    // The liquid's surface and the resting wax's, up the bottle; the glass's thickness.
    constant float LIQUID = 0.226, POOL = 0.02, WALL_GLASS = 0.003;

    // MARK: The lamp's glow

    // The bulb under the bottle: its light fades up the bottle.
    static float bulb(float y) { return 0.3 + 2.2 * exp(-y / 0.05f); }
    static float3 waxColor(float y) { return mix(float3(1.0, 0.42, 0.06), float3(1.0, 0.2, 0.3), smoothstep(0.04, 0.22, y)); }
    static float3 liquidColor(float y) { return mix(float3(0.22, 0.015, 0.16), float3(0.05, 0.0, 0.1), smoothstep(0.0, 0.16, y)); }

    // MARK: Surfaces

    static Surface translucent(Surface s, float share) { s.translucency = share; return s; }

    // Oiled walnut planks with the grain along them, worn paler and rougher where arms rest.
    static Surface walnut(Hit h, Ctx c) {
        if (h.bounce > 0) return material(float3(0.1, 0.05, 0.025), 0.4, h.n);
        float2 g = h.p.xz;
        float plank = floor((g.y + 0.6f) / 0.19f), id = hash(plank);
        float along = g.x + id * 13;
        float warp = c.fbm(float3(along * 0.6f, g.y * 4, id * 9), 4), figure = c.fbm(float3(along * 1.5f, g.y * 9, id * 3 + 5), 3);
        float lines = pow(abs(sin(g.y * (150 + 90 * id) + warp * 22 + id * 6)), 6.0f) * smoothstep(0.3, 0.7, c.noise(float3(along * 3, g.y * 40, id)));
        float pores = c.noise(float3(along * 4, g.y * 500, 2.5));
        float3 color = mix(float3(0.075, 0.036, 0.017), float3(0.14, 0.075, 0.036), figure) * (0.8 + 0.25 * hash(plank + 3.0f));
        color *= (1 - 0.35 * lines) * (0.88 + 0.16 * pores);
        float seam = smoothstep(0.0012, 0.0, 0.095f - abs(fract((g.y + 0.6f) / 0.19f) - 0.5f) * 0.19f);
        color *= 1 - 0.45 * seam;
        float worn = smoothstep(0.1, 0.4, g.y) * smoothstep(0.6, 0.0, abs(g.x)) * c.fbm(float3(g * 3, 1), 3);
        float ring = smoothstep(0.0025, 0.0, abs(length(g - float2(-0.08, 0.13)) - 0.041f)) * 0.5f;
        color = mix(color, color * 1.35 + 0.01, worn * 0.5) * (1 - ring);
        float4 n = c.fbmd(float3(along * 2, g.y * 120, 5), 3);
        float scratch = smoothstep(0.97, 1.0, c.noise(float3(g.x * 3 + g.y * 40, g.y * 3 - g.x * 9, 7)));
        Surface s = material(color, mix(0.34 + 0.25 * worn + 0.1 * pores, 0.6, scratch), h.n);
        s.normal = bump(h.n, float3(n.y * 2, 0, n.w * 120), 0.00025);
        return s;
    }

    // Painted plaster, faintly mottled and trowelled.
    static Surface plaster(Hit h, Ctx c) {
        float4 n = detail(h.p * 7, h, c);
        float3 color = float3(0.16, 0.18, 0.2) * (0.88 + 0.24 * n.x);
        Surface s = material(color, 0.85, h.n);
        if (h.bounce == 0) s.normal = bump(h.n, n.yzw * 7 + c.fbmd(h.p * 60, 2).yzw * 2, 0.0012);
        return s;
    }

    // Turned metal with fine grooves round it, polished (under 0.2) since sampled highlights speckle this near the lamp.
    static Surface turned(Hit h, Ctx c) {
        Surface s = material(float3(0.88, 0.86, 0.83), 0.16, h.n);
        s.metallic = 1;
        if (h.bounce == 0) s.normal = normalize(h.n + float3(0, (c.noise(float3(0.5, h.local.y * 700, 0.5)) - 0.5f) * 0.02f, 0));
        return s;
    }

    // A cloth-bound book from a unit box: boards, a spine with gilt bands, and page edges.
    static Surface book(Hit h, Ctx c) {
        Instance in = c.instances[h.instance];
        float3 size = 1 / float3(length(in.inverse[0].xyz), length(in.inverse[1].xyz), length(in.inverse[2].xyz));
        float3 p = h.local * size, edge = size * 0.5f - abs(p), id = hash3(float3(h.instance, 4.2, 1.9));
        const float board = 0.0025;
        bool pages = edge.x > board && (edge.y < min(edge.x, edge.z) || (edge.z < edge.x && p.z < 0));
        if (pages) {
            float leaves = 0.75 + 0.25 * c.noise(float3(p.x * 2500, p.y * 40 + p.z * 40, id.y * 9));
            return material(float3(0.5, 0.45, 0.34) * leaves * (0.85 + 0.15 * id.z), 0.8, h.n);
        }
        const float3 cloth[6] = {float3(0.16, 0.025, 0.02), float3(0.02, 0.03, 0.08), float3(0.03, 0.06, 0.035), float3(0.28, 0.16, 0.04),
                                 float3(0.33, 0.29, 0.21), float3(0.025, 0.025, 0.028)};
        float3 color = cloth[min(int(id.x * 6), 5)] * (0.8 + 0.4 * c.noise(h.local * 40 + id * 30));
        float weave = 0.9 + 0.1 * c.noise(p * 1500);
        Surface s = material(color * weave, 0.75, h.n);
        bool spine = p.z > 0 && edge.z < min(edge.x, edge.y);
        float y = abs(p.y) - (size.y * 0.5f - 0.02f);
        float title = step(abs(p.y + size.y * 0.15f), 0.035f) * step(abs(p.x), size.x * 0.25f) * step(0.45, c.noise(float3(p.y * 600, p.x * 900, id.z * 7)));
        if (spine && (abs(y) < 0.003f || title > 0) && id.y > 0.3) {
            s.albedo = float3(0.85, 0.62, 0.3);
            s.metallic = 1;
            s.roughness = 0.35;
        }
        return s;
    }

    // Speckled stoneware.
    static Surface stoneware(Hit h, Ctx c) {
        float speck = smoothstep(0.78, 0.82, noise(h.local * 900));
        float3 color = mix(float3(0.42, 0.36, 0.28), float3(0.06, 0.04, 0.025), speck) * (0.9 + 0.15 * c.noise(h.local * 60));
        return material(color, 0.32 - 0.06 * speck, h.n);
    }

    // Terracotta, dusted white with salts toward its foot.
    static Surface terracotta(Hit h, Ctx c) {
        float4 n = detail(h.local * 40, h, c);
        float salts = smoothstep(0.55, 0.75, c.fbm(h.local * 25 + 3, 3) + 0.3 * (1 - h.local.y / 0.12f));
        float3 color = mix(float3(0.32, 0.12, 0.06) * (0.8 + 0.3 * n.x), float3(0.42, 0.38, 0.33), salts * 0.7);
        Surface s = material(color, 0.9, h.n);
        if (h.bounce == 0) s.normal = bump(h.n, n.yzw * 40, 0.0015);
        return s;
    }

    // A snake plant's leaf: dark green crossed by pale wavy bands, a waxy sheen.
    static Surface sansevieria(Hit h, Ctx c) {
        float bands = sin(h.local.y * 160 + 6 * c.noise(float3(h.local.x * 60, h.local.y * 6, float(h.instance))));
        float3 color = mix(float3(0.02, 0.05, 0.025), float3(0.07, 0.12, 0.06), smoothstep(0.3, 0.9, bands));
        float margin = smoothstep(0.9, 0.98, abs(h.local.x) / max(0.0375f * (0.55f + 1.3f * h.local.y / 0.42f) * pow(max(1 - h.local.y / 0.42f, 0.0f), 0.85f), 1e-4f));
        color = mix(color, float3(0.3, 0.27, 0.06), margin);
        return translucent(material(color, 0.42, h.n), 0.15);
    }

    // Ruled paper with lines of handwriting in blue-black ink.
    static Surface paper(Hit h, Ctx c) {
        float2 p = h.local.xz;
        float3 color = float3(0.6, 0.55, 0.44) * (0.94 + 0.08 * c.noise(float3(p * 300, 2)));
        if (h.local.y > 0.0035f && abs(p.x) > 0.008f) {
            float line = fract(p.y / 0.0072f + 0.5f), row = floor(p.y / 0.0072f + 0.5f);
            color = mix(color, float3(0.22, 0.32, 0.45), smoothstep(0.035, 0.0, abs(line - 0.5f)) * 0.45f);
            float x = abs(p.x), reach = 0.03 + 0.11 * hash(row + (p.x > 0 ? 40.0f : 0.0f));
            bool written = x > 0.016f && x < reach && row > -13 && (p.x < 0 || row < 2);
            float word = step(0.32, c.noise(float3(p.x * 90, row * 3.1, 1)));
            float ink = smoothstep(0.55, 0.75, c.noise(float3(p.x * 1400, line * 6, row))) * smoothstep(0.1, 0.25, line) * smoothstep(0.62, 0.45, line);
            if (written) color = mix(color, float3(0.02, 0.025, 0.06), ink * word * 0.85f);
        }
        return material(color, 0.85, h.n);
    }

    // What's pinned to the cork: sticky notes and an index card scrawled on, and a polaroid.
    static Surface note(Hit h, Ctx c) {
        float2 uv = h.local.xy;
        float id = hash(float(h.instance) * 3.7f);
        if (id > 0.75f) {
            bool photo = abs(uv.x) < 0.42f && uv.y > -0.28f && uv.y < 0.44f;
            float3 sunset = mix(float3(0.5, 0.2, 0.08), float3(0.05, 0.08, 0.2), smoothstep(-0.2, 0.4, uv.y));
            return material(photo ? mix(sunset, float3(0.02, 0.03, 0.02), step(uv.y, -0.05f + 0.05f * sin(uv.x * 9))) : float3(0.62, 0.6, 0.55), photo ? 0.3 : 0.8, h.n);
        }
        float3 paper = id < 0.45f ? float3(0.62, 0.5, 0.1) : id < 0.6f ? float3(0.6, 0.3, 0.35) : float3(0.62, 0.6, 0.55);
        float row = floor(uv.y * 7 + 0.5f), line = fract(uv.y * 7 + 0.5f);
        float ink = smoothstep(0.55, 0.75, c.noise(float3(uv.x * 60, line * 4, row + id * 50))) * step(abs(uv.x), 0.38f) * step(abs(line - 0.5f), 0.22f)
                    * step(uv.x, 0.38f * hash(row + id)) * step(abs(uv.y), 0.4f);
        return material(mix(paper, float3(0.02, 0.025, 0.06), ink * 0.8f), 0.8, h.n);
    }

    // A screen print in a white mat: a sun going down behind layered hills.
    static Surface artwork(Hit h, Ctx c) {
        float2 uv = float2(h.local.x / 0.41f + 0.5f, 0.5f - h.local.y / 0.31f), art = (uv - 0.09f) / 0.82f;
        float3 color = float3(0.55, 0.52, 0.45);
        if (all(art > 0) && all(art < 1)) {
            color = mix(float3(0.5, 0.3, 0.2), float3(0.42, 0.36, 0.3), art.y);
            color = mix(color, float3(0.45, 0.12, 0.05), smoothstep(0.205, 0.2, length((art - float2(0.62, 0.45)) * float2(1.3, 1))));
            const float3 hills[3] = {float3(0.06, 0.16, 0.15), float3(0.03, 0.08, 0.08), float3(0.015, 0.03, 0.05)};
            for (int k = 0; k < 3; k++) {
                float ridge = 0.5 + 0.13 * k + 0.06 * sin(art.x * (5 + 3 * k) + k * 2) + 0.03 * sin(art.x * 13 + k);
                color = mix(color, hills[k], smoothstep(ridge - 0.004f, ridge + 0.004f, art.y));
            }
        }
        return material(color * (0.92 + 0.12 * c.noise(h.local * 900)), 0.85, h.n);
    }

    Surface surface(Hit h, Ctx c) {
        switch (h.material) {
        case DESK: return walnut(h, c);
        case WALL: return plaster(h, c);
        case PAINT: {
            float4 n = detail(h.local * float3(40, 3, 40), h, c);
            Surface s = material(float3(0.5, 0.48, 0.45) * (0.92 + 0.12 * n.x), 0.4, h.n);
            if (h.bounce == 0) s.normal = bump(h.n, n.yzw * float3(40, 3, 40), 0.0004);
            return s;
        }
        case GLASS: {
            Surface s = material(float3(0.95, 0.97, 0.96), 0, h.n);
            s.transmission = 1;
            return s;
        }
        case METAL: return turned(h, c);
        case GLOW: return material(float3(0), 1, h.n);
        case CERAMIC: return stoneware(h, c);
        case GLAZE: {
            float pool = c.fbm(h.local * 30, 3);
            return material(mix(float3(0.02, 0.07, 0.07), float3(0.05, 0.14, 0.12), pool), 0.3, h.n);
        }
        case TEA: return material(float3(0.03, 0.012, 0.004), 0.05, h.n);
        case BOOK: return book(h, c);
        case TERRACOTTA: return terracotta(h, c);
        case SOIL: return material(float3(0.03, 0.022, 0.016) * (0.6 + 0.8 * c.noise(h.p * 300)), 0.95, h.n);
        case LEAF: return sansevieria(h, c);
        case VINE: return material(float3(0.04, 0.07, 0.02), 0.6, h.n);
        case POTHOS: {
            float streak = smoothstep(0.55, 0.85, c.noise(float3(h.local.x * 160, h.local.y * 25, float(h.instance) * 0.37f)));
            float vein = smoothstep(0.0015, 0.0, abs(h.local.x));
            float3 color = mix(float3(0.02, 0.06, 0.012), float3(0.16, 0.17, 0.035), max(streak * 0.7f, vein * 0.6f));
            return translucent(material(color, 0.35, h.n), 0.4);
        }
        case PLASTIC: return material(float3(0.018, 0.018, 0.02), 0.45, h.n);
        case SHELL: return material(float3(0.3, 0.27, 0.22) * (0.95 + 0.1 * c.noise(h.local * 500)), 0.5, h.n);
        case LEATHER: {
            float4 n = detail(h.p * 300, h, c);
            Surface s = material(float3(0.13, 0.075, 0.042), 0.42 + 0.1 * n.x, h.n);
            if (h.bounce == 0) s.normal = bump(h.n, n.yzw * 300, 0.00006);
            return s;
        }
        case PAPER: return paper(h, c);
        case COVER: return material(float3(0.05, 0.03, 0.02) * (0.8 + 0.4 * c.noise(h.p * 400)), 0.55, h.n);
        case PEN: {
            Surface s = material(float3(0.01, 0.012, 0.02), 0.22, h.n);
            if (h.local.y > 0.1f && h.local.y < 0.106f) { s.albedo = float3(0.85, 0.62, 0.3); s.metallic = 1; }
            if (h.local.y > 0.125f) { s.albedo = float3(0.8, 0.78, 0.74); s.metallic = 1; }
            return s;
        }
        case PENCIL: {
            float3 color = h.local.y > 0.172f ? float3(0.03) : h.local.y > 0.16f ? float3(0.45, 0.3, 0.18) : float3(0.55, 0.32, 0.02);
            return material(color, h.local.y > 0.16f ? 0.8 : 0.4, h.n);
        }
        case ALUMINIUM: {
            Surface s = material(float3(0.7, 0.7, 0.72), 0.32 + 0.06 * c.noise(h.local * 2000), h.n);
            s.metallic = 1;
            return s;
        }
        case KEY: return material(float3(0.012), 0.5, h.n);
        case SCREEN: return material(float3(0.01), 0.18, h.n);
        case PRINT: return artwork(h, c);
        case CORK: {
            float grains = c.noise(h.p * 900), dark = smoothstep(0.7, 0.8, noise(h.p * 1400));
            return material(mix(float3(0.24, 0.14, 0.07) * (0.8 + 0.4 * grains), float3(0.06, 0.035, 0.02), dark), 0.9, h.n);
        }
        case NOTE: return note(h, c);
        case PIN: return material(hash(float(h.instance)) > 0.5f ? float3(0.4, 0.02, 0.02) : float3(0.02, 0.06, 0.35), 0.25, h.n);
        case CANDLE: return material(float3(0.55, 0.5, 0.4) * (0.95 + 0.1 * c.noise(h.p * 200)), 0.6, h.n);
        case SUCCULENT: return material(mix(float3(0.1, 0.15, 0.13), float3(0.25, 0.12, 0.14), smoothstep(0.6, 1.0, abs(h.local.y))), 0.45, h.n);
        case CABLE: return material(float3(0.012), 0.5, h.n);
        case FABRIC: {
            float4 n = detail(h.p * float3(80, 4, 80), h, c);
            bool curtain = h.p.x < 0;
            float3 color = (curtain ? float3(0.3, 0.24, 0.18) : float3(0.02)) * (0.75 + 0.4 * n.x);
            Surface s = translucent(material(color, 0.95, h.n), curtain ? 0.35 : 0);
            if (h.bounce == 0) s.normal = bump(h.n, n.yzw * float3(80, 4, 80), 0.0008);
            return s;
        }
        default: return material(float3(0.6, 0.58, 0.54), 0.4, h.n);
        }
    }

    // MARK: Glow

    // A dark code editor: indented rows of syntax-coloured words, scrolling on now and then.
    static float3 code(float2 uv, float t) {
        float3 color = uv.x < 0.17f ? float3(0.02, 0.022, 0.03) : float3(0.012, 0.013, 0.02);
        float row = floor(uv.y * 44), f = fract(uv.y * 44);
        if (f < 0.25f || f > 0.75f || uv.y > 0.96f) return uv.y > 0.965f ? float3(0.02, 0.06, 0.16) : color;
        if (uv.x < 0.17f) return color + float3(0.1, 0.11, 0.13) * step(uv.x, 0.04f + 0.1f * hash(row + 300)) * step(0.02f, uv.x) * step(0.3, hash(row + 301));
        float line = row + floor(t / 11) * 3, indent = floor(hash(line) * 4) * 0.03f + 0.2f;
        float x = uv.x - indent, word = floor(x / 0.05f + hash(line + 1) * 3), end = 0.12 + 0.6 * hash(line + 2);
        if (x < 0 || uv.x > indent + end || fract(x / 0.05f + hash(line + 1) * 3) > 0.8f || hash(line + 3) < 0.15f) return color;
        const float3 syntax[4] = {float3(0.75, 0.4, 0.8), float3(0.45, 0.7, 1.0), float3(0.6, 0.85, 0.45), float3(0.6, 0.6, 0.65)};
        return syntax[int(hash(float2(line, word)) * 4)] * 0.45f;
    }

    Emission emission(Hit h, Ctx c) {
        if (h.material == GLOW && h.tag == CANDLE_LIGHT) return {float3(30, 16, 6), CANDLE_LIGHT};
        if (h.material == CANDLE) return {float3(1.0, 0.45, 0.12) * 0.4f * exp(-distance(h.p, FLAME) / 0.012f), CANDLE_LIGHT};
        if (h.material == GLOW) {
            float y = h.p.y - BOTTLE.y;
            return {mix(float3(1.0, 0.35, 0.08), float3(0.6, 0.08, 0.3), smoothstep(0.03, 0.2, y)) * bulb(y) * 0.5f, y < 0.11f ? LOW : HIGH};
        }
        if (h.material == SCREEN) {
            float2 uv = float2(h.local.x / 0.28f + 0.5f, 0.5f - h.local.y / 0.175f);
            if (any(abs(uv - 0.5f) > float2(0.47, 0.45))) return {float3(0), SCREEN_LIGHT};
            uv = (uv - float2(0.03, 0.05)) / float2(0.94, 0.9);
            float cursor = step(fract(c.t * 0.9f), 0.5f) * step(abs(uv.y - 0.62f), 0.009f) * step(abs(uv.x - 0.48f), 0.002f);
            return {code(uv, c.t) + cursor * 0.5f, SCREEN_LIGHT};
        }
        if (h.material == KEY && h.local.y > 0.0006f) {
            float2 q = abs(h.local.xz);
            return {float3(0.5, 0.55, 0.6) * 0.06f * step(max(q.x, q.y), 0.0025f) * step(0.0012f, max(q.x, q.y)), SCREEN_LIGHT};
        }
        return {float3(0), SCREEN_LIGHT};
    }

    // MARK: Rain and the city

    // Rain on the window glass at q (meters): beads that gather and dry, and drops that run down
    // leaving a trail. xy: the water's tilt, which bends the view through it; z: 1 inside water.
    static float3 rain(float2 q, float t) {
        float3 result = 0;
        for (int layer = 0; layer < 2; layer++) {
            float size = layer == 0 ? 0.009f : 0.017f;
            float2 cell = floor(q / size), f = q / size - cell;
            for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
                float2 id = cell + float2(x, y) + layer * 71;
                float3 h = hash3(float3(id, 3.1));
                float life = fract(t * (0.006 + 0.02 * h.z) + h.x);
                float r = (0.1 + 0.28 * h.y * h.y) * smoothstep(0.0, 0.1, life) * smoothstep(1.0, 0.75, life) * step(layer == 0 ? 0.72f : 0.6f, h.z);
                float2 o = f - float2(x, y) - 0.2 - 0.6 * hash2(id + 0.5f);
                float l = length(o / float2(1, 1.15));
                if (l < r) result = float3(o / r, 1);
            }
        }
        const float lane = 0.05;
        float column = floor(q.x / lane);
        float3 h = hash3(float3(column, 7.7, 1.3));
        float clock = t + h.y * 100;
        float fall = fract((clock + 0.9 * sin(clock * 0.6f + h.z * 9)) * (0.02 + 0.05 * h.x) + h.z);
        float drop = mix(WINDOW.w, WINDOW.y, fall);
        float path = (column + 0.5 + 0.4 * (noise(float2(q.y * 14, column)) - 0.5)) * lane;
        float2 o = float2((q.x - path) / 0.0035, (q.y - drop) / 0.0045);
        if (length(o) < 1 && h.x > 0.35f) result = float3(o, 1);
        float behind = q.y - drop;
        float trail = step(0.0, behind) * smoothstep(0.0016, 0.0006, abs(q.x - path)) * exp(-behind * 6) * step(0.35, h.x);
        if (trail > 0 && fract(q.y / 0.004f) < 0.5f) result = float3(float2(q.x - path, 0) / 0.0016, trail);
        return result;
    }

    // The city across the street, out of focus, laid out flat to the window: low cloud lit by the
    // city, a skyline flecked with windows, a tower's beacon, a plane crossing every few minutes, the
    // block opposite lit warm behind curtains or blue by a television, and street lights as discs.
    static float3 city(float3 v, float t, Ctx c) {
        float2 p = v.xy / max(-v.z, 0.05f);
        float3 color = mix(float3(0.05, 0.028, 0.03), float3(0.003, 0.006, 0.02), smoothstep(0.08, 0.45, p.y));
        float cloud = smoothstep(0.25, 0.75, c.fbm(float3(p.x * 2.5f + t * 0.003f, p.y * 7, t * 0.004f), 4));
        color = color * (0.35 + 1.3 * cloud) + float3(0.3, 0.32, 0.42) * c.param(15).x * cloud * smoothstep(0.0, 0.4, p.y);
        float column = floor(p.x / 0.05f), tower = step(abs(p.x + 0.98f), 0.02f);
        float top = mix(0.12 + 0.08 * pow(hash(column + 0.3f), 2.0f) + 0.04 * step(0.8, hash(column + 0.7f)), 0.27, tower);
        float2 w = float2(p.x / 0.006f, p.y / 0.008f);
        float lit = step(0.82, hash(floor(w) + column * 7)) * smoothstep(0.5, 0.15, max(abs(fract(w.x) - 0.5f), abs(fract(w.y) - 0.5f)));
        float3 far = float3(0.002, 0.0025, 0.004) + lit * mix(float3(1.0, 0.6, 0.3), float3(0.6, 0.75, 1.0), hash(floor(w) + 4.0f)) * 0.05f;
        color = mix(color, far, smoothstep(top + 0.005f, top - 0.005f, p.y));
        color += float3(1.0, 0.06, 0.03) * step(0.55, fract(t * 0.5f)) * exp(-length(p - float2(-0.98, 0.275)) * 700) * 4;
        float2 plane = float2(-1.25 + 0.9 * fract(t / 170), 0.47 + 0.04 * fract(t / 170));
        color += mix(float3(1.0, 0.9, 0.8), float3(1.0, 0.1, 0.05), step(0.5, fract(t * 0.8f))) * step(0.7, fract(t * 0.8f + 0.25f)) * exp(-length(p - plane) * 1500) * 2;
        float2 g = float2(p.x / 0.048f, (p.y + 0.3f) / 0.04f), gi = floor(g), gf = fract(g) - 0.5f;
        float on = step(0.62, hash(gi + floor(t / 150 + hash(gi)) * 0.13f)), tv = step(0.9, hash(gi + 9.0f));
        float3 room = mix(blackbody(2200 + 1800 * hash(gi + 2.0f)), float3(0.45, 0.6, 1.0) * (0.75 + 0.25 * sin(t * 5 + gi.x * 3)), tv);
        float drawn = mix(1.0, smoothstep(0.0, 0.25, abs(gf.x + 0.3f * (hash(gi + 7.0f) - 0.5f))), step(0.5, hash(gi + 8.0f)));
        float2 size = float2(0.22 + 0.12 * hash(float2(gi.x, 3)), 0.3);
        room *= smoothstep(0.08, 0.0, max(abs(gf.x) - size.x, abs(gf.y) - size.y)) * on * drawn * (0.03 + 0.07 * hash(gi + 5.0f)) * (0.5 + smoothstep(0.3, -0.3, gf.y));
        color = mix(color, float3(0.0025, 0.0025, 0.0035) + room, smoothstep(0.095, 0.085, p.y));
        for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
            float2 id = floor(p / 0.035f) + float2(x, y);
            float3 h = hash3(float3(id, 12.7));
            if (h.z < 0.68f) continue;
            float2 center = (id + 0.2f + 0.6f * h.xy) * 0.035f;
            float radius = 0.008 + 0.009 * h.x, d = length(p - center);
            float disc = smoothstep(radius, radius * 0.9f, d) * (0.85 + 0.3 * smoothstep(radius * 0.6f, radius, d));
            float3 tone = h.y < 0.65f ? float3(1.0, 0.6, 0.28) : h.y < 0.93f ? float3(0.8, 0.88, 1.0) : float3(1.0, 0.3, 0.2);
            color += tone * disc * (0.03 + 0.25 * (h.z - 0.68f)) * smoothstep(0.13, 0.0, center.y);
        }
        float streak = smoothstep(0.75, 1.0, c.noise(float3(p.x * 700, p.y * 12 + t * 10, p.x * 5)));
        return color * (1 + streak * 0.5f);
    }

    float3 sky(float3 d, Ctx c) {
        float2 q = (EYE + d * ((GLASS_Z - EYE.z) / min(d.z, -1e-3f))).xy;
        float3 water = rain(q, c.t);
        float3 v = normalize(d - float3(water.xy * 0.3f, 0));
        float3 color = city(v, c.t, c);
        if (water.z > 0) {
            float rim = smoothstep(0.65, 1.0, length(water.xy));
            float3 n = normalize(float3(-water.xy, 1.2));
            float glint = pow(saturate(dot(n, normalize(float3(0.75, -0.2, 1)))), 40.0f);
            color = color * (1.5 - 1.2 * rim) + glint * float3(1.0, 0.45, 0.3) * 0.2f * c.f->tint[LOW].r;
        }
        return color;
    }

    // MARK: The lamp

    // The bottle's outer radius at height y and its slope: a narrow neck in the base swelling to a
    // shoulder, then a long taper to the cap.
    static float2 profile(float y) {
        const float neck = 0.04, widest = 0.058, end = 0.032, shoulder = 0.06;
        float k = (widest - end) / (H - shoulder), a = (widest + k * shoulder - neck) / (shoulder * shoulder), d = min(y - shoulder, 0.0f);
        return float2(widest - k * (y - shoulder) - a * d * d, -k - 2 * a * d);
    }

    // Distance to the glass from outside, in the bottle's frame.
    static float bottle(float3 q) {
        float2 r = profile(clamp(q.y, 0.0f, H));
        return max((length(q.xz) - r.x) * rsqrt(1 + r.y * r.y), max(-q.y, q.y - H));
    }

    static float3 bottleNormal(float3 q) {
        return normalize(float3(q.x, 0, q.z) / max(length(q.xz), 1e-5f) - float3(0, profile(q.y).y, 0));
    }

    // The blobs near one ray through the liquid: each stretched along its climb and trailed by a
    // smaller drop that lags behind and pinches off when it moves fast.
    struct Wax {
        float3 center[2 * BLOBS];
        float3 radii[2 * BLOBS];
        int count;
    };

    static Wax gather(float3 o, float3 d, float length, Ctx c) {
        Wax w;
        w.count = 0;
        for (int i = 0; i < BLOBS; i++) {
            float4 b = c.param(i);
            float climb = c.param(BLOBS + i / 4)[i % 4];
            float room = max(profile(b.y).x - WALL_GLASS - b.w * 1.05f, 0.0f);
            float3 center = float3(b.x * room, b.y, b.z * room);
            float stretch = 1 + min(abs(climb) * 30, 0.7f);
            float3 parts[2] = {center, center - float3(0, climb * 3.5f + sign(climb) * b.w * 0.6f, 0)};
            float3 sizes[2] = {b.w * float3(rsqrt(stretch), stretch, rsqrt(stretch)), float3(b.w * 0.5f)};
            for (int k = 0; k < 2; k++) {
                float s = clamp(dot(parts[k] - o, d), 0.0f, length);
                if (distance_squared(o + d * s, parts[k]) > pow(sizes[k].y + 0.02f, 2.0f)) continue;
                w.center[w.count] = parts[k];
                w.radii[w.count] = sizes[k];
                w.count++;
            }
        }
        return w;
    }

    static float wax(float3 q, thread const Wax& w) {
        const float k = 0.005;
        float sum = exp((POOL - q.y) / k);
        for (int i = 0; i < w.count; i++) sum += exp(-sdEllipsoid(q - w.center[i], w.radii[i]) / k);
        return max(-k * log(max(sum, 1e-30f)), bottle(q) + WALL_GLASS);
    }

    // Lit through the wax from the bulb below: brightest underneath and where the wax is thin.
    static float3 shadeWax(float3 q, float3 d, thread const Wax& w) {
        float3 n = sdfNormal([&](float3 x) { return wax(x, w); }, q, 4e-4f);
        float3 toBulb = normalize(float3(0, -0.05, 0) - q);
        float lit = saturate(dot(n, toBulb) * 0.5f + 0.5f);
        float depth = saturate(-wax(q - n * 0.007f, w) / 0.007f);
        float facing = saturate(dot(n, -d));
        float3 color = mix(waxColor(q.y) * waxColor(q.y), float3(1.0, 0.62, 0.2), lit * lit * lit * smoothstep(0.2, 0.0, q.y) * 0.7f);
        return color * bulb(q.y) * (0.08 + 1.4 * lit * lit * lit + 0.7 * (1 - depth)) * mix(0.35, 1.0, facing) * 1.15f;
    }

    // The static world behind the bottle, along a ray bent through it.
    static float3 behind(float3 o, float3 d, Ctx c) {
        Hit h;
        float t;
        float3 ng;
        h.bounce = 1;
        if (!c.intersect(ray(o, d, 0, INFINITY), CAMERA_MASK, h, t, ng)) return 0;
        if (dot(h.n, d) > 0) h.n = -h.n;
        Surface s = surface(h, c);
        return c.shade(h.p, s.normal, -d, s);
    }

    // What the bottle reflects: the rainy window, the warm desk below, the dark room above.
    static float3 surroundings(float3 p, float3 d, Ctx c) {
        float3 color = mix(float3(0.02, 0.01, 0.008), float3(0.003, 0.003, 0.005), smoothstep(-0.2, 0.3, d.y));
        if (d.z < 0) {
            float2 q = (p + d * ((GLASS_Z - p.z) / d.z)).xy;
            if (all(q > WINDOW.xy) && all(q < WINDOW.zw)) color = sky(d, c);
        }
        return color;
    }

    // The candle's flame: a teardrop leaning and stretching in the draught, white-gold at its
    // heart, blue at its root.
    static Live candleFlame(float3 ro, float3 rd, float maxDist, Ctx c) {
        float2 span = boxInterval(ro, rd, FLAME - float3(0.012, 0.003, 0.012), FLAME + float3(0.012, 0.04, 0.012));
        span.y = min(span.y, maxDist);
        if (span.x >= span.y) return nothing();
        float4 draught = c.param(15);
        const int steps = 20;
        float dt = (span.y - span.x) / steps, t = span.x + dt * hash(rd * 731.7f), through = 1;
        Live result = nothing();
        for (int i = 0; i < steps; i++, t += dt) {
            float3 q = ro + rd * t - FLAME;
            float h = q.y / (0.026f * draught.w);
            q.xz -= draught.yz * h * h * 0.006f;
            float width = 0.0042f * sqrt(saturate(h * 3)) * pow(saturate(1 - h), 0.6f) + 1e-4f;
            float heat = smoothstep(1.0, 0.45, length(q.xz) / width) * step(0.0f, h) * step(h, 1.0f);
            if (heat <= 0) continue;
            result.depth = min(result.depth, t);
            float3 color = mix(float3(0.15, 0.3, 1.0) * 0.6f, blackbody(1400 + 1100 * heat * (1 - h)), smoothstep(0.04, 0.2, h));
            result.color += through * color * heat * 700 * dt;
            through *= exp(-heat * 300 * dt);
        }
        result.alpha = 1 - through;
        return result;
    }

    // The bottle, its liquid and wax, refracted and reflected by hand so the wax shows through it.
    Live live(float3 ro, float3 rd, float maxDist, Ctx c) {
        float2 span = boxInterval(ro, rd, BOTTLE - float3(0.06, 0, 0.06), BOTTLE + float3(0.06, H, 0.06));
        span.y = min(span.y, maxDist);
        if (span.x >= span.y) return candleFlame(ro, rd, maxDist, c);
        float t = span.x;
        for (int i = 0; i < 40; i++) {
            float d = bottle(ro + rd * t - BOTTLE);
            if (d < 1e-4f) break;
            t += d;
            if (t > span.y) return nothing();
        }
        float3 q = ro + rd * t - BOTTLE, n = bottleNormal(q), v = -rd;
        float fresnel = schlick(0.04f, dot(n, v));
        float3 reflected = surroundings(ro + rd * t, reflect(rd, n), c) + c.shade(ro + rd * t, n, v, material(float3(0), 0.08, n));
        if (q.y > LIQUID) return Live{mix(behind(ro + rd * (t + 0.13f), rd, c) * 0.8f, reflected, fresnel), 1, t};
        float3 d = refract(rd, n, 1 / 1.45f), glow = 0, through = 1, inner = 0;
        Wax w = gather(q, d, 0.14, c);
        float s = 0.002;
        for (int i = 0; i < 96; i++) {
            float3 p = q + d * s;
            float solid = wax(p, w), room = -(bottle(p) + WALL_GLASS);
            if (solid < 3e-4f) {
                for (int k = 0; k < 3; k++) s += wax(q + d * s, w);
                inner = shadeWax(q + d * s, d, w);
                break;
            }
            if (p.y > LIQUID) {
                inner = liquidColor(0) * bulb(0);
                break;
            }
            if (room < 3e-4f && s > 0.01f) {
                float3 out = refract(d, -bottleNormal(p), 1.45f);
                inner = all(out == 0) ? liquidColor(p.y) * bulb(p.y) : behind(BOTTLE + p, out, c);
                break;
            }
            float dt = clamp(min(solid, room), 0.0008f, 0.015f);
            float3 light = liquidColor(p.y) * bulb(p.y) * (1.2f + 2 * exp(-length(p.xz) / 0.02f)) + waxColor(p.y) * bulb(p.y) * exp(-solid / 0.004f) * 4;
            glow += through * light * dt;
            through *= exp(-float3(6, 20, 5) * dt);
            s += dt;
        }
        return Live{mix(glow + through * inner, reflected, fresnel), 1, t};
    }

    // MARK: Light patterns

    // Rain running down the window dapples its light; the wax throws soft, slow shapes round the
    // room, brighter on whichever side its blobs crowd.
    float3 groupTint(uint group, float3 p, Ctx c) {
        float3 tint = c.f->tint[group].rgb;
        if (group == WINDOW_LIGHT) {
            float2 q = (p + STREET * ((GLASS_Z - p.z) / STREET.z)).xy;
            return tint * (0.75 + 0.5 * c.noise(float3(q.x * 30, q.y * 12 + c.t * 0.5f, c.t * 0.05f)));
        }
        if (group != LOW && group != HIGH) return tint;
        float2 toward = normalize(p.xz - BOTTLE.xz + 1e-4f);
        float sum = 0;
        for (int i = 0; i < BLOBS; i++) {
            float4 b = c.param(i);
            float weight = group == LOW ? smoothstep(0.17, 0.05, b.y) : smoothstep(0.05, 0.17, b.y);
            sum += weight * pow(b.w / 0.02f, 2.0f) * dot(b.xz, toward);
        }
        return tint * clamp(1 + 0.35f * sum, 0.5f, 1.6f);
    }

    // MARK: Steam and dust

    // Steam curls off the tea, lit from behind by the lamp, and thins as it climbs.
    Particle steam(uint i, Ctx c) {
        const float life = 7;
        float phase = c.t / life + hash(float(i) + 0.3f), cycle = floor(phase), f = phase - cycle, age = f * life;
        float3 a = hash3(float3(i, cycle, 5.1));
        float3 swirl = float3(sin(age * 1.1f + a.y * 6), 0, cos(age * 0.9f + a.x * 6)) * 0.01f * age;
        Particle s;
        s.position = MUG + float3((a.x - 0.5f) * 0.035f, 0.085f + 0.03f * age, (a.z - 0.5f) * 0.035f) + swirl + float3(0.004, 0, 0) * age * age;
        s.velocity = float3(0, 0.03, 0);
        s.size = 0.008 + 0.03 * f;
        s.color = float3(0.9) * c.light(s.position);
        s.alpha = 0.1 * smoothstep(0.0, 0.15, f) * (1 - f) * (1 - f);
        s.puff = 1;
        return s;
    }

    // Dust adrift in the lamp's light, glinting as it turns.
    Particle dust(uint i, Ctx c) {
        float3 a = hash3(float3(i, 1.7, 9.2)), b = hash3(float3(i, 4.4, 2.6));
        float3 drift = 0.04f * float3(sin(c.t * 0.05f * (1 + b.x) + a.x * 20), sin(c.t * 0.03f * (1 + b.y) + a.y * 20), cos(c.t * 0.04f * (1 + b.z) + a.z * 20));
        Particle s;
        s.position = BOTTLE + (a - 0.5f) * float3(1.0, 0.6, 0.5) + float3(0, 0.12, 0.15) + drift;
        s.velocity = drift * 0.05f;
        s.size = 0.0005 + 0.0007 * b.x;
        float glint = pow(0.5f + 0.5f * sin(c.t * (0.4f + 1.5f * b.z) + a.x * 30), 6.0f);
        s.color = c.light(s.position) * (0.3 + 2.5 * glint) * 0.3f;
        s.alpha = 1;
        s.glow = 0.12 * glint;
        return s;
    }

    // MARK: Air

    // A faint haze in the room, glowing round the lamp.
    Atmosphere atmosphere(float3 ro, float3 rd, float dist, Ctx c) {
        float d = min(dist, 6.0f), density = 0.025;
        return {c.inscatter(ro, rd, d) * density, float3(exp(-density * d))};
    }
    """#)
}
