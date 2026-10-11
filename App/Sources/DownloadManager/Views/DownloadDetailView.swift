import SwiftUI
import AppKit

/// Dosya özelinde indirme penceresi (IDM tarzı): durum bilgileri, parça çubuğu ve bağlantı tablosu.
/// İndirme bitince "tamamlandı" görünümüne dönüşür.
struct DownloadDetailView: View {
    let id: UUID
    @EnvironmentObject var store: DownloadStore
    @EnvironmentObject var settings: AppSettings
    @State private var showDetails = true

    private var item: DownloadItem? { store.items.first { $0.id == id } }

    var body: some View {
        if let item {
            Group {
                if item.state == .completed {
                    completedView(item)
                } else {
                    activeView(item)
                }
            }
            .padding(16)
            .frame(minWidth: 520, idealWidth: 560)
        } else {
            Text("This download was removed from the list.").padding()
        }
    }

    // MARK: - İndirme sürerken

    private func activeView(_ item: DownloadItem) -> some View {
        VStack(spacing: 14) {
            infoGrid(item)
            hashSection(item)
            ProgressView(value: item.totalBytes > 0 ? item.progress : 0)
                .progressViewStyle(.linear)
            HStack(spacing: 12) {
                Button(showDetails ? "<< Hide Details" : "Show Details >>") {
                    withAnimation { showDetails.toggle() }
                    DetailWindowManager.shared.resize(id: id, compact: !showDetails)
                }
                Toggle("Close when completed", isOn: $settings.autoCloseDetail)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                Spacer()
                switch item.state {
                case .downloading, .probing, .queued:
                    Button("Pause") { store.pause(item.id) }
                    Button("Cancel") { store.cancel(item.id) }
                case .paused, .failed, .cancelled:
                    Button("Resume") { store.resume(item.id) }.keyboardShortcut(.defaultAction)
                    Button("Remove from List") { store.remove(item.id); DetailWindowManager.shared.close(id: item.id) }
                case .completed:
                    EmptyView()
                }
            }
            if showDetails {
                Divider()
                if item.kind == .video {
                    logView(item)
                } else {
                    connections(item)
                }
            }
        }
    }

