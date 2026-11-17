import AppKit
import Combine
import SwiftAppKit
import SwiftUI

/// Tether's parts on top of SwiftAppKit's standard menu bar app (panel, menu, Settings, updates,
/// launch at login).
@MainActor
final class AppDelegate: MenuBarAppDelegate {
    private let prefs = Preferences.shared
    private let displays = Displays()
    private let screensaver = Screensaver()
    private lazy var tap = EventTap(.scrollWheel, .systemDefined) { [unowned self] event in
        if event.type == .scrollWheel {
            if prefs.traditionalWheel { WheelScroll.makeTraditional(event) }
            return true
        }
        return !(prefs.brightnessKeys && displays.handleBrightnessKey(event))
    }
    private var retry: Timer?
    private var subscriptions = Set<AnyCancellable>()

    // Only changing or swallowing events needs it.
    override var needsAccessibility: Bool { prefs.usesEvents }

    override func start() {
        applyTap(wanted: prefs.usesEvents)
        // @Published fires before the property changes, so use the values passed in.
        prefs.$traditionalWheel.combineLatest(prefs.$brightnessKeys).dropFirst()
            .sink { [weak self] wheel, keys in self?.applyTap(wanted: wheel || keys) }
            .store(in: &subscriptions)
    }

    override func makePanelView() -> AnyView? {
        applyTap(wanted: prefs.usesEvents) // picks up access granted after the retries ended
        displays.refresh()
        return AnyView(PanelView(displays: displays, prefs: prefs) { [weak self] in self?.startScreensaver() })
    }

    override func makeSettingsView() -> AnyView {
        AnyView(SettingsView(prefs: prefs))
    }

    private func startScreensaver() {
        closePanel()
        let scene = SaverScene.named(prefs.saverScene)
        do {
            try screensaver.start(scene, for: prefs.saverMinutes == 0 ? nil : TimeInterval(prefs.saverMinutes * 60), locks: prefs.saverLocks)
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
        }
    }

    /// Starts or stops the event tap. macOS refuses the tap until Accessibility is granted, so
    /// a refused start is retried every 2 seconds for 5 minutes, and again when the panel opens.
    private func applyTap(wanted: Bool) {
        retry?.invalidate()
        retry = nil
        guard wanted else { return tap.stop() }
        guard !tap.start() else { return }
        let deadline = Date.now.addingTimeInterval(300)
        retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.tap.start() || Date.now > deadline else { return }
                self.retry?.invalidate()
                self.retry = nil
            }
        }
    }
}

extension CGEventType {
    /// Media keys, the brightness keys among them.
    static let systemDefined = CGEventType(rawValue: 14)!
}
