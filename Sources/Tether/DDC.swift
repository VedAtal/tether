import CoreGraphics
import Foundation
import IOKit

/// One monitor's DDC/CI channel: the control commands a monitor takes over its video cable.
/// macOS has no public API for it on Apple silicon, so this calls private ones, looked up at run
/// time: a macOS without them loses the feature and nothing else.
final class DDCChannel: @unchecked Sendable {
    enum Feature: UInt8 {
        case brightness = 0x10
    }

    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private typealias DisplayInfo = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

    private static let create: Create? = symbol("IOKit", "IOAVServiceCreateWithService")
    private static let readI2C: Transfer? = symbol("IOKit", "IOAVServiceReadI2C")
    private static let writeI2C: Transfer? = symbol("IOKit", "IOAVServiceWriteI2C")
    private static let displayInfo: DisplayInfo? = symbol("CoreDisplay", "CoreDisplay_DisplayCreateInfoDictionary")

    // A command takes about 100 ms, and a monitor answers one at a time.
    private static let queue = DispatchQueue(label: "ddc")

    private let service: CFTypeRef

    /// Nil for a display with no channel: the built-in one, or one behind an adapter that drops it.
    init?(display: CGDirectDisplayID) {
        // Identical monitors report the same name and serial number, so the only thing tying a
        // display to its channel is the port: both registry paths name it ("dispext1").
        guard let info = Self.displayInfo?(display)?.takeRetainedValue() as? [String: Any],
              let location = info["IODisplayLocation"] as? String,
              let port = location.split(separator: "/").last(where: { $0.hasPrefix("dispext") })?.prefix(while: { $0 != "@" })
        else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var found: CFTypeRef?
        while found == nil, case let entry = IOIteratorNext(iterator), entry != 0 {
            if let path = IORegistryEntryCopyPath(entry, kIOServicePlane)?.takeRetainedValue() as String?,
               path.contains("/\(port):") {
                found = Self.create?(nil, entry)?.takeRetainedValue()
            }
            IOObjectRelease(entry)
        }
        guard let found else { return nil }
        service = found
    }

    /// The feature's current and highest value, or nil if the monitor doesn't answer.
    func get(_ feature: Feature) async -> (current: Int, max: Int)? {
        await run { [self] in
            guard let reply = request([0x01, feature.rawValue], replyLength: 12), reply[3] == 0 else { return nil }
            return (Int(reply[8]) << 8 | Int(reply[9]), Int(reply[6]) << 8 | Int(reply[7]))
        }
    }

    func set(_ feature: Feature, to value: Int) async {
        await run { [self] in _ = request([0x03, feature.rawValue, UInt8(value >> 8), UInt8(value & 0xFF)], replyLength: 0) }
    }

    private func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Self.queue.async { continuation.resume(returning: work()) }
        }
    }

    /// Sends one DDC/CI message to the monitor (I2C address 0x37) and returns its checked reply.
    private func request(_ payload: [UInt8], replyLength: Int) -> [UInt8]? {
        guard let readI2C = Self.readI2C, let writeI2C = Self.writeI2C else { return nil }
        var message = [0x80 | UInt8(payload.count)] + payload
        message.append(message.reduce(0x6E ^ 0x51, ^))
        // Monitors drop the odd message, so each gets a few tries.
        for _ in 0..<4 {
            usleep(50_000)
            guard writeI2C(service, 0x37, 0x51, &message, UInt32(message.count)) == KERN_SUCCESS else { continue }
            guard replyLength > 0 else { return [] }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: replyLength)
            guard readI2C(service, 0x37, 0, &reply, UInt32(replyLength)) == KERN_SUCCESS else { continue }
            let length = Int(reply[1] & 0x7F)
            guard reply[1] & 0x80 != 0, length > 0, length + 2 < replyLength,
                  reply[...(length + 1)].reduce(0x50, ^) == reply[length + 2] else { continue }
            return reply
        }
        return nil
    }

    private static func symbol<T>(_ framework: String, _ name: String) -> T? {
        let handle = dlopen("/System/Library/Frameworks/\(framework).framework/\(framework)", RTLD_NOW)
        return dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
    }
}
