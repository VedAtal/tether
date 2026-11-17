import simd

/// Noise for building meshes on the CPU. Its hash isn't the prelude's, so the GPU can't recompute it.
enum Procedural {
    /// 0 to 1. Consecutive z give nearly the same value, so vary x or y between independent picks.
    static func hash(_ x: Int32, _ y: Int32, _ z: Int32, _ seed: Int32 = 0) -> Float {
        var h = UInt32(bitPattern: x) &* 374_761_393 &+ UInt32(bitPattern: y) &* 668_265_263
        h = h &+ UInt32(bitPattern: z) &* 2_147_483_647 &+ UInt32(bitPattern: seed) &* 1_442_695_041
        h = (h ^ (h >> 13)) &* 1_274_126_177
        return Float((h ^ (h >> 16)) & 0xFF_FFFF) / Float(0xFF_FFFF)
    }

    /// Smooth value noise, 0 to 1.
    static func noise(_ p: SIMD3<Float>, seed: Int32 = 0) -> Float {
        let i = floor(p), f = p - i
        let u = f * f * (3 - 2 * f)
        let (x, y, z) = (Int32(i.x), Int32(i.y), Int32(i.z))
        func h(_ dx: Int32, _ dy: Int32, _ dz: Int32) -> Float { hash(x + dx, y + dy, z + dz, seed) }
        let x00 = h(0, 0, 0) + (h(1, 0, 0) - h(0, 0, 0)) * u.x, x10 = h(0, 1, 0) + (h(1, 1, 0) - h(0, 1, 0)) * u.x
        let x01 = h(0, 0, 1) + (h(1, 0, 1) - h(0, 0, 1)) * u.x, x11 = h(0, 1, 1) + (h(1, 1, 1) - h(0, 1, 1)) * u.x
        let y0 = x00 + (x10 - x00) * u.y, y1 = x01 + (x11 - x01) * u.y
        return y0 + (y1 - y0) * u.z
    }

    /// Five octaves of `noise`, 0 to about 1.
    static func fbm(_ p: SIMD3<Float>, octaves: Int = 5, seed: Int32 = 0) -> Float {
        var sum: Float = 0, amplitude: Float = 0.5, q = p
        for _ in 0..<octaves {
            sum += amplitude * noise(q, seed: seed)
            q = q * 2.03 + SIMD3(1.7, 9.2, 3.1)
            amplitude *= 0.5
        }
        return sum
    }
}

/// The shaders' smoothstep, for building meshes and frames on the CPU.
func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

/// A repeatable random number generator (SplitMix64), so a scene builds the same every time.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
