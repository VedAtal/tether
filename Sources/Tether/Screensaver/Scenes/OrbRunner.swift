import simd

extension SaverScene {
    static let orbRunner = SaverScene(name: "Orb Runner", symbol: "airplane") { OrbRunner.world() }
}

/// A sandstone canyon at golden hour, laid out as a race course: a racer flies itself out along
/// the right, round a hairpin and back along the left, threading ring gates that flash as it
/// passes, while a hologram over the course counts its score.
private enum OrbRunner {
    enum Group {
        static let sun = 0, sky = 1, lamps = 2
    }

    /// Matches the shader's `enum`.
    enum Material: Int {
        case wall, ground, water, rock, scrub, housing, armor, steel, paint, channel, lamp, beacon, marker, lens, bay, banner, sheet, sign
    }

    static let fieldOfView: Float = 30
    static let sun = simd_normalize(SIMD3<Float>(0.38, 0.41, -0.83))
    static let sunColor = SIMD3<Float>(5, 2.8, 1.25)

    static func world() -> SaverWorld {
        var world = SaverWorld(camera: .init(eye: [6, 12, 8], target: [2, 8, -60], fieldOfView: fieldOfView), shader: shader)
        world.look.exposure = 0.9
        world.look.bounces = 1
        world.look.liveSamples = 4
        world.groups = 3
        world.skyGroup = Group.sky
        world.liveReflections = true
        addCanyon(&world)
        addRocks(&world)
        addScrub(&world)
        addGates(&world)
        addGantry(&world)
        addFloodlights(&world)
        addMarkers(&world)
        addGarage(&world)
        addWalkway(&world)
        world.lights = [.directional(toward: sun, angle: 0.035, color: sunColor, group: Group.sun)]
            + walkwayLamps.map { .sphere($0 + [-0.3, -0.2, 0], radius: 0.25, color: [22, 14, 7], group: Group.lamps) }
            + [.sphere([garageFront + 4.5, ground(garageFront + 4.5, garageZ) + 5.2, garageZ - 1], radius: 1.2, color: [40, 27, 15], group: Group.lamps)]
        world.particles = [.init(function: "trail", count: 1600, blend: .additive), .init(function: "orbs", count: orbs.count, blend: .additive),
                           .init(function: "sparks", count: 16 * orbs.count, blend: .additive), .init(function: "dust", count: 160, blend: .alpha)]
        world.update = { time, frame in
            let t = Float(time), now = progress(t)
            frame.lights = floodlights
            var score: Float = 0
            for (g, gate) in gates.enumerated() {
                let last = (now - gate.progress).rounded(.down) + gate.progress
                let since = t - passTime(last, near: t - (now - last) * lap), until = passTime(last + 1, near: t + (last + 1 - now) * lap) - t
                // Cyan while it waits, brightening as the ship nears, a white burst as it passes, then amber for a few seconds.
                let cleared = smoothstep(0, 0.4, since) * (1 - smoothstep(4, 9, since))
                let color = simd_mix(SIMD3<Float>(0.1, 0.55, 1) * (0.7 + 1.3 * exp(-until * 0.7)), [1.2, 0.48, 0.1], SIMD3(repeating: cleared))
                    + SIMD3<Float>(1, 0.92, 0.85) * 8 * exp(-since * 5)
                frame.params[1 + g] = SIMD4(color, until)
                frame.lights.append(.init(position: gate.position, radius: 2.5, color: 90 * color, range: 24))
                score += 100 * ((now - gate.progress).rounded(.down) + min(since / 0.6, 1))
            }
            for orb in orbs {
                score += 25 * (now - orb).rounded(.down) + 25
                let since = (now - orb - (now - orb).rounded(.down)) * lap / (1 - 0.35 * cos(4 * .pi * orb))
                if since < 0.6 { frame.lights.append(.init(position: line(orb, t), radius: 0.4, color: [4, 14, 20] * (1 - since / 0.6), range: 10)) }
            }
            frame.params[0] = SIMD4(max(score, 0).rounded(), now.rounded(.down) + 1, Procedural.noise([t * 0.7, 3, 0]), 0)
            let ship = line(now, t), velocity = (line(progress(t + 0.01), t + 0.01) - line(progress(t - 0.01), t - 0.01)) / 0.02
            frame.params[8] = SIMD4(ship, 0)
            frame.params[9] = SIMD4(velocity, 0)
            let flicker = 0.9 + 0.1 * Procedural.noise([t * 23, 0, 0])
            frame.lights.append(.init(position: ship - simd_normalize(velocity) * 4.2, radius: 0.6, color: [20, 45, 80] * flicker, shadows: true, range: 25))
        }
        return world
    }

    // MARK: The canyon

    /// The canyon's middle, its floor's half width and its walls' height, at z.
    static func center(_ z: Float) -> Float { 7 * sin(z / 95 + 0.4) + 3 * sin(z / 41 + 1.3) }
    static func halfWidth(_ z: Float) -> Float { 30 + 4 * sin(z / 63) + 0.4 * max(0, -420 - z) }
    static func rim(_ z: Float) -> Float { 6 + 48 * smoothstep(-760, -420, z) }

    /// The rock's layers from 6 m down, bottom up: (top, how far its face stands back,
    /// hardness). Hard layers stand out as cliffs, soft ones weather back into notches, and each
    /// step back is a ledge.
    static let strata: [SIMD3<Float>] = {
        var layers: [SIMD3<Float>] = []
        var top: Float = -6, face: Float = 0, k: Int32 = 0
        while top < 62 {
            let massive = Procedural.hash(k, 7, 1) < 0.35
            let hard = massive ? 1 : Procedural.hash(k, 4, 1)
            top += massive ? 6 + 9 * Procedural.hash(k, 5, 1) : 1.5 + 3.5 * Procedural.hash(k, 5, 1)
            layers.append([top, face, hard])
            face += hard > 0.45 ? 0.8 + 2.2 * Procedural.hash(k, 6, 1) : 1.2
            k += 1
        }
        return layers
    }()

    /// How far the strata have risen at z: they dip and roll gently along the canyon.
    static func tilt(_ z: Float) -> Float { 0.008 * z + 2 * sin(z / 150) }

    /// How far a wall's face stands back from the floor's edge at bedding height b. Joints split
    /// the cliffs into blocks of uneven width, each standing out its own amount, some hollowed
    /// into arched alcoves, and the whole face swings in and out in bays.
    static func face(_ b: Float, _ z: Float, _ side: Float) -> Float {
        let y = b - tilt(z)
        var bottom: Float = -6, k = 0
        while k < strata.count - 1 && b >= strata[k].x {
            bottom = strata[k].x
            k += 1
        }
        let layer = strata[k], u = min(max((b - bottom) / (layer.x - bottom), 0), 1), massive = layer.x - bottom > 6
        let key = Int32(k) &+ (side > 0 ? 977 : 0)
        let cell = z / (5 + 9 * Procedural.hash(key, 7, 3)) + 3 * Procedural.noise([z / 31, Float(k) * 1.7, side * 5]), block = cell.rounded(.down)
        let f = cell - block, edge = min(f, 1 - f), seed = Int32(block) &* 31 &+ key
        let joint = Procedural.hash(Int32(cell.rounded()) &* 7 &+ key, 5, 3), width = 0.06 + 0.12 * joint
        let joined = smoothstep(0, width, edge)
        var x = layer.y + 7 * sin(z / 41 + side * 2) * smoothstep(-8, 10, y) + 3 * sin(z / 17 + side) + (massive ? 1.4 : 0.6) * (Procedural.hash(seed, 1, 3) - 0.5) * joined
        if layer.z > 0.45 {
            x += -0.3 + (massive ? 0.6 * pow(smoothstep(0.9, 1, u), 2) : (Procedural.hash(seed, 6, 3) - 0.3) * 0.5 * u) + 0.4 * (1 - smoothstep(0, 0.08, u))
            if massive, Procedural.hash(seed, 2, 3) < 0.22 {
                let dz = (f - 0.5) / 0.5, dy = (u - 0.5) / (u < 0.5 ? 0.35 : 0.55)
                x += (1.5 + 2.5 * Procedural.hash(seed, 3, 3)) * smoothstep(0, 0.7, 1 - dz * dz - dy * dy)
            }
        } else {
            x += (0.2 + 1.2 * Procedural.hash(seed, 4, 3)) * u
        }
        return x + (massive ? 0.3 + 2.4 * pow(joint, 3) : 0.2 + 0.5 * joint) * (1 - joined) * smoothstep(-6, 4, y)
    }

    /// How far a wall's face is from the canyon's middle at height y.
    static func wall(_ y: Float, _ z: Float, _ side: Float) -> Float {
        let erosion = 4 * (Procedural.fbm([z / 35, y / 22, side], octaves: 4) - 0.5) + 1.6 * (Procedural.fbm([z / 6, y / 40, side + 3], octaves: 2) - 0.5)
        return halfWidth(z) + face(y + tilt(z), z, side) + erosion
    }

    static func ground(_ x: Float, _ z: Float) -> Float {
        let d = abs(x - center(z)), w = halfWidth(z)
        let dunes = 0.9 * (Procedural.fbm([x / 30, 0, z / 30], octaves: 4) - 0.5) + 0.3 * (Procedural.fbm([x / 7, 1, z / 9], octaves: 3) - 0.5)
        let bed = center(z) + 6 * sin(z / 27 + 1)
        let channel = -0.9 * exp(-pow((x - bed) / 3.5, 2))
        let pad = x > center(z) ? smoothstep(13, 8, abs(z - garageZ)) : 0
        let talus = 10 * pow(smoothstep(w - 13, w + 2, d), 1.6) * (0.6 + 0.8 * Procedural.fbm([x / 12, 2, z / 12], octaves: 3)) * (1 - 0.92 * pad)
        return dunes + channel + talus
    }

