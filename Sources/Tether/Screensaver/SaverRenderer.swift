import Foundation
import Metal
import QuartzCore
import os
import simd

enum SaverError: Error, CustomStringConvertible {
    case unsupported
    case outOfMemory
    /// The scene's world or Metal source is wrong; the compiler's log, if it got that far.
    case scene(String)

    var description: String {
        switch self {
        case .unsupported: "This Mac's GPU can't ray trace."
        case .outOfMemory: "The GPU ran out of memory."
        case .scene(let message): message
        }
    }
}

/// Draws a scene across every screen. Its static world is path-traced into one image per light
/// group, a few slices between each frame; every frame mixes those by the groups' tints, draws
/// what moves on top and finishes it like film. All screens show the same moment.
@MainActor
final class SaverRenderer {
    struct Stats {
        /// Samples per pixel baked so far.
        var samples: Int
        /// GPU time per baked sample over every screen.
        var bakeMilliseconds: Double
        /// GPU time per frame, not counting the bake.
        var liveMilliseconds: Double
    }

    /// The bake fades in from black over this many seconds, baking faster while it's dark.
    static let fadeIn = 2.0

    private let world: SaverWorld
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let gpu: GPUWorld
    private let pipelines: Pipelines
    private let timings = Timings()
    /// The frame at t = 0 with every tint 1: the bake stores each group untinted.
    private let bakeFrame: [UInt32]
    private var screens: [ScreenTargets] = []
    private var bake = Bake()
    /// How much of its budget the bake may use, cut while the window server falls behind.
    private var bakeShare = 1.0
    private var frameIndex: UInt32 = 0
    private var planeRadius: Float = 1

    var stats: Stats {
        let megapixels = Double(screens.reduce(0) { $0 + $1.pixels }) / 1e6
        return Stats(samples: bake.samples, bakeMilliseconds: timings.bakeCost * megapixels, liveMilliseconds: timings.medianLive)
    }

    var isBaked: Bool { bake.samples >= world.look.samples }
    var triangleCount: Int { gpu.triangleCount }

    /// Builds the world off the main thread, then compiles its Metal and uploads it. Cancelling
    /// stops it between steps, before it takes more memory.
    static func make(_ scene: SaverScene, device: MTLDevice, screens: [SaverScreen]) async throws -> SaverRenderer {
        guard device.supportsRaytracing, let queue = device.makeCommandQueue() else { throw SaverError.unsupported }
        let world = await Task.detached(priority: .userInitiated) { scene.make() }.value
        try Task.checkCancellation()
        try check(world)
        let pipelines: Pipelines
        do {
            let library = try await device.makeLibrary(source: ShaderCore.source(for: world), options: nil)
            try Task.checkCancellation()
            pipelines = try await Pipelines(library: library, world: world, device: device)
        } catch where error is SaverError || error is CancellationError {
            throw error
        } catch {
            let log = (error as NSError).localizedDescription
            throw SaverError.scene(log.contains("Undefined symbol")
                ? log + "\nA function the scene declares or opts into (surface, sky, or one behind a HAS_ define) isn't defined." : log)
        }
        try Task.checkCancellation()
        let gpu = try await GPUWorld(world, device: device, queue: queue, noiseKernel: pipelines.noise)
        let renderer = SaverRenderer(world: world.withoutGeometry, device: device, queue: queue, gpu: gpu, pipelines: pipelines)
        try await renderer.measureSky()
        try Task.checkCancellation()
        try renderer.setScreens(screens)
        return renderer
    }

    private init(world: SaverWorld, device: MTLDevice, queue: MTLCommandQueue, gpu: GPUWorld, pipelines: Pipelines) {
        self.world = world
        self.device = device
        self.queue = queue
        self.gpu = gpu
        self.pipelines = pipelines
        var frame = SaverFrame(groups: world.groups)
        world.update(0, &frame)
        frame.tints = Array(repeating: SIMD3(repeating: 1), count: world.groups)
        bakeFrame = Self.frameData(frame, time: 0, baking: true, world: world)
    }

    private static func check(_ world: SaverWorld) throws {
        var problems: [String] = []
        if !(1...SaverWorld.maxGroups).contains(world.groups) { problems.append("groups must be 1 to \(SaverWorld.maxGroups)") }
        if let sky = world.skyGroup, !(0..<world.groups).contains(sky) { problems.append("skyGroup \(sky) isn't a group") }
        for light in world.lights where !(0..<world.groups).contains(light.group) { problems.append("a light is in group \(light.group), which isn't a group") }
        for system in world.particles where system.count <= 0 || system.function.isEmpty { problems.append("particle system \(system.function) is empty") }
        if !problems.isEmpty { throw SaverError.scene(problems.joined(separator: "\n")) }
    }

