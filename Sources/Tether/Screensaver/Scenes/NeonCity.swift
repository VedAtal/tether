import simd

extension SaverScene {
    static let neonCity = SaverScene(name: "Neon City", symbol: "building.2") { NeonCity.world() }
}

/// A shopping street on a rainy night, seen from a footbridge over it: a canyon of walk-ups and
/// towers hung with neon runs away from the eye, its wet road doubling every light.
private enum NeonCity {
    enum Group {
        /// The sky's glow, street lamps, shops and windows, which hold steady.
        static let steady = 0
        /// Neon circuits, each buzzing and failing on its own.
        static let neon = 1, circuits = 5
    }

    /// Matches the shader's `enum`. Shops, walls and signs tag each copy with their kind, style or index.
    enum Material: Int {
        case road, sidewalk, glass, frame, iron, board, lamp, tower, signbox, awning, unit, shop, wall, neon, lightbox
    }

    static let eye = SIMD3<Float>(0, 5.2, 0)
    /// The curbs and the building line, either side of x = 0.
    static let roadEdge: Float = 5, frontage: Float = 8.5, curb: Float = 0.15
    static let ground: Float = 4.2, storey: Float = 3.1, bay: Float = 3, pilaster: Float = 0.4, shopWidth: Float = 5
    static let wallStyles = 16

    /// Neon colors: pink, cyan, orange, violet, green and amber.
    static let palette: [SIMD3<Float>] = [[1.0, 0.06, 0.36], [0.04, 0.7, 1.0], [1.0, 0.3, 0.05], [0.45, 0.14, 1.0], [0.25, 1.0, 0.3], [1.0, 0.55, 0.22]]
    /// Each kind of shop's light: shut, a bright convenience store, a warm restaurant, a dim bar.
    static let shopLight: [SIMD3<Float>] = [[0, 0, 0], [0.8, 0.92, 1.0], [1.0, 0.58, 0.26], [0.85, 0.2, 0.5]]

    static func world() -> SaverWorld {
        var world = SaverWorld(camera: .init(eye: eye, target: [0, eye.y, -100], fieldOfView: 38), shader: shader)
        world.groups = Group.neon + Group.circuits
        world.skyGroup = Group.steady
        world.liveReflections = true
        world.look.exposure = 1.2
        world.look.bloom = 0.05
        world.look.halation = 0.3
        world.look.bounces = 1
        world.look.liveSamples = 4
        addStreet(&world)
        addBuildings(&world)
        addSigns(&world)
        addLamps(&world)
        addWires(&world)
        world.particles = [.init(function: "rain", count: 24000, blend: .additive), .init(function: "splash", count: 4000, blend: .additive),
                           .init(function: "steam", count: 140, blend: .alpha), .init(function: "drip", count: 600, blend: .additive),
                           .init(function: "halo", count: 2 * maxCars + lamps.count, blend: .additive)]
        world.update = { time, frame in
            let t = Float(time)
            for i in 0..<Group.circuits { frame.tints[Group.neon + i] = SIMD3(repeating: circuit(i, t)) }
            let cars = cars(t)
            for (i, car) in cars.enumerated() { frame.params[i] = car }
            frame.lights = carLights(cars)
        }
        return world
    }

    /// How bright neon circuit `i` is at time t: all hum; one blinks, one breathes, the rest are faulty.
    static func circuit(_ i: Int, _ t: Float) -> Float {
        let hum = 0.94 + 0.06 * Procedural.hash(Int32(t * 30), Int32(i), 3)
        switch i % 3 {
        case 1: return hum * (fmod(t + Float(i), 7.3) < 6.4 ? 1 : 0.04)
        case 2: return hum * (0.72 + 0.28 * sin(t * 0.8 + Float(i)))
        default:
            let fault = Procedural.noise([t * 0.11, Float(i) * 17.3, 1])
            return hum * (fault > 0.7 && Procedural.hash(Int32(t * 14), Int32(i), 5) < 0.45 ? 0.12 : 1)
        }
    }

    // MARK: Traffic

    /// A lane of cars: where it runs, which way, how fast and how far apart its cars are.
    struct Lane {
        var x: Float
        var toward: Bool
        var speed: Float
        var gap: Float
        var seed: Int32
    }

    static let lanes = [Lane(x: -2.3, toward: true, speed: 10, gap: 17, seed: 1), Lane(x: 2.3, toward: false, speed: 8, gap: 21, seed: 2)]
    /// Where cars are drawn along the street; past that they're behind the eye or lost in the haze.
    static let traffic: (near: Float, far: Float) = (16, -260)
    static let maxCars = 40

    /// The cars at time t, nearest first: x, z, velocity along z, and which car (0 to 1), negative
    /// while braking. Every car that comes along is a new one, so the traffic never repeats.
    static func cars(_ t: Float) -> [SIMD4<Float>] {
        var cars: [SIMD4<Float>] = []
        let length = traffic.near - traffic.far
        for lane in lanes {
            // Each lane surges and slows as a whole.
            let a = t * 0.047 + Float(lane.seed) * 2.1, b = t * 0.113 + Float(lane.seed) * 4.2
            let travelled = lane.speed * t + 9 * sin(a) + 5 * sin(b), speed = lane.speed + 9 * 0.047 * cos(a) + 5 * 0.113 * cos(b)
            let braking = 9 * 0.047 * 0.047 * sin(a) + 5 * 0.113 * 0.113 * sin(b) > 0.02
            for k in Int(((travelled - length) / lane.gap).rounded(.down))...Int((travelled / lane.gap).rounded(.up)) {
                let slot = Int32(truncatingIfNeeded: k)
                guard Procedural.hash(slot, 1, 0, lane.seed) < 0.75 else { continue }
                let u = travelled - Float(k) * lane.gap + (Procedural.hash(slot, 2, 0, lane.seed) - 0.5) * lane.gap * 0.4
                guard u > 0 && u < length else { continue }
                cars.append([lane.x, lane.toward ? traffic.far + u : traffic.near - u, lane.toward ? speed : -speed,
                             (braking ? -1 : 1) * (0.01 + 0.98 * Procedural.hash(slot, 3, 0, lane.seed))])
            }
        }
        return Array(cars.sorted { abs($0.y) < abs($1.y) }.prefix(maxCars))
    }

    /// A beam from each near car's headlights and the tail lights of those going away, faded out before the frame runs short of lights.
    static func carLights(_ cars: [SIMD4<Float>]) -> [SaverFrame.Light] {
        let lights = cars.filter { (-90...4).contains($0.y) }.flatMap { car -> [SaverFrame.Light] in
            let way: Float = car.z > 0 ? 1 : -1, fade = smoothstep(90, 60, -car.y)
            let beam = SaverFrame.Light(position: [car.x, 0.66, car.y + way * 2.4], radius: 0.2, color: [1, 0.88, 0.72] * 80 * fade, range: 30,
                                        spot: .init(direction: [0, -0.07, way], inner: 0.12, outer: 0.32))
            let tail = SaverFrame.Light(position: [car.x, 0.72, car.y - way * 2.5], radius: 0.4, color: [1, 0.05, 0.02] * (car.w < 0 ? 4 : 1.2) * fade, range: 8)
            return way > 0 ? [beam] : [tail, beam]
        }
        return Array(lights.prefix(SaverFrame.maxLights))
    }

    // MARK: Street

    static func addStreet(_ world: inout SaverWorld) {
        world.add(.grid(size: [600, 600], cells: [1, 1]), material: Material.road.rawValue, at: [.translation([0, 0, -250])])
        let walk = Mesh.box([frontage + 1 - roadEdge, curb, 520])
        world.add(walk, material: Material.sidewalk.rawValue,
                  at: [-1, 1].map { side in .translation([side * (roadEdge + frontage + 1) / 2, curb / 2, -220]) })
    }

    // MARK: Buildings

    struct Block {
        var side: Float
        var z: (near: Float, far: Float)
        var floors: Int
        var style: Int
        /// 0 plain, 1 balconies, 2 a fire escape.
        var kind: Int
        var seed: Int32

        var height: Float { ground + Float(floors) * storey }
        var width: Float { z.near - z.far }
        /// The street face: its bottom left corner seen from the street, and the way along it.
        var origin: SIMD3<Float> { side < 0 ? [-frontage, 0, z.near] : [frontage, 0, z.far] }
        var right: SIMD3<Float> { side < 0 ? [0, 0, -1] : [0, 0, 1] }
        var normal: SIMD3<Float> { [-side, 0, 0] }
        var yaw: Float { -side * .pi / 2 }
        var detailed: Bool { z.near > -170 }
        /// The two buildings nearest the eye fill the outer screens, so they get the most going on.
        var featured: Bool { z.near > -16 && z.far < -4 }

        /// A transform for something built facing +z, `along` the face from its origin.
        func at(_ along: Float, up: Float, out: Float = 0, scale: SIMD3<Float> = [1, 1, 1]) -> simd_float4x4 {
            .place(origin + right * along + normal * out + [0, up, 0], yaw: yaw, scale: scale)
        }
    }