    static let waterLevel: Float = -0.42

    /// The walls, in rows 0.4 m apart up the bedding, then the plateau above.
    static func addCanyon(_ world: inout SaverWorld) {
        let columns = 1100, rows = 170
        for side: Float in [-1, 1] {
            world.add(.parametric(columns, rows + 8) { i, j in
                let z = 40 - 840 * pow(Float(i) / Float(columns), 2), out = Float(max(0, j - rows))
                let y = min(-6 + 0.4 * Float(min(j, rows)) - tilt(z), rim(z))
                return [center(z) + side * (wall(y, z, side) + 1.5 * out * out), y + 0.3 * out, z]
            }, material: Material.wall.rawValue)
        }
        let deep = 450, wide = 300
        world.add(.parametric(deep, wide) { i, j in
            let z = 60 - 1360 * pow(Float(i) / Float(deep), 1.8)
            let v = Float(j) / Float(wide) * 2 - 1
            let x = center(z) + 170 * v * abs(v)
            return [x, ground(x, z), z]
        }, material: Material.ground.rawValue)
        world.add(.grid(size: [400, 1400], cells: [1, 1]), material: Material.water.rawValue, at: [.translation([0, waterLevel, -600])], castsShadows: false)
    }

    /// Blocks fallen from the cliffs heaped at their feet, stones across the floor, and pebbles
    /// near the eye.
    static func addRocks(_ world: inout SaverWorld) {
        var random = SeededRandom(seed: 11)
        func r() -> Float { Float.random(in: 0..<1, using: &random) }
        let blocks = (0..<6).map { block(seed: Int32($0)) }
        let stones = (0..<5).map { Mesh.stone(seed: 40 + Int32($0), roughness: 0.35, subdivisions: 3) }
        var blockPlaces = [[simd_float4x4]](repeating: [], count: blocks.count), stonePlaces = [[simd_float4x4]](repeating: [], count: stones.count)
        func scatter(_ count: Int, near: ClosedRange<Float>, size: (Float) -> Float, spread: (Float, Float) -> Float, into places: inout [[simd_float4x4]]) {
            for i in 0..<count {
                let z = near.upperBound - (near.upperBound - near.lowerBound) * pow(r(), 1.3)
                let x = center(z) + spread(r(), z), s = size(r())
                if x > center(z) + 10, abs(z - garageZ) < 12 { continue }
                let up = simd_normalize(SIMD3(r() - 0.5, 2.2, r() - 0.5))
                places[i % places.count].append(.place([x, ground(x, z) - 0.12 * s, z], up: up, yaw: r() * 6.3, scale: SIMD3(repeating: s)))
            }
        }
        let side = { (u: Float, z: Float) -> Float in (u < 0.5 ? -1 : 1) * (halfWidth(z) - 2 - 12 * pow(abs(u * 2 - 1), 3)) }
        scatter(300, near: -520...4, size: { 1 + 5 * pow($0, 3) }, spread: side, into: &blockPlaces)
        scatter(500, near: -420...(-10), size: { 0.25 + 1.1 * pow($0, 3) }, spread: { u, z in (u * 2 - 1) * halfWidth(z) }, into: &stonePlaces)
        scatter(2600, near: -140...(-10), size: { 0.05 + 0.2 * pow($0, 2) }, spread: { u, _ in (u * 2 - 1) * 30 }, into: &stonePlaces)
        for (mesh, places) in zip(blocks + stones, blockPlaces + stonePlaces) { world.add(mesh, material: Material.rock.rawValue, at: places) }
    }

    /// Dry scrub clinging to the ledges of both walls and dotting the talus at their feet.
    static func addScrub(_ world: inout SaverWorld) {
        var random = SeededRandom(seed: 23)
        func r() -> Float { Float.random(in: 0..<1, using: &random) }
        let bushes = (0..<3).map { seed in
            Mesh.sphere(radius: 0.5, subdivisions: 3).displaced { p, _ in
                0.22 * (Procedural.fbm(p * 7 + Float(seed) * 5, octaves: 3) - 0.5) + 0.12 * (Procedural.noise(p * 19 + Float(seed)) - 0.5) - 0.1 * max(-p.y * 2, 0)
            }
        }
        var places = [[simd_float4x4]](repeating: [], count: bushes.count)
        for i in 0..<420 {
            let z = -4 - 260 * pow(r(), 1.4), side: Float = r() < 0.5 ? -1 : 1, s = 0.5 + 0.9 * r()
            var p: SIMD3<Float>
            if i % 3 == 0 {
                let x = center(z) + side * (halfWidth(z) - 3 - 8 * r())
                p = [x, ground(x, z) - 0.1 * s, z]
            } else {
                let boundary = strata[Int(r() * Float(strata.count - 1))].x, y = boundary - tilt(z)
                guard y > 1, y < rim(z) - 1 else { continue }
                p = [center(z) + side * (wall(y - 0.05, z, side) + wall(y + 0.05, z, side)) / 2, y - 0.05 * s, z]
            }
            places[i % bushes.count].append(.place(p, yaw: r() * 6.3, scale: [s, s * (0.5 + 0.3 * r()), s]))
        }
        for (mesh, transforms) in zip(bushes, places) { world.add(mesh, material: Material.scrub.rawValue, at: transforms) }
    }

    /// A weathered block about a meter long: a rounded cube, chipped, with corners broken off
    /// along flat fractures.
    static func block(seed: Int32) -> Mesh {
        var mesh = Mesh.sphere(radius: 1, subdivisions: 4)
        let cuts = (0..<3).map { i in simd_normalize(SIMD3(Procedural.hash(seed, Int32(i), 8) - 0.5, Procedural.hash(seed, Int32(i), 9) - 0.3, Procedural.hash(seed, Int32(i), 10) - 0.5)) }
        mesh.positions = mesh.positions.map { v in
            var p = SIMD3(pow(abs(v.x), 0.3) * (v.x < 0 ? -1 : 1), pow(abs(v.y), 0.3) * (v.y < 0 ? -1 : 1), pow(abs(v.z), 0.3) * (v.z < 0 ? -1 : 1))
            p *= 1 + 0.12 * (Procedural.fbm(v * 2.5 + Float(seed) * 3, octaves: 4) - 0.5)
            for (i, n) in cuts.enumerated() { p -= n * max(0, simd_dot(p, n) - 0.55 - 0.3 * Procedural.hash(seed, Int32(i), 11)) }
            return p * SIMD3(0.55, 0.36, 0.45)
        }
        return mesh.withSmoothNormals()
    }

    // MARK: The course

    /// A lap takes `lap` seconds, and a SaverWorld.cycle holds a whole number of laps and of every
    /// slower rhythm below, so the motion joins up where the time starts over.
    static let cycle = Float(SaverWorld.cycle), lap: Float = 36
    /// The loop: two straights joined by turns, the near one sweeping under the eye.
    static let straight: Float = 230, turn: Float = 13, nearTurn: Float = -4
    static let perimeter = 2 * straight + 2 * .pi * turn

    /// The loop at fraction s of a lap, as (across from the canyon's middle, z): out along the
    /// right, round the far hairpin and back along the left, from the middle of the near turn.
    static func loop(_ s: Float) -> SIMD2<Float> {
        let q = (s - s.rounded(.down)) * perimeter, a = .pi / 2 * turn, far = nearTurn - straight
        if q < a { return [turn * sin(q / turn), nearTurn + turn * cos(q / turn)] }
        if q < a + straight { return [turn, nearTurn - q + a] }
        if q < 3 * a + straight { return [turn * cos((q - a - straight) / turn), far - turn * sin((q - a - straight) / turn)] }
        if q < 3 * a + 2 * straight { return [-turn, far + q - 3 * a - straight] }
        return [-turn * cos((q - 3 * a - 2 * straight) / turn), nearTurn + turn * sin((q - 3 * a - 2 * straight) / turn)]
    }

    /// The racing line at fraction s, slaloming and rising and dipping; at time t its line drifts
    /// a little from lap to lap.
    static func line(_ s: Float, _ t: Float, drift: Float = 1) -> SIMD3<Float> {
        let plan = loop(s), w = 2 * Float.pi * s, slow = 2 * Float.pi * t / cycle
        let x = plan.x + 3 * sin(5 * w) + drift * 1.4 * sin(4 * w + 53 * slow)
        let y = 7 + 2.5 * sin(3 * w + 0.5) + 1.2 * sin(7 * w + 1.3) + drift * 0.9 * sin(6 * w + 71 * slow)
        return [center(plan.y) + x, y, plan.y]
    }

    /// Laps flown by time t, slowing into the turns and running a little early or late.
    static func progress(_ t: Float) -> Float {
        let tau = t / lap + 0.015 * sin(2 * .pi * 37 * t / cycle)
        return tau - 0.35 / (4 * .pi) * sin(4 * .pi * tau)
    }

    /// When progress reaches `target`, refined from a guess.
    static func passTime(_ target: Float, near guess: Float) -> Float {
        var t = guess
        for _ in 0..<4 { t -= (progress(t) - target) * 0.02 / (progress(t + 0.01) - progress(t - 0.01)) }
        return t
    }