    /// Starts the bake over for a new arrangement of screens.
    func setScreens(_ screens: [SaverScreen]) throws {
        guard screens != self.screens.map(\.screen) else { return }
        // The old targets go first, so the two sets are never held at once.
        self.screens = []
        self.screens = try screens.map { try ScreenTargets($0, groups: world.groups, device: device) }
        planeRadius = screens.flatMap { s in [CGPoint(x: s.rect.minX, y: s.rect.minY), CGPoint(x: s.rect.maxX, y: s.rect.maxY),
                                               CGPoint(x: s.rect.minX, y: s.rect.maxY), CGPoint(x: s.rect.maxX, y: s.rect.minY)] }
            .map { Float(hypot($0.x, $0.y)) }.max() ?? 1
        bake = Bake()
    }

    /// Whether a frame can start: at most two are in flight, so a slow GPU drops frames instead
    /// of queueing them. Ask before taking drawables, which block while every one is in use.
    var canRender: Bool { timings.framesInFlight < 2 }

    /// Encodes a frame at `time` into `targets`, one per screen in the order given to
    /// `setScreens`, and queues bake work behind it. `behind` says earlier frames aren't on screen
    /// yet. Commit the buffer it returns (after presenting); nil means skip this frame.
    func render(time: Double, into targets: [MTLTexture], behind: Bool = false) -> MTLCommandBuffer? {
        guard targets.count == screens.count, let buffer = queue.makeCommandBuffer(), timings.beginFrame() else { return nil }
        let now = CACurrentMediaTime()
        if bake.started == nil { startBake(into: buffer, now: now) }
        compact(into: buffer)
        let time = time.truncatingRemainder(dividingBy: SaverWorld.cycle)
        var frame = SaverFrame(groups: world.groups)
        world.update(time, &frame)
        let data = Self.frameData(frame, time: Float(time), baking: false, world: world)
        let dark = now - (bake.started ?? now)
        let fade = Float(min(1, dark / Self.fadeIn))
        frameIndex &+= 1
        for (screen, output) in zip(screens, targets) {
            encodeFrame(screen, into: output, frame: data, exposure: world.look.exposure * fade * fade * (3 - 2 * fade), buffer: buffer)
        }
        buffer.addCompletedHandler { [timings] buffer in
            timings.frameFinished(milliseconds: (buffer.gpuEndTime - buffer.gpuStartTime) * 1000)
        }
        // Reserves the frame's place in the queue, so the bake below runs after it.
        buffer.enqueue()
        // Frames not yet on screen mean the window server is short of GPU time: give it back fast,
        // and take it again slowly.
        bakeShare = behind ? max(0.05, bakeShare * 0.6) : min(1, bakeShare + 0.02)
        encodeBake(milliseconds: bakeShare * (dark < Self.fadeIn ? Self.darkBake : max(0, Self.frameBudget - timings.medianLive)))
        return buffer
    }

    // MARK: Baking

    private struct Bake {
        var started: CFTimeInterval?
        var samples = 0
        /// What's left of the current pass, which adds `passSize` samples to every pixel.
        var pending: [(screen: Int, rows: Range<Int>)] = []
        var passSize = 1
        var compacted = 0
    }

    /// Frames take about this much GPU time while baking: well short of a 30 fps frame, so the
    /// window server can show them on time.
    private static let frameBudget = 22.0
    /// Bake work per frame while the picture is still fading in.
    private static let darkBake = 26.0
    /// Bake work goes to the GPU in pieces about this long, so other work can run between them.
    private static let pieceMilliseconds = 4.0

    /// Shades every screen's first hit. The bake's first pass follows in pieces while the picture is still black.
    private func startBake(into buffer: MTLCommandBuffer, now: CFTimeInterval) {
        guard let encoder = buffer.makeComputeCommandEncoder() else { return }
        bake.started = now
        gpu.bind(encoder, frame: bakeFrame)
        encoder.setComputePipelineState(pipelines.surface)
        for target in screens {
            var view = view(of: target)
            encoder.setBytes(&view, length: MemoryLayout<GPUView>.stride, index: 0)
            encoder.setTexture(target.surfaces, index: 0)
            dispatch(encoder, width: target.width, height: target.height)
        }
        encoder.endEncoding()
    }

