import SwiftUI

struct ScreenshotsSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ScreenshotCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var settings = settings
        return Form {
            Section {
                Toggle(isOn: $settings.screenshotsEnabled) {
                    SettingsFeatureToggleLabel(
                        anchor: .screenshotsScreenshots, title: "Enable Screenshots",
                        subtitle: "Capture, copy, and save images. Search text in your screenshot folder locally.")
                }
            }
            .settingsAnchor(.screenshotsScreenshots)

            Section {
                LabeledContent {
                    if settings.screenshotsFolder != nil { Button("Use Default", action: coordinator.resetFolder) }
                    Button("Choose…", action: coordinator.chooseFolder)
                    Button("Open Folder", action: coordinator.openFolder)
                } label: {
                    SettingsRowTitle(.screenshotsFolder, "Save Location")
                    Text((coordinator.folder.path as NSString).abbreviatingWithTildeInPath)
                }
            } header: {
                SettingsSectionHeader(.screenshotsFolder)
            }

            FeatureCommandsSection(owner: .screenshots, anchor: .screenshotsCommands)
                .settingsEnabled(settings.screenshotsEnabled)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.screenshots)
    }
}
