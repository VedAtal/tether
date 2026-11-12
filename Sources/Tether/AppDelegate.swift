import AppKit
import Combine
import SwiftAppKit
import SwiftUI

/// Tether's parts on top of SwiftAppKit's standard menu bar app (menu, Settings, updates,
/// launch at login).
@MainActor
final class AppDelegate: MenuBarAppDelegate {
    private let prefs = Preferences.shared
    private let scrollTap = ScrollTap()
    private var retry: Timer?
    private var subscriptions = Set<AnyCancellable>()

    // Only changing scroll events needs it.
    override var needsAccessibility: Bool { prefs.traditionalWheel }

    override func start() {
        apply(traditionalWheel: prefs.traditionalWheel)
        // @Published fires before the property changes, so use the value passed in.
        prefs.$traditionalWheel.dropFirst()
            .sink { [weak self] on in self?.apply(traditionalWheel: on) }
            .store(in: &subscriptions)
    }

    override func addMenuItems(to menu: NSMenu) {
        apply(traditionalWheel: prefs.traditionalWheel) // picks up access granted after the retries ended
        menu.addItem("Traditional Mouse Wheel") { [prefs] in prefs.traditionalWheel.toggle() }
            .state = prefs.traditionalWheel ? .on : .off
        if prefs.traditionalWheel && !ScrollTap.naturalScrolling {
            menu.addDisabledItem("Natural scrolling is off in System Settings")
        }
    }

    override func makeSettingsView() -> AnyView {
        AnyView(SettingsView(prefs: prefs))
    }

    /// Starts or stops the scroll tap. macOS refuses the tap until Accessibility is granted, so
    /// a refused start is retried every 2 seconds for 5 minutes, and again when the menu opens.
    private func apply(traditionalWheel: Bool) {
        retry?.invalidate()
        retry = nil
        guard traditionalWheel else { return scrollTap.stop() }
        guard !scrollTap.start() else { return }
        let deadline = Date.now.addingTimeInterval(300)
        retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.scrollTap.start() || Date.now > deadline else { return }
                self.retry?.invalidate()
                self.retry = nil
            }
        }
    }
}