    /// Once baked, packs one screen's groups a frame, so only one screen's are ever held twice.
    private func compact(into buffer: MTLCommandBuffer) {
        guard isBaked, bake.compacted < screens.count, let encoder = buffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipelines.compact)
        try? screens[bake.compacted].compact(encoder)
        bake.compacted += 1
        encoder.endEncoding()
    }

    /// Queues about `milliseconds` of bake work as short command buffers, unless earlier ones are
    /// still running.
    private func encodeBake(milliseconds: Double) {
        guard !isBaked, timings.bakesInFlight == 0 else { return }
        let cost = timings.bakeCost
        var left = milliseconds / cost
        while !isBaked, left > 0, let piece = queue.makeCommandBuffer(), let encoder = piece.makeComputeCommandEncoder() {
            let cap = min(left, Self.pieceMilliseconds / cost)
            let megasamples = encodePasses(encoder) { $0 < cap }
            encoder.endEncoding()
            left -= megasamples
            timings.bakeQueued()
            piece.addCompletedHandler { [timings] piece in
                timings.bakeFinished(milliseconds: (piece.gpuEndTime - piece.gpuStartTime) * 1000, megasamples: megasamples)
            }
            piece.commit()
        }
    }

    /// Encodes bake slices while `more` says so, given the millions of pixel-samples so far; at
    /// least one. Returns how many it encoded.
    private func encodePasses(_ encoder: MTLComputeCommandEncoder, while more: (Double) -> Bool) -> Double {
        gpu.bind(encoder, frame: bakeFrame)
        encoder.setComputePipelineState(pipelines.bake)
        var megasamples = 0.0
        repeat {
            if bake.pending.isEmpty { startPass() }
            let slice = bake.pending.removeFirst(), target = screens[slice.screen]
            var view = view(of: target)
            view.rowOffset = UInt32(slice.rows.lowerBound)
            view.sample = UInt32(bake.samples)
            view.count = UInt32(bake.passSize)
            encoder.setBytes(&view, length: MemoryLayout<GPUView>.stride, index: 0)
            encoder.setTexture(target.groups, index: 0)
            encoder.setTexture(target.skyLight, index: 1)
            dispatch(encoder, width: target.width, height: slice.rows.count)
            megasamples += Double(target.width * slice.rows.count * bake.passSize) / 1e6
            if bake.pending.isEmpty { bake.samples += bake.passSize }
        } while !isBaked && more(megasamples)
        return megasamples
    }

    private func startPass() {
        // Four samples a pass share one hit from the eye and one read and write of every group;
        // the first pass is one sample, so the picture appears at once.
        bake.passSize = bake.samples == 0 ? 1 : min(4, world.look.samples - bake.samples)
        bake.pending = screens.indices.flatMap { i in
            let target = screens[i]
            let rows = max(8, 500_000 / (target.width * bake.passSize))
            return stride(from: 0, to: target.height, by: rows).map { (i, $0..<min($0 + rows, target.height)) }
        }
    }

    private func measureSky() async throws {
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeComputeCommandEncoder() else { throw SaverError.outOfMemory }
        gpu.bind(encoder, frame: bakeFrame)
        encoder.setBuffer(gpu.ambient, offset: 0, index: 11)
        encoder.setComputePipelineState(pipelines.ambient)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: min(256, pipelines.ambient.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        encoder.endEncoding()
        try await buffer.completion()
    }

    // MARK: Each frame

    private func encodeFrame(_ target: ScreenTargets, into output: MTLTexture, frame: [UInt32], exposure: Float, buffer: MTLCommandBuffer) {
        var view = view(of: target)
        if let encoder = buffer.makeComputeCommandEncoder() {
            gpu.bind(encoder, frame: frame)
            encoder.setBytes(&view, length: MemoryLayout<GPUView>.stride, index: 0)
            for (i, texture) in [target.groups, target.skyLight, target.surfaces, target.color, target.depth].enumerated() {
                encoder.setTexture(texture, index: i)
            }
            encoder.setComputePipelineState(pipelines.live)
            dispatch(encoder, width: target.width, height: target.height)
            encoder.endEncoding()
        }
        if !world.particles.isEmpty, let encoder = buffer.makeRenderCommandEncoder(descriptor: pass(into: target.color, load: true)) {
            gpu.bind(encoder, frame: frame)
            encoder.setVertexBytes(&view, length: MemoryLayout<GPUView>.stride, index: 0)
            encoder.setFragmentTexture(target.depth, index: 0)
            encoder.setFragmentTexture(gpu.noise, index: 1)
            for (system, pipeline) in zip(world.particles, pipelines.particles) {
                encoder.setRenderPipelineState(pipeline)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: system.count)
            }
            encoder.endEncoding()
        }
        if let encoder = buffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(pipelines.bloomDown)
            for (i, (source, destination)) in zip([target.color] + target.down.dropLast(), target.down).enumerated() {
                var first: UInt32 = i == 0 ? 1 : 0
                encoder.setBytes(&first, length: 4, index: 0)
                encoder.setTexture(source, index: 0)
                encoder.setTexture(destination, index: 1)
                dispatch(encoder, width: destination.width, height: destination.height)
            }
            encoder.setComputePipelineState(pipelines.bloomUp)
            for k in target.up.indices.reversed() {
                encoder.setTexture(k == target.up.count - 1 ? target.down[k + 1] : target.up[k + 1], index: 0)
                encoder.setTexture(target.down[k], index: 1)
                encoder.setTexture(target.up[k], index: 2)
                dispatch(encoder, width: target.up[k].width, height: target.up[k].height)
            }
            encoder.endEncoding()
        }
        let source = target.scaled(to: output, commandBuffer: buffer)
        if let encoder = buffer.makeRenderCommandEncoder(descriptor: pass(into: output, load: false)) {
            let look = world.look
            var finish = GPUFinish(rect: target.screen.rect.corners, plane: SIMD4(0, 0, planeRadius, 0),
                                   size: SIMD2(Float(output.width), Float(output.height)), exposure: exposure, bloom: look.bloom,
                                   halation: look.halation, grain: look.grain, vignette: look.vignette, frame: frameIndex)
            encoder.setRenderPipelineState(pipelines.finish)
            encoder.setFragmentBytes(&finish, length: MemoryLayout<GPUFinish>.stride, index: 0)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentTexture(target.up[0], index: 1)
            encoder.setFragmentTexture(target.down[1], index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
    }

    // MARK: Helpers

    private func view(of target: ScreenTargets) -> GPUView {
        let camera = world.camera
        let forward = simd_normalize(camera.target - camera.eye)
        let right = simd_normalize(simd_cross(forward, [0, 1, 0])), up = simd_cross(right, forward)
        let r = target.screen.rect
        // The image plane sits where a band one unit tall fills the field of view.
        let plane = 0.5 / tan(camera.fieldOfView * .pi / 360)
        return GPUView(eye: SIMD4(camera.eye, plane), right: SIMD4(right, 0), up: SIMD4(up, 0),
                       forward: SIMD4(forward, Float(r.width) / Float(target.width) / plane), rect: r.corners,
                       size: SIMD2(UInt32(target.width), UInt32(target.height)), bounces: UInt32(world.look.bounces), clampLimit: world.look.clamp)
    }

    /// `Frame` in ShaderPrelude, as words.
    private static func frameData(_ frame: SaverFrame, time: Float, baking: Bool, world: SaverWorld) -> [UInt32] {
        var words = [UInt32](repeating: 0, count: 4 * (2 + SaverWorld.maxGroups + SaverFrame.maxParams + 4 * SaverFrame.maxLights))
        func put(_ v: SIMD4<Float>, at slot: Int) {
            for k in 0..<4 { words[slot * 4 + k] = v[k].bitPattern }
        }
        let lights = frame.lights.prefix(SaverFrame.maxLights)
        words[0] = time.bitPattern
        words[1] = UInt32(world.lights.count)
        words[2] = world.skyGroup.map(UInt32.init) ?? .max
        words[3] = UInt32(lights.count)
        words[4] = baking ? 1 : 0
        for (i, tint) in frame.tints.prefix(SaverWorld.maxGroups).enumerated() { put(SIMD4(tint, 0), at: 2 + i) }
        for (i, param) in frame.params.prefix(SaverFrame.maxParams).enumerated() { put(param, at: 2 + SaverWorld.maxGroups + i) }
        for (i, light) in lights.enumerated() {
            let slot = 2 + SaverWorld.maxGroups + SaverFrame.maxParams + 4 * i
            put(SIMD4(light.position, light.radius), at: slot)
            put(SIMD4(light.color, light.shadows ? 1 : 0), at: slot + 1)
            // No spot: a zero axis, and cosines below any angle's.
            let spot = light.spot.map { (simd_normalize($0.direction), cos($0.outer), cos($0.inner)) } ?? (.zero, -2, -1)
            let range = light.range ?? .infinity
            put(SIMD4(spot.0, spot.1), at: slot + 2)
            // A cone under 60° and its range fit in a smaller sphere than the range's, through its apex.
            put(SIMD4(range, spot.2, light.glow, spot.1 > 0.5 && range.isFinite ? range / (2 * spot.1) : 0), at: slot + 3)
        }
        return words
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, width: Int, height: Int) {
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
    }

    private func pass(into texture: MTLTexture, load: Bool) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = load ? .load : .dontCare
        pass.colorAttachments[0].storeAction = .store
        return pass
    }
}

