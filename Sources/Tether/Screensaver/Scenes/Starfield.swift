import simd

extension SaverScene {
    static let starfield = SaverScene(name: "Starfield", symbol: "sparkles") { Starfield.world() }
}

/// Gliding toward a ringed giant under a nebula, while a stream of rocks tumbles across the way.
/// The far rocks are baked; the near ones are traced live from meshes kept out of sight; dust
/// streams past.
private enum Starfield {
    static let fieldOfView: Float = 34
    /// The image plane's distance from the eye, where the band every screen shares is one unit tall.
    static let plane = 0.5 / tan(fieldOfView * .pi / 360)
    static let sun = simd_normalize(SIMD3<Float>(0.65, 0.85, 0.3))
    static let sunColor = SIMD3<Float>(3.0, 2.8, 2.5)
    /// A blue giant up on the left that rims everything from behind.
    static let beacon = toward(-1.62, 0.95)
    static let beaconColor = SIMD3<Float>(0.45, 0.65, 1.2)
    /// Where the nebula warms to gold, off to the right.
    static let warm = toward(2.8, 0)
    /// The planet's middle and radius on the image plane.
    static let planetAt = SIMD2<Float>(-0.04, 0.04), planetRadius: Float = 0.36
    static let planet = toward(planetAt.x, planetAt.y)
    static let planetSize = sin(atan(planetRadius / plane))
    /// The middle of the planet's night side as the eye sees it.
    static let night = simd_normalize(SIMD3<Float>(-0.55, -0.3, 0.78))
    /// The planet's pole: its rings open toward the eye and tilt across the picture.
    static let pole = simd_normalize(SIMD3<Float>(-sin(0.2) * cos(0.34), cos(0.2) * cos(0.34), sin(0.34)))
    /// The nebula's band across the sky, as the pole of its great circle.
    static let galaxy = simd_normalize(simd_cross(toward(2.6, -0.45), toward(-2.0, 1.3)))
    /// Where the drifting rocks' meshes wait, far below and out of sight, to be traced live.
    static let hold = SIMD3<Float>(0, -20000, 0)
    static let holdScale: Float = 100, holdSpacing: Float = 2000
    static let shapes = 6, drifters = 16

    static func world() -> SaverWorld {
        let drifting = (0..<shapes).map { rock(seed: Int32(40 + $0)) }
        let reach = drifting.map { $0.positions.map(simd_length).max() ?? 2 }
        var world = SaverWorld(camera: .init(eye: [0, 0, 0], target: [0, 0, -1], fieldOfView: fieldOfView), shader: shader(reach: reach))
        world.look.bounces = 2
        world.look.bloom = 0.05
        world.look.halation = 0.3
        world.look.liveSamples = 4
        addField(&world)
        for (i, mesh) in drifting.enumerated() {
            world.add(mesh, material: 0, at: [.translation(hold + [holdSpacing * Float(i), 0, 0]) * .scale(SIMD3(repeating: holdScale))])
        }
        world.lights = [
            .directional(toward: sun, angle: 0.004, color: sunColor, group: 0),
            .directional(toward: beacon, angle: 0.002, color: beaconColor, group: 0),
        ]
        world.particles = [.init(function: "dust", count: 6000, blend: .additive)]
        world.update = { time, frame in
            for k in 0..<drifters {
                let rock = drifter(k, at: Float(time), reach: reach[k % shapes])
                frame.params[2 * k] = SIMD4(rock.center, rock.size)
                frame.params[2 * k + 1] = rock.turn.vector
            }
        }
        return world
    }

