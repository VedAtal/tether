import CoreGraphics
import Foundation

/// Makes mouse wheels scroll the traditional way while macOS natural scrolling is on. macOS has
/// one direction for every device, so this sits in the scroll event stream and turns wheel
/// events back around. Needs Accessibility.
@MainActor
final class ScrollTap {
    private var tap: CFMachPort?

    /// The macOS setting (System Settings → Trackpad or Mouse), which is on unless switched off.
    static var naturalScrolling: Bool {
        UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
    }

    /// False if macOS refused the tap, which it does until Accessibility is granted.
    func start() -> Bool {
        guard tap == nil else { return true }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            let tap = Unmanaged<ScrollTap>.fromOpaque(userInfo!).takeUnretainedValue()
            MainActor.assumeIsolated { tap.handle(type, event) }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: 1 << CGEventType.scrollWheel.rawValue,
            callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        self.tap = tap
        return true
    }

    func stop() {
        guard let tap else { return }
        CFMachPortInvalidate(tap) // its run loop source goes with it
        self.tap = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .scrollWheel:
            // A wheel sends whole steps. Trackpads and the Magic Mouse scroll continuously.
            guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0, Self.naturalScrolling else { return }
            for (lines, fixed, points) in Self.axes {
                let (l, f, p) = (event.getIntegerValueField(lines), event.getDoubleValueField(fixed), event.getIntegerValueField(points))
                // Setting the line delta resets the other two, so it goes first.
                event.setIntegerValueField(lines, value: -l)
                event.setDoubleValueField(fixed, value: -f)
                event.setIntegerValueField(points, value: -p)
            }
        default:
            break
        }
    }

    /// Each axis's delta in its three units: vertical, then horizontal.
    private static let axes: [(CGEventField, CGEventField, CGEventField)] = [
        (.scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1),
        (.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2),
    ]
}