    /// Both sides of the street, from behind the eye to the haze: walk-ups near, towers far.
    static let blocks: [Block] = {
        var blocks: [Block] = []
        var seed: Int32 = 0
        for side: Float in [-1, 1] {
            var z: Float = 40
            while z > -460 {
                seed += 1
                let width = 9 + 10 * Procedural.hash(seed, 1, 0)
                let far = min(1, max(0, -z) / 300)
                let floors = 3 + Int((4 + 26 * far * far) * pow(Procedural.hash(seed, 2, 0), 1.2))
                var block = Block(side: side, z: (z, z - width), floors: floors, style: Int(Procedural.hash(seed, 5, 0) * Float(wallStyles)),
                                  kind: Int(Procedural.hash(seed, 6, 0) * 3), seed: seed)
                if block.featured { block.kind = side < 0 ? 2 : 1 }
                blocks.append(block)
                z -= width
            }
        }
        return blocks
    }()

    /// Copies of the parts buildings share, gathered before they're added.
    struct Parts {
        /// Bays and shopfronts by wall style, which their walls take.
        var windows = [[simd_float4x4]](repeating: [], count: wallStyles)
        var doors = [[simd_float4x4]](repeating: [], count: wallStyles)
        var fronts = [[simd_float4x4]](repeating: [], count: wallStyles)
        var trims = [[simd_float4x4]](repeating: [], count: wallStyles)
        var shops = [[simd_float4x4]](repeating: [], count: shopLight.count)
        var awnings: [simd_float4x4] = []
        var units: [simd_float4x4] = []
        var escapes: [simd_float4x4] = []
        var railings: [simd_float4x4] = []
        var pipes: [simd_float4x4] = []
        var tanks: [simd_float4x4] = []
        var masts: [simd_float4x4] = []
        var towers: [simd_float4x4] = []
    }

    static func addBuildings(_ world: inout SaverWorld) {
        var parts = Parts()
        for block in blocks {
            if block.detailed { building(block, &parts, &world) } else {
                let x = block.side * (frontage + 11)
                parts.towers.append(.place([x, 0, (block.z.near + block.z.far) / 2], scale: [22, block.height, block.width]))
            }
        }
        var random = SeededRandom(seed: 7)
        for _ in 0..<80 {
            let side: Float = Bool.random(using: &random) ? 1 : -1
            let x = side * Float.random(in: 34...150, using: &random), z = Float.random(in: -480 ... -30, using: &random)
            let size = SIMD3<Float>(Float.random(in: 18...40, using: &random), Float.random(in: 40...170, using: &random), Float.random(in: 18...40, using: &random))
            parts.towers.append(.place([x, 0, z], scale: size))
        }

        let window = bayModule(opening: (-0.8, 0.8, 0.9, 2.6), bars: [0], transom: 2.15)
        let door = bayModule(opening: (-0.95, 0.95, 0.05, 2.45), bars: [-0.3, 0.3], transom: nil)
        let shop = shopModule()
        for style in 0..<wallStyles {
            for (module, transforms) in [(window.wall, parts.windows[style]), (door.wall, parts.doors[style]), (shop.wall, parts.fronts[style])] {
                world.add(module, material: Material.wall.rawValue, at: transforms, tag: style)
            }
            world.add(unitBox, material: Material.wall.rawValue, at: parts.trims[style], tag: style)
        }
        for (module, transforms) in [(window, parts.windows.flatMap { $0 }), (door, parts.doors.flatMap { $0 })] {
            world.add(module.glass, material: Material.glass.rawValue, at: transforms)
            world.add(module.frame, material: Material.frame.rawValue, at: transforms)
        }
        let fronts = parts.fronts.flatMap { $0 }
        world.add(shop.frame, material: Material.frame.rawValue, at: fronts)
        world.add(shop.sign, material: Material.signbox.rawValue, at: fronts, castsShadows: false)
        for (kind, transforms) in parts.shops.enumerated() {
            world.add(shop.glass, material: Material.shop.rawValue, at: transforms, castsShadows: false, tag: kind)
        }
        world.add(awning(), material: Material.awning.rawValue, at: parts.awnings)
        world.add(acUnit(), material: Material.unit.rawValue, at: parts.units)
        world.add(fireEscape(), material: Material.iron.rawValue, at: parts.escapes)
        world.add(railing(), material: Material.iron.rawValue, at: parts.railings)
        world.add(.cylinder(radius: 0.07, height: 1, segments: 10, caps: false), material: Material.iron.rawValue, at: parts.pipes)
        world.add(waterTank(), material: Material.unit.rawValue, at: parts.tanks)
        world.add(mast(), material: Material.iron.rawValue, at: parts.masts)
        world.add(unitBox, material: Material.tower.rawValue, at: parts.towers)
    }

    /// A walk-up: bays of windows over shops, pilasters, a cornice and, by kind, balconies or a fire escape.
    static func building(_ b: Block, _ parts: inout Parts, _ world: inout SaverWorld) {
        let depth: Float = 22, h = b.height
        func mass(_ inset: Float, _ y0: Float, _ y1: Float) -> simd_float4x4 {
            boxAt([b.side * (frontage + (inset + depth) / 2), (y0 + y1) / 2, (b.z.near + b.z.far) / 2], [depth - inset, y1 - y0, b.width])
        }
        parts.trims[b.style] += [mass(0.25, ground, h), mass(0.45, 0, ground)]
        let across = simd_abs(b.right), out = simd_abs(b.normal)
        for end: Float in [0, 1] {
            parts.trims[b.style].append(boxAt(b.origin + b.right * (pilaster / 2 + end * (b.width - pilaster)) + b.normal * -0.1 + [0, h / 2, 0],
                                            across * pilaster + out * 0.5 + [0, h, 0]))
        }
        parts.trims[b.style].append(boxAt(b.origin + b.right * b.width / 2 + [0, h + 0.3, 0], across * (b.width + 0.2) + out * 0.7 + [0, 0.6, 0]))
        parts.pipes.append(b.at(pilaster + 0.15, up: 0, out: 0.12, scale: [1, h, 1]))
        // On the roof, against the sky: a stair bulkhead, and maybe a water tank and an antenna.
        let roof = SIMD3<Float>(b.side * (frontage + 5 + 8 * Procedural.hash(b.seed, 50, 0)), h, b.z.far + b.width * (0.2 + 0.6 * Procedural.hash(b.seed, 51, 0)))
        parts.trims[b.style].append(boxAt(roof + [b.side * 4, 1.3, 0], [3, 2.6, 3.2]))
        if Procedural.hash(b.seed, 52, 0) < 0.5 { parts.tanks.append(.place(roof, yaw: Procedural.hash(b.seed, 54, 0) * 3)) }
        if Procedural.hash(b.seed, 53, 0) < 0.6 { parts.masts.append(.place(roof + [b.side * 2, 0, 2], scale: [1, 1 + Procedural.hash(b.seed, 55, 0), 1])) }

        let inner = b.width - 2 * pilaster
        let bays = max(1, Int((inner / bay).rounded())), width = inner / Float(bays)
        let escape = b.kind == 2 && bays >= 3 ? bays / 2 - 1 : -1
        for floor in 0..<b.floors {
            let y = ground + Float(floor) * storey
            for k in 0..<bays {
                let module = b.at(pilaster + (Float(k) + 0.5) * width, up: y, scale: [width / bay, 1, 1])
                if b.kind == 1 {
                    parts.doors[b.style].append(module)
                    parts.railings.append(module)
                } else {
                    parts.windows[b.style].append(module)
                }
                let r = Procedural.hash(b.seed, Int32(floor * 32 + k), 9)
                if b.kind == 1 && r < 0.4 {
                    parts.units.append(module * .translation([0.95, 0.16, 0.35]))
                } else if b.kind != 1 && r < 0.22 && k != escape && k != escape + 1 {
                    parts.units.append(module * .translation([0.3 * (r * 9 - 1), 0.25, 0]))
                }
            }
            if b.kind == 1 {
                parts.trims[b.style].append(boxAt(b.origin + b.right * b.width / 2 + b.normal * 0.55 + [0, y + 0.08, 0], across * inner + out * 1.1 + [0, 0.16, 0]))
            }
            if escape >= 0 { parts.escapes.append(b.at(pilaster + Float(escape + 1) * width, up: y)) }
        }

        for shop in shops(of: b) {
            parts.shops[shop.kind].append(shop.module)
            parts.fronts[b.style].append(shop.module)
            if shop.awning { parts.awnings.append(shop.module) }
            let front = (shop.module * SIMD4(0, 2.3, 0.9, 1)).xyz
            if shop.kind != 0 && front.z > -14 && front.z < -3 {
                world.lights.append(.sphere(front, radius: 0.5, color: shopLight[shop.kind] * 7, group: Group.steady))
            }
        }
    }

