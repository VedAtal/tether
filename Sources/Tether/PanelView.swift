import SwiftAppKit
import SwiftUI

/// What the menu bar icon opens. SwiftAppKit adds the footer.
struct PanelView: View {
    @ObservedObject var displays: Displays
    @ObservedObject var prefs: Preferences
    let startScreensaver: () -> Void

    private static let durations = [(0, "No limit"), (15, "15 min"), (30, "30 min"), (60, "1 hr"), (120, "2 hr")]

    var body: some View {
        PanelSection("Displays") {
            group("Brightness") {
                if displays.monitors.isEmpty {
                    Text("No monitor that takes brightness commands").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(displays.monitors) { monitor in
                    brightness(monitor)
                }
            }
            group("Screensaver") {
                sceneMenu
                HStack(spacing: 6) {
                    ForEach(Self.durations, id: \.0) { minutes, label in
                        choice(minutes == prefs.saverMinutes, select: { prefs.saverMinutes = minutes }) {
                            Text(label).font(.caption.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                    }
                }
                PanelToggle("Lock when it ends", isOn: $prefs.saverLocks)
                Button(action: startScreensaver) {
                    Label("Start", systemImage: "play.fill")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.panelTile(highlighted: true))
                .keyboardShortcut(.defaultAction)
                Text("Keeps the displays awake. Any key, click or mouse movement ends it\(prefs.saverLocks ? " and locks the Mac" : "").")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        PanelSection("Mouse") {
            PanelToggle("Traditional wheel", isOn: $prefs.traditionalWheel)
            if prefs.traditionalWheel && !WheelScroll.naturalScrolling {
                Text("Natural scrolling is off in System Settings").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout.weight(.medium))
            content()
        }
    }

    private var sceneMenu: some View {
        let scene = SaverScene.named(prefs.saverScene)
        return Menu {
            Picker("Scene", selection: $prefs.saverScene) {
                ForEach(SaverScene.all) { Label($0.name, systemImage: $0.symbol).tag($0.name) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: scene.symbol).frame(width: 18)
                Text(scene.name)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        // Drawn by SwiftUI rather than as a pop-up button, so it takes the tile look.
        .menuStyle(.button)
        .buttonStyle(.panelTile)
        .menuIndicator(.hidden)
    }

    private func brightness(_ monitor: Monitor) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(monitor.name).fontWeight(.medium)
                Spacer()
                Text(monitor.brightness, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "sun.min").font(.caption)
                Slider(value: Binding(get: { monitor.brightness }, set: { displays.setBrightness($0, of: monitor.id) }))
                Image(systemName: "sun.max")
            }
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .panelTile()
    }

    /// A tile that picks one of several values; the chosen one is highlighted.
    private func choice(_ chosen: Bool, select: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: select) {
            label().foregroundStyle(chosen ? .primary : .secondary)
        }
        .buttonStyle(.panelTile(highlighted: chosen))
    }
}