    /// Seven gates, three out along the right, one at the hairpin and three back along the left, each
    /// where the line (without its drift) crosses it.
    static let gates: [(progress: Float, position: SIMD3<Float>, forward: SIMD3<Float>)] = {
        let a = Float.pi / 2 * turn, far = nearTurn - straight
        let out: [Float] = [-30, -88, -160], back: [Float] = [-190, -130, -62]
        let fractions = out.map { (a + nearTurn - $0) / perimeter } + [0.5] + back.map { (3 * a + straight + $0 - far) / perimeter }
        return fractions.map { s in
            let p = line(s, 0, drift: 0)
            return (s, p, simd_normalize(line(s + 0.001, 0, drift: 0) - p))
        }
    }()

    /// Orbs float on the line between the gates, two in each gap.
    static let orbs: [Float] = zip(gates, gates.dropFirst()).flatMap { g, next in [1, 2].map { g.progress + (next.progress - g.progress) * $0 / 3 } }

    /// A gate standing in its own xy plane: a chunky housing, lit channels round its inside and
    /// both faces, cooling fins and two collars for its legs.
    static func ring() -> (housing: Mesh, channel: Mesh) {
        let profile: [SIMD2<Float>] = [[4.49, -0.51], [4.83, -0.51], [4.83, -0.41], [5.04, -0.41], [5.04, -0.51], [5.27, -0.51], [5.44, -0.34], [5.44, 0.34],
                                       [5.27, 0.51], [5.04, 0.51], [5.04, 0.41], [4.83, 0.41], [4.83, 0.51], [4.49, 0.51], [4.39, 0.41], [4.39, 0.2],
                                       [4.59, 0.15], [4.59, -0.15], [4.39, -0.2], [4.39, -0.41]]
        var housing = Mesh()
        for (p, q) in zip(profile, profile.dropFirst() + [profile[0]]) {
            housing += .parametric(1, 192, wrap: true) { i, j in
                let e = i == 0 ? p : q, angle = Float(j) / 192 * 2 * .pi
                return [e.x * cos(angle), e.x * sin(angle), e.y]
            }
        }
        for k in 0..<8 {
            housing += Mesh.box([0.5, 0.12, 0.8]).transformed(.rotation((Float(k) + 0.5) / 8 * 2 * .pi, axis: [0, 0, 1]) * .translation([5.62, 0, 0]))
        }
        for angle in collars { housing += Mesh.box([0.8, 1.1, 1.3], segments: 2).transformed(.rotation(angle, axis: [0, 0, 1]) * .translation([5.6, 0, 0])) }
        func circle(_ r: Float, _ z: Float) -> [SIMD3<Float>] { (0...192).map { j in SIMD3(r * cos(Float(j) / 192 * 2 * .pi), r * sin(Float(j) / 192 * 2 * .pi), z) } }
        let channel = [circle(4.55, 0), circle(4.935, 0.46), circle(4.935, -0.46)].map { Mesh.tube($0, radius: { _ in 0.085 }, segments: 8) }.reduce(Mesh(), +)
        return (housing, channel)
    }

    static let collars: [Float] = [215 * .pi / 180, 325 * .pi / 180]

    /// A gate's own frame: its axis along the line, standing upright.
    static func frame(_ position: SIMD3<Float>, _ forward: SIMD3<Float>) -> simd_float4x4 {
        let ahead = simd_normalize(SIMD3(forward.x, 0, forward.z)), right = simd_cross([0, 1, 0], ahead)
        return simd_float4x4(columns: (SIMD4(right, 0), [0, 1, 0, 0], SIMD4(ahead, 0), SIMD4(position, 1)))
    }

    /// The gates on splayed legs braced together, each foot on a concrete pad. Each gate's channels
    /// carry its index as their tag, so they glow in its own color.
    static func addGates(_ world: inout SaverWorld) {
        let frames = gates.map { frame($0.position, $0.forward) }, (housing, channel) = ring()
        world.add(housing, material: Material.housing.rawValue, at: frames)
        for (g, m) in frames.enumerated() { world.add(channel, material: Material.channel.rawValue, at: [m], castsShadows: false, tag: g) }
        var legs = Mesh(), pads: [simd_float4x4] = []
        for m in frames {
            let tops = collars.map { angle -> SIMD3<Float> in (m * SIMD4<Float>(5.8 * cos(angle), 5.8 * sin(angle), 0, 1)).xyz }
            var feet: [SIMD3<Float>] = []
            for top in tops {
                let out = simd_normalize(SIMD3(top.x - m.columns.3.x, 0, top.z - m.columns.3.z))
                var foot = top + out * 1.6
                foot.y = ground(foot.x, foot.z)
                guard top.y - foot.y > 0.8 else { continue }
                legs += strut(top, foot - [0, 0.3, 0], 0.24)
                pads.append(.place(foot, yaw: atan2(out.x, out.z), scale: [1.2, 0.5, 1.2]))
                feet.append(foot)
            }
            if feet.count == 2 {
                let (a, b) = (tops[0], tops[1])
                legs += strut((a + feet[0]) / 2, (b + feet[1]) / 2, 0.09) + strut((a + feet[0]) / 2, b, 0.07) + strut(a, (b + feet[1]) / 2, 0.07)
            }
        }
        world.add(legs, material: Material.steel.rawValue)
        world.add(.box([1, 1, 1], segments: 2), material: Material.rock.rawValue, at: pads)
    }

    static let garageZ: Float = -24
    static var garageFront: Float { [-4, 0, 3].flatMap { dz in [0, 2, 4, 6].map { center(garageZ + dz) + wall($0, garageZ + dz, 1) } }.min()! - 9.5 }

    /// A crew's pit stall by the right wall near the eye, open toward the eye: corrugated walls and
    /// roof with the racer's number lit on its edge, a lit back wall of racks on a steel deck, tool
    /// chests inside, crates and fuel drums outside.
    static func addGarage(_ world: inout SaverWorld) {
        let x = garageFront, z = garageZ, floor = ground(x + 4.5, z) - 0.2, deck = floor + 0.55
        var steel = Mesh(), sheet = Mesh()
        for px: Float in [0, 4.5, 9] { steel += strut([x + px, floor, z + 3], [x + px, floor + 6.2, z + 3], 0.16) }
        steel += strut([x, floor + 6.2, z + 3], [x + 9, floor + 6.2, z + 3], 0.12)
        steel += .box([9.4, 0.7, 7.6], center: [x + 4.5, floor + 0.2, z - 0.7])
        sheet += .box([10, 0.4, 8], center: [x + 4.5, floor + 6.5, z - 0.6], segments: 2)
        for side in [x - 0.2, x + 9.2] { sheet += .box([0.4, 6.4, 7.4], center: [side, floor + 3.2, z - 0.8], segments: 2) }
        world.add(steel, material: Material.steel.rawValue)
        world.add(sheet, material: Material.sheet.rawValue)
        world.add(.box([3.2, 1.1, 0.25]), material: Material.sign.rawValue, at: [.translation([x + 4.5, floor + 7.25, z + 3.3])])
        world.add(.box([9, 6.2, 0.3], segments: 2), material: Material.bay.rawValue, at: [.translation([x + 4.5, floor + 3.1, z - 4.3])])
        var random = SeededRandom(seed: 5)
        func r() -> Float { Float.random(in: 0..<1, using: &random) }
        var crates: [simd_float4x4] = [.place([x + 2.5, deck, z - 3.5], scale: [2.6, 1, 0.9]), .place([x + 7, deck, z - 3.6], scale: [1.2, 2.2, 0.8])], drums: [simd_float4x4] = []
        for k in 0..<9 {
            let size = 1.1 + 0.7 * r(), p = SIMD3(x - 0.5 + 4 * r(), 0, z + 4.5 + 4 * r())
            crates.append(.place([p.x, ground(p.x, p.z) - 0.1 + (k % 3 == 2 ? size * 0.8 : 0), p.z], yaw: r() * 0.6, scale: [size, size * 0.8, size * 1.2]))
        }
        for _ in 0..<7 {
            let p = SIMD3(x + 5 + 4 * r(), 0, z + 4 + 3 * r())
            drums.append(.place([p.x, ground(p.x, p.z) - 0.05, p.z], up: simd_normalize(SIMD3(r() - 0.5, 6, r() - 0.5))))
        }
        world.add(.box([1, 1, 1], center: [0, 0.5, 0], segments: 3), material: Material.paint.rawValue, at: crates)
        world.add(.cylinder(radius: 0.36, height: 0.95, segments: 20), material: Material.paint.rawValue, at: drums)
    }

    /// The catwalk's outer edge along the right wall, every three meters.
    static let walkway: [SIMD3<Float>] = stride(from: Float(-2), through: -96, by: -3).map { z in
        [center(z) + [7, 8.5, 10].map { wall($0, z, 1) }.min()! - 0.3, 9, z]
    }
    static var walkwayLamps: [SIMD3<Float>] { stride(from: 2, to: walkway.count, by: 6).map { walkway[$0] + [-1.2, 1.9, 0] } }

    /// A catwalk bolted along the right wall above the course: a deck on brackets, a railing,
    /// and a warm lamp every eighteen meters.
    static func addWalkway(_ world: inout SaverWorld) {
        var steel = Mesh(), housings = Mesh(), lenses = Mesh()
        let out = SIMD3<Float>(-1.5, 0, 0)
        for (p, q) in zip(walkway, walkway.dropFirst()) {
            steel += slab(p + out / 2, q + out / 2, width: 1.5, height: 0.12)
            steel += strut(q + out, q + out + [0, 1.1, 0], 0.035) + strut(p + out + [0, 1.1, 0], q + out + [0, 1.1, 0], 0.03)
            steel += strut(q + out * 0.9, q + [0, -1.4, 0], 0.05)
        }
        for lamp in walkwayLamps {
            steel += strut(lamp - [0, 2.4, 0] + [-0.3, 0.5, 0], lamp + [-0.3, 0.3, 0], 0.04)
            housings += .box([0.6, 0.3, 0.5], center: lamp + [-0.3, 0.3, 0], segments: 2)
            lenses += .box([0.5, 0.03, 0.4], center: lamp + [-0.3, 0.14, 0])
        }
        world.add(steel, material: Material.steel.rawValue)
        world.add(housings, material: Material.armor.rawValue)
        world.add(lenses, material: Material.lamp.rawValue, castsShadows: false)
    }