/// The scene's compiled functions.
private struct Pipelines {
    let bake, surface, live, bloomDown, bloomUp, noise, ambient, compact: MTLComputePipelineState
    let finish: MTLRenderPipelineState
    let particles: [MTLRenderPipelineState]

    init(library: MTLLibrary, world: SaverWorld, device: MTLDevice) async throws {
        func function(_ name: String) throws -> MTLFunction {
            guard let function = library.makeFunction(name: name) else { throw SaverError.scene("No Metal function \(name)") }
            return function
        }
        func compute(_ name: String) async throws -> MTLComputePipelineState {
            try await device.makeComputePipelineState(function: function(name))
        }
        func render(_ vertex: String, _ fragment: String, format: MTLPixelFormat, blend: SaverWorld.Particles.Blend?) async throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = try function(vertex)
            descriptor.fragmentFunction = try function(fragment)
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = format
            if let blend {
                // Premultiplied; the alpha channel is left as it was.
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = blend == .additive ? .one : .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .zero
                attachment.destinationAlphaBlendFactor = .one
            }
            return try await device.makeRenderPipelineState(descriptor: descriptor)
        }
        // The bake kernel is the slow one to compile, so the rest compile beside it.
        async let bake = compute("bakeKernel")
        async let live = compute("liveKernel")
        surface = try await compute("surfaceKernel")
        bloomDown = try await compute("bloomDown")
        bloomUp = try await compute("bloomUp")
        noise = try await compute("noiseKernel")
        ambient = try await compute("ambientKernel")
        compact = try await compute("compactKernel")
        finish = try await render("fullscreen", "finishFragment", format: .bgra8Unorm, blend: nil)
        var particles: [MTLRenderPipelineState] = []
        for (i, system) in world.particles.enumerated() {
            particles.append(try await render("particles\(i)", "particleFragment", format: .rgba16Float, blend: system.blend))
        }
        self.particles = particles
        self.bake = try await bake
        self.live = try await live
    }
}

