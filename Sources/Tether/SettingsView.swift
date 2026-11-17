import SwiftAppKit
import SwiftUI

/// Tether's sections of the Settings window. SettingsForm adds the standard General section.
struct SettingsView: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        SettingsForm(needsAccessibility: prefs.usesEvents, height: 420) {
            Section {
                Toggle("Brightness keys", isOn: $prefs.brightnessKeys)
            } header: {
                Text("Displays")
            } footer: {
                Text("The keyboard's brightness keys change the screen the pointer is on, external monitors included.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Traditional wheel scrolling", isOn: $prefs.traditionalWheel)
            } header: {
                Text("Mouse")
            } footer: {
                Text("A mouse wheel scrolls the traditional way while natural scrolling is on in System Settings. "
                     + "The trackpad and Magic Mouse stay natural.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