    /// One of the near rocks at time t: it drifts in past the right edge and out past the left,
    /// tumbling, mostly above the planet and sometimes below, never across it. Each pass is a
    /// different rock on a different line.
    static func drifter(_ k: Int, at t: Float, reach: Float) -> (center: SIMD3<Float>, size: Float, turn: simd_quatf) {
        func perRock(_ i: Int32) -> Float { Procedural.hash(Int32(k), i, 1) }
        let period = 110 + 90 * perRock(1), phase = t / period + perRock(2), cycle = Int32(phase.rounded(.down)), f = phase - Float(cycle)
        func perPass(_ i: Int32) -> Float { Procedural.hash(Int32(k), cycle, i, 7) }
        let size = 0.6 + 1.6 * perPass(1) * perPass(1)
        let lane = perPass(2), rise = lane < 0.65 ? 0.3 + 0.16 * lane / 0.65 : -0.27 - 0.15 * (lane - 0.65) / 0.35
        let far = 18 + 82 * perPass(3) * perPass(3), near = far * 0.8
        // Starts and ends just past the outer screens' edges, so it never pops in or out.
        let from = SIMD3(tan(1.04 + asin(min(size * reach * 1.2 / far, 1))) * far, rise * far, -far)
        let to = SIMD3(-tan(0.99 + asin(min(size * reach * 1.2 / near, 1))) * near, (rise - 0.05) * near, -near)
        let axis = simd_normalize(SIMD3(perPass(4), perPass(5), perPass(6)) - 0.5)
        return (from + (to - from) * f, size, simd_quatf(angle: (0.03 + 0.08 * perRock(3)) * t + 2 * .pi * perPass(7), axis: axis))
    }

    /// The direction through a point on the image plane.
    static func toward(_ x: Float, _ y: Float) -> SIMD3<Float> {
        simd_normalize(SIMD3(x, y, -plane))
    }

    // MARK: Rocks

    /// A rock about two units across: a broken chunk, the inside of a dozen random planes with its
    /// edges worn, then lumped, pocked by craters and strewn with boulders, mostly small.
    static func rock(seed: Int32) -> Mesh {
        var random = SeededRandom(seed: UInt64(seed) &* 7919 &+ 1)
        func pick(_ range: ClosedRange<Float>) -> Float { Float.random(in: range, using: &random) }
        func direction() -> SIMD3<Float> {
            let z = pick(-1...1), angle = pick(0...2 * .pi)
            return SIMD3((1 - z * z).squareRoot() * cos(angle), (1 - z * z).squareRoot() * sin(angle), z)
        }
        let faces = (0..<12).map { _ in (normal: direction(), distance: pick(0.72...1)) }
        let craters = (0..<70).map { _ in (center: direction(), size: 0.04 + 0.3 * pow(pick(0...1), 2.5), depth: pick(0.5...1.3)) }
        let boulders = (0..<50).map { _ in (center: direction(), size: 0.03 + 0.07 * pow(pick(0...1), 2)) }
        let stretch = SIMD3(1.1 + 0.7 * Procedural.hash(seed, 1, 5), 0.75 + 0.25 * Procedural.hash(seed, 2, 5), 0.85 + 0.25 * Procedural.hash(seed, 3, 5))
        var mesh = Mesh.sphere(radius: 1, subdivisions: 6)
        mesh.positions = mesh.positions.map { v in
            let chunk = faces.reduce(Float(1.3)) { r, face in
                let c = simd_dot(v, face.normal)
                return c > 0.1 ? softMin(r, face.distance / c, 0.1) : r
            }
            var height = 0.16 * (Procedural.fbm(v * 1.8, octaves: 4, seed: seed) - 0.47) + 0.04 * (Procedural.fbm(v * 7, octaves: 3, seed: seed + 7) - 0.44)
            for crater in craters {
                let x = acos(min(simd_dot(v, crater.center), 1)) / crater.size
                if x < 3 { height += crater.size * crater.depth * bowl(x) }
            }
            for boulder in boulders {
                let x = acos(min(simd_dot(v, boulder.center), 1)) / boulder.size
                if x < 1 { height += boulder.size * 0.5 * (1 - x * x) * (1 - x * x) }
            }
            return v * chunk * (1 + height) * stretch
        }
        return mesh.withSmoothNormals()
    }

    static func softMin(_ a: Float, _ b: Float, _ k: Float) -> Float {
        let h = max(k - abs(a - b), 0) / k
        return min(a, b) - h * h * k / 4
    }

    /// A crater's height x radii from its middle: a bowl inside a raised rim, then thinning ejecta.
    static func bowl(_ x: Float) -> Float {
        x < 1 ? 0.45 * (x * x - 1) + 0.08 : 0.08 * exp(-2.5 * (x - 1))
    }

