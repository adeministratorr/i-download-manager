import SwiftUI
import AppKit

/// Category checkboxes + custom extensions. Used by the first-launch sheet and the Settings tab.
struct CaptureTypesEditor: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(CaptureTypes.groups) { g in
                Toggle(isOn: Binding(
                    get: { settings.captureGroupIDs.contains(g.id) },
                    set: { on in if on { settings.captureGroupIDs.insert(g.id) } else { settings.captureGroupIDs.remove(g.id) } }
                )) {
                    HStack(spacing: 8) {
                        Image(systemName: g.category.symbol).frame(width: 18).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g.category.label)
                            Text(g.extensions.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
            LabeledContent("Other extensions") {
                TextField("e.g. torrent, srt, ttf", text: $settings.customExtensions)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

/// First-launch flow: 1) file types  2) browser extensions (opens the guided wizard).
struct OnboardingView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var server: ServerController
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    private let browsers = BrowserIntegration.installedBrowsers

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to iDownload Manager").font(.title2.bold())
                    if step == 0 {
                        Text("Which file types should be captured?").foregroundStyle(.secondary)
                    } else {
                        Text("Install the browser extensions?").foregroundStyle(.secondary)
                    }
                }
            }
            if step == 0 {
                Text("Browser downloads and copied links with these extensions are handed to the app. Everything else stays in the browser. You can change this later in Settings ▸ File Types.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                CaptureTypesEditor()
                Divider()
                Toggle("Watch the clipboard for links and ask to download them", isOn: $settings.watchClipboard)
            } else {
                Text("The extensions let your browsers hand their downloads to iDownload Manager and capture videos on pages. A guided setup walks you through each browser, one at a time. You can run it later from Settings ▸ Browser Extensions.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(browsers) { b in
                        HStack(spacing: 8) {
                            if let icon = b.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                            Text(b.name)
                        }
                    }
                }
                .font(.callout)
            }
            HStack {
                if step == 1 { Button("Back") { step = 0 } }
                Spacer()
                if step == 0 {
                    Button("Continue") { step = 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now") { finish() }.keyboardShortcut(.cancelAction)
                    Button("Start Setup") {
                        finish()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ExtensionWizardWindow.shared.show(server: server) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func finish() {
        settings.onboardingDone = true
        LoginItem.registerByDefaultIfNeeded()
        AppDelegate.sharedStore?.prepareDownloadFolder()
        dismiss()
    }
}