    /// The shops along a building's ground floor: where each stands, its kind and whether it has an awning.
    static func shops(of b: Block) -> [(module: simd_float4x4, kind: Int, awning: Bool)] {
        let inner = b.width - 2 * pilaster, count = max(1, Int((inner / shopWidth).rounded())), span = inner / Float(count)
        return (0..<count).map { k in
            let r = Procedural.hash(b.seed, Int32(k) + 40, 0), pick = Procedural.hash(b.seed, Int32(k) + 80, 0)
            let kind = r < 0.25 && !b.featured ? 0 : pick < 0.3 ? 1 : pick < 0.85 ? 2 : 3
            return (b.at(pilaster + (Float(k) + 0.5) * span, up: 0, scale: [span / shopWidth, 1, 1]), kind, kind != 0 && r > 0.55)
        }
    }

    /// The front edges of the awnings nearest the eye, which rain drips off: x, height, and z from and to.
    static let eaves: [SIMD4<Float>] = blocks.filter { $0.z.near > -45 }.flatMap(shops).filter(\.awning).prefix(12).map { shop in
        let a = (shop.module * SIMD4(-shopWidth / 2 + 0.2, 2.37, 1.35, 1)).xyz, b = (shop.module * SIMD4(shopWidth / 2 - 0.2, 2.37, 1.35, 1)).xyz
        return [a.x, a.y, a.z, b.z]
    }

    static func panel(_ corner: SIMD3<Float>, _ u: SIMD3<Float>, _ v: SIMD3<Float>) -> Mesh {
        .parametric(1, 1) { i, j in corner + u * Float(i) + v * Float(j) }
    }

    /// A box one unit on a side standing on the origin, so `boxAt` can stretch it to any size.
    static let unitBox = Mesh.box([1, 1, 1], center: [0, 0.5, 0])

    static func boxAt(_ center: SIMD3<Float>, _ size: SIMD3<Float>) -> simd_float4x4 { .place(center - [0, size.y / 2, 0], scale: size) }

    /// A wall facing +z with an opening set `depth` into it, glass at its back in a frame of `bars` and a `transom`.
    static func opening(width: Float, height: Float, _ o: (x0: Float, x1: Float, y0: Float, y1: Float), depth: Float,
                        bars: [Float], transom: Float?) -> (wall: Mesh, glass: Mesh, frame: Mesh) {
        let (w, oh) = (o.x1 - o.x0, o.y1 - o.y0)
        var wall = panel([-width / 2, 0, 0], [o.x0 + width / 2, 0, 0], [0, height, 0]) + panel([o.x1, 0, 0], [width / 2 - o.x1, 0, 0], [0, height, 0])
        wall += panel([o.x0, 0, 0], [w, 0, 0], [0, o.y0, 0]) + panel([o.x0, o.y1, 0], [w, 0, 0], [0, height - o.y1, 0])
        wall += panel([o.x0, o.y0, 0], [0, 0, -depth], [0, oh, 0]) + panel([o.x1, o.y0, 0], [0, oh, 0], [0, 0, -depth])
        wall += panel([o.x0, o.y1, 0], [0, 0, -depth], [w, 0, 0]) + panel([o.x0, o.y0, 0], [w, 0, 0], [0, 0, -depth])
        let glass = panel([o.x0, o.y0, -depth + 0.06], [w, 0, 0], [0, oh, 0])
        let z = -depth + 0.08, bar: Float = 0.06, cy = (o.y0 + o.y1) / 2, cx = (o.x0 + o.x1) / 2
        var frame = Mesh.box([bar, oh, 0.07], center: [o.x0 + bar / 2, cy, z]) + .box([bar, oh, 0.07], center: [o.x1 - bar / 2, cy, z])
        frame += .box([w, bar, 0.07], center: [cx, o.y0 + bar / 2, z]) + .box([w, bar, 0.07], center: [cx, o.y1 - bar / 2, z])
        for x in bars { frame += .box([0.045, oh, 0.06], center: [x, cy, z]) }
        if let transom { frame += .box([w, 0.045, 0.06], center: [cx, transom, z]) }
        return (wall, glass, frame)
    }

    /// One bay of an upper floor, with a sill under its opening.
    static func bayModule(opening o: (Float, Float, Float, Float), bars: [Float], transom: Float?) -> (wall: Mesh, glass: Mesh, frame: Mesh) {
        var parts = opening(width: bay, height: storey, o, depth: 0.22, bars: bars, transom: transom)
        parts.frame += .box([o.1 - o.0 + 0.16, 0.07, 0.34], center: [(o.0 + o.1) / 2, o.2 - 0.035, -0.05])
        return parts
    }

    /// A shopfront `shopWidth` wide: a deep display window with mullions, and a lit sign above.
    static func shopModule() -> (wall: Mesh, glass: Mesh, frame: Mesh, sign: Mesh) {
        let half = shopWidth / 2 - 0.25
        let parts = opening(width: shopWidth, height: ground, (-half, half, 0.45, 3.05), depth: 0.4, bars: [-half / 3, half / 3], transom: 2.55)
        return (parts.wall, parts.glass, parts.frame, Mesh.box([shopWidth - 0.7, 0.75, 0.24], center: [0, 3.62, 0.12]))
    }

    /// A shop's awning in the same space, sloping out over the sidewalk with a valance.
    static func awning() -> Mesh {
        let half = shopWidth / 2 - 0.2
        return panel([-half, 3.2, 0], [2 * half, 0, 0], [0, -0.55, 1.35]) + panel([-half, 2.65, 1.35], [2 * half, 0, 0], [0, -0.28, 0])
    }

    /// A balcony's railing across one bay: a rail on balusters along the slab's front edge.
    static func railing() -> Mesh {
        var mesh = Mesh.box([bay, 0.05, 0.06], center: [0, 1.12, 1.05]) + .box([bay, 0.03, 0.03], center: [0, 0.24, 1.05])
        for k in 0..<20 { mesh += .box([0.018, 0.9, 0.018], center: [-bay / 2 + (Float(k) + 0.5) * bay / 20, 0.68, 1.05]) }
        return mesh
    }

    /// A rooftop water tank: a timber drum with a conical cap on four legs.
    static func waterTank() -> Mesh {
        var mesh = Mesh.cylinder(radius: 1.2, height: 2.3, segments: 24).transformed(.translation([0, 1.7, 0]))
        mesh += Mesh.cone(radius: 1.3, height: 0.7, segments: 24).transformed(.translation([0, 4.0, 0]))
        for k in 0..<4 {
            let angle = Float(k) * .pi / 2 + .pi / 4
            mesh += .box([0.14, 1.7, 0.14], center: [cos(angle) * 0.85, 0.85, sin(angle) * 0.85])
        }
        return mesh
    }

    /// An antenna mast with crossbars, 5 m tall.
    static func mast() -> Mesh {
        var mesh = Mesh.tube(from: .zero, to: [0, 5, 0], radius: 0.04, segments: 6, rings: 1)
        for (y, width) in [(Float(3.2), Float(1.4)), (4.1, 1.0), (4.8, 0.6)] { mesh += .box([width, 0.04, 0.04], center: [0, y, 0]) }
        return mesh
    }

    /// A window air conditioner on brackets, its back to the wall at the origin.
    static func acUnit() -> Mesh {
        Mesh.box([0.78, 0.55, 0.3], center: [0, 0.3, 0.17]) + .box([0.04, 0.04, 0.34], center: [-0.25, 0.01, 0.17]) + .box([0.04, 0.04, 0.34], center: [0.25, 0.01, 0.17])
    }

    /// One floor of a two-bay fire escape: a landing, its railing and the stair down to the one below.
    static func fireEscape() -> Mesh {
        let half = bay, deep: Float = 1.25
        var mesh = Mesh.box([2 * half, 0.05, deep], center: [0, 0, deep / 2])
        for y: Float in [1.0, 0.55, 0.1] {
            mesh += .box([2 * half, 0.04, 0.04], center: [0, y, deep])
            mesh += .box([0.04, 0.04, deep], center: [-half, y, deep / 2]) + .box([0.04, 0.04, deep], center: [half, y, deep / 2])
        }
        for k in 0...20 { mesh += .box([0.022, 1.0, 0.022], center: [-half + Float(k) * half / 10, 0.5, deep]) }
        let run = SIMD3<Float>(-2.4, -storey, 0), start = SIMD3<Float>(1.2, 0, 0)
        for z: Float in [0.2, 0.9] {
            mesh += .tube(from: start + [0, 0, z], to: start + run + [0, 0, z], radius: 0.03, segments: 6, rings: 1)
            mesh += .tube(from: start + [0, 0.9, z], to: start + run + [0, 0.9, z], radius: 0.02, segments: 6, rings: 1)
        }
        for k in 1..<12 {
            let f = Float(k) / 12
            mesh += .box([0.2, 0.03, 0.72], center: start + run * f + [0, 0, 0.55])
        }
        return mesh
    }

    // MARK: Signs

    struct Sign {
        var center: SIMD3<Float>
        var size: SIMD2<Float>
        var color: Int
        var circuit: Int
        /// Tubes of neon, or a lit box.
        var neon: Bool
    }

