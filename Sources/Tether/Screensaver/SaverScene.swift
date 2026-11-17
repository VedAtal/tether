import CoreGraphics
import simd

/// One screensaver: a name, its icon in the panel, and how to build its world.
struct SaverScene: Identifiable, Sendable {
    let name: String
    /// An SF Symbol.
    let symbol: String
    /// Builds the world, off the main thread, each time the screensaver starts.
    let make: @Sendable () -> SaverWorld

    var id: String { name }

    init(name: String, symbol: String, world: @escaping @Sendable () -> SaverWorld) {
        self.name = name
        self.symbol = symbol
        make = world
    }
}

/// A scene's world. Its static part (meshes, lights, sky) is path-traced once per screen layout
/// into one image per light group. Each frame those are mixed by the groups' tints, and what moves
/// (`live()`, particles, live lights, the sky, emission) is drawn on top. ShaderPrelude has the
/// Metal side of the contract.
struct SaverWorld: Sendable {
    struct Camera: Sendable {
        var eye: SIMD3<Float>
        var target: SIMD3<Float>
        /// Vertical, in degrees, over the band of height every screen shares.
        var fieldOfView: Float
    }

    /// An analytic light. Lights are seen only through what they light, never directly or in
    /// mirrors: a visible lamp or neon tube is an emissive mesh beside its light.
    struct Light: Sendable {
        enum Shape: Sendable {
            case sphere(center: SIMD3<Float>, radius: Float)
            case tube(from: SIMD3<Float>, to: SIMD3<Float>, radius: Float)
            /// `direction` points toward the light; `angle` is its angular radius in radians.
            case directional(direction: SIMD3<Float>, angle: Float)
        }

        var shape: Shape
        /// Spheres and tubes: radiant intensity, so a surface a meter away facing it receives this
        /// much. Directional: the irradiance it gives a surface facing it.
        var color: SIMD3<Float>
        var group: Int

        static func sphere(_ center: SIMD3<Float>, radius: Float, color: SIMD3<Float>, group: Int) -> Light {
            Light(shape: .sphere(center: center, radius: radius), color: color, group: group)
        }

        static func tube(from a: SIMD3<Float>, to b: SIMD3<Float>, radius: Float, color: SIMD3<Float>, group: Int) -> Light {
            Light(shape: .tube(from: a, to: b, radius: radius), color: color, group: group)
        }

        static func directional(toward direction: SIMD3<Float>, angle: Float, color: SIMD3<Float>, group: Int) -> Light {
            Light(shape: .directional(direction: simd_normalize(direction), angle: angle), color: color, group: group)
        }
    }

    /// Quads drawn from a Metal function `Particle name(uint i, Ctx c)`.
    struct Particles: Sendable {
        enum Blend: Sendable { case additive, alpha }

        var function: String
        var count: Int
        var blend: Blend
    }

    struct Look: Sendable {
        var exposure: Float = 1
        var bloom: Float = 0.04
        var halation: Float = 0.25
        var grain: Float = 0.035
        var vignette: Float = 0.25
        /// Samples per pixel the bake stops at.
        var samples = 1024
        var bounces = 4
        /// The brightest one bounced sample may be, which keeps out isolated bright pixels.
        var clamp: Float = 20
        /// Rays per pixel through `live()` each frame, spread over the pixel and the shutter, for
        /// antialiasing and motion blur. Each costs a full `live()`.
        var liveSamples = 1
    }

    struct Instance: Sendable {
        var mesh: Int
        var transform: simd_float4x4
        var material: Int
        var castsShadows: Bool
        var cutOut: Bool
        var tag: Int
    }

    static let maxGroups = 8
    /// Scene time starts over every this many seconds, since float time loses smoothness after a
    /// few hours. Motion whose period divides it loops without a jump.
    static let cycle = 7200.0

