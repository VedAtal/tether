import Metal
import MetalFX

/// One screen's images: the bake, the frame drawn over it, its bloom, and its scaler.
@MainActor
final class ScreenTargets {
    nonisolated static let bloomLevels = 6

    let screen: SaverScreen
    let width: Int
    let height: Int
    /// One running mean per light group, compacted once the bake is done.
    private(set) var groups: MTLTexture
    /// rgb: smooth reflections that reach the sky; a: how much sky is seen directly.
    let skyLight: MTLTexture
    /// What each pixel's center sees first (see `surfaceKernel`).
    let surfaces: MTLTexture
    let color: MTLTexture
    let depth: MTLTexture
    /// Each half the size of the one before, starting at half of `color`.
    let down: [MTLTexture]
    let up: [MTLTexture]
    private var scaler: (MTLFXSpatialScaler, MTLTexture)?
    private let device: MTLDevice

    var pixels: Int { width * height }

    init(_ screen: SaverScreen, groups count: Int, device: MTLDevice) throws {
        self.screen = screen
        self.device = device
        width = max(1, Int(screen.size.width.rounded()))
        height = max(1, Int(screen.size.height.rounded()))
        let (width, height) = (width, height)
        groups = try Self.texture(.rgba16Float, width, height, layers: count, device: device)
        skyLight = try Self.texture(.rgba16Float, width, height, device: device)
        surfaces = try Self.texture(.rgba32Uint, width, height, device: device)
        color = try Self.texture(.rgba16Float, width, height, usage: [.shaderRead, .shaderWrite, .renderTarget], device: device)
        depth = try Self.texture(.r16Float, width, height, device: device)
        let sizes = (1...Self.bloomLevels).map { (width >> $0, height >> $0) }
        down = try sizes.map { try Self.texture(.rg11b10Float, $0.0, $0.1, device: device) }
        up = try sizes.dropLast().map { try Self.texture(.rg11b10Float, $0.0, $0.1, device: device) }
    }

    /// Moves the finished bake into half the memory. Its rounding is dithered, so the coarser
    /// steps (about 1%) show as faint static noise under the grain rather than as bands.
    func compact(_ encoder: MTLComputeCommandEncoder) throws {
        let compacted = try Self.texture(.rg11b10Float, width, height, layers: groups.arrayLength, device: device)
        encoder.setTexture(groups, index: 0)
        encoder.setTexture(compacted, index: 1)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: groups.arrayLength), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        groups = compacted
    }

    private static func texture(_ format: MTLPixelFormat, _ width: Int, _ height: Int, layers: Int = 0,
                                usage: MTLTextureUsage = [.shaderRead, .shaderWrite], device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(width, 1), height: max(height, 1), mipmapped: false)
        if layers > 0 {
            descriptor.textureType = .type2DArray
            descriptor.arrayLength = layers
        }
        descriptor.usage = usage
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw SaverError.outOfMemory }
        return texture
    }

    /// `color` scaled to `target`'s size, or `color` itself if it's already that size.
    func scaled(to target: MTLTexture, commandBuffer: MTLCommandBuffer) -> MTLTexture {
        guard target.width != width || target.height != height else { return color }
        if scaler.map({ $0.1.width != target.width || $0.1.height != target.height }) ?? true {
            let descriptor = MTLFXSpatialScalerDescriptor()
            (descriptor.inputWidth, descriptor.inputHeight) = (width, height)
            (descriptor.outputWidth, descriptor.outputHeight) = (target.width, target.height)
            descriptor.colorTextureFormat = .rgba16Float
            descriptor.outputTextureFormat = .rgba16Float
            descriptor.colorProcessingMode = .hdr
            guard let made = descriptor.makeSpatialScaler(device: device),
                  let texture = try? Self.texture(.rgba16Float, target.width, target.height, usage: made.outputTextureUsage, device: device) else { return color }
            made.colorTexture = color
            made.outputTexture = texture
            made.inputContentWidth = width
            made.inputContentHeight = height
            scaler = (made, texture)
        }
        guard let (scaler, output) = scaler else { return color }
        scaler.encode(commandBuffer: commandBuffer)
        return output
    }
}