    /// The distant rocks, baked in clumps placed on the image plane: a big one low on the left, one
    /// on the right, a scatter under the rings and a few far ones all round.
    static func addField(_ world: inout SaverWorld) {
        let shapes = (0..<6).map { rock(seed: Int32($0)) }
        let reach = shapes.flatMap(\.positions).map(simd_length).max() ?? 2
        var places = [[simd_float4x4]](repeating: [], count: shapes.count)
        var taken: [(center: SIMD3<Float>, radius: Float)] = []
        var random = SeededRandom(seed: 5)
        func spread() -> Float { (0..<3).map { _ in Float.random(in: -1...1, using: &random) }.reduce(0, +) / 1.5 }
        let clumps: [(middle: SIMD2<Float>, extent: SIMD2<Float>, distance: Float, count: Int, largest: Float)] = [
            ([-1.95, -0.5], [0.45, 0.2], 300, 22, 0.045),
            ([2.15, -0.22], [0.45, 0.2], 340, 26, 0.04),
            ([-0.2, -0.47], [0.9, 0.035], 450, 12, 0.018),
            ([0.1, 0.4], [2.6, 1.0], 800, 40, 0.012),
            ([-1.9, 1.0], [0.4, 0.4], 650, 6, 0.018),
        ]
        for clump in clumps {
            for _ in 0..<clump.count {
                let at = clump.middle + SIMD2(spread(), spread()) * clump.extent
                if simd_distance(at, planetAt) < planetRadius * 1.1 { continue }
                let depth = clump.distance * (1 + 0.3 * spread())
                let center = toward(at.x, at.y) * depth, scale = clump.largest * pow(Float.random(in: 0.01...1, using: &random), 1.4) * depth / plane
                // Rocks that would touch are left out, so the field floats rather than piles up.
                guard !taken.contains(where: { simd_distance($0.center, center) < ($0.radius + scale * reach) * 1.3 }) else { continue }
                taken.append((center, scale * reach))
                let up = simd_normalize(SIMD3(spread(), spread(), spread()) + 1e-3)
                places[Int.random(in: 0..<shapes.count, using: &random)].append(
                    .place(center, up: up, yaw: Float.random(in: 0..<2 * .pi, using: &random), scale: SIMD3(repeating: scale)))
            }
        }
        for (shape, transforms) in zip(shapes, places) { world.add(shape, material: 0, at: transforms) }
    }

    // MARK: Shading