    var camera: Camera
    var shader: MetalSource
    /// Light groups, at most `maxGroups`. Each bakes to its own image.
    var groups = 1
    /// The group the sky's light belongs to, or nil if the sky lights nothing.
    var skyGroup: Int? = 0
    var lights: [Light] = []
    var particles: [Particles] = []
    var look = Look()
    /// Whether glossy surfaces reflect what `live()` draws.
    var liveReflections = false
    /// Whether `atmosphere()` also hazes the live sky in mirrors, along the reflected ray.
    var hazeMirrors = false
    /// Whether shadows and bounced light take cut-out meshes as solid, so their holes show only
    /// where the eye sees them: far cheaper for foliage at scale, but its shadows lose their dapple.
    var cutOutsSolidToLight = false
    /// Called once per frame with the time in seconds (as `c.t` has it) and a frame at its defaults.
    var update: @Sendable (Double, inout SaverFrame) -> Void = { _, _ in }
    private(set) var meshes: [Mesh] = []
    private(set) var instances: [Instance] = []

    init(camera: Camera, shader: MetalSource) {
        self.camera = camera
        self.shader = shader
    }

    /// The same world without its meshes, once they're on the GPU.
    var withoutGeometry: SaverWorld {
        var world = self
        world.meshes = []
        world.instances = []
        return world
    }

    /// Adds a copy of `mesh` at each transform. `material` and `tag` are passed to the shader's
    /// functions in `Hit`. Glass and water shouldn't cast shadows. A cut-out mesh has holes where
    /// the shader's `opacity()` says so, for leaves and grass; it costs only the rays that meet it.
    mutating func add(_ mesh: Mesh, material: Int, at transforms: [simd_float4x4] = [.identity], castsShadows: Bool = true,
                      cutOut: Bool = false, tag: Int = 0) {
        guard !mesh.indices.isEmpty, !transforms.isEmpty else { return }
        meshes.append(mesh)
        instances += transforms.map {
            Instance(mesh: meshes.count - 1, transform: $0, material: material, castsShadows: castsShadows, cutOut: cutOut, tag: tag)
        }
    }
}

/// What a scene's `update` sets each frame. Every field starts at its default.
struct SaverFrame: Sendable {
    /// A light that moves or changes, shaded live from the baked surfaces and in `Context::shade`.
    struct Light: Sendable {
        /// A cone of light, as from a headlight.
        struct Spot: Sendable {
            var direction: SIMD3<Float>
            /// Half-angles in radians: full brightness inside `inner`, dark past `outer`.
            var inner: Float
            var outer: Float
        }

        var position: SIMD3<Float>
        var radius: Float = 0.05
        /// Radiant intensity, as for a sphere light.
        var color: SIMD3<Float>
        /// Casts shadows from the static world, at the cost of one ray per lit pixel in reach.
        var shadows = false
        /// Meters at which its light has faded smoothly to nothing; nothing farther is lit or traced.
        var range: Float?
        var spot: Spot?
        /// How strongly it glows in `c.inscatter`, as a multiple of its color: more for a beam
        /// through haze, 0 for none.
        var glow: Float = 1
    }

    static let maxParams = 64
    /// Each light is in the frame's constant data, which `setBytes` caps at 4 KB.
    static let maxLights = 32

    /// Each group's tint, 1 by default.
    var tints: [SIMD3<Float>]
    /// Anything the scene's Metal functions need, as `c.param(i)`.
    var params = [SIMD4<Float>](repeating: .zero, count: maxParams)
    var lights: [Light] = []

    init(groups: Int) {
        tints = Array(repeating: SIMD3(repeating: 1), count: groups)
    }
}

/// A scene's Metal source. Errors report lines in the Swift file, so write it as one raw string
/// literal that starts on the line of the call: `MetalSource(#"""`.
struct MetalSource: Sendable {
    let code: String
    let file: String
    let line: Int

    init(_ code: String, file: String = #filePath, line: Int = #line) {
        self.code = code
        self.file = file
        self.line = line
    }
}

extension SIMD where Scalar == Float {
    /// The vector as a Metal literal, to interpolate into a scene's shader.
    var metal: String { "float\(scalarCount)(" + indices.map { "\(self[$0])" }.joined(separator: ", ") + ")" }
}

extension Array where Element: SIMD, Element.Scalar == Float {
    /// The vectors as a Metal array's initializer.
    var metal: String { "{" + map(\.metal).joined(separator: ", ") + "}" }
}

/// One screen's part of the picture.
struct SaverScreen: Equatable, Sendable {
    /// Where it sits on the shared image plane, in scene units (SaverLayout).
    var rect: CGRect
    /// In points, which is the resolution scenes render at before scaling up.
    var size: CGSize
    /// Pixels per point.
    var scale: CGFloat
}