    private func infoGrid(_ item: DownloadItem) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("URL").foregroundStyle(.secondary)
                Text(item.url.absoluteString).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            GridRow {
                Text("Status").foregroundStyle(.secondary)
                Text(statusText(item)).foregroundStyle(item.state == .failed ? .red : .primary)
            }
            GridRow {
                Text("File size").foregroundStyle(.secondary)
                Text(item.totalBytes > 0 ? Fmt.size(item.totalBytes) : String(localized: "Unknown"))
            }
            GridRow {
                Text("Downloaded").foregroundStyle(.secondary)
                Text(item.totalBytes > 0
                     ? "\(Fmt.size(item.receivedBytes))  (\(Int(item.progress * 100))%)"
                     : Fmt.size(item.receivedBytes))
            }
            GridRow {
                Text("Transfer rate").foregroundStyle(.secondary)
                Text(item.state == .downloading ? Fmt.speed(item.speed) : "—")
            }
            GridRow {
                Text("Time left").foregroundStyle(.secondary)
                Text(item.eta.map(Fmt.duration) ?? "—")
            }
            GridRow {
                Text("Resume capability").foregroundStyle(.secondary)
                Text(item.kind == .video ? "yt-dlp" : (item.supportsRanges ? String(localized: "Yes") : (item.state == .queued || item.state == .probing ? "?" : String(localized: "No"))))
            }
            GridRow {
                Text("Save to").foregroundStyle(.secondary)
                Text(item.finalPath ?? store.destinationURL(for: item).path).lineLimit(1).truncationMode(.middle)
            }
            if let exp = item.expectedHash, !exp.isEmpty {
                GridRow {
                    Text("Expected hash").foregroundStyle(.secondary)
                    Text("\(item.hashAlgorithm?.uppercased() ?? "HASH"): \(exp)").lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .font(.system(.callout, design: .monospaced))
                }
            }
        }
        .font(.callout.monospacedDigit())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Hash

    @ViewBuilder
    private func hashSection(_ item: DownloadItem) -> some View {
        if item.expectedHash != nil || item.computedHash != nil || item.hashChecking {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                HStack(spacing: 8) {
                    Text("Integrity").font(.headline)
                    Spacer()
                    hashStatusBadge(item)
                }
                if let exp = item.expectedHash, !exp.isEmpty {
                    hashRow(label: "Expected", value: exp)
                }
                if let actual = item.computedHash, !actual.isEmpty {
                    hashRow(label: "Actual", value: actual)
                } else if item.hashChecking {
                    Text("Computing hash…").font(.caption).foregroundStyle(.secondary)
                }
                if item.finalPath != nil {
                    HStack(spacing: 8) {
                        ForEach(HashAlgorithm.allCases, id: \.self) { algo in
                            Button(algo.displayName) { store.computeHash(item.id, algorithm: algo) }
                                .disabled(item.hashChecking)
                        }
                        if item.computedHash != nil {
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.computedHash ?? "", forType: .string)
                            }
                        }
                        Spacer()
                    }
                    .font(.callout)
                    .buttonStyle(.link)
                }
            }
        }
    }

    @ViewBuilder
    private func hashStatusBadge(_ item: DownloadItem) -> some View {
        if item.hashChecking {
            Label("Checking…", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
        } else if let ok = item.hashVerified {
            if ok {
                Label("Verified", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
            } else {
                Label("Mismatch", systemImage: "xmark.seal.fill").font(.caption).foregroundStyle(.red)
            }
        } else if item.expectedHash != nil {
            Label("Pending", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func hashRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).foregroundStyle(.secondary).font(.caption).frame(width: 64, alignment: .leading)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .lineLimit(2).truncationMode(.middle)
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
            .font(.caption).buttonStyle(.link)
        }
    }

    private func statusText(_ item: DownloadItem) -> String {
        switch item.state {
        case .downloading:
            if item.kind == .video { return item.stage.isEmpty ? String(localized: "Downloading with yt-dlp…") : item.stage }
            return String(localized: "Receiving data…")
        case .failed: return item.errorMessage ?? String(localized: "Error")
        default: return item.state.label
        }
    }

    // MARK: - Tamamlandı görünümü

    private func completedView(_ item: DownloadItem) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: item.hashVerified == false ? "xmark.seal.fill" : "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(item.hashVerified == false ? .red : .green)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.hashVerified == false ? "Download completed — hash mismatch" : "Download completed").font(.title2.bold())
                    Text(item.fileName).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Size").foregroundStyle(.secondary)
                    Text(Fmt.size(item.totalBytes))
                }
                GridRow {
                    Text("Location").foregroundStyle(.secondary)
                    Text(item.finalPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? store.destinationDirectory(for: item).path)
                        .lineLimit(1).truncationMode(.middle)
                }
                GridRow {
                    Text("URL").foregroundStyle(.secondary)
                    Text(item.url.absoluteString).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                if let d = item.completedAt {
                    GridRow {
                        Text("Finished").foregroundStyle(.secondary)
                        Text(d.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            hashSection(item)
            HStack {
                Button("Close") { DetailWindowManager.shared.close(id: item.id) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Show in Finder") { store.revealInFinder(item) }
                Button("Open") { store.open(item); DetailWindowManager.shared.close(id: item.id) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Bağlantı tablosu

    private func connections(_ item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Start positions and download progress by connections")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            SegmentBar(segments: item.segments, total: item.totalBytes, fallback: item.progress,
                       tint: item.state == .paused ? .secondary : .accentColor)
                .frame(height: 12)
            Table(connectionRows(item)) {
                TableColumn("N.") { Text("\($0.index)") }.width(36)
                TableColumn("Downloaded") { Text(Fmt.size($0.received)) }.width(110)
                TableColumn("Start") { Text(Fmt.size($0.start)) }.width(110)
                TableColumn("Info") { Text($0.info) }
            }
            .font(.callout.monospacedDigit())
            .frame(minHeight: 160)
        }
    }

    private struct ConnRow: Identifiable {
        let id: Int
        var index: Int { id + 1 }
        let received: Int64
        let start: Int64
        let info: String
    }

    private func connectionRows(_ item: DownloadItem) -> [ConnRow] {
        if item.segments.isEmpty {
            guard item.state != .queued else { return [] }
            let info: String
            switch item.state {
            case .probing: info = String(localized: "Sending GET…")
            case .downloading: info = String(localized: "Receiving data… (single stream)")
            case .paused: info = String(localized: "Paused")
            default: info = item.state.label
            }
            return [ConnRow(id: 0, received: item.receivedBytes, start: 0, info: info)]
        }
        return item.segments.enumerated().map { i, s in
            let info: String
            if s.isDone { info = String(localized: "Completed") }
            else if item.state == .downloading { info = s.received == 0 ? String(localized: "Sending GET…") : String(localized: "Receiving data…") }
            else if item.state == .paused { info = String(localized: "Paused") }
            else { info = item.state.label }
            return ConnRow(id: i, received: s.received, start: s.start, info: info)
        }
    }

    private func logView(_ item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("yt-dlp output").font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(item.log.isEmpty ? String(localized: "Waiting…") : item.log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("end")
                }
                .onChange(of: item.log) { _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            .frame(minHeight: 160)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
    }
}

/// Dosya özelindeki pencereleri AppKit ile yönetir; böylece SwiftUI ortamı olmadan
/// (örneğin tarayıcıdan gelen istekte) her yerden açılabilir.
final class DetailWindowManager {
    static let shared = DetailWindowManager()
    private var windows: [UUID: NSWindow] = [:]
    private var observers: [UUID: Any] = [:]

    static let fullHeight: CGFloat = 540
    static let compactHeight: CGFloat = 290
    static let completedHeight: CGFloat = 250

    func show(id: UUID, store: DownloadStore) {
        AppPresence.shared.showInDock()
        if let w = windows[id] {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = DownloadDetailView(id: id)
            .environmentObject(store)
            .environmentObject(store.settings)
        let completed = store.items.first { $0.id == id }?.state == .completed
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: completed ? Self.completedHeight : Self.fullHeight),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: root)
        w.isReleasedWhenClosed = false
        w.title = store.items.first { $0.id == id }?.fileName ?? String(localized: "Download")
        w.center()
        if let last = windows.values.first?.frame {
            w.setFrameTopLeftPoint(NSPoint(x: last.minX + 24, y: last.maxY - 24))
        }
        windows[id] = w
        observers[id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.windows[id] = nil
            if let o = self?.observers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(o) }
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // The policy switch and the system's activation can race; order front once more on the next turn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func close(id: UUID) {
        windows[id]?.close()
    }

    func resize(id: UUID, compact: Bool) {
        setHeight(id: id, compact ? Self.compactHeight : Self.fullHeight)
    }

    /// İndirme bitince: otomatik kapat ya da "tamamlandı" boyutuna küçült.
    func didComplete(id: UUID, autoClose: Bool) {
        guard windows[id] != nil else { return }
        if autoClose {
            close(id: id)
        } else {
            setHeight(id: id, Self.completedHeight)
        }
    }

    private func setHeight(id: UUID, _ height: CGFloat) {
        guard let w = windows[id] else { return }
        var frame = w.frame
        let delta = height - w.contentRect(forFrameRect: frame).height
        frame.size.height += delta
        frame.origin.y -= delta
        w.setFrame(frame, display: true, animate: true)
    }

    /// Başlıkları ilerlemeye göre günceller ("%24 · dosya.zip").
    func refreshTitles(items: [DownloadItem]) {
        for (id, w) in windows {
            guard let item = items.first(where: { $0.id == id }) else { continue }
            let pct = item.totalBytes > 0 && item.state != .completed ? "\(Int(item.progress * 100))% · " : ""
            let title = pct + item.fileName
            if w.title != title { w.title = title }
        }
    }
}