    static func shader(reach: [Float]) -> MetalSource {
        let right = simd_normalize(simd_cross(planet, [0, 1, 0])), up = simd_cross(right, planet)
        let east = simd_normalize(simd_cross(pole, [0, 0, 1])), north = simd_cross(pole, east)
        return MetalSource(#"""
        #define HAS_LIVE
        #define HAS_ATMOSPHERE

        constant float3 SUN = \#(sun.metal), SUN_COLOR = \#(sunColor.metal);
        constant float3 BEACON = \#(beacon.metal), BEACON_COLOR = \#(beaconColor.metal);
        constant float3 PLANET = \#(planet.metal), RIGHT = \#(right.metal), UP = \#(up.metal);
        constant float PLANET_SIZE = \#(planetSize), MOON_SIZE = \#(planetSize * 0.14);
        constant float3 POLE = \#(pole.metal), EAST = \#(east.metal), NORTH = \#(north.metal), NIGHT = \#(night.metal);
        constant float3 GALAXY = \#(galaxy.metal), WARM = \#(warm.metal);
        constant float3 HOLD = \#(hold.metal);
        constant float HOLD_SCALE = \#(holdScale), HOLD_SPACING = \#(holdSpacing);
        constant float REACH[] = {\#(reach.map { "\($0)" }.joined(separator: ", "))};
        #define SHAPES \#(shapes)
        #define DRIFTERS \#(drifters)

        static float sq(float x) { return x * x; }

        // MARK: Rock

        // Small craters round random points, as height and its gradient.
        static float4 pits(float3 q) {
            float3 cell = floor(q);
            float4 sum = 0;
            for (int i = 0; i < 27; i++) {
                float3 o = cell + float3(i % 3, (i / 3) % 3, i / 9) - 1, a = hash3(o), b = hash3(o + 41.3f);
                if (b.x > 0.5f) continue;
                float3 v = q - (o + 0.15f + 0.7f * a);
                float r = 0.2f + 0.3f * b.y, d = length(v), x = d / r;
                if (x >= 2.5f) continue;
                float e = exp(-2.5f * (x - 1));
                float2 h = x < 1 ? float2(0.45f * (x * x - 1) + 0.08f, 0.9f * x) : float2(0.08f * e, -0.2f * e);
                sum += float4(h.x * r, h.y * v / max(d, 1e-5f)) * (0.3f + 0.7f * b.z);
            }
            return sum;
        }

        // A gradient in the mesh's own space, turned to the world with the instance's scale divided out.
        static float3 toWorld(float3 g, Hit h, Ctx c) {
            device const float4* m = c.instances[h.instance].inverse;
            return (m[0].xyz * g.x + m[1].xyz * g.y + m[2].xyz * g.z) / length(m[0].xyz);
        }

        // Dusty regolith in patches, pitted with small craters and gritty underfoot.
        static Surface rock(Hit h, float seed, Ctx c) {
            float3 q = h.local + seed * 3.7f, kind = hash3(float3(seed, 1.7, 3.1));
            float3 tint = mix(float3(0.95, 0.84, 0.74), float3(0.78, 0.8, 0.84), kind.x) * (0.45f + 0.75f * kind.y);
            float3 albedo = mix(float3(0.025), float3(0.1), smoothstep(0.15, 0.8, c.fbm(q * 1.7f, 5))) * tint;
            if (h.bounce > 0) return material(albedo, 0.9, h.n);
            float4 big = pits(h.local * 6), small = pits(h.local * 14 + 3.7f), grit = c.fbmd(q * 12, 4);
            albedo *= (0.85f + 0.3f * c.fbm(q * 6, 3)) * (0.85f + 0.3f * c.noise(q * 40));
            Surface s = material(albedo, 0.88, h.n);
            s.normal = bump(h.n, toWorld(big.yzw * 0.6f + small.yzw * 0.4f + grit.yzw * 0.03f, h, c), 1);
            return s;
        }

        Surface surface(Hit h, Ctx c) { return rock(h, float(h.instance), c); }

        // MARK: Planet

        // The giant's cloud tops at normal n: belts and zones by latitude, torn along their edges and
        // each turning at its own rate so they slowly shear, with a great storm riding one of them.
        static float3 clouds(float3 n, Ctx c) {
            float lat = dot(n, POLE), turn = c.t * (0.0015f + 0.0006f * sin(lat * 13));
            float2 e = rot(turn) * float2(dot(n, EAST), dot(n, NORTH));
            float3 q = float3(e.x, lat, e.y);
            float2 storm = float2(atan2(e.y, e.x) + 0.9f, (lat + 0.33f) * 2.0f) / 0.18f;
            float spin = 2.5f * exp(-dot(storm, storm) * 0.6f);
            float2 swirl = rot(spin) * storm;
            float torn = c.fbm(q * float3(4, 16, 4) + float3((swirl - storm) * 0.04f, 2), 5) - 0.5f;
            float l = lat + 0.035f * torn;
            float broad = c.noise(float3(l * 7, 0.5, 2.5)), narrow = c.noise(float3(l * 19, 3.5, 0.5)), thin = c.noise(float3(l * 47, 6.5, 4.5));
            float streak = c.fbm(q * float3(6, 70, 6) + torn * 4, 4);
            float dark = smoothstep(0.42f, 0.62f, broad * 0.55f + narrow * 0.35f + thin * 0.1f + 0.2f * (streak - 0.5f));
            float3 belt = mix(float3(0.6, 0.42, 0.28), float3(0.52, 0.27, 0.15), smoothstep(0.4f, 0.7f, c.noise(float3(l * 5, 7.5, 1.5))));
            float3 color = mix(float3(0.9, 0.83, 0.68), belt, dark) * (0.86f + 0.28f * streak);
            float eye = smoothstep(1.4f, 0.7f, length(storm));
            float3 core = float3(0.74, 0.38, 0.21) * (0.75f + 0.5f * c.fbm(float3(swirl * 1.2f, 4.5), 4));
            color = mix(color, mix(float3(0.93, 0.87, 0.75), core, smoothstep(1.0f, 0.7f, length(storm))), eye);
            return mix(color, float3(0.5, 0.55, 0.6), smoothstep(0.75f, 0.95f, abs(l)));
        }

        // Now and then a storm on the visible night side flashes under the cloud tops, in bursts from
        // one place that moves on every forty seconds.
        static float lightning(float3 n, Ctx c) {
            float slot = floor(c.t / 1.3f), when = fract(c.t / 1.3f) * 1.3f;
            float3 storm = hash3(float3(floor(c.t / 40), 7.7, 1.3)), flash = hash3(float3(slot, 2.9, 5.1));
            when -= flash.y * 0.8f;
            if (flash.x > 0.3f || when < 0) return 0;
            float glow = exp(-when / 0.06f) + 0.6f * step(0.12f, when) * exp(-(when - 0.12f) / 0.05f);
            float spread = 1 - dot(n, normalize(NIGHT + (storm - 0.5f) * 0.35f));
            return glow * (exp(-spread / 0.0003f) + 0.3f * exp(-spread / 0.002f)) * (0.4f + c.noise(n * 35));
        }

        // How much light the rings stop r planet radii out; ringlets finer than `blur` fade out.
        static float ringDensity(float r, float blur, Ctx c) {
            if (r < 1.2f || r > 2.38f) return 0;
            float detail = saturate(1 - blur * 100);
            float fine = (0.5f + 0.3f * c.noise(float3(r * 17, 0.5, 0.5)) + 0.2f * mix(0.5f, c.noise(float3(r * 53, 4.5, 0.5)), detail))
                         * mix(1.0f, 0.7f + 0.6f * smoothstep(0.3f, 0.7f, c.noise(float3(r * 160, 8.5, 1.5))), saturate(1 - blur * 300));
            float inner = (smoothstep(1.2f, 1.26f, r) * 0.1f + smoothstep(1.38f, 1.5f, r) * 0.08f) * (0.6f + 0.8f * c.noise(float3(r * 40, 1.5, 3.5)));
            float middle = smoothstep(1.5f, 1.54f, r) * smoothstep(1.955f, 1.94f, r) * (0.7f + 0.3f * smoothstep(1.62f, 1.8f, r));
            float outer = smoothstep(2.0f, 2.03f, r) * smoothstep(2.27f, 2.255f, r) * 0.55f * smoothstep(0.002f, 0.006f + blur, abs(r - 2.21f));
            return saturate(max(max(inner, middle), outer) * fine + 0.45f * exp(-sq((r - 2.33f) / (0.004f + blur))));
        }

        static float3 ringColor(float r, Ctx c) {
            float3 color = mix(float3(0.4, 0.4, 0.42), float3(0.86, 0.75, 0.58), smoothstep(1.45f, 1.6f, r));
            color = mix(color, float3(0.68, 0.66, 0.63), smoothstep(1.98f, 2.05f, r));
            return color * (0.75f + 0.25f * c.noise(float3(r * 7, 2.5, 7.5)) + 0.15f * c.noise(float3(r * 29, 6.5, 2.5)));
        }

        // How much sunlight gets past the planet to p.
        static float planetShadow(float3 p) {
            float3 o = p - PLANET;
            float toward = dot(o, SUN);
            return toward < 0 ? smoothstep(0.97f, 1.03f, sqrt(max(dot(o, o) - toward * toward, 0.0f)) / PLANET_SIZE) : 1;
        }

        // How much sunlight gets through the rings to p.
        static float ringShadow(float3 p, Ctx c) {
            float t = dot(PLANET - p, POLE) / dot(SUN, POLE);
            return t > 0 ? 1 - 0.92f * ringDensity(length(p + SUN * t - PLANET) / PLANET_SIZE, 0, c) : 1;
        }

        // Where d first meets a sphere (the eye at the origin), and how much of the pixel it covers.
        static float2 sphere(float3 d, float3 center, float radius, Ctx c) {
            float b = dot(center, d), miss = sqrt(max(dot(center, center) - b * b, 0.0f));
            return float2(b - sqrt(sq(radius) - sq(min(miss, radius))), saturate((radius - miss) / (c.pixel * b) + 0.5f));
        }

        // The moon, swinging slowly round the far side of the planet.
        static float3 moonAt(Ctx c) {
            float angle = 0.75f + 0.6f * sin(c.t * 0.0003f);
            return PLANET + (EAST * cos(angle) + NORTH * sin(angle)) * (PLANET_SIZE * 4);
        }

        // Grey and cratered, darker in its old lava plains, eclipsed where the planet hides the sun.
        static float3 moon(float3 n, float3 at, Ctx c) {
            float3 albedo = float3(0.26, 0.25, 0.24) * (0.55f + 0.45f * smoothstep(0.35f, 0.6f, c.fbm(n * 2.5f + 3.1f, 4))) * (0.8f + 0.4f * c.noise(n * 24));
            return albedo / PI * (SUN_COLOR * saturate(dot(n, SUN)) * planetShadow(at) + BEACON_COLOR * saturate(dot(n, BEACON)));
        }

        // The planet, its moon and its rings along d, premultiplied, with how much of the sky they hide.
        static float4 planet(float3 d, Ctx c) {
            float2 hit = sphere(d, PLANET, PLANET_SIZE, c);
            float b = dot(PLANET, d), miss = sqrt(max(1 - b * b, 0.0f)), far = hit.y > 0 ? hit.x : INFINITY;
            float3 color = 0, edge = normalize(d * b - PLANET + 1e-6f);
            float haze = exp(-max(miss / PLANET_SIZE - 1, 0.0f) / 0.008f);
            if (hit.y > 0) {
                float3 at = d * hit.x, n = (at - PLANET) / PLANET_SIZE;
                float lit = dot(n, SUN), facing = saturate(dot(n, -d));
                float3 dusk = mix(float3(1.0, 0.42, 0.22), float3(1), smoothstep(0.0f, 0.3f, lit));
                color = clouds(n, c) / PI * (SUN_COLOR * pow(saturate(lit), 1.15f) * pow(facing, 0.15f) * dusk * ringShadow(at, c) + BEACON_COLOR * saturate(dot(n, BEACON)));
                // Ringshine and lightning on the night side.
                color += (float3(0.03, 0.027, 0.022) * saturate(dot(n, POLE)) + float3(0.3, 0.33, 0.4) * lightning(n, c)) * saturate(1 - lit * 4);
                haze = pow(1 - facing, 5.0f);
            }
            float4 body = float4(color * hit.y, hit.y);
            float3 satellite = moonAt(c);
            float2 moonHit = sphere(d, satellite, MOON_SIZE, c);
            if (moonHit.y > 0) {
                float3 at = d * moonHit.x;
                float4 layer = float4(moon((at - satellite) / MOON_SIZE, at, c) * moonHit.y, moonHit.y);
                body = moonHit.x < far ? over(layer, body) : over(body, layer);
                far = min(far, moonHit.x);
            }
            body.rgb += haze * float3(0.3, 0.45, 0.85) * smoothstep(-0.25f, 0.4f, dot(edge, SUN)) * 0.8f;
            float tr = dot(PLANET, POLE) / dot(d, POLE);
            if (tr > 0 && tr < far) {
                float3 at = d * tr;
                float r = length(at - PLANET) / PLANET_SIZE, density = ringDensity(r, c.pixel * tr / (abs(dot(d, POLE)) * PLANET_SIZE), c);
                if (density > 0) {
                    float3 ring = ringColor(r, c) * SUN_COLOR / PI * (0.35f + 0.65f * abs(dot(SUN, POLE))) * planetShadow(at);
                    body = over(float4(ring * density, density), body);
                }
            }
            return body;
        }

        // MARK: Sky

        // Glowing gas along the galaxy's band, brightest round the blue star, cut by lanes of dust;
        // `dust` is how much the lanes dim what's behind them.
        static float3 nebula(float3 d, Ctx c, thread float& dust) {
            float slow = c.t * 0.00015f;
            float3 p = d * 1.6f;
            float3 w = float3(c.fbm(p + float3(0, slow, 0), 3), c.fbm(p + float3(5.2, 1.3, -slow), 3), c.fbm(p + float3(slow, 9.1, 4.7), 3)) - 0.44f;
            float3 q = p * 2.2f + w * 2.6f;
            float gas = c.fbm(q, 7), lane = c.fbm(q * 1.4f + float3(7.7, 2.1, 5.3) + w, 6);
            float band = exp(-sq(dot(d, GALAXY) / 0.3f)), near = exp(-(1 - dot(d, BEACON)) * 11);
            float region = saturate(band * smoothstep(0.25f, 0.65f, c.fbm(p * 0.7f + 3.3f, 3) + 0.15f * band) + near);
            float glow = pow(region * smoothstep(0.38f, 0.85f, gas), 1.5f);
            float wisps = pow(1 - abs(2 * c.fbm(q * 2.1f + 1.9f, 5) - 1), 8.0f) * region * smoothstep(0.35f, 0.6f, gas);
            float3 tint = mix(float3(0.85, 0.16, 0.3), float3(0.08, 0.5, 0.55), smoothstep(0.38f, 0.62f, c.fbm(p * 0.9f + w * 1.2f + 6.1f, 3)));
            tint = mix(tint, float3(0.9, 0.42, 0.14), smoothstep(0.5f, 0.95f, dot(d, WARM)));
            tint = mix(tint, float3(0.2, 0.4, 1.0), near);
            float3 light = tint * (glow * 0.4f + wisps * 0.15f) + region * float3(0.004, 0.003, 0.007);
            dust = smoothstep(0.46f, 0.58f, lane) * (band * 0.9f + 0.1f) * 3;
            float rim = smoothstep(0.4f, 0.46f, lane) * smoothstep(0.52f, 0.46f, lane);
            return light * exp(-dust) + float3(0.6, 0.32, 0.14) * rim * glow * 0.15f;
        }

        // Stars a pixel or two across whatever the stretch, crowding where `crowd` is high.
        static float3 stars(float3 d, float crowd, Ctx c) {
            float3 sum = 0;
            float sigma = c.pixel * 0.65f * pow(max(-d.z, 0.3f), 1.5f);
            for (int layer = 0; layer < 4; layer++) {
                float scale = layer < 2 ? 240.0f : layer == 2 ? 110.0f : 45.0f;
                float3 q = d * scale + layer * 0.37f, cell = floor(q), a = hash3(cell + layer * 7.1f);
                if (a.x > (layer < 2 ? 0.9f : 0.6f) * (0.5f + 0.5f * crowd)) continue;
                float r = length(q - cell - 0.3f - 0.4f * hash3(cell + 3.3f + layer)) / scale;
                if (r > 4 * sigma) continue;
                float bright = (layer < 2 ? 0.6f : layer == 2 ? 3.0f : 25.0f) * pow(a.y, 3.0f) + 0.04f;
                sum += blackbody(4500 + 8000 * a.z) * bright * exp(-sq(r / sigma) * 0.5f);
            }
            return sum;
        }

        // The blue star, with a glow round it on the lens: round on the image plane, not the sky.
        static float3 beacon(float3 d, Ctx c) {
            if (d.z >= 0) return 0;
            float2 q = d.xy / -d.z - BEACON.xy / -BEACON.z;
            float r = length(q);
            return BEACON_COLOR * (2000 * exp(-sq(r / (c.pixel * 1.3f))) + 6 / (1 + sq(r / 0.004f)) + 0.5f / (1 + sq(r / 0.03f))
                                   + 0.05f * exp(-abs(q.y) / 0.001f - abs(q.x) / 0.12f));
        }

        float3 sky(float3 d, Ctx c) {
            float4 world = planet(d, c);
            if (world.a >= 1) return world.rgb;
            float dust;
            float3 light = nebula(d, c, dust);
            // Stars and the blue star's glare light nothing, and in the bake would only speckle it.
            if (!c.baking) light += stars(d, exp(-sq(dot(d, GALAXY)) / 0.05f), c) * exp(-dust * 1.5f) + beacon(d, c);
            return world.rgb + (1 - world.a) * (light + float3(0.0012, 0.0014, 0.0024));
        }

        // MARK: Near rocks

        // v turned by the unit quaternion q, and turned back.
        static float3 turned(float3 v, float4 q) {
            float3 t = 2 * cross(q.xyz, v);
            return v + q.w * t + cross(q.xyz, t);
        }
        static float3 unturned(float3 v, float4 q) { return turned(v, float4(-q.xyz, q.w)); }

        // The near rocks, placed each frame by update(), each traced where its mesh waits, turned
        // and scaled into place, then lit by the sun, the blue star and the sky, shadowed by itself.
        Live live(float3 ro, float3 rd, float maxDist, Ctx c) {
            float nearest = maxDist;
            uint which = DRIFTERS;
            Hit h;
            float3 ng;
            for (uint k = 0; k < DRIFTERS; k++) {
                float4 place = c.param(2 * k), turn = c.param(2 * k + 1);
                float radius = place.w * REACH[k % SHAPES];
                float3 oc = ro - place.xyz;
                float b = dot(oc, rd), disc = b * b - dot(oc, oc) + radius * radius;
                if (disc <= 0) continue;
                float enter = max(-b - sqrt(disc), 0.0f), exit = min(-b + sqrt(disc), nearest), scale = HOLD_SCALE / place.w, t;
                if (enter >= exit) continue;
                float3 o = HOLD + float3(HOLD_SPACING * (k % SHAPES), 0, 0) + unturned(oc + rd * enter, turn) * scale;
                if (!c.intersect(ray(o, unturned(rd, turn), 0, (exit - enter) * scale), CAMERA_MASK, h, t, ng)) continue;
                nearest = enter + t / scale;
                which = k;
            }
            if (which == DRIFTERS) return nothing();
            float4 place = c.param(2 * which), turn = c.param(2 * which + 1);
            float3 v = unturned(-rd, turn);
            if (dot(ng, v) < 0) ng = -ng;
            if (dot(h.n, v) < 0) h.n = -h.n;
            h.bounce = 0;
            Surface s = rock(h, float(which) * 13.1f + place.w * 97, c);
            float3 n = turned(s.normal, turn), o = offset(h.p, ng), light = c.ambient(n);
            for (uint i = 0; i < c.f->lightCount; i++) {
                float3 l = c.lights[i].a.xyz;
                if (dot(n, l) > 0 && !c.blocked(o, unturned(l, turn), 6 * HOLD_SCALE)) light += c.lights[i].color.rgb * dot(n, l);
            }
            return Live{s.albedo / PI * light, 1, nearest};
        }

        // MARK: Air

        // A faint haze of nebula dust, so the far rocks sit back into the colour behind them.
        Atmosphere atmosphere(float3 ro, float3 rd, float dist, Ctx c) {
            if (dist >= FAR) return {float3(0), float3(1)};
            float fog = 1 - exp(-dist * 0.0006f);
            return {float3(0.012, 0.01, 0.02) * fog, float3(1 - fog)};
        }

        // MARK: Dust

        // Dust and ice standing still while the eye glides toward the planet, so it streams out
        // from there: unseen far off, close by a bright head trailing a fading streak.
        Particle dust(uint i, Ctx c) {
            const float span = 40, speed = 1.4;
            // Each mote is a head and a longer streak, since one tail's linear fade looks even once tone-mapped.
            bool streak = i & 1;
            float3 a = hash3(float3(i / 2, 0.5, 1.5));
            float phase = a.x + c.t * speed / span, cycle = floor(phase), f = phase - cycle;
            float3 b = hash3(float3(i / 2, cycle, 2.5));
            float angle = TAU * b.y, reach = 0.8f + 13 * sqrt(b.x);
            Particle p;
            p.velocity = -PLANET * speed * (streak ? 8 : 1);
            p.position = PLANET * mix(span, -1.0f, f) + (RIGHT * cos(angle) + UP * sin(angle)) * reach - p.velocity * SHUTTER / 2;
            float dist = length(p.position);
            p.size = max(0.002f, dist * c.pixel * 1.2f);
            p.color = mix(float3(0.75, 0.85, 1.0), float3(1.0, 0.85, 0.65), b.z) * (0.4f + 3 * pow(a.y, 6.0f)) * sq(0.003f / p.size) * exp(-dist * 0.15f) * (streak ? 1 : 3);
            p.alpha = smoothstep(0.0f, 0.3f, f);
            p.tail = 1;
            p.glow = streak ? 0 : 0.1f * pow(a.y, 6.0f);
            p.halo = 4;
            return p;
        }
        """#)
    }
}
