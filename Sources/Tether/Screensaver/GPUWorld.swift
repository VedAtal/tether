import Metal

/// A world's static geometry, lights and noise on the GPU, with its acceleration structures.
@MainActor
final class GPUWorld {
    let triangleCount: Int
    private let lights: MTLBuffer
    private let instances: MTLBuffer
    private let positions: MTLBuffer
    private let normals: MTLBuffer
    private let uvs: MTLBuffer
    private let indices: MTLBuffer
    let ambient: MTLBuffer
    let noise: MTLTexture
    private let scene: MTLAccelerationStructure
    /// The cut-out copies, if any, apart from the rest, so that only rays that meet them pay for their holes.
    /// Without any, `scene` is bound in their place: the shaders declare them regardless, and Metal
    /// wants every declared argument bound.
    private let cutOuts: MTLAccelerationStructure?
    private let parts: [MTLAccelerationStructure]

    init(_ world: SaverWorld, device: MTLDevice, queue: MTLCommandQueue, noiseKernel: MTLComputePipelineState) async throws {
        // An empty world still needs something to trace against.
        let meshes = world.meshes.isEmpty ? [Mesh(positions: [.zero, .zero, .zero], normals: [[0, 1, 0], [0, 1, 0], [0, 1, 0]], indices: [0, 1, 2])] : world.meshes
        let placed = world.instances.isEmpty ? [SaverWorld.Instance(mesh: 0, transform: .identity, material: 0, castsShadows: false, cutOut: false, tag: 0)]
            : world.instances
        let vertexCount = meshes.reduce(0) { $0 + $1.positions.count }, indexCount = meshes.reduce(0) { $0 + $1.indices.count }
        triangleCount = placed.reduce(0) { $0 + meshes[$1.mesh].triangleCount }
        guard let positions = device.makeBuffer(length: vertexCount * 12), let normals = device.makeBuffer(length: vertexCount * 12),
              let uvs = device.makeBuffer(length: vertexCount * 8), let indices = device.makeBuffer(length: indexCount * 4) else { throw SaverError.outOfMemory }
        var offsets: [(vertex: Int, index: Int)] = []
        var vertex = 0, index = 0
        let p = positions.contents().bindMemory(to: Float.self, capacity: vertexCount * 3)
        let n = normals.contents().bindMemory(to: Float.self, capacity: vertexCount * 3)
        let uv = uvs.contents().bindMemory(to: SIMD2<Float>.self, capacity: vertexCount)
        let ix = indices.contents().bindMemory(to: UInt32.self, capacity: indexCount)
        for mesh in meshes {
            offsets.append((vertex, index))
            for (i, (position, normal)) in zip(mesh.positions, mesh.normals).enumerated() {
                for k in 0..<3 {
                    p[vertex * 3 + k] = position[k]
                    n[vertex * 3 + k] = normal[k]
                }
                uv[vertex] = i < mesh.uvs.count ? mesh.uvs[i] : .zero
                vertex += 1
            }
            for i in mesh.indices {
                ix[index] = i
                index += 1
            }
        }
        self.positions = positions
        self.normals = normals
        self.uvs = uvs
        self.indices = indices

        let lightData: [SIMD4<Float>] = world.lights.flatMap { light -> [SIMD4<Float>] in
            let color = SIMD4(light.color, Float(light.group))
            switch light.shape {
            case .sphere(let center, let radius): return [SIMD4(center, radius), SIMD4(0, 0, 0, 0), color]
            case .tube(let a, let b, let radius): return [SIMD4(a, radius), SIMD4(b, 1), color]
            case .directional(let direction, let angle): return [SIMD4(direction, angle), SIMD4(0, 0, 0, 2), color]
            }
        }
        let instanceData = placed.map { instance in
            let inverse = instance.transform.inverse.transpose
            return GPUInstance(inverse: (inverse.columns.0, inverse.columns.1, inverse.columns.2),
                               vertexOffset: UInt32(offsets[instance.mesh].vertex), indexOffset: UInt32(offsets[instance.mesh].index),
                               material: UInt32(instance.material), tag: UInt32(truncatingIfNeeded: instance.tag))
        }
        guard let lights = device.makeBuffer(bytes: lightData + [.zero, .zero, .zero], length: (lightData.count + 3) * 16),
              let instances = device.makeBuffer(bytes: instanceData, length: instanceData.count * MemoryLayout<GPUInstance>.stride),
              let ambient = device.makeBuffer(length: 9 * 16, options: .storageModePrivate) else { throw SaverError.outOfMemory }
        self.lights = lights
        self.instances = instances
        self.ambient = ambient

        // One acceleration structure per mesh, compacted once built, and one over the copies of them,
        // with any cut-outs in another, so that only rays that meet them pay for their holes. A copy's
        // user ID is its index.
        let partDescriptors: [MTLAccelerationStructureDescriptor] = meshes.enumerated().map { i, mesh in
            let geometry = MTLAccelerationStructureTriangleGeometryDescriptor()
            geometry.vertexBuffer = positions
            geometry.vertexBufferOffset = offsets[i].vertex * 12
            geometry.vertexStride = 12
            geometry.indexBuffer = indices
            geometry.indexBufferOffset = offsets[i].index * 4
            geometry.indexType = .uint32
            geometry.triangleCount = mesh.triangleCount
            geometry.opaque = true
            let descriptor = MTLPrimitiveAccelerationStructureDescriptor()
            descriptor.geometryDescriptors = [geometry]
            descriptor.usage = .preferFastIntersection
            return descriptor
        }
        let copies = placed.enumerated().map { i, instance in
            let m = instance.transform
            func packed(_ v: SIMD4<Float>) -> MTLPackedFloat3 { MTLPackedFloat3Make(v.x, v.y, v.z) }
            return MTLAccelerationStructureUserIDInstanceDescriptor(
                transformationMatrix: MTLPackedFloat4x3(columns: (packed(m.columns.0), packed(m.columns.1), packed(m.columns.2), packed(m.columns.3))),
                options: [instance.cutOut ? .nonOpaque : .opaque, .disableTriangleCulling], mask: instance.castsShadows ? 3 : 1,
                intersectionFunctionTableOffset: 0, accelerationStructureIndex: UInt32(instance.mesh), userID: UInt32(i))
        }
        // Builds in one encoder run at once, so each gets its own stretch of scratch.
        func build(_ descriptors: [MTLAccelerationStructureDescriptor], into buffer: MTLCommandBuffer) throws -> [MTLAccelerationStructure] {
            let sizes = descriptors.map { device.accelerationStructureSizes(descriptor: $0) }
            let offsets = sizes.reduce(into: [0]) { $0.append($0.last! + ($1.buildScratchBufferSize + 255) & ~255) }
            let structures = sizes.compactMap { device.makeAccelerationStructure(size: $0.accelerationStructureSize) }
            guard structures.count == descriptors.count, let scratch = device.makeBuffer(length: offsets.last!, options: .storageModePrivate),
                  let encoder = buffer.makeAccelerationStructureCommandEncoder() else { throw SaverError.outOfMemory }
            for (i, structure) in structures.enumerated() {
                encoder.build(accelerationStructure: structure, descriptor: descriptors[i], scratchBuffer: scratch, scratchBufferOffset: offsets[i])
            }
            encoder.endEncoding()
            return structures
        }
        guard let first = queue.makeCommandBuffer(), let compactedSizes = device.makeBuffer(length: 4 * meshes.count) else { throw SaverError.outOfMemory }
        let built = try build(partDescriptors, into: first)
        guard let encoder = first.makeAccelerationStructureCommandEncoder() else { throw SaverError.outOfMemory }
        for (i, part) in built.enumerated() { encoder.writeCompactedSize(accelerationStructure: part, buffer: compactedSizes, offset: 4 * i) }
        encoder.endEncoding()
        try await first.completion()
        let sizes = compactedSizes.contents().bindMemory(to: UInt32.self, capacity: built.count)
        let parts = built.indices.compactMap { device.makeAccelerationStructure(size: Int(sizes[$0])) }
        guard parts.count == built.count, let noise = Self.noiseTexture(device), let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeAccelerationStructureCommandEncoder() else { throw SaverError.outOfMemory }
        for (part, compacted) in zip(built, parts) { encoder.copyAndCompact(sourceAccelerationStructure: part, destinationAccelerationStructure: compacted) }
        encoder.endEncoding()
        let sceneDescriptors: [MTLAccelerationStructureDescriptor] = try (placed.contains(where: \.cutOut) ? [false, true] : [false]).map { cutOut in
            let set = copies.filter { placed[Int($0.userID)].cutOut == cutOut }
            let length = set.count * MemoryLayout<MTLAccelerationStructureUserIDInstanceDescriptor>.stride
            guard let buffer = device.makeBuffer(length: max(length, 1)) else { throw SaverError.outOfMemory }
            buffer.contents().copyMemory(from: set, byteCount: length)
            let descriptor = MTLInstanceAccelerationStructureDescriptor()
            descriptor.instanceCount = set.count
            descriptor.instanceDescriptorBuffer = buffer
            descriptor.instanceDescriptorType = .userID
            descriptor.usage = .preferFastIntersection
            descriptor.instancedAccelerationStructures = parts
            return descriptor
        }
        let scenes = try build(sceneDescriptors, into: buffer)
        self.parts = parts
        scene = scenes[0]
        cutOuts = scenes.dropFirst().first
        self.noise = noise
        if let encoder = buffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(noiseKernel)
            encoder.setTexture(noise, index: 0)
            encoder.dispatchThreads(MTLSize(width: 128, height: 128, depth: 128), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 4))
            encoder.endEncoding()
        }
        try await buffer.completion()
    }

    /// Binds what `WORLD_ARGS` declares, with `frame` as the frame.
    func bind(_ encoder: MTLComputeCommandEncoder, frame: [UInt32]) {
        encoder.setBytes(frame, length: frame.count * 4, index: 1)
        for (i, buffer) in [lights, instances, positions, normals, indices, ambient].enumerated() {
            encoder.setBuffer(buffer, offset: 0, index: i + 2)
        }
        encoder.setBuffer(uvs, offset: 0, index: 9)
        encoder.setAccelerationStructure(scene, bufferIndex: 8)
        encoder.setAccelerationStructure(cutOuts ?? scene, bufferIndex: 10)
        encoder.setTexture(noise, index: 8)
        encoder.useResources(parts, usage: .read)
    }

    /// The same, for the vertex stage.
    func bind(_ encoder: MTLRenderCommandEncoder, frame: [UInt32]) {
        encoder.setVertexBytes(frame, length: frame.count * 4, index: 1)
        for (i, buffer) in [lights, instances, positions, normals, indices, ambient].enumerated() {
            encoder.setVertexBuffer(buffer, offset: 0, index: i + 2)
        }
        encoder.setVertexBuffer(uvs, offset: 0, index: 9)
        encoder.setVertexAccelerationStructure(scene, bufferIndex: 8)
        encoder.setVertexAccelerationStructure(cutOuts ?? scene, bufferIndex: 10)
        encoder.setVertexTexture(noise, index: 8)
        encoder.useResources(parts, usage: .read, stages: .vertex)
    }

    /// One channel: four would halve how fast every lookup filters.
    private static func noiseTexture(_ device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r16Float
        (descriptor.width, descriptor.height, descriptor.depth) = (128, 128, 128)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }
}

/// Matches `Instance` in ShaderPrelude.
private struct GPUInstance {
    var inverse: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    var vertexOffset: UInt32
    var indexOffset: UInt32
    var material: UInt32
    var tag: UInt32
}

extension MTLCommandBuffer {
    /// Commits the buffer and waits for the GPU to finish it, without blocking the thread.
    @MainActor
    func completion() async throws {
        await withCheckedContinuation { continuation in
            addCompletedHandler { _ in continuation.resume() }
            commit()
        }
        if let error { throw error }
    }
}