/// GPU times, reported from Metal's threads.
private final class Timings: Sendable {
    private struct State {
        var baked = (milliseconds: 0.0, megasamples: 0.0)
        var recentLive: [Double] = []
        var framesInFlight = 0
        var bakesInFlight = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var framesInFlight: Int { state.withLock { $0.framesInFlight } }
    var bakesInFlight: Int { state.withLock { $0.bakesInFlight } }
    var medianLive: Double { state.withLock { $0.recentLive.sorted().dropFirst($0.recentLive.count / 2).first ?? 0 } }

    /// GPU milliseconds per million pixel-samples of bake, guessed high until measured.
    var bakeCost: Double {
        state.withLock { $0.baked.megasamples > 0 ? $0.baked.milliseconds / $0.baked.megasamples : 8 }
    }

    func beginFrame() -> Bool {
        state.withLock { s in
            guard s.framesInFlight < 2 else { return false }
            s.framesInFlight += 1
            return true
        }
    }

    func frameFinished(milliseconds: Double) {
        state.withLock { s in
            s.framesInFlight -= 1
            s.recentLive = (s.recentLive + [milliseconds]).suffix(60)
        }
    }

    func bakeQueued() { state.withLock { $0.bakesInFlight += 1 } }

    func bakeFinished(milliseconds: Double, megasamples: Double) {
        state.withLock { s in
            s.bakesInFlight -= 1
            s.baked.milliseconds += milliseconds
            s.baked.megasamples += megasamples
        }
    }
}

/// Matches `View` in ShaderCore.
private struct GPUView {
    var eye: SIMD4<Float>
    var right: SIMD4<Float>
    var up: SIMD4<Float>
    var forward: SIMD4<Float>
    var rect: SIMD4<Float>
    var size: SIMD2<UInt32>
    var rowOffset: UInt32 = 0
    var sample: UInt32 = 0
    var count: UInt32 = 0
    var bounces: UInt32
    var clampLimit: Float
}

/// Matches `Finish` in ShaderCore.
private struct GPUFinish {
    var rect: SIMD4<Float>
    var plane: SIMD4<Float>
    var size: SIMD2<Float>
    var exposure: Float
    var bloom: Float
    var halation: Float
    var grain: Float
    var vignette: Float
    var frame: UInt32
}

private extension CGRect {
    /// Min x, min y, max x, max y, as `View` and `Finish` take a rect.
    var corners: SIMD4<Float> { SIMD4(Float(minX), Float(minY), Float(maxX), Float(maxY)) }
}