    /// Blade signs off the near buildings, facing the eye, one above another up their faces.
    static let signs: [Sign] = {
        var signs: [Sign] = []
        var random = SeededRandom(seed: 3)
        for b in blocks where b.z.near > -150 && b.z.far < -4 {
            var z = min(b.z.near, -5) - Float.random(in: 0.3...2, using: &random)
            while z > b.z.far + 0.5 {
                let size = SIMD2<Float>(Float.random(in: 0.8...1.4, using: &random), Float.random(in: 2.4...6.5, using: &random))
                let top = min(b.height - 1, 17)
                let y = Float.random(in: 4.6...max(4.7, top - size.y), using: &random) + size.y / 2
                signs.append(Sign(center: [b.side * (frontage - 0.35 - size.x / 2), y, z], size: size,
                                  color: Int.random(in: 0..<palette.count, using: &random), circuit: signs.count % Group.circuits,
                                  neon: Bool.random(using: &random)))
                z -= Float.random(in: 3.5...9, using: &random)
            }
        }
        // The arch over the street, and a tall sign close by on the right to balance the left's.
        signs.append(Sign(center: [0, 9.6, -36], size: [2 * frontage - 0.4, 2], color: 0, circuit: 0, neon: true))
        signs.append(Sign(center: [frontage - 0.95, 6.7, -8], size: [1.2, 4.3], color: 0, circuit: 3, neon: true))
        return signs
    }()

    static func addSigns(_ world: inout SaverWorld) {
        let board = Mesh.box([1, 1, 0.2], center: [0, 0, -0.1])
        var brackets: [simd_float4x4] = [], boards: [simd_float4x4] = []
        for side: Float in [-1, 1] {
            world.add(.cylinder(radius: 0.14, height: 10.6, segments: 16), material: Material.iron.rawValue, at: [.translation([side * (roadEdge + 0.7), 0, -36.1])])
        }
        for (k, sign) in signs.enumerated() {
            let place = simd_float4x4.translation(sign.center), shape = place * .scale([sign.size.x, sign.size.y, 1])
            if sign.neon {
                world.add(neon(sign.size, seed: Int32(k)), material: Material.neon.rawValue, at: [place], castsShadows: false, tag: k)
                boards.append(shape)
            } else {
                world.add(board, material: Material.lightbox.rawValue, at: [shape], tag: k)
            }
            let wall = sign.center.x > 0 ? frontage : -frontage
            for y in [sign.size.y / 2 - 0.25, 0.25 - sign.size.y / 2] where sign.center.x != 0 {
                let a = SIMD3<Float>(sign.center.x, sign.center.y + y, sign.center.z - 0.1)
                brackets.append(boxAt([(a.x + wall) / 2, a.y, a.z], [abs(wall - a.x), 0.06, 0.06]))
            }
            guard sign.center.z > -20 || sign.center.x == 0 else { continue }
            let half = sign.size.x > sign.size.y ? SIMD3(sign.size.x / 2 - 0.3, 0, 0.3) : SIMD3(0, sign.size.y / 2 - 0.3, 0.3)
            world.lights.append(.tube(from: sign.center - half + [0, 0, 0.6], to: sign.center + half, radius: 0.3,
                                      color: palette[sign.color] * (sign.neon ? 2.5 : 3) * (sign.center.x == 0 ? 3 : 1), group: Group.neon + sign.circuit))
        }
        world.add(board, material: Material.board.rawValue, at: boards)
        world.add(unitBox, material: Material.iron.rawValue, at: brackets)
    }

    /// Strokes between points of a three by three grid, from and to, which invented glyphs are made of.
    static let strokes: [SIMD4<Float>] = [
        [0, 2, 2, 2], [0, 1, 2, 1], [0, 0, 2, 0], [0, 0, 0, 2], [1, 0, 1, 2], [2, 0, 2, 2], [0, 1, 1, 2],
        [1, 2, 2, 1], [0, 0, 1, 1], [1, 1, 2, 0], [1, 1, 1, 2], [0, 1, 1, 1], [1, 1, 2, 1], [1, 0, 1, 1],
    ]

