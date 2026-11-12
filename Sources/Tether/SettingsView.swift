import SwiftAppKit
import SwiftUI

/// Tether's sections of the Settings window. SettingsForm adds the standard General section.
struct SettingsView: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        SettingsForm(needsAccessibility: prefs.traditionalWheel, height: 300) {
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
