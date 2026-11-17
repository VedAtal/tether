import CoreGraphics

/// Sits in the session's event stream, where it can change events or swallow them. Needs Accessibility.
@MainActor
final class EventTap {
    private let types: [CGEventType]
    private let handler: (CGEvent) -> Bool
    private var tap: CFMachPort?

    /// `handler` gets every event of `types` and returns false to swallow it.
    init(_ types: CGEventType..., handler: @escaping (CGEvent) -> Bool) {
        self.types = types
        self.handler = handler
    }

    /// False if macOS refused the tap, which it does until Accessibility is granted.
    func start() -> Bool {
        guard tap == nil else { return true }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            let tap = Unmanaged<EventTap>.fromOpaque(userInfo!).takeUnretainedValue()
            return MainActor.assumeIsolated { tap.handle(type, event) } ? Unmanaged.passUnretained(event) : nil
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: types.reduce(0) { $0 | 1 << $1.rawValue },
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

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }
        return handler(event)
    }
}