    /// A sign's neon in its own space, facing +z: a border round invented glyphs of a few strokes each.
    static func neon(_ size: SIMD2<Float>, seed: Int32) -> Mesh {
        func stroke(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Mesh {
            .tube(from: SIMD3(a, 0.06), to: SIMD3(b, 0.06), radius: 0.016 + 0.012 * min(size.x, size.y), segments: 8, rings: 1, caps: true)
        }
        let inset = size / 2 - 0.09
        var mesh = stroke([-inset.x, -inset.y], [inset.x, -inset.y]) + stroke([inset.x, -inset.y], [inset.x, inset.y])
        mesh += stroke([inset.x, inset.y], [-inset.x, inset.y]) + stroke([-inset.x, inset.y], [-inset.x, -inset.y])
        let row = size.x > size.y, length = row ? size.x : size.y
        let cell = (row ? size.y : size.x) - 0.42, glyphs = Int((length - 0.3) / (cell * 1.25))
        for g in 0..<glyphs {
            let along = (Float(g) - Float(glyphs - 1) / 2) * cell * 1.25
            let base = row ? SIMD2<Float>(along - cell / 2, -cell / 2) : SIMD2<Float>(-cell / 2, -along - cell / 2)
            var used = Set<Int>()
            for s in 0..<4 {
                let pick = Int(Procedural.hash(seed, Int32(g * 8 + s), 0) * Float(strokes.count))
                guard used.insert(pick).inserted else { continue }
                mesh += stroke(base + strokes[pick].lowHalf * cell / 2, base + strokes[pick].highHalf * cell / 2)
            }
        }
        return mesh
    }

    // MARK: Lamps and wires

    static let lamps: [SIMD3<Float>] = (0..<7).map { k in
        let side: Float = k % 2 == 0 ? -1 : 1
        return [side * (roadEdge - 1.1), 7.4, -14 - Float(k) * 21]
    }

    /// Lamps on poles at the curbs, their heads reaching out over the road.
    static func addLamps(_ world: inout SaverWorld) {
        var poles = Mesh(), heads = Mesh()
        for head in lamps {
            let out = SIMD3<Float>(-head.x / abs(head.x), 0, 0), foot = SIMD3(head.x - out.x * 1.6, curb, head.z)
            poles += .cylinder(radius: 0.08, height: head.y + 0.2 - curb, segments: 12).transformed(.translation(foot))
            poles += .tube([foot + [0, head.y - curb - 0.1, 0], foot + [0, head.y - curb + 0.25, 0] + out * 0.6, head + [0, 0.2, 0]], radius: { _ in 0.045 }, segments: 8)
            heads += .box([0.5, 0.12, 0.28], center: head + [0, 0.14, 0])
            // Far lamps glow and show in the road, but their light is lost in the haze.
            if head.z > -60 { world.lights.append(.sphere(head - [0, 0.1, 0], radius: 0.12, color: [0.55, 0.8, 1.0] * 22, group: Group.steady)) }
        }
        world.add(poles, material: Material.iron.rawValue)
        world.add(heads, material: Material.lamp.rawValue, castsShadows: false)
    }

    /// Power lines sagging across the street from roof to roof.
    static func addWires(_ world: inout SaverWorld) {
        var wires = Mesh()
        var random = SeededRandom(seed: 11)
        for _ in 0..<9 {
            let z = Float.random(in: -150 ... -12, using: &random), y = Float.random(in: 8...15, using: &random)
            for k in 0..<Int.random(in: 2...4, using: &random) {
                let a = SIMD3<Float>(-frontage, y + Float(k) * 0.3, z + Float(k) * 0.2), b = SIMD3<Float>(frontage, y + Float(k) * 0.3 + Float.random(in: -1...1, using: &random), z - 1)
                let sag = Float.random(in: 0.5...1.4, using: &random)
                wires += .tube((0...24).map { i in
                    let f = Float(i) / 24
                    return a + (b - a) * f - [0, sag * 4 * f * (1 - f), 0]
                }, radius: { _ in 0.012 }, segments: 5)
            }
        }
        world.add(wires, material: Material.iron.rawValue, castsShadows: false)
    }

    // MARK: Shading

    static let signTable = signs.map { s in
        let c = palette[s.color]
        return "{float4(\(c.x), \(c.y), \(c.z), \(Group.neon + s.circuit)), float2(\(s.size.x), \(s.size.y))}"
    }.joined(separator: ", ")

    static let shader = MetalSource(#"""
    #define HAS_EMISSION
    #define HAS_GROUP_TINT
    #define HAS_LIVE
    #define HAS_ATMOSPHERE

    enum : uint { ROAD, SIDEWALK, GLASS, FRAME, IRON, BOARD, LAMP, TOWER, SIGNBOX, AWNING, UNIT, SHOP, WALL, NEON, LIGHTBOX };
    struct Sign { float4 color; float2 size; };
    constant Sign SIGNS[] = { \#(signTable) };
    constant float3 SHOP_LIGHT[] = \#(shopLight.metal);
    constant float4 EAVES[] = \#(eaves.metal);
    constant float3 LAMPS[] = \#(lamps.metal);
    #define EAVE_COUNT \#(eaves.count)
    #define STEADY 0u
    #define ROAD_EDGE \#(roadEdge)
    #define FRONTAGE \#(frontage)
    #define CURB \#(curb)
    #define CARS \#(maxCars)
    // Manholes, the first two steaming.
    constant float3 VENTS[] = { float3(1.3, 0, -17), float3(-2.7, 0, -43), float3(0.6, 0, -71) };

    // MARK: Street

    // Lane lines, and a zebra crossing with a stop line before it for the oncoming lane.
    static float paint(float2 g) {
        if (g.y > -22 && g.y < -18.5) return step(0.5, fract(g.x + 0.25)) * step(abs(g.x), ROAD_EDGE - 0.4);
        if (g.y > -23 && g.y < -22.5 && g.x < 0) return step(g.x, -0.3) * step(-ROAD_EDGE + 0.4, g.x);
        return saturate(step(abs(abs(g.x) - 0.15), 0.06) + step(abs(abs(g.x) - (ROAD_EDGE - 0.5)), 0.06));
    }

    // Where water stands on the road: in the wheel ruts, the gutters and wherever it dips.
    static float puddle(float2 g, Ctx c, int octaves) {
        float ruts = exp(-pow((abs(abs(g.x) - 2.4) - 0.8) / 0.3f, 2.0f)) * 0.08 + smoothstep(ROAD_EDGE - 0.9, ROAD_EDGE, abs(g.x)) * 0.12;
        return smoothstep(0.55, 0.6, c.fbm(float3(g * float2(0.5, 0.15), 5.1), octaves) + ruts);
    }

    // A cast iron manhole cover: rings and a grid of studs, or 0 off the covers.
    static float manhole(float2 g) {
        for (int i = 0; i < 3; i++) {
            float r = length(g - VENTS[i].xz);
            if (r < 0.38) return r > 0.34 ? 0.5 : step(0.5, fract(r * 14)) * 0.6 + 0.4 * step(0.6, hash(floor(g * 18)));
        }
        return -1;
    }

    // Wet asphalt: dark aggregate, patched and stained, pooled in the wheel ruts and gutters.
    static Surface road(Hit h, Ctx c) {
        float2 g = h.p.xz;
        float water = puddle(g, c, h.bounce == 0 ? 3 : 2);
        if (h.bounce > 0) return material(float3(0.03) * (1 - 0.4 * water), mix(0.14, 0.02, water), h.n);
        float cover = manhole(g);
        if (cover >= 0) {
            Surface s = material(float3(0.05, 0.045, 0.04) * (0.6 + 0.6 * cover), 0.3 - 0.15 * cover, h.n);
            s.metallic = 0.6;
            return s;
        }
        float broad = c.fbm(float3(g * 0.18, 1.3), 3);
        float3 color = float3(0.03, 0.03, 0.034) * (0.7 + 0.6 * broad);
        float lines = paint(g) * smoothstep(0.35, 0.6, c.fbm(float3(g * float2(3, 0.6), 2), 3));
        color = mix(color, float3(0.36, 0.36, 0.34), lines);
        Surface s = material(color * (1 - 0.4 * water), mix(mix(0.14, 0.3, lines), 0.02, water), h.n);
        float4 grit = c.fbmd(float3(g * 14, 0.5), 3);
        s.albedo *= 0.75 + 0.5 * grit.x;
        s.normal = bump(h.n, float3(grit.y, 0, grit.z) * 14, 0.0015 * (1 - water));
        return s;
    }

    // Pavers in a running bond, the curb's granite at the road's edge.
    static Surface sidewalk(Hit h, Ctx c) {
        float2 g = h.p.xz;
        float edge = abs(g.x) - ROAD_EDGE;
        float2 cell = float2(g.x / 0.3, g.y / 0.6 + 0.5 * step(0.5, fract(g.x / 0.6)));
        float2 f = abs(fract(cell) - 0.5);
        float joint = edge < 0.3 ? smoothstep(0.47, 0.5, abs(fract(g.y / 1.2) - 0.5)) : smoothstep(0.44, 0.5, max(f.x, f.y * 0.5 + 0.25));
        float3 color = edge < 0.3 ? float3(0.2, 0.2, 0.19) : mix(float3(0.11, 0.1, 0.095), float3(0.16, 0.14, 0.12), hash(floor(cell)));
        float water = smoothstep(0.58, 0.62, c.fbm(float3(g * 0.4, 7.7), h.bounce == 0 ? 3 : 2));
        Surface s = material(color * (1 - 0.5 * joint) * (1 - 0.35 * water), mix(mix(0.26, 0.5, joint), 0.03, water), h.n);
        if (h.bounce == 0) s.albedo *= 0.8 + 0.4 * c.noise(float3(g * 9, 3.3));
        return s;
    }

    // MARK: Buildings

    // Brick, tile, concrete or painted render, by style, grimed and streaked by the rain.
    static Surface wall(Hit h, Ctx c, uint style) {
        float2 uv = planar(h.p, h.n);
        float3 tone = hash3(float3(style, 1.7, 9.1));
        if (h.bounce > 0) return material(mix(float3(0.11, 0.06, 0.045), float3(0.12, 0.12, 0.12), tone.y) * (0.5 + c.fbm(float3(uv.x * 1.5, uv.y * 0.12, float(style)), 2)), 0.7, h.n);
        uint kind = style % 4;
        float3 color;
        float rough = 0.75, relief = 0;
        if (kind == 0) {
            float2 cell = float2(uv.x / 0.23 + 0.5 * step(0.5, fract(uv.y / 0.15)), uv.y / 0.075);
            float2 f = abs(fract(cell) - 0.5);
            relief = smoothstep(0.42, 0.5, max(f.x * 0.5 + 0.25, f.y));
            color = mix(float3(0.13, 0.06, 0.04), float3(0.11, 0.075, 0.06), tone.x) * (0.75 + 0.5 * hash(floor(cell) + float(style)));
            color = mix(color, float3(0.09, 0.085, 0.08), relief);
        } else if (kind == 1) {
            float2 f = abs(fract(uv / 0.11) - 0.5);
            relief = smoothstep(0.43, 0.5, max(f.x, f.y));
            color = mix(float3(0.3, 0.28, 0.25), float3(0.2, 0.23, 0.24), tone.y) * (0.85 + 0.3 * hash(floor(uv / 0.11)));
            rough = mix(0.45, 0.75, relief);
        } else if (kind == 2) {
            float2 f = abs(fract(uv / float2(1.8, 0.9)) - 0.5);
            relief = smoothstep(0.485, 0.5, max(f.x, f.y));
            color = float3(0.14) * (0.8 + 0.4 * tone.z) * (1 - 0.4 * relief);
        } else {
            color = mix(float3(0.18, 0.13, 0.11), float3(0.1, 0.13, 0.15), tone.x) * (0.7 + 0.5 * tone.z);
            rough = 0.6;
        }
        float grime = c.fbm(float3(uv.x * 1.5, uv.y * 0.12, float(style)), 4);
        float streaks = c.noise(float3(uv.x * 7, uv.y * 0.25, float(style) + 4));
        color *= (0.55 + 0.6 * grime) * (1 - 0.35 * smoothstep(0.55, 0.8, streaks));
        Surface s = material(color, rough * (1 - 0.3 * smoothstep(0.5, 0.8, streaks)), h.n);
        if (h.bounce == 0) {
            float4 n = c.fbmd(float3(uv * 6, float(style)), 3);
            s.albedo *= 0.85 + 0.3 * n.x;
            s.normal = bump(h.n, unplanar(n.yz * 6, h.n), 0.004);
        }
        return s;
    }

    // An awning's paint, by copy: plain or striped.
    static float3 stripes(Hit h) {
        float3 r = hash3(float3(float(h.instance), 5.5, 1.1));
        float3 base = hsv(r.x, 0.55 + 0.3 * r.y, 0.25);
        return r.z < 0.5 ? mix(base, float3(0.32, 0.3, 0.28), step(0.5, fract(h.local.x / 0.42))) : base;
    }

    static Surface glass(float3 n) { return material(float3(0.015, 0.017, 0.02), 0.04, n); }

    static Surface metallic(float3 albedo, float roughness, float3 n) {
        Surface s = material(albedo, roughness, n);
        s.metallic = 0.7;
        return s;
    }

    static Surface surfaceOf(Hit h, Ctx c) {
        switch (h.material) {
        case ROAD: return road(h, c);
        case SIDEWALK: return sidewalk(h, c);
        case WALL: return wall(h, c, h.tag);
        case GLASS: return glass(h.n);
        // A lit shop's window, or the shutter of one that's shut.
        case SHOP: return h.tag ? glass(h.n) : metallic(float3(0.09, 0.095, 0.1) * (0.8 + 0.2 * sin(h.local.y * 80)), 0.45, h.n);
        case FRAME: return metallic(float3(0.05, 0.05, 0.055), 0.3, h.n);
        case IRON: return metallic(float3(0.04, 0.042, 0.045), 0.3, h.n);
        case NEON: return material(float3(0.8), 0.15, h.n);
        case LIGHTBOX: return material(float3(0.6), 0.25, h.n);
        case BOARD: return material(float3(0.03, 0.03, 0.035), 0.4, h.n);
        case LAMP: return material(float3(0.1), 0.5, h.n);
        case SIGNBOX: return material(float3(0.04), 0.3, h.n);
        case AWNING: return material(stripes(h), 0.55, h.n);
        case UNIT: return material(float3(0.26, 0.25, 0.23) * (h.bounce == 0 ? 0.7 + 0.3 * c.fbm(h.p * 3, 3) : 0.85), 0.5, h.n);
        default: return material(float3(0.035, 0.04, 0.05) * (0.8 + 0.4 * hash(float(h.instance))), 0.4, h.n);
        }
    }

    Surface surface(Hit h, Ctx c) {
        Surface s = surfaceOf(h, c);
        // Only the road and the shop windows are low enough to mirror the traffic.
        s.reflectsLive = h.material == ROAD || h.material == SHOP;
        return s;
    }

    // MARK: Light

    // Where a ray from the glass meets the inside of the room lo…hi, and which face: 0 sides, 1 floor or ceiling, 2 back.
    static float4 interior(float3 o, float3 d, float3 lo, float3 hi) {
        float3 t3 = (select(lo, hi, d > 0) - o) / d;
        float t = min(t3.x, min(t3.y, t3.z));
        return float4(o + d * t, t == t3.x ? 0 : t == t3.y ? 1 : 2);
    }

    // The eye's ray in a bay's own space, from the glass into the room.
    static float3 inward(Hit h, Ctx c) {
        float3 across = normalize(cross(float3(0, 1, 0), h.n)), rd = normalize(h.p - c.eye);
        return float3(dot(rd, across), rd.y, -dot(rd, h.n));
    }

    // How open a point inside a box room is: darker into its corners, away from the face it's on.
    static float corners(float4 q, float3 hi) {
        float3 e = float3(hi.x - abs(q.x), min(q.y, hi.y - q.y), hi.z - q.z);
        float edge = q.w == 0 ? min(e.y, e.z) : q.w == 1 ? min(e.x, e.z) : min(e.x, e.y);
        return 0.45 + 0.55 * smoothstep(0.0f, 0.7f, edge);
    }

    // Which of two boxes of furniture, lo…lo + size, the ray from o along d meets first, before the room
    // at q: 0, 1 or -1 for neither. q moves to where it does.
    static int furniture(float3 o, float3 d, float3 lo0, float3 size0, float3 lo1, float3 size1, thread float4& q) {
        float far = length(q.xyz - o);
        int found = -1;
        for (int k = 0; k < 2; k++) {
            float2 span = k == 0 ? boxInterval(o, d, lo0, lo0 + size0) : boxInterval(o, d, lo1, lo1 + size1);
            if (span.x < span.y && span.x < far) {
                far = span.x;
                found = k;
            }
        }
        if (found >= 0) q.xyz = o + d * far;
        return found;
    }

    // A lamp-lit flat seen in parallax behind the window, or a television's flicker; now and then the light goes on or off.
    static float3 room(Hit h, Ctx c) {
        float3 r = hash3(float3(float(h.instance), 3.1, 7.7));
        float on = step(r.x, 0.3 + 0.3 * smoothstep(-30.0f, -8.0f, h.p.z)) * step(0.1, hash(float3(float(h.instance), floor(c.t / (60 + 240 * r.z) + r.y), 2)));
        if (on == 0) return 0;
        bool tv = fract(r.y * 13) < 0.12;
        float flicker = 0.35 + 0.65 * c.noise(float3(c.t * 3, float(h.instance) * 0.37f, 1.5));
        float3 lamp = tv ? float3(0.3, 0.45, 1.0) * 0.5 * flicker : mix(blackbody(2500 + 2200 * r.y), float3(0.7, 0.92, 1.0), step(0.86, r.z)) * (0.5 + 1.2 * r.z);
        if (h.bounce > 0) return lamp * 0.3;
        float3 o = float3(h.local.x, h.local.y, 0), d = inward(h, c), hi = float3(1.45, 3.0, 3 + 2 * r.y);
        float4 q = interior(o, d, float3(-hi.x, 0.02, 0), hi);
        float3 albedo = q.w == 1 ? (q.y < 1 ? float3(0.16, 0.09, 0.05) : float3(0.75)) : mix(float3(0.55, 0.47, 0.36), hsv(r.y * 3, 0.3, 0.5), step(0.5, fract(r.x * 7)));
        float shade = corners(q, hi);
        // A cabinet against the back wall and a table in the room.
        int piece = furniture(o, d, float3(r.y * 1.6 - 1.5, 0, hi.z - 0.5), float3(1.3, 0.6 + 1.3 * r.z, 0.5), float3(r.z * 1.4 - 1.2, 0, 1 + r.x * 2), float3(0.9, 0.75, 0.8), q);
        if (piece >= 0) {
            albedo = float3(0.07, 0.05, 0.04) * (1 + float(piece));
            shade = 0.6;
        }
        float3 source = tv ? float3(0.5, 0.5, hi.z - 0.3) : float3(0.3 * r.z, 2.7, hi.z * 0.5);
        float3 color = albedo * lamp * shade * (0.08 + 2.4 / (0.4 + distance_squared(source, q.xyz)));
        float curtain = step(0.55, r.z) * step(0.8 - 0.5 * r.y, abs(h.local.x) * 1.25);
        float blinds = step(0.75, r.y) * step(0.45, fract(h.local.y * 11));
        return mix(color, lamp * float3(0.9, 0.7, 0.5) * 0.4 * (0.75 + 0.25 * sin(h.local.x * 60)), max(curtain, blinds * 0.85));
    }

    // A shop seen in parallax through its window: shelves or posters, a counter, a table and bright ceiling panels.
    static float3 shop(Hit h, Ctx c, uint kind) {
        float3 light = SHOP_LIGHT[kind];
        if (h.bounce > 0) return light * 0.6;
        float3 hi = float3(2.3, 3.3, 6), o = float3(h.local.x, h.local.y, 0), d = inward(h, c);
        float4 q = interior(o, d, float3(-hi.x, 0, 0), hi);
        float tiles = 0.6 + 0.4 * step(0.5, fract(floor(q.x / 0.5) * 0.5 + floor(q.z / 0.5) * 0.5));
        float3 albedo = q.w == 1 ? (q.y < 1 ? float3(0.3, 0.29, 0.27) * tiles : float3(0.6)) : float3(0.42, 0.4, 0.37);
        float along = q.w == 2 ? q.x : q.z, id = float(h.instance);
        if (q.w != 1) {
            // Stock on shelves, or a dark wainscot with menus and posters above it.
            float shelf = step(0.3, q.y) * step(q.y, 2.1) * step(0.5, q.w + float(kind == 1u)) * step(0.2, fract(q.y / 0.42));
            float2 slot = float2(floor(along / 0.22), floor(q.y / 0.42)), board = float2(floor(along / 1.3), id);
            float poster = (1 - shelf) * step(1.35, q.y) * step(q.y, 2.15) * step(abs(fract(along / 1.3) - 0.5), 0.3) * step(0.35, hash(board));
            albedo *= q.y < 1 && shelf == 0 ? 0.4 : 1;
            albedo = mix(albedo, hsv(hash(slot + id), 0.45, 0.15 + 0.3 * hash(slot.yx)), shelf);
            albedo = mix(albedo, hsv(hash(board + 3.0f), 0.55, 0.7), poster);
        }
        float shade = corners(q, hi);
        // A counter down one side and a table of goods in the middle; lit on top.
        float3 r = hash3(float3(float(h.instance), 2.2, 6.1)), counter = float3(0.7, 1.05, 3.5), table = float3(1.2, 0.8, 0.9);
        int piece = furniture(o, d, float3(r.x < 0.5 ? -2.3 : 1.6, 0, 1.5), counter, float3(r.y * 2 - 1.6, 0, 1.2 + 2 * r.z), table, q);
        if (piece >= 0) {
            albedo = piece == 0 ? float3(0.12, 0.07, 0.04) : hsv(r.z, 0.4, 0.3);
            shade = 0.55 + 0.45 * step((piece == 0 ? counter.y : table.y) - 0.01, q.y);
        }
        float panel = q.w == 1 && q.y > 3 ? step(0.65, fract(q.z / 1.4)) * step(abs(q.x), 1.4) : 0;
        return albedo * light * shade * (kind == 3u ? 0.3 : 0.75) * (0.3 + 0.7 * smoothstep(6.0f, 0.5f, q.z)) + light * panel * 2.5;
    }

    constant float4 STROKES[] = \#(strokes.metal);

    // Distance from f (0 to 1 across a glyph's cell) to the strokes of glyph `seed`.
    static float glyph(float2 f, float seed) {
        float d = 9;
        for (int s = 0; s < 4; s++) {
            // Short of the count, since hash() can round up to 1.
            float4 k = STROKES[uint(hash(float2(seed, s)) * (\#(strokes.count) - 0.01f))] * 0.5f;
            d = min(d, sdSegment(f, k.xy, k.zw));
        }
        return d;
    }

    // A lit sign box `size` across, p from its middle: bordered glyphs, lit on a dark face or dark on a lit one.
    static float3 lightbox(float2 p, float2 size, float3 color, float seed) {
        bool column = size.y > size.x;
        float2 q = column ? p : p.yx, s = column ? size : size.yx;
        float cell = s.x * 0.62, spacing = cell * 1.18, count = floor((s.y - s.x * 0.4) / spacing);
        float k = floor(q.y / spacing + count / 2);
        float2 f = float2(q.x / cell + 0.5, (q.y - (k - count / 2) * spacing) / cell - 0.08);
        float ink = k >= 0 && k < count && all(abs(f - 0.5) < 0.6) ? smoothstep(0.1, 0.06, glyph(column ? f : f.yx, hash(float2(k, seed)))) : 0;
        float edge = min(s.x / 2 - abs(q.x), s.y / 2 - abs(q.y));
        ink = max(ink, smoothstep(0.025, 0.012, abs(edge - 0.07)));
        bool dark = hash(seed + 0.37f) < 0.75;
        float3 face = dark ? color * 0.015 : color * 0.28 * (0.8 + 0.2 * sin(q.y * 9));
        return mix(face, dark ? color * 1.5 : float3(1.1, 1.05, 1.0), ink);
    }

    // A tower's lights: scattered windows or whole office floors, and a red beacon blinking on its roof.
    static float3 towerWindows(Hit h, Ctx c) {
        float3 r = hash3(float3(float(h.instance), 1.3, 2.9));
        if (h.local.y > 0.999 && all(abs(h.local.xz) > 0.47)) return float3(1, 0.05, 0.02) * 6 * step(0.8, fract(c.t * 0.45 + r.x));
        if (abs(h.n.y) > 0.5) return 0;
        float2 uv = planar(h.p, h.n);
        bool office = r.y > 0.6;
        float2 cell = uv / float2(office ? 1.5 : 1.1 + 0.6 * r.x, 3.6), f = fract(cell);
        float pane = office ? step(0.3, f.y) : step(0.25, f.x) * step(f.x, 0.75) * step(0.35, f.y) * step(f.y, 0.85);
        float3 k = hash3(float3(floor(cell), float(h.instance)));
        float lit = office ? step(hash(float2(floor(cell.y), float(h.instance))), 0.3 * r.z) * (0.6 + 0.4 * k.z) : step(k.x, 0.05 + 0.1 * r.z);
        float3 lamp = office ? float3(0.75, 0.9, 1.0) : blackbody(2600 + 2400 * k.y);
        return pane * lit * lamp * (0.08 + 0.2 * k.z);
    }

    Emission emission(Hit h, Ctx c) {
        Sign sign = SIGNS[h.tag];
        switch (h.material) {
        case LIGHTBOX:
            if (h.local.z < -0.01) return {float3(0), STEADY};
            return {lightbox(h.local.xy * sign.size, sign.size, sign.color.rgb, float(h.tag)), uint(sign.color.w)};
        case NEON: {
            float core = h.bounce == 0 ? 0.55 + 0.45 * abs(dot(h.n, normalize(c.eye - h.p))) : 0.8;
            return {sign.color.rgb * 1.8 * core, uint(sign.color.w)};
        }
        case SHOP: return {h.tag ? shop(h, c, h.tag) : float3(0), STEADY};
        case GLASS: return {room(h, c), STEADY};
        case LAMP: return {h.n.y < -0.5 ? float3(0.6, 0.85, 1.0) * 14 : float3(0), STEADY};
        case SIGNBOX: {
            if (h.local.z < 0.23) return {float3(0), STEADY};
            float3 r = hash3(float3(float(h.instance), 9.3, 4.4));
            return {lightbox(float2(h.local.x, h.local.y - 3.62), float2(4.3, 0.75), hsv(r.x, 0.8, 0.8), float(h.instance)) * step(0.3, r.y) * 0.6, STEADY};
        }
        case TOWER: return {towerWindows(h, c), STEADY};
        default: return {float3(0), STEADY};
        }
    }

    // MARK: Traffic

    // Car i at this sample's time, moved along over the shutter so it blurs: a sedan, a hatchback or a van, now and then a taxi.
    struct Car { float3 center; float facing, length, roof, cabin, back, seed; bool taxi, braking; };

    static Car car(int i, Ctx c) {
        float4 q = c.param(i);
        float seed = abs(q.w);
        bool taxi = fract(seed * 3.7f) < 0.14;
        uint b = taxi ? 0 : uint(fract(seed * 7.31f) * 3);
        float4 size = b == 0 ? float4(2.3, 1.4, 1.05, -0.25) : b == 1 ? float4(2.0, 1.46, 0.95, -0.3) : float4(2.4, 1.85, 1.75, -0.25);
        return {float3(q.x, 0, q.y + q.z * (c.t - c.f->time)), sign(q.z), size.x, size.y, size.z, size.w, seed, taxi, q.w < 0};
    }

    // A car in its own space (x right, y up, z forward); `wheel` gets the distance to its wheels.
    static float carShape(float3 q, Car k, thread float& wheel) {
        // The body rounds down over its nose and tail; the glasshouse narrows as it rises.
        float3 b = q - float3(0, 0.62, 0);
        b.y += 0.12 * smoothstep(k.length - 0.9, k.length, abs(q.z));
        float body = sdRoundBox(b, float3(0.89, 0.27, k.length), 0.16);
        float3 w = q - float3(0, (k.roof + 0.82) / 2, k.back);
        w.x *= 1 + 0.35 * saturate(w.y / (k.roof - 0.82) + 0.5);
        float cabin = sdRoundBox(w, float3(0.8, (k.roof - 0.82) / 2, k.cabin), 0.12);
        cabin = smax(cabin, dot(w, float3(0, 0.72, 0.69)) - k.cabin * 0.55, 0.12);
        cabin = smax(cabin, dot(w, float3(0, 0.78, -0.62)) - k.cabin * 0.66, 0.12);
        float d = smin(body, cabin, 0.08) * 0.8;
        if (k.taxi) d = min(d, sdRoundBox(q - float3(0, k.roof + 0.09, k.back), float3(0.28, 0.08, 0.12), 0.02));
        wheel = 9;
        for (int i = -1; i <= 1; i += 2) {
            float r = length(float2(q.y - 0.33, q.z - i * (k.length - 0.72)));
            d = smax(d, -max(r - 0.42, 0.6 - abs(q.x)), 0.03);
            wheel = min(wheel, max(r - 0.33, abs(abs(q.x) - 0.77) - 0.11));
        }
        return min(d, wheel);
    }

    // The low cloud's glow from the city's lights, brightest at the horizon.
    static float3 cityGlow(float up) { return mix(float3(0.04, 0.018, 0.034), float3(0.002, 0.0025, 0.007), smoothstep(0.0, 0.35, up)); }

    // What glossy paint and glass mirror: neon down the street that slides by as the car moves.
    static float3 mirrored(float3 r, float3 p) {
        if (r.y > 0.3) return cityGlow(r.y) * 1.5;
        float band = floor(atan2(r.x, r.z) * 9 + p.z * 0.35);
        float lit = step(0.55, hash(band + 3.3f)) * smoothstep(-0.08, 0.02, r.y) * smoothstep(0.3, 0.12, r.y);
        return hsv(hash(band), 0.7, 1.2) * lit + float3(0.01, 0.012, 0.016);
    }

    static float3 paintColor(float seed) {
        const float3 paints[7] = {float3(0.012), float3(0.5, 0.5, 0.48), float3(0.18, 0.19, 0.2), float3(0.015, 0.025, 0.07),
                                  float3(0.2, 0.01, 0.015), float3(0.03), float3(0.06, 0.065, 0.07)};
        return paints[uint(fract(seed * 13.7f) * 7)];
    }

    // The traffic, each car marched in a box round it and darkening the road beneath it.
    Live live(float3 ro, float3 rd, float maxDist, Ctx c) {
        float2 street = boxInterval(ro, rd, float3(-3.6, 0, -270), float3(3.6, 2, 20));
        if (street.x >= min(street.y, maxDist)) return nothing();
        float nearest = min(street.y, maxDist), shadow = 0, wheel;
        float3 ground = ro + rd * maxDist;
        int hit = -1;
        for (int i = 0; i < CARS && c.param(i).w != 0; i++) {
            Car k = car(i, c);
            shadow = max(shadow, 0.85 * smoothstep(0.6f, -0.2f, sdBox(ground.xz - k.center.xz, float2(0.8, k.length - 0.1))));
            float2 span = boxInterval(ro, rd, k.center - float3(0.95, 0, k.length + 0.15), k.center + float3(0.95, k.roof + 0.2, k.length + 0.15));
            if (span.x >= min(span.y, nearest)) continue;
            float t = sdfMarch([&](float3 p) { return carShape((p - k.center) * float3(k.facing, 1, k.facing), k, wheel); }, ro, rd, span.x, min(span.y, nearest), 40);
            if (t > 0) {
                nearest = t;
                hit = i;
            }
        }
        if (hit < 0) return Live{0, ground.y < 0.05 ? shadow : 0, maxDist};
        Car k = car(hit, c);
        float3 p = ro + rd * nearest, axes = float3(k.facing, 1, k.facing);
        auto shape = [&](float3 x) { return carShape((x - k.center) * axes, k, wheel); };
        float3 n = sdfNormal(shape, p, 2e-3f), q = (p - k.center) * axes;
        shape(p);
        float3 albedo = k.taxi ? float3(0.45, 0.28, 0.02) : paintColor(k.seed), lamp = 0;
        float gloss = 1;
        if (wheel < 0.01) {
            albedo = 0.015;
            gloss = 0.05;
        } else if (q.y > k.roof + 0.01) {
            lamp = float3(1, 0.75, 0.35) * 3;
        } else if (q.y > 0.93 && q.y < k.roof - 0.05 && abs(n.y) < 0.85) {
            albedo = 0.008;
            gloss = 2;
        } else if (q.y < 0.45) {
            albedo = 0.018;
            gloss = 0.3;
        }
        if (q.z > k.length - 0.12 && q.y > 0.52 && q.y < 0.76 && abs(q.x) > 0.4 && abs(q.x) < 0.84) lamp = float3(1, 0.9, 0.78) * 25;
        if (q.z < 0.12 - k.length && q.y > 0.6 && q.y < 0.82 && abs(q.x) < 0.84) lamp = float3(1, 0.04, 0.02) * (abs(q.x) < 0.5 ? 0.8 : k.braking ? 11 : 3);
        float fresnel = schlick(0.04f, dot(n, -rd));
        // Unshadowed: little in the street stands between a car and the lamps and signs over it.
        return Live{lamp + albedo * c.light(p) * (0.7 + 0.7 * n.y) + fresnel * gloss * mirrored(reflect(rd, n), p), 1, nearest};
    }

    // Rain on the puddles: the reflections in them brighten and darken in spreading rings.
    float3 groupTint(uint group, float3 p, Ctx c) {
        float3 tint = c.f->tint[group].rgb;
        if (abs(p.y) > 0.01 || abs(p.x) > ROAD_EDGE) return tint;
        float2 g = p.xz * 2.5, cell = floor(g);
        float3 r = hash3(float3(cell, 5.5));
        float age = fract(c.t * (0.7 + 0.6 * r.z) + r.x);
        float d = length(g - cell - 0.25 - 0.5 * r.xy) - age * 0.45;
        if (abs(d) > 0.1) return tint;
        float ring = (smoothstep(0.05, 0.0, abs(d)) - 0.6 * smoothstep(0.05, 0.0, abs(d + 0.07))) * (1 - age);
        return tint * (1 + 1.5 * ring * puddle(p.xz, c, 2));
    }

    // MARK: Rain and steam

    // Rain falling through the view, slanting a little in the wind, lit by whatever light it passes.
    Particle rain(uint i, Ctx c) {
        float3 a = hash3(float3(i, 1.3, 7.1));
        float ahead = mix(1.5f, 50.0f, a.x * a.x), height = c.eye.y + 1.3 * ahead + 3;
        float phase = c.t * 9 / height + a.y, cycle = floor(phase), f = phase - cycle;
        float3 b = hash3(float3(i, cycle, 2.9));
        Particle s;
        s.velocity = float3(0.7, -9, 0.3);
        s.position = float3((b.x - 0.5) * 3.8 * ahead, height * (1 - f), c.eye.z - ahead + b.y) - s.velocity * (1 - f) * 0.05;
        s.size = 0.0015 + 0.002 * b.z;
        s.color = c.light(s.position) * 2.5 + float3(0.012, 0.015, 0.02);
        s.alpha = 0.7;
        s.tail = 0.7;
        return s;
    }

    // Drops bursting back up off the wet street, catching the light.
    Particle splash(uint i, Ctx c) {
        const float life = 0.25;
        float3 a = hash3(float3(i, 4.4, 0.7));
        float phase = c.t / life + a.x, cycle = floor(phase), age = (phase - cycle) * life;
        float3 b = hash3(float3(i, cycle, 6.6));
        float x = (b.y - 0.5) * 2 * FRONTAGE, ground = abs(x) > ROAD_EDGE ? CURB : 0;
        float3 kick = float3((b.z - 0.5) * 0.8, 0.9 + 0.7 * a.z, (a.y - 0.5) * 0.8);
        Particle s;
        s.position = float3(x, ground, -mix(6.0f, 45.0f, b.x)) + kick * age - float3(0, 4.9 * age * age, 0);
        s.velocity = kick - float3(0, 9.8 * age, 0);
        s.size = 0.005;
        s.color = c.light(s.position) * 1.5 + 0.01;
        s.alpha = (1 - age / life) * step(ground, s.position.y);
        s.glow = 0.4;
        s.halo = 4;
        return s;
    }

    // Water dripping off the front edges of the awnings, a drop at a time.
    Particle drip(uint i, Ctx c) {
        float4 eave = EAVES[i % EAVE_COUNT];
        float3 a = hash3(float3(i, 3.3, 9.1));
        float period = 0.8 + 1.8 * a.x, phase = c.t / period + a.y, cycle = floor(phase), age = (phase - cycle) * period;
        Particle s;
        s.position = float3(eave.x, eave.y - 4.9 * age * age, mix(eave.z, eave.w, hash(float2(i, cycle))));
        s.velocity = float3(0, -9.8 * age, 0);
        s.size = 0.003;
        s.color = c.light(s.position) * 2 + 0.01;
        s.alpha = 0.8 * step(CURB, s.position.y);
        return s;
    }

    // Steam rolling out of two manholes and drifting off, lit by the signs.
    Particle steam(uint i, Ctx c) {
        const float life = 9;
        float phase = c.t / life + hash(float(i) + 0.31f), cycle = floor(phase), f = phase - cycle, age = f * life;
        float3 a = hash3(float3(i, cycle, 8.1)), rise = float3(0.22, 0.35, -0.1);
        Particle s;
        s.position = VENTS[i % 2] + float3((a.x - 0.5) * 0.5, 0.05, (a.z - 0.5) * 0.5) + rise * age
                     + 0.3 * f * float3(sin(age * 0.9 + a.y * 6), 0, cos(age * 0.7 + a.x * 6));
        s.velocity = rise;
        s.size = 0.3 + 1.8 * f;
        s.color = 2.5 * c.light(s.position) + 0.012;
        s.alpha = 0.06 * smoothstep(0.0, 0.08, f) * (1 - f);
        s.puff = 1;
        return s;
    }

    // A halo in the wet air round each lamp that faces the eye: headlights, tail lights and the street lamps.
    Particle halo(uint i, Ctx c) {
        Particle s;
        s.size = 0.06;
        s.alpha = 1;
        s.glow = 0.3;
        s.halo = 10;
        if (i >= 2 * CARS) {
            s.position = LAMPS[i - 2 * CARS] - float3(0, 0.12, 0);
            s.color = float3(0.6, 0.85, 1.0) * 4;
            return s;
        }
        Car k = car(i / 2, c);
        bool head = k.facing > 0;
        s.position = k.center + float3((i & 1 ? 1 : -1) * (head ? 0.62 : 0.67), head ? 0.64 : 0.71, k.length + 0.08);
        s.velocity = float3(0, 0, c.param(i / 2).z);
        s.color = head ? float3(1, 0.9, 0.78) * 6 : float3(1, 0.05, 0.02) * (k.braking ? 4 : 1.2);
        s.alpha = c.param(i / 2).w != 0;
        return s;
    }

    // MARK: Sky and air

    // Low cloud lit from beneath by the city, drifting.
    float3 sky(float3 d, Ctx c) {
        if (d.y < 0) return float3(0.002, 0.002, 0.003);
        float up = d.y;
        float2 deck = d.xz / (up + 0.08) * 0.35 + float2(c.t * 0.006, c.t * 0.002);
        float cloud = c.fbm(float3(deck, 0.5), 4);
        return cityGlow(up) * (0.15 + 2.2 * cloud * cloud);
    }

    // Rainy haze that thins with height, lit by every lamp and sign and faintly by the city.
    Atmosphere atmosphere(float3 ro, float3 rd, float dist, Ctx c) {
        const float density = 0.02, height = 16.7;
        float d = min(dist, 800.0f), near = density * exp(-ro.y / height);
        float3 transmittance = float3(exp(-fogDepth(ro, rd, d, density, height)));
        // Rain falling through the glow round every light, as streaks scrolling down the view.
        float rain = 0.85 + 0.3 * c.noise(float3(atan2(rd.x, -rd.z) * 500, rd.y * 70 + c.t * 25, 0.5));
        // Only so far, and only near each light, since the gathered light isn't dimmed by the haze.
        float far = min(d, 45.0f);
        float3 glow = c.inscatter(ro, rd, far, DISTANT_LIGHTS | LOCAL_LIGHTS, 4) + 0.5 * c.inscatter(ro, rd, far, LIVE_LIGHTS, 1.5);
        return {glow * near * rain + float3(0.008, 0.005, 0.01) * (1 - transmittance), transmittance};
    }
    """#)
}
