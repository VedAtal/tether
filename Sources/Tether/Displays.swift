import AppKit
import Combine

/// An external monitor whose brightness can be set.
struct Monitor: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    /// 0 to 1.
    var brightness: Double
    let maxBrightness: Int
    let channel: DDCChannel
}

/// The connected monitors that take commands, and their brightness.
@MainActor
final class Displays: ObservableObject {
    @Published private(set) var monitors: [Monitor] = []
    private var writing: Set<CGDirectDisplayID> = []
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// Reads every monitor again: they come and go, and their own buttons change brightness too.
    func refresh() {
        // Left to right, as they're arranged.
        let screens = NSScreen.screens.filter { CGDisplayIsBuiltin($0.displayID) == 0 }
            .sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        Task {
            var found: [Monitor] = []
            for (index, screen) in screens.enumerated() {
                guard let channel = DDCChannel(display: screen.displayID),
                      let level = await channel.get(.brightness), level.max > 0 else { continue }
                found.append(Monitor(
                    id: screen.displayID, name: Self.name(of: screen, at: index, among: screens),
                    brightness: Double(level.current) / Double(level.max), maxBrightness: level.max, channel: channel
                ))
            }
            monitors = found
        }
    }

    func setBrightness(_ brightness: Double, of id: CGDirectDisplayID) {
        guard let index = monitors.firstIndex(where: { $0.id == id }) else { return }
        monitors[index].brightness = min(max(brightness, 0), 1)
        // A drag asks for values faster than a monitor takes them. One loop per monitor sends
        // the newest value each time round, skipping the ones in between.
        guard writing.insert(id).inserted else { return }
        Task {
            var sent: Int?
            while let monitor = monitors.first(where: { $0.id == id }),
                  case let value = Int((monitor.brightness * Double(monitor.maxBrightness)).rounded()), value != sent {
                await monitor.channel.set(.brightness, to: value)
                sent = value
            }
            writing.remove(id)
        }
    }

    /// Handles a brightness key for the monitor under the pointer. False if the pointer is on a
    /// screen this doesn't control, which leaves the key to macOS.
    func handleBrightnessKey(_ event: CGEvent) -> Bool {
        // Media keys arrive as "system defined" events: the key in data1's high half, then its state.
        guard let event = NSEvent(cgEvent: event), event.subtype.rawValue == 8,
              case let key = (event.data1 & 0xFFFF_0000) >> 16, key == NX_KEYTYPE_BRIGHTNESS_UP || key == NX_KEYTYPE_BRIGHTNESS_DOWN,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }),
              let monitor = monitors.first(where: { $0.id == screen.displayID })
        else { return false }
        if (event.data1 & 0xFF00) >> 8 == 0xA { // key down, including repeats
            // The same sixteen steps the keys give the built-in screen.
            setBrightness(monitor.brightness + (key == NX_KEYTYPE_BRIGHTNESS_UP ? 1 : -1) / 16, of: monitor.id)
        }
        return true
    }

    /// Identical monitors share a name, so several are told apart by where they sit.
    private static func name(of screen: NSScreen, at index: Int, among screens: [NSScreen]) -> String {
        let positions = [2: ["Left", "Right"], 3: ["Left", "Middle", "Right"]]
        let name = positions[screens.count]?[index] ?? screen.localizedName
        return screen.frame.height > screen.frame.width ? "\(name) · portrait" : name
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}