    /// A box from a to b, `width` across and `height` tall.
    static func slab(_ a: SIMD3<Float>, _ b: SIMD3<Float>, width: Float, height: Float) -> Mesh {
        let across = simd_normalize(simd_cross([0, 1, 0], b - a))
        return Mesh.box([1, 1, 1]).transformed(simd_float4x4(columns: (SIMD4(across * width, 0), [0, height, 0, 0], SIMD4(b - a, 0), SIMD4((a + b) / 2, 1))))
    }

    static func strut(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ radius: Float) -> Mesh {
        Mesh.cylinder(radius: radius, height: 1, segments: 10, caps: true).transformed(.span(from: a, to: b))
    }

    static let gantryZ: Float = -115
    static var gantryX: Float { center(gantryZ) }
    static let towerHeight: Float = 24
    static var hologram: SIMD3<Float> { [gantryX, towerHeight + 8.5, gantryZ] }

    /// The gantry over the course 120 m out: two lattice towers and a box truss between them
    /// faced with a banner, floodlights hung beneath, red beacons on the towers and the hologram's
    /// projector on top.
    static func addGantry(_ world: inout SaverWorld) {
        var steel = Mesh()
        for side: Float in [-21, 21] {
            let base = SIMD3<Float>(gantryX + side, 0, gantryZ), floor = ground(base.x, base.z) - 0.5
            let corners: [SIMD2<Float>] = [[-0.8, -0.8], [0.8, -0.8], [0.8, 0.8], [-0.8, 0.8]]
            for c in corners { steel += strut(base + [c.x, floor, c.y], base + [c.x, towerHeight + 3, c.y], 0.13) }
            var y = floor + 1
            while y < towerHeight + 2.5 {
                for (p, q) in zip(corners, corners.dropFirst() + [corners[0]]) {
                    steel += strut(base + [p.x, y, p.y], base + [q.x, y, q.y], 0.06)
                    steel += strut(base + [p.x, y, p.y], base + [q.x, y + 2.4, q.y], 0.04)
                }
                y += 2.4
            }
            steel += strut(base + [0, towerHeight + 3, 0], base + [0, towerHeight + 3.2, 0], 0.25)
        }
        let span = (start: gantryX - 21, end: gantryX + 21)
        for (dy, dz) in [(Float(0), Float(-0.75)), (0, 0.75), (2, -0.75), (2, 0.75)] {
            steel += strut([span.start, towerHeight + dy, gantryZ + dz], [span.end, towerHeight + dy, gantryZ + dz], 0.14)
        }
        var x = span.start
        while x < span.end - 0.1 {
            for dz: Float in [-0.75, 0.75] {
                steel += strut([x, towerHeight, gantryZ + dz], [x, towerHeight + 2, gantryZ + dz], 0.05)
                steel += strut([x, towerHeight, gantryZ + dz], [x + 2.1, towerHeight + 2, gantryZ + dz], 0.045)
            }
            steel += strut([x, towerHeight, gantryZ - 0.75], [x, towerHeight, gantryZ + 0.75], 0.04)
            steel += strut([x, towerHeight + 2, gantryZ - 0.75], [x, towerHeight + 2, gantryZ + 0.75], 0.04)
            x += 2.1
        }
        var housings = Mesh(), lenses = Mesh()
        for dx: Float in [-11, 0, 11] {
            let lamp = SIMD3(gantryX + dx, towerHeight - 1.6, gantryZ + 0.2)
            housings += .box([1.4, 0.6, 0.8], center: lamp + [0, 0.9, 0], segments: 2)
            housings += strut(lamp + [0, 1.2, 0], [lamp.x, towerHeight, lamp.z], 0.05)
            lenses += .box([1.2, 0.04, 0.6], center: lamp + [0, 0.58, 0])
        }
        housings += Mesh.lathe([[0, 0], [0.9, 0.1], [1.2, 0.5], [0.5, 0.6], [0.4, 1.4], [0, 1.5]], segments: 32).transformed(.translation([gantryX, towerHeight + 2.1, gantryZ]))
        world.add(steel, material: Material.steel.rawValue)
        world.add(housings, material: Material.armor.rawValue)
        world.add(lenses, material: Material.lamp.rawValue, castsShadows: false)
        world.add(.box([30, 1.8, 0.12], segments: 2), material: Material.banner.rawValue, at: [.translation([gantryX, towerHeight + 1, gantryZ + 0.85])])
        world.add(.lathe([[0.35, 1.45], [0, 1.55]], segments: 32), material: Material.lens.rawValue, at: [.translation([gantryX, towerHeight + 2.1, gantryZ])], castsShadows: false)
        world.add(.sphere(radius: 0.22, subdivisions: 2), material: Material.beacon.rawValue, at: [-21, 21].map { .translation([gantryX + $0, towerHeight + 3.3, gantryZ]) }, castsShadows: false)
    }

    /// The lamp heads of the floodlight masts along the course.
    static let masts: [SIMD3<Float>] = [(Float(-50), Float(1)), (-170, -1), (-215, 1)].map { z, side in
        let x = center(z) + side * (halfWidth(z) - 5)
        return [x - side * 1.4, ground(x, z) + 14.2, z]
    }

    /// Each mast's floodlight, as a cone tilted across at the line like its lamps.
    static let floodlights: [SaverFrame.Light] = masts.map { lamp in
        let side: Float = lamp.x > center(lamp.z) ? 1 : -1, aim = SIMD3<Float>(-side * sin(0.6), -cos(0.6), 0)
        return .init(position: lamp + aim * 0.3, radius: 0.4, color: [240, 180, 120], shadows: true, range: 40, spot: .init(direction: aim, inner: 0.22, outer: 0.42))
    }

    /// Floodlight masts along the course, each with a crossbar of three lamps aimed at the line.
    static func addFloodlights(_ world: inout SaverWorld) {
        var steel = Mesh(), housings = Mesh(), lenses = Mesh()
        for lamp in masts {
            let side: Float = lamp.x > center(lamp.z) ? 1 : -1, foot = SIMD3(lamp.x + side * 1.4, ground(lamp.x + side * 1.4, lamp.z) - 0.4, lamp.z)
            steel += strut(foot, foot + [0, 15, 0], 0.22) + strut(foot + [0, 14.8, -1.6], foot + [0, 14.8, 1.6], 0.08)
            for dz: Float in [-1.2, 0, 1.2] {
                let head = lamp + [0, 0, dz], tilt = simd_float4x4.translation(head) * .rotation(side * 0.6, axis: [0, 0, 1])
                housings += Mesh.box([0.7, 0.45, 0.9], segments: 2).transformed(tilt * .translation([0, 0.3, 0]))
                lenses += Mesh.box([0.6, 0.03, 0.8]).transformed(tilt * .translation([0, 0.06, 0]))
            }
        }
        world.add(steel, material: Material.steel.rawValue)
        world.add(housings, material: Material.armor.rawValue)
        world.add(lenses, material: Material.lamp.rawValue, castsShadows: false)
    }

    /// Lane lights set in the sand either side of the line, every eight meters.
    static func addMarkers(_ world: inout SaverWorld) {
        var places: [simd_float4x4] = []
        for k in 0..<Int(perimeter / 8) {
            let s = Float(k) * 8 / perimeter, p = line(s, 0, drift: 0)
            guard p.z < -12 else { continue }
            let ahead = simd_normalize(line(s + 0.001, 0, drift: 0) - p), across = simd_normalize(SIMD3(-ahead.z, 0, ahead.x))
            for side: Float in [-1, 1] {
                let q = p + across * side * 6.5
                places.append(.translation([q.x, ground(q.x, q.z) - 0.02, q.z]))
            }
        }
        world.add(.cylinder(radius: 0.2, height: 0.14, segments: 12), material: Material.steel.rawValue, at: places)
        world.add(.cylinder(radius: 0.12, height: 0.03, segments: 12), material: Material.marker.rawValue, at: places.map { $0 * .translation([0, 0.14, 0]) }, castsShadows: false)
    }

    // MARK: Shading

