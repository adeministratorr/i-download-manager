import SwiftUI
import AppKit

struct AddDownloadView: View {
    @EnvironmentObject var store: DownloadStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var asVideo = false
    @State private var segments = 0
    @State private var expectedHash = ""
    @State private var hashAlgorithm: HashAlgorithm = .sha256
    @State private var hashError: String? = nil
    @State private var asPlaylist = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Download").font(.title2.bold())
            Text("One URL per line.").foregroundStyle(.secondary).font(.callout)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Toggle("Download video from page (yt-dlp)", isOn: $asVideo)
            if asVideo {
                Toggle("Playlist: list all videos and download each (same quality)", isOn: $asPlaylist)
                    .font(.callout)
                if asPlaylist {
                    Text("Each video downloads separately with your Video settings (MP4/M4A, no re-encode). Files go into a playlist subfolder.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !asVideo {
                Stepper(value: $segments, in: 0...16) {
                    if segments == 0 {
                        Text("Connections: default (\(settings.segmentCount))")
                    } else {
                        Text("Connections: \(segments)")
                    }
                }
            }
            DisclosureGroup("Expected hash (optional, e.g. ISO SHA-256)") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Algorithm", selection: $hashAlgorithm) {
                        ForEach(HashAlgorithm.allCases, id: \.self) { algo in
                            Text(algo.displayName).tag(algo)
                        }
                    }
                    .pickerStyle(.segmented)
                    TextField("Paste the publisher's hash…", text: $expectedHash)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: expectedHash) { _ in hashError = nil }
                    if let hashError {
                        Text(hashError).font(.caption).foregroundStyle(.red)
                    } else {
                        Text("Leave empty to skip verification. Download is checked automatically when finished.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
            .font(.callout)
            HStack {
                Button("Paste from Clipboard") {
                    if let s = NSPasteboard.general.string(forType: .string) { text = s }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Download") {
                    if asVideo, asPlaylist {
                        store.addURLs(text, kind: .video, asPlaylist: true)
                        dismiss()
                        return
                    }
                    let trimmed = expectedHash.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        store.addURLs(text, kind: asVideo ? .video : .file, segments: segments == 0 ? nil : segments)
                        dismiss()
                    } else {
                        let norm = HashAlgorithm.normalize(trimmed)
                        guard HashAlgorithm.isHex(norm) else {
                            hashError = String(localized: "Hash must be hexadecimal (0-9, a-f).")
                            return
                        }
                        if norm.count != hashAlgorithm.hexLength,
                           let detected = HashAlgorithm.detect(norm) {
                            hashAlgorithm = detected
                        }
                        guard norm.count == hashAlgorithm.hexLength else {
                            hashError = String(localized: "\(hashAlgorithm.displayName) must be \(hashAlgorithm.hexLength) hex characters (got \(norm.count)).")
                            return
                        }
                        store.addURLs(text, kind: asVideo ? .video : .file,
                                      segments: segments == 0 ? nil : segments,
                                      expectedHash: norm, hashAlgorithm: hashAlgorithm)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               s.hasPrefix("http"), !s.contains("\n") {
                text = s
            }
        }
    }
}
