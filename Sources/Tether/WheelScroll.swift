import CoreGraphics
import Foundation

/// Makes mouse wheels scroll the traditional way while macOS natural scrolling is on. macOS has
/// one direction for every device, so wheel events get turned back around.
enum WheelScroll {
    /// The macOS setting (System Settings → Trackpad or Mouse), which is on unless switched off.
    static var naturalScrolling: Bool {
        UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
    }

    static func makeTraditional(_ event: CGEvent) {
        // A wheel sends whole steps. Trackpads and the Magic Mouse scroll continuously.
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0, naturalScrolling else { return }
        for (lines, fixed, points) in axes {
            let (l, f, p) = (event.getIntegerValueField(lines), event.getDoubleValueField(fixed), event.getIntegerValueField(points))
            // Setting the line delta resets the other two, so it goes first.
            event.setIntegerValueField(lines, value: -l)
            event.setDoubleValueField(fixed, value: -f)
            event.setIntegerValueField(points, value: -p)
        }
    }

    /// Each axis's delta in its three units: vertical, then horizontal.
    private static let axes: [(CGEventField, CGEventField, CGEventField)] = [
        (.scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1),
        (.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2),
    ]
}