    static let shader = MetalSource(#"""
    #define HAS_EMISSION
    #define HAS_LIVE
    #define HAS_ATMOSPHERE

    enum : uint { WALL, GROUND, WATER, ROCK, SCRUB, HOUSING, ARMOR, STEEL, PAINT, CHANNEL, LAMP, BEACON, MARKER, LENS, BAY, BANNER, SHEET, SIGN };
    #define LAMPS 2u
    constant float3 SUN = \#(sun.metal);
    constant float3 STRATA[] = \#(strata.metal);
    constant int LAYERS = \#(strata.count);
    constant float WATER_LEVEL = \#(waterLevel);
    constant float CYCLE = \#(cycle), LAP = \#(lap), STRAIGHT = \#(straight), TURN = \#(turn), NEAR_TURN = \#(nearTurn), PERIMETER = \#(perimeter);
    constant float ORB[] = {\#(orbs.map { "\($0)" }.joined(separator: ", "))};
    constant float3 HOLOGRAM = \#(hologram.metal);

    // MARK: The course, as in Swift

    static float center(float z) { return 7 * sin(z / 95 + 0.4f) + 3 * sin(z / 41 + 1.3f); }

    static float2 loop(float s) {
        float q = fract(s) * PERIMETER, a = PI / 2 * TURN, far = NEAR_TURN - STRAIGHT;
        if (q < a) return float2(TURN * sin(q / TURN), NEAR_TURN + TURN * cos(q / TURN));
        if (q < a + STRAIGHT) return float2(TURN, NEAR_TURN - q + a);
        if (q < 3 * a + STRAIGHT) return float2(TURN * cos((q - a - STRAIGHT) / TURN), far - TURN * sin((q - a - STRAIGHT) / TURN));
        if (q < 3 * a + 2 * STRAIGHT) return float2(-TURN, far + q - 3 * a - STRAIGHT);
        return float2(-TURN * cos((q - 3 * a - 2 * STRAIGHT) / TURN), NEAR_TURN + TURN * sin((q - 3 * a - 2 * STRAIGHT) / TURN));
    }

    static float3 line(float s, float t) {
        float2 plan = loop(s);
        float w = TAU * s, slow = TAU * t / CYCLE;
        float x = plan.x + 3 * sin(5 * w) + 1.4f * sin(4 * w + 53 * slow);
        float y = 7 + 2.5f * sin(3 * w + 0.5f) + 1.2f * sin(7 * w + 1.3f) + 0.9f * sin(6 * w + 71 * slow);
        return float3(center(plan.y) + x, y, plan.y);
    }

    static float progress(float t) {
        float tau = t / LAP + 0.015f * sin(TAU * 37 * t / CYCLE);
        return tau - 0.35f / (4 * PI) * sin(4 * PI * tau);
    }

    // Laps since the ship last passed fraction s, turned into seconds.
    static float since(float s, Ctx c) { return fract(progress(c.t) - s) * LAP / (1 - 0.35f * cos(4 * PI * s)); }

    struct Ship {
        float3 p, right, up, ahead;
    };

    // The racer's frame at time t: along the line, banked into its turns, never quite still.
    static Ship ship(float t) {
        const float h = 0.25;
        float3 p = line(progress(t), t), before = line(progress(t - h), t - h), after = line(progress(t + h), t + h);
        float3 ahead = normalize(line(progress(t + 0.02f), t + 0.02f) - line(progress(t - 0.02f), t - 0.02f));
        float3 lift = float3(0, 9.8, 0) + (before + after - 2 * p) / (h * h);
        float3 right = normalize(cross(lift, ahead));
        right = normalize(right + float3(0, 0.035f * sin(t * 2.3f) + 0.02f * sin(t * 5.1f), 0));
        float3 up = normalize(cross(ahead, right));
        return {p, right, up, ahead};
    }

    static float blink(float t, float phase) { return 0.05 + smoothstep(0.0, 0.05, fract(t * 0.55f + phase)) * smoothstep(0.35, 0.2, fract(t * 0.55f + phase)); }

    // The hologram flickers, and now and then glitches badly.
    static float holoFlicker(Ctx c) { return 0.85 + 0.15 * c.noise(float3(c.t * 9, 1.5, 2.5)) - 0.5 * smoothstep(0.78, 0.82, c.param(0).z) * step(0.5, hash(floor(c.t * 24))); }

    // MARK: Digits

    constant uint SEGMENTS[10] = {0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F};
    constant float4 SEGMENT[7] = {float4(-0.36, 0.92, 0.36, 0.92), float4(0.46, 0.82, 0.46, 0.1), float4(0.46, -0.1, 0.46, -0.82),
                                  float4(-0.36, -0.92, 0.36, -0.92), float4(-0.46, -0.82, -0.46, -0.1), float4(-0.46, 0.1, -0.46, 0.82),
                                  float4(-0.36, 0, 0.36, 0)};

    // Distance to the lit segments of a slanted seven-segment digit in a cell 1 wide and 2 tall.
    static float digit(uint n, float2 p) {
        p.x -= p.y * 0.12f;
        float d = 9;
        for (int k = 0; k < 7; k++) {
            if (!((SEGMENTS[n] >> k) & 1u)) continue;
            d = min(d, sdSegment(p, SEGMENT[k].xy, SEGMENT[k].zw));
        }
        return d;
    }

    // MARK: Rock and sand

    static float bedding(float3 p) { return p.y + 0.008f * p.z + 2 * sin(p.z / 150); }

    // The layer a bedding height falls in: (index, how far up it 0 to 1, its thickness).
    static float3 stratum(float y) {
        float bottom = -6;
        for (int k = 0; k < LAYERS; k++) {
            if (y < STRATA[k].x) return float3(k, (y - bottom) / (STRATA[k].x - bottom), STRATA[k].x - bottom);
            bottom = STRATA[k].x;
        }
        return float3(LAYERS - 1, 1, 1);
    }

    // Banded sandstone: thin ledgy layers in deep reds, massive cliffs paler and cross-bedded,
    // pitted with honeycomb weathering, streaked by dark desert varnish hanging from their tops.
    static Surface sandstone(Hit h, float y, Ctx c) {
        float3 layer = stratum(y + 0.5f * (c.noise(h.p * 0.25f) - 0.5f));
        float3 pick = hash3(float3(layer.x, 3.1, 7.7));
        float massive = smoothstep(5.0, 8.0, layer.z);
        float3 color = mix(float3(0.36, 0.1, 0.04), float3(0.56, 0.2, 0.07), pick.x);
        color = mix(color, mix(float3(0.6, 0.27, 0.1), float3(0.64, 0.38, 0.2), pick.y), massive * 0.85);
        if (h.bounce > 0) return material(color, 0.9, h.n);
        float4 big = c.fbmd(h.p * float3(0.3, 0.7, 0.3));
        color *= 0.7 + 0.6 * big.x;
        float near = smoothstep(220.0, 50.0, distance(h.p, c.eye));
        float stain = c.fbm(h.p * float3(0.45, 0.9, 0.45) + 11, 3);
        color *= mix(float3(1.18, 1.1, 1.0), float3(0.78, 0.62, 0.55), smoothstep(0.3, 0.7, stain));
        float cross = smoothstep(0.85, 1.0, sin((y + 0.35f * (h.p.x + h.p.z) * sign(pick.z - 0.5f)) * 5 + 2 * c.noise(h.p * 0.5f))) * massive;
        float lamina = sin(y * (6 + 8 * pick.z) + 3 * c.noise(h.p * 0.6f));
        color *= (0.9 + 0.1 * lamina * (1 - 0.6 * massive)) * (1 - 0.22 * cross * near);
        float streak = c.fbm(float3(h.p.x * 0.7f, y * 0.04f, h.p.z * 0.7f), 3);
        float varnish = smoothstep(0.38, 0.62, streak) * mix(0.45, 1.0, massive) * (0.6 + 0.4 * smoothstep(0.2, 1.0, layer.y));
        color = mix(color, color * float3(0.2, 0.15, 0.13), varnish * 0.9);
        float3 cells = voronoi(h.p * float3(0.9, 1.6, 0.9));
        float crack = smoothstep(0.03, 0.0, cells.y - cells.x) * smoothstep(0.62, 0.75, c.noise(h.p * 0.12f + 2)) * near;
        float pit = smoothstep(0.5, 0.1, cells.x) * smoothstep(0.55, 0.7, c.noise(h.p * 0.35f + 4)) * massive;
        float4 mid = c.fbmd(h.p * 2.2f, 3), fine = c.fbmd(h.p * 14, 2), grit = c.noised(h.p * 55);
        color *= (0.78 + 0.44 * mid.x) * (0.86 + 0.28 * fine.x) * (0.82 + 0.36 * grit.x) * (1 - 0.45 * pit) * (1 - 0.4 * crack);
        Surface s = material(color, 0.85, h.n);
        float3 ridge = float3(0, (6 + 8 * pick.z) * cos(y * (6 + 8 * pick.z) + 3 * c.noise(h.p * 0.6f)), 0) * 0.01 * (1 - massive) * float(h.material == WALL);
        s.normal = bump(h.n, (big.yzw * float3(0.3, 0.7, 0.3) * 0.06 + mid.yzw * 2.2f * 0.05 + ridge) * near + fine.yzw * 14 * 0.01 + grit.yzw * 55 * 0.0015, 1);
        return s;
    }

    // Wind-rippled sand with darker crusts of desert pavement, damp and smooth by the water.
    static Surface sand(Hit h, Ctx c) {
        float2 g = h.p.xz;
        float damp = smoothstep(WATER_LEVEL + 0.3, WATER_LEVEL + 0.02, h.p.y);
        if (h.bounce > 0) return material(float3(0.45, 0.27, 0.15) * (1 - 0.55 * damp), 0.9, h.n);
        float4 broad = c.fbmd(float3(g * 0.06f, 1.5));
        float crust = smoothstep(0.52, 0.68, c.fbm(float3(g * 0.05f, 6.5), 3));
        float3 color = mix(float3(0.4, 0.23, 0.12), float3(0.54, 0.33, 0.18), broad.x);
        color = mix(color, float3(0.27, 0.17, 0.12), crust * 0.65) * (1 - 0.55 * damp);
        float phase = dot(g, float2(0.8, 0.6)) * 9 + c.noise(float3(g * 0.18f, 4.5)) * 14;
        float4 grain = c.fbmd(float3(g * 7, 2.5), 3);
        color *= (0.9 + 0.2 * grain.x) * (0.96 + 0.06 * sin(phase));
        float near = smoothstep(160.0, 40.0, distance(h.p, c.eye)) * (1 - damp) * (1 - crust);
        Surface s = material(color, mix(0.92, 0.3, damp), h.n);
        s.normal = bump(h.n, float3(0.8, 0, 0.6) * cos(phase) * 9 * 0.008 * near + grain.yzw * 7 * 0.0025, 1);
        s.reflectsLive = false;
        return s;
    }

    // MARK: Metal

    // Graphite armor, dusted where it faces up. The gates wear a pearl shell in sixteen panels round
    // their outer half, hazard-striped across the crown, its rim scuffed.
    static Surface armor(Hit h, Ctx c) {
        float3 color = float3(0.04, 0.043, 0.048);
        if (h.material == HOUSING) {
            float angle = atan2(h.local.y, h.local.x), r = length(h.local.xy), panel = fract(angle / TAU * 16);
            color = mix(color, float3(0.62, 0.6, 0.57), step(5.04f, r));
            if (h.bounce == 0) {
                float crown = smoothstep(0.75, 0.85, h.local.y / r) * step(0.45f, abs(h.local.z)) * step(5.04f, r) * step(r, 5.3f);
                color = mix(color, sin((angle * 5.3f + r) * 9) > 0 ? float3(0.6, 0.4, 0.03) : float3(0.02), crown);
                color *= 1 - 0.8 * smoothstep(0.012, 0.0, min(panel, 1 - panel));
                color = mix(color, float3(0.16, 0.15, 0.14), 0.5 * smoothstep(0.6, 0.8, c.noise(h.p * 6)) * smoothstep(0.15, 0.0, abs(r - 5.44f)));
            }
        }
        float dust = smoothstep(0.3, 0.9, h.n.y) * (0.3 + 0.6 * c.noise(h.p * 2.5f));
        color = mix(color, float3(0.42, 0.27, 0.17), dust * 0.7);
        Surface s = material(color, mix(0.35, 0.8, dust), h.n);
        s.metallic = 0.6 * (1 - dust) * step(color.r, 0.2f);
        return s;
    }

    Surface surface(Hit h, Ctx c) {
        switch (h.material) {
        case WALL: return sandstone(h, bedding(h.p), c);
        case ROCK: return sandstone(h, h.local.y * 4 + hash(float(h.instance)) * 60 - 6, c);
        case GROUND: return sand(h, c);
        case SCRUB: {
            float4 n = detail(h.p * 9, h, c);
            float3 color = mix(float3(0.08, 0.075, 0.05), float3(0.2, 0.19, 0.13), n.x) * (0.7 + 0.6 * hash(float(h.instance)));
            Surface s = material(color, 0.92, h.n);
            s.normal = bump(h.n, n.yzw * 9, 0.04);
            return s;
        }
        case WATER: {
            Surface s = material(float3(0.7, 0.75, 0.7), 0, h.n);
            s.transmission = 1;
            s.ior = 1.33;
            return s;
        }
        case HOUSING: case ARMOR: return armor(h, c);
        case PAINT: {
            float3 pick = hash3(float3(h.instance, 2.2, 6.1));
            float3 color = pick.x < 0.45 ? float3(0.72, 0.22, 0.03) : pick.x < 0.75 ? float3(0.55, 0.53, 0.48) : float3(0.04, 0.24, 0.26);
            float band = step(abs(h.local.y - 0.82f), 0.05f);
            float dust = smoothstep(0.3, 0.9, h.n.y) * 0.6 + 0.3 * smoothstep(0.55, 0.75, c.noise(h.p * 3));
            return material(mix(color * (1 - 0.6 * band), float3(0.4, 0.26, 0.16), dust), 0.55, h.n);
        }
        case BAY: case SIGN: return material(float3(0.1), 0.8, h.n);
        case BANNER: {
            // A dark screen between checkered flags, framed in orange.
            float2 q = abs(h.local.xy);
            float checker = fract((floor(h.local.x / 0.375f) + floor(h.local.y / 0.375f)) * 0.5f) * 2;
            float3 color = q.x < 10.5f ? float3(0.02) : mix(float3(0.03), float3(0.75), checker);
            return material(q.x > 14.85f || q.y > 0.75f ? float3(0.72, 0.22, 0.03) : color, 0.35, h.n);
        }
        case SHEET: {
            // Corrugated steel, its edges painted orange.
            if (abs(h.n.z) > 0.7f) return material(float3(0.72, 0.22, 0.03), 0.45, h.n);
            float x = planar(h.p, h.n).x * (TAU / 0.18f), dust = smoothstep(0.3, 0.9, h.n.y) * 0.7;
            Surface s = material(mix(float3(0.45, 0.46, 0.47), float3(0.42, 0.28, 0.18), dust), mix(0.35, 0.8, dust), h.n);
            s.metallic = 0.8 * (1 - dust);
            if (h.bounce == 0) s.normal = bump(h.n, unplanar(float2(cos(x) * (TAU / 0.18f), 0), h.n), 0.015);
            return s;
        }
        case STEEL: {
            float dust = smoothstep(0.2, 0.9, h.n.y) * 0.6 + 0.25 * c.noise(h.p * 4);
            return material(mix(float3(0.06, 0.055, 0.05), float3(0.4, 0.26, 0.16), dust), 0.6, h.n);
        }
        default: return material(float3(0.8), 0.25, h.n);
        }
    }

    // MARK: Glow

    // Each gate's channel chases round faster as the ship comes; beacons blink; the banner's
    // chevrons run outward; lane lights run ahead of the ship.
    Emission emission(Hit h, Ctx c) {
        switch (h.material) {
        case CHANNEL: {
            float4 gate = c.param(1 + h.tag);
            float chase = sin(atan2(h.local.y, h.local.x) * 12 - c.t * (2 + 9 * exp(-gate.w * 0.5f)));
            return {gate.rgb * 6 * (0.5 + 0.5 * smoothstep(0.2, 0.9, chase)), LAMPS};
        }
        case LAMP: return {float3(16, 12, 8), LAMPS};
        case BEACON: return {float3(40, 2, 0.8) * blink(c.t, step(HOLOGRAM.x, h.p.x) * 0.37f), LAMPS};
        case LENS: return {float3(2, 8, 10) * holoFlicker(c), LAMPS};
        case BAY: {
            // Shelves of parts, each lit from under the one above, below a strip light.
            float2 cell = h.local.xy / float2(1.7, 1.1), f = fract(cell);
            float3 pick = hash3(float3(floor(cell), 4.5));
            float shelf = step(0.05f, f.x) * step(f.x, 0.95f) * step(f.y, 0.88f) * step(h.local.y, 2.2f);
            float stock = step(f.y, 0.2f + 0.5f * pick.x) * step(abs(f.x - 0.3f - 0.4f * pick.z), 0.1f + 0.2f * pick.y);
            float strip = smoothstep(2.75, 2.95, h.local.y) * step(0.45f, fract(h.local.x / 2.4f));
            return {float3(1.0, 0.72, 0.42) * (0.05 + 1.1 * shelf * f.y * f.y * (1 - 0.9 * stock) + 9 * strip), LAMPS};
        }
        case BANNER: {
            float2 q = abs(h.local.xy);
            float chevron = fract((q.x + q.y * 0.8f) / 1.1f - c.t * 0.9f);
            return {float3(1.0, 0.45, 0.08) * 5 * smoothstep(0.0, 0.08, chevron) * smoothstep(0.45, 0.37, chevron) * step(q.x, 10.3f) * step(q.y, 0.62f) * step(0.0f, h.local.z), LAMPS};
        }
        case SIGN: {
            float2 q = h.local.xy / 0.45f;
            float d = min(digit(0, q + float2(0.65, 0)), digit(7, q - float2(0.65, 0)));
            return {float3(1.0, 0.6, 0.3) * 6 * smoothstep(0.17, 0.11, d) * step(0.0f, h.local.z), LAMPS};
        }
        case MARKER: {
            float a = PI / 2 * TURN, far = NEAR_TURN - STRAIGHT, x = h.p.x - center(h.p.z);
            float s = x > 0 ? (a + NEAR_TURN - h.p.z) / PERIMETER : (3 * a + STRAIGHT + h.p.z - far) / PERIMETER;
            float ahead = fract(s - progress(c.t));
            float lead = exp(-pow((ahead - 0.025f) / 0.012f, 2.0f)) * 6;
            return {float3(0.55, 0.85, 1.0) * (0.35 + 0.25 * sin(s * 500 - c.t * 4) + lead), LAMPS};
        }
        default: return {float3(0), LAMPS};
        }
    }

    // MARK: Sky

    // Golden hour: warm and pale low down, deepening blue overhead, a glow round the sun and
    // high streaks of cloud lit from below.
    float3 sky(float3 d, Ctx c) {
        float up = saturate(d.y), toward = saturate(dot(d, SUN));
        float3 color = mix(float3(0.9, 0.5, 0.26), float3(0.2, 0.32, 0.58), smoothstep(0.0, 0.3, up));
        color = mix(color, float3(0.04, 0.1, 0.32), smoothstep(0.2, 0.9, up));
        color += float3(1.0, 0.45, 0.15) * (0.5 * pow(toward, 4.0f) + 1.4 * pow(toward, 30.0f)) * (1 - up);
        float2 uv = d.xz / max(d.y, 0.04f) * 0.6f + float2(c.t * 0.004f, c.t * 0.0015f);
        float streaks = c.fbm(float3(uv.x * 0.6f, uv.y * 2.2f, 1.5), c.baking ? 2 : 5);
        float cloud = smoothstep(0.42, 0.7, streaks) * smoothstep(0.02, 0.12, d.y) * (1 - 0.4 * smoothstep(0.3, 0.8, d.y));
        float3 lit = mix(float3(0.95, 0.5, 0.42), float3(1.0, 0.72, 0.4), toward) * (0.55 + 2.2 * pow(toward, 4.0f));
        color = mix(color, lit * (c.baking ? 1.0f : 0.8 + 0.4 * c.fbm(float3(uv * 3, 7.5), 3)), cloud * 0.9);
        color += float3(1.0, 0.8, 0.55) * 25 * smoothstep(0.99985, 0.9999, dot(d, SUN));
        return mix(color, float3(0.16, 0.08, 0.045), smoothstep(0.0, -0.08, d.y));
    }

    // MARK: The racer

    // The racer is modeled 5.4 m long and flown a quarter larger.
    constant float SCALE = 1.25;

    // The racer in its own frame (+z ahead, +y up): a tapering fuselage under a canopy, two
    // engine pods on swept wings, canted fins and a splitter under the nose.
    static float hull(float3 q) {
        float taper = 1 + 0.55f * saturate((q.z - 0.2f) / 2.3f);
        float body = sdEllipsoid(float3(q.x, q.y - 0.02f, q.z - 0.1f) * float3(taper, taper, 1), float3(0.7, 0.46, 2.6)) / taper;
        body = smax(body, -q.y - 0.24f, 0.1);
        float3 e = float3(abs(q.x) - 1.3f, q.y + 0.04f, q.z + 0.7f);
        float pod = sdCapsule(e, float3(0, 0, -1.75), float3(0, 0, 1.45), 0.35f - 0.09f * saturate(e.z));
        pod = max(pod, -max(length(e.xy) - 0.25f, e.z + 1.55f));
        float3 w = q - float3(0, -0.07, -0.55);
        w.z += abs(q.x) * 0.5f;
        float wing = sdRoundBox(w, float3(1.32, 0.035, 0.58), 0.03);
        float3 f = float3(abs(q.x) - 1.3f, q.y - 0.42f, q.z + 1.85f);
        f.z += f.y * 0.9f;
        f.x -= f.y * 0.22f;
        float fin = sdRoundBox(f, float3(0.03, 0.34, 0.3), 0.02);
        float3 n = q - float3(0, -0.22, 1.7);
        n.z += abs(q.x) * 0.45f;
        float splitter = sdRoundBox(n, float3(0.8, 0.016, 0.17), 0.012);
        float canopy = sdEllipsoid(q - float3(0, 0.26, 0.5), float3(0.32, 0.25, 0.95));
        return min(smin(smin(smin(body, pod, 0.2), wing, 0.1), min(fin, splitter), 0.05), canopy);
    }

    // The racer's paint and glass at a point on it, lit: pearl white with an orange stripe,
    // graphite underneath, panel seams, a glossy coat that mirrors the canyon and sky, glowing
    // nozzles, and running lights.
    static float3 racer(float3 p, float3 q, float3 n, float3 nl, float3 rd, Ctx c) {
        float3 e = float3(abs(q.x) - 1.3f, q.y + 0.04f, q.z + 0.7f);
        float canopy = sdEllipsoid(q - float3(0, 0.26, 0.5), float3(0.32, 0.25, 0.95));
        bool glass = canopy < 0.01f;
        float stripe = smoothstep(0.16, 0.13, abs(abs(q.x) - 0.24f)) * step(0.0f, nl.y) * step(q.z, 1.6f);
        stripe = max(stripe, step(0.9f, abs(q.x)) * step(abs(q.x), 1.75f) * smoothstep(0.25, 0.35, e.z));
        stripe = max(stripe, step(0.9f, abs(q.x)) * step(abs(q.x), 1.75f) * step(-1.2f, e.z) * step(e.z, -0.95f));
        float3 color = mix(float3(0.78, 0.78, 0.76), float3(0.9, 0.2, 0.02), stripe);
        float2 decal = float2((0.15f - e.z) * sign(q.x), e.y) / 0.13f;
        float number = min(digit(0, decal + float2(0.65, 0)), digit(7, decal - float2(0.65, 0)));
        color = mix(color, float3(0.02), smoothstep(0.16, 0.11, number) * step(0.18f, e.x));
        color = mix(color, float3(0.03, 0.032, 0.035), smoothstep(-0.25, -0.5, nl.y));
        float seam = max(smoothstep(0.012, 0.0, abs(fract(q.z * 1.25f) - 0.5f) - 0.49f), smoothstep(0.01, 0.0, abs(abs(q.x) - 0.42f)));
        color *= 1 - 0.6 * seam;
        Surface m = material(glass ? float3(0.01) : color, glass ? 0.05 : 0.28, n);
        float3 v = -rd, lit = c.shade(p, n, v, m);
        float3 r = reflect(rd, n);
        float hit = c.hitDistance(offset(p, n), r);
        float3 env = hit < FAR ? mix(float3(0.035, 0.03, 0.03), float3(0.6, 0.3, 0.14), smoothstep(12.0, 30.0, p.y + r.y * hit)) : sky(r, c);
        float fresnel = schlick(0.04f, dot(n, v));
        lit = mix(lit, env, fresnel * (glass ? 1.0 : 0.75)) + (glass ? env * 0.05 : float3(0));
        lit += float3(0.25, 0.75, 1.0) * 6 * smoothstep(0.03, 0.01, abs(e.y)) * step(0.2f, e.x) * step(-1.5f, e.z) * step(e.z, 1.3f);
        lit += float3(0.2, 0.7, 1.0) * 5 * smoothstep(-0.27, -0.33, e.y) * smoothstep(0.12, 0.06, abs(e.x)) * step(abs(e.z + 0.2f), 1.1f);
        float flame = smoothstep(-1.5, -1.62, e.z) * smoothstep(0.23, 0.12, length(e.xy));
        float flicker = 0.85 + 0.15 * c.noise(float3(c.t * 31, q.x, 4));
        lit += mix(float3(0.3, 0.55, 1.0), float3(1.0, 0.97, 0.95), smoothstep(0.2, 0.05, length(e.xy))) * 30 * flame * flicker;
        lit += float3(0.4, 0.9, 1.0) * 25 * smoothstep(0.05, 0.02, abs(q.y + 0.1f)) * smoothstep(0.3, 0.2, abs(q.x)) * smoothstep(2.2, 2.3, q.z) * (1 - float(glass));
        float3 tip = float3(1.3, -0.04, 1.07);
        lit += (q.x < 0 ? float3(1, 0.05, 0.02) : float3(0.05, 1, 0.2)) * 40 * smoothstep(0.07, 0.03, distance(float3(abs(q.x), q.y, q.z), tip));
        float strobe = step(fract(c.t * 0.8f), 0.04f);
        lit += float3(30) * strobe * smoothstep(0.06, 0.03, distance(float3(abs(q.x), q.y, q.z), float3(1.38, 0.74, -2.45)));
        return lit;
    }

    // Exhaust behind each nozzle: a blue flame with shock diamonds, fading over a few meters.
    static float3 plume(float3 ro, float3 rd, float limit, Ship s, Ctx c) {
        float3 sum = 0;
        for (int k = 0; k < 2; k++) {
            float side = k == 0 ? -1 : 1;
            float3 a = s.p + (s.right * side * 1.3f - s.up * 0.04f - s.ahead * 2.7f) * SCALE, b = a - s.ahead * 3.6f;
            float3 x = nearest(ro, rd, a, b);
            if (x.y < 0 || x.y > limit) continue;
            float width = 0.14f + 0.22f * x.z, diamonds = 0.7 + 0.3 * cos(x.z * 24 - c.t * 40);
            sum += mix(float3(0.7, 0.85, 1.0), float3(0.15, 0.25, 1.0), sqrt(x.z)) * exp(-x.x * x.x / (width * width)) * (1 - x.z) * (1 - x.z) * diamonds * 5;
        }
        return sum;
    }

    // MARK: The hologram

    // Distance to a number's digits, `count` cells wide from the left, in the same units.
    static float number(float value, int count, float2 p) {
        int cell = int(floor(p.x / 1.25f));
        if (cell < 0 || cell >= count) return 9;
        uint n = uint(fmod(floor(value / pow(10.0f, float(count - 1 - cell))), 10.0f));
        return digit(n, float2(p.x - (float(cell) + 0.5f) * 1.25f, p.y));
    }

    // The scoreboard projected over the gantry: the score large, the lap beneath, in a bracketed
    // frame on a smoky panel, scanlined, flickering, and glitching now and then. Returns its
    // glow and how much the panel dims what's behind.
    static float4 hologram(float3 ro, float3 rd, float limit, Ctx c) {
        float t = (HOLOGRAM.z - ro.z) / rd.z;
        if (t <= 0 || t > limit) return 0;
        float2 p = ((ro + rd * t).xy - HOLOGRAM.xy) / 1.6f;
        if (abs(p.x) > 6.5f || abs(p.y) > 3.2f) return 0;
        float4 data = c.param(0);
        float glitch = smoothstep(0.78, 0.82, data.z);
        p.x += glitch * (hash(float2(floor(p.y * 5), floor(c.t * 18))) - 0.5f) * 0.8f;
        float score = number(data.x, 6, (p - float2(-4.1, 0.75)) / 1.1f) * 1.1f;
        float lap = number(data.y, 3, (p - float2(0.4, -1.75)) / 0.55f) * 0.55f;
        float2 corner = abs(p) - float2(5.6, 2.55);
        float frame = max(corner.x, corner.y) > 0 ? length(max(corner, 0.0f)) : min(abs(corner.x), abs(corner.y));
        float bracket = (abs(p.x) > 4.8f && abs(p.y) > 1.7f) ? frame : 9;
        float rule = max(abs(p.y + 0.62f), abs(p.x) - 4.4f);
        float chevron = abs(abs(p.y + 1.75f) - (p.x + 0.95f) * 0.8f);
        chevron = max(chevron, max(p.x + 0.95f - 0.5f, -(p.x + 0.95f)));
        float3 cyan = float3(0.3, 0.9, 1.0), amber = float3(1.0, 0.55, 0.15);
        float3 glow = cyan * (smoothstep(0.1, 0.05, score) * 4 + exp(-score * 7) * 0.7);
        glow += amber * (smoothstep(0.06, 0.03, min(lap, chevron)) * 2.2 + exp(-min(lap, chevron) * 10) * 0.35);
        glow += cyan * (smoothstep(0.05, 0.02, min(bracket, rule)) * 1.6 + exp(-min(bracket, rule) * 12) * 0.25);
        glow += cyan * 0.06 * smoothstep(6.5, 4.0, abs(p.x)) * smoothstep(3.2, 2.0, abs(p.y));
        float scan = 0.75 + 0.25 * sin(p.y * 70 - c.t * 6), flicker = holoFlicker(c);
        float panel = 0.5 * smoothstep(0.3, -0.1, max(corner.x, corner.y)) * (0.85 + 0.15 * scan) * flicker;
        return float4(glow * scan * flicker * (1 + glitch * 0.6f), panel);
    }

    // The projector's beam: a faint fan of light from its lens up to the board.
    static float3 beam(float3 ro, float3 rd, float limit, Ctx c) {
        float t = (HOLOGRAM.z - 0.3f - ro.z) / rd.z;
        if (t <= 0 || t > limit) return 0;
        float2 p = ((ro + rd * t).xy - HOLOGRAM.xy) / 1.6f;
        float rise = saturate((p.y + 5.9f) / 3.5f);
        if (rise <= 0 || rise >= 1) return 0;
        return float3(0.3, 0.9, 1.0) * 0.12 * smoothstep(5.6 * rise + 0.3, 5.6 * rise - 0.2, abs(p.x)) * (0.4 + 0.6 * rise) * holoFlicker(c);
    }

    // How much the racer darkens sunlit ground at p: its shape marched along the sun ray, softened
    // by the sun's width.
    static float shadow(float3 p, Ship s, Ctx c) {
        float3 o = p - s.p;
        float along = dot(-o, SUN);
        float3 lo = float3(dot(o, s.right), dot(o, s.up), dot(o, s.ahead)) / SCALE, ld = float3(dot(SUN, s.right), dot(SUN, s.up), dot(SUN, s.ahead));
        float lit = 1, t = along / SCALE - 4;
        for (int i = 0; i < 40 && t < along / SCALE + 4; i++) {
            float d = hull(lo + ld * t);
            lit = min(lit, d / (0.06f * t * SCALE));
            if (lit < 0.02f) break;
            t += clamp(d, 0.05f, 0.4f);
        }
        if (lit >= 1 || c.blocked(offset(p, SUN), SUN, FAR)) return 0;
        return 0.62 * (1 - smoothstep(0.0, 1.0, lit));
    }

    // MARK: Live

    // The racer, its exhaust, its shadow on the sand and the hologram.
    Live live(float3 ro, float3 rd, float maxDist, Ctx c) {
        float4 board = hologram(ro, rd, maxDist, c);
        Live l = {board.rgb + beam(ro, rd, maxDist, c), board.a, maxDist};
        // Only rays passing near the racer, or ending where its shadow may fall, need its frame.
        float3 at = c.param(8).xyz + c.param(9).xyz * (c.t - c.f->time), o = ro - at, under = at - ro - rd * maxDist;
        float b = dot(o, rd), along = dot(under, SUN);
        bool passes = b * b - dot(o, o) + 81 > 0, shaded = maxDist < FAR && along > 0 && dot(under, under) - along * along < 25;
        if (!passes && !shaded) return l;
        Ship s = ship(c.t);
        if (shaded) l.alpha = max(l.alpha, shadow(ro + rd * maxDist, s, c));
        float3 lo = float3(dot(o, s.right), dot(o, s.up), dot(o, s.ahead)) / SCALE, ld = float3(dot(rd, s.right), dot(rd, s.up), dot(rd, s.ahead));
        float2 span = boxInterval(lo, ld, float3(-1.8, -0.5, -2.85), float3(1.8, 1.0, 2.75));
        span.y = min(span.y, maxDist / SCALE);
        float t = span.x < span.y ? sdfMarch([&](float3 q) { return hull(q); }, lo, ld, span.x, span.y, 80) : -1;
        if (t > 0) {
            float3 q = lo + ld * t, nl = sdfNormal([&](float3 x) { return hull(x); }, q, 2e-3f);
            l = {l.color + racer(ro + rd * t * SCALE, q, normalize(s.right * nl.x + s.up * nl.y + s.ahead * nl.z), nl, rd, c), 1, t * SCALE};
        }
        l.color += plume(ro, rd, l.depth, s, c);
        return l;
    }

    // MARK: Particles

    // Ion trails from both nozzles, hot white-blue fading to violet as they spread and rise.
    Particle trail(uint i, Ctx c) {
        const float life = 0.9;
        float side = (i & 1u) ? 1 : -1, phase = c.t / life + float(i >> 1) / 800, f = fract(phase), born = c.t - f * life;
        Ship s = ship(born);
        float3 r = hash3(float3(i, floor(phase), 1.7)) - 0.5f;
        Particle o;
        o.position = s.p + (s.right * side * 1.3f - s.up * 0.04f - s.ahead * 3.0f) * SCALE + (r * 0.8f + float3(0, 0.4, 0)) * f * f;
        o.velocity = -s.ahead * 3 * (1 - f);
        o.size = 0.06f + 0.3f * f;
        o.color = mix(float3(0.35, 0.65, 1.0) * 0.8, float3(0.3, 0.15, 1.0) * 0.3, sqrt(f)) * (1 - f) * (1 - f);
        o.alpha = 1;
        o.puff = 0.7f * f;
        o.glow = 0.2f * saturate(1 - 3 * f);
        o.halo = 4;
        return o;
    }

    // Orbs on the line ahead of the ship, bobbing, gone once taken until it's far round the lap.
    Particle orbs(uint i, Ctx c) {
        float ahead = fract(ORB[i] - progress(c.t));
        Particle o;
        o.position = line(ORB[i], c.t) + float3(0, 0.3f * sin(c.t * 1.7f + i * 2.3f), 0);
        o.size = 0.36;
        o.color = float3(0.6, 0.95, 1.0) * 10;
        o.alpha = smoothstep(0.0, 0.002, ahead) * smoothstep(0.85, 0.75, ahead);
        o.glow = 0.04;
        o.halo = 4;
        return o;
    }

    // Dust blown off the sand under the racer where it flies low, lit by the sun and lamps.
    Particle dust(uint i, Ctx c) {
        const float life = 2.6;
        float phase = c.t / life + float(i) / 160, f = fract(phase), born = c.t - f * life;
        float3 p = line(progress(born), born), r = hash3(float3(i, floor(phase), 9.1)) - 0.5f;
        Particle o;
        o.position = float3(p.x, 0.3, p.z) + float3(r.x * 3, 0.6 + r.y, r.z * 3) * (0.3 + 1.5 * f) + float3(0, 1.2, 0) * f;
        o.velocity = float3(r.x, 0.4, r.z) * 2 * (1 - f);
        o.size = 0.6 + 1.8 * f;
        o.color = float3(0.55, 0.38, 0.25) * c.light(o.position) * 2.5;
        o.alpha = 0.22 * smoothstep(7.5, 4.5, p.y) * smoothstep(0.0, 0.15, f) * (1 - f);
        o.puff = 1;
        return o;
    }

    // A burst of sparks where each orb is taken, streaking out and falling.
    Particle sparks(uint i, Ctx c) {
        uint k = i / 16;
        float age = since(ORB[k], c);
        float3 d = normalize(hash3(float3(i, floor(progress(c.t) - ORB[k]), 5.3)) - 0.5f);
        Particle o;
        o.position = line(ORB[k], c.t - age) + d * 5 * (1 - exp(-age * 3)) + float3(0, -1.5, 0) * age * age;
        o.velocity = d * 15 * exp(-age * 3) + float3(0, -3, 0) * age;
        o.size = 0.04;
        o.color = mix(float3(0.9, 1.0, 1.0), float3(0.1, 0.6, 1.0), saturate(age)) * 12;
        o.alpha = smoothstep(1.2, 0.3, age);
        o.tail = 1;
        return o;
    }

    // MARK: Air

    // Dust hanging low in the canyon: blue-grey in the shade, gold far down it where the sun is,
    // glowing round the lamps, the gates and the racer's exhaust, and in the floodlights' beams.
    Atmosphere atmosphere(float3 ro, float3 rd, float dist, Ctx c) {
        float d = min(dist, 2500.0f);
        float3 transmittance = exp(-fogDepth(ro, rd, d, 0.0008f, 33.3f) * float3(0.8, 1.0, 1.25));
        float3 haze = mix(float3(0.1, 0.11, 0.15), float3(0.9, 0.5, 0.24), smoothstep(150.0, 800.0, d)) * (1 + 2 * pow(saturate(dot(rd, SUN)), 6.0f));
        return {haze * (1 - transmittance) + c.inscatter(ro, rd, min(d, 400.0f), LOCAL_LIGHTS | LIVE_LIGHTS, 4) * 0.003f, transmittance};
    }
    """#)
}
