import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers
import UserNotifications

struct NewDownloadRequest {
    var url: URL
    var fileName: String?
    var referer: String?
    var userAgent: String?
    var cookieHeader: String?
    var cookies: [[String: Any]]?
    var kind: DownloadKind = .file
    var extraHeaders: [String: String] = [:]
    var segments: Int? = nil
    var expectedHash: String? = nil
    var hashAlgorithm: HashAlgorithm? = nil
    var playlistId: String? = nil
    var playlistTitle: String? = nil
    var playlistIndex: Int? = nil
    var playlistCount: Int? = nil
    var sourceBrowser: String? = nil

    init(url: URL) { self.url = url }
}

/// Tüm indirmelerin durumu, kuyruk ve kalıcılık. Yalnızca ana iş parçacığında kullanılır.
final class DownloadStore: ObservableObject {
    @Published private(set) var items: [DownloadItem] = []

    let settings: AppSettings
    private var downloaders: [UUID: SegmentedDownloader] = [:]
    private var videoProcesses: [UUID: Process] = [:]
    private var torrentProcesses: [UUID: Process] = [:]
    /// .torrent dosyasını önce HTTP ile çeken öğeler (iki aşamalı torrent başlangıcı).
    private var torrentFetching: Set<UUID> = []
    /// yt-dlp downloads several files (video, audio): bytes completed in earlier phases + approx total.
    private var videoPhase: [UUID: (base: Int64, lastDownloaded: Int64, approxTotal: Int64)] = [:]
    /// YouTube downloads waiting for the deno install prompt / install to finish.
    private var denoWaiters: [UUID] = []
    private var denoPrompting = false
    private var denoDeclinedThisLaunch = false
    /// Video downloads that are retried without cookies after YouTube rejected the signed-in client.
    private var cookielessVideos: Set<UUID> = []
    /// Geçici "listeleniyor" öğeleri: asla indirme başlatmaz, kuyruğa girmez, diske yazılmaz.
    private var probeIDs: Set<UUID> = []
    /// Failed downloads waiting for the "download in the browser instead?" prompt.
    private var handOffQueue: [UUID] = []
    private var handOffPrompting = false
    /// Hosts the extensions must leave to the browser for a short while (a download handed back to the browser).
    private var browserBypass: [String: Date] = [:]
    private var samples: [UUID: (bytes: Int64, time: Date)] = [:]
    private var timer: Timer?
    private var saveWork: DispatchWorkItem?
    private var tickCount = 0
    private let supportDir: URL
    private let storeURL: URL

    init(settings: AppSettings) {
        self.settings = settings
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        supportDir = base.appendingPathComponent("iDownload Manager", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        storeURL = supportDir.appendingPathComponent("downloads.json")
        Self.migrateLegacySupportDir(newStoreURL: storeURL)
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// MC Download Manager'dan geçiş: kuyruk + cookie'ler + araçlar kopyalanır.
    /// Köprü anahtarı UserDefaults'tadır (bundle'a özel), o yenilenir — eklentileri
    /// bir kez yeniden eşleştirmek gerekir. Eski klasör silinmez.
    private static func migrateLegacySupportDir(newStoreURL: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: newStoreURL.path),
              let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let legacy = base.appendingPathComponent("MC Download Manager", isDirectory: true)
        guard fm.fileExists(atPath: legacy.appendingPathComponent("downloads.json").path) else { return }
        let dest = newStoreURL.deletingLastPathComponent()
        for name in ["downloads.json", "cookies", "bin"] {
            let src = legacy.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { continue }
            let target = dest.appendingPathComponent(name)
            if !fm.fileExists(atPath: target.path) {
                try? fm.copyItem(at: src, to: target)
            }
        }
    }

    // MARK: - Sorgular

    /// Final folder for an item: base folder, plus a category subfolder when enabled.
    func destinationDirectory(for item: DownloadItem) -> URL {
        guard settings.organizeByCategory else { return item.directory }
        return item.directory.appendingPathComponent(item.category.label, isDirectory: true)
    }

    func destinationURL(for item: DownloadItem) -> URL {
        destinationDirectory(for: item).appendingPathComponent(item.fileName)
    }

    var activeCount: Int { items.filter { $0.state.isActive && !probeIDs.contains($0.id) }.count }
    /// Byte-weighted progress of active downloads with a known size (nil when nothing measurable is running).
    var overallProgress: Double? {
        let measurable = items.filter { $0.state.isActive && $0.totalBytes > 0 }
        guard !measurable.isEmpty else { return nil }
        let total = measurable.reduce(Int64(0)) { $0 + $1.totalBytes }
        let received = measurable.reduce(Int64(0)) { $0 + min($1.receivedBytes, $1.totalBytes) }
        return total > 0 ? Double(received) / Double(total) : nil
    }

    /// Touches the download folder so macOS asks for Downloads-folder access now (first run / setup),
    /// not in the middle of the first download — where the system prompt pushed the download window behind the browser.
    func prepareDownloadFolder() {
        let dir = URL(fileURLWithPath: settings.downloadDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
    }
    var totalSpeed: Double { items.filter { $0.state == .downloading }.reduce(0) { $0 + $1.speed } }

    private func index(of id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    private func update(_ id: UUID, _ mutate: (inout DownloadItem) -> Void) {
        guard let i = index(of: id) else { return }
        var item = items[i]
        mutate(&item)
        items[i] = item
    }

    // MARK: - Ekleme

    @discardableResult
    func add(_ req: NewDownloadRequest, isProbe: Bool = false, showDetail: Bool? = nil) -> DownloadItem {
        // İkinci katman: köprü zaten filtreliyor; doğrudan çağrılarda da
        // kimlik/taşıyıcı başlıklar enjekte edilemesin.
        var headers = NetGuard.sanitizedExtraHeaders(req.extraHeaders)
        if let r = req.referer, !r.isEmpty { headers["Referer"] = r }
        if let ua = req.userAgent, !ua.isEmpty { headers["User-Agent"] = ua }
        if let c = req.cookieHeader, !c.isEmpty { headers["Cookie"] = c }
        if headers["User-Agent"] == nil { headers["User-Agent"] = Self.defaultUserAgent }

        var name = req.fileName.flatMap { $0.isEmpty ? nil : $0 } ?? Self.fileName(from: req.url)
        if req.kind == .video { name = req.url.host ?? "video" }
        if req.kind == .torrent, TorrentDownloader.isMagnet(req.url) {
            name = TorrentDownloader.displayName(from: req.url) ?? "magnet link"
        }
        name = Self.sanitize(name)

        var item = DownloadItem(url: req.url, fileName: name,
                                directory: URL(fileURLWithPath: settings.downloadDirectory),
                                kind: req.kind)
        item.headers = headers
        item.requestedSegments = req.segments ?? 0
        item.playlistId = req.playlistId
        item.playlistTitle = req.playlistTitle
        item.playlistIndex = req.playlistIndex
        item.playlistCount = req.playlistCount
        if let raw = req.expectedHash {
            let norm = HashAlgorithm.normalize(raw)
            if !norm.isEmpty, HashAlgorithm.isHex(norm) {
                let algo = req.hashAlgorithm ?? HashAlgorithm.detect(norm) ?? .sha256
                item.expectedHash = norm
                item.hashAlgorithm = algo.rawValue
            }
        }
        item.sourceBrowser = req.sourceBrowser
        if req.kind == .video, let cookies = req.cookies, !cookies.isEmpty {
            item.cookieFile = writeCookieFile(cookies, id: item.id)
        }
        try? FileManager.default.createDirectory(at: item.directory, withIntermediateDirectories: true)
        items.insert(item, at: 0)
        if isProbe { probeIDs.insert(item.id) }
        scheduleSave()
        if settings.autoStart { pumpQueue() }
        if !isProbe, showDetail ?? settings.showDetailOnStart { DetailWindowManager.shared.show(id: item.id, store: self) }
        return item
    }

    func addURLs(_ text: String, kind: DownloadKind, segments: Int? = nil, expectedHash: String? = nil, hashAlgorithm: HashAlgorithm? = nil, asPlaylist: Bool = false) {
        var urls: [URL] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { continue }
            let isMagnet = scheme == "magnet"
            // Magnet yalnızca torrent türüyle kabul edilir; torrent http(s) .torrent
            // bağlantılarını da kabul eder.
            guard ["http", "https"].contains(scheme) || (isMagnet && kind == .torrent) else { continue }
            urls.append(url)
        }
        // Çoklu yapıştırmada öğe başına detay penceresi açma (pencere fırtınası).
        let showDetail: Bool? = urls.count > 1 ? false : nil
        for url in urls {
            if asPlaylist, kind == .video {
                addPlaylist(url: url, referer: nil, userAgent: nil, cookies: nil)
            } else {
                var r = NewDownloadRequest(url: url)
                r.kind = kind
                r.segments = segments
                r.expectedHash = expectedHash
                r.hashAlgorithm = hashAlgorithm
                add(r, showDetail: showDetail)
            }
        }
    }

    /// Playlist URL'sini yt-dlp ile listeleyip her videoyu ayrı kuyruk öğesi yapar.
    /// Kalite kaybı yok: her çocuk `settings.ytdlpFormatArguments` ile tek tek iner.
    /// Liste değilse (tek video) normal tekli indirmeye düşer.
    func addPlaylist(url: URL, referer: String?, userAgent: String?, cookies: [[String: Any]]?,
                     headers extra: [String: String] = [:]) {
        guard let exe = VideoDownloader.locateYtDlp(custom: settings.ytdlpPath) else {
            var r = NewDownloadRequest(url: url)
            r.kind = .video
            r.referer = referer
            r.userAgent = userAgent
            r.cookies = cookies
            r.extraHeaders = extra
            let item = add(r)
            update(item.id) {
                $0.state = .failed
                $0.errorMessage = String(localized: "yt-dlp not found. Use “Install yt-dlp” in Settings ▸ Video.")
            }
            pumpQueue()
            return
        }
        var headers = extra
        if let r = referer, !r.isEmpty { headers["Referer"] = r }
        headers["User-Agent"] = (userAgent?.isEmpty == false ? userAgent! : Self.defaultUserAgent)
        // Geçici "listeleniyor" öğesi: kullanıcıya ilerleme gösterir, bitince kaldırılır.
        var probeReq = NewDownloadRequest(url: url)
        probeReq.kind = .video
        probeReq.referer = referer
        probeReq.userAgent = userAgent
        probeReq.cookies = cookies
        probeReq.extraHeaders = extra
        let probe = add(probeReq, isProbe: true)
        update(probe.id) {
            $0.state = .downloading
            $0.stage = String(localized: "Reading playlist…")
            $0.fileName = url.host ?? "playlist"
        }
        // Cookie dosyasını listelemede kullan + çocuklara aynen aktar.
        let cookiePath: String? = {
            guard let cookies, !cookies.isEmpty else { return nil }
            return writeCookieFile(cookies, id: probe.id)
        }()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fetched: Result<VideoDownloader.PlaylistInfo, Error> = {
                do { return .success(try VideoDownloader.fetchPlaylistEntries(executable: exe, url: url, headers: headers, cookieFile: cookiePath)) }
                catch { return .failure(error) }
            }()
            DispatchQueue.main.async {
                guard let self else { return }
                // Prob öğesini kaldır (cookie dosyasıyla birlikte).
                self.remove(probe.id)
                switch fetched {
                case .failure(let e):
                    // Liste okunamazsa tek video olarak dene (kullanıcı yine izler).
                    var r = NewDownloadRequest(url: url)
                    r.kind = .video
                    r.referer = referer
                    r.userAgent = userAgent
                    r.cookies = cookies
                    r.extraHeaders = extra
                    let item = self.add(r)
                    self.update(item.id) {
                        $0.errorMessage = nil
                        $0.log = String(localized: "Playlist could not be listed (\(e.localizedDescription)); trying as a single video…") + "\n"
                    }
                case .success(let info):
                    guard !info.entries.isEmpty else {
                        var r = NewDownloadRequest(url: url)
                        r.kind = .video
                        r.referer = referer
                        r.userAgent = userAgent
                        r.cookies = cookies
                        r.extraHeaders = extra
                        self.add(r)
                        return
                    }
                    let pid = info.id ?? url.absoluteString
                    let ptitle = info.title ?? url.host ?? "playlist"
                    let count = info.entries.count
                    // Sıralı ekle: en son eklenen en üstte görünür; ters sırada ekle.
                    for e in info.entries.reversed() {
                        var r = NewDownloadRequest(url: e.url)
                        r.kind = .video
                        r.referer = referer ?? url.absoluteString
                        r.userAgent = userAgent
                        r.cookies = cookies
                        r.extraHeaders = extra
                        r.playlistId = pid
                        r.playlistTitle = ptitle
                        r.playlistIndex = e.index
                        r.playlistCount = count
                        if let t = e.title, !t.isEmpty {
                            r.fileName = String(format: "%02d - %@", e.index, t)
                        }
                        self.add(r, showDetail: false)
                    }
                }
            }
        }
    }

    // MARK: - Kuyruk

    func pumpQueue() {
        var slots = max(0, settings.maxConcurrent - activeCount)
        for item in items.reversed() where item.state == .queued && !probeIDs.contains(item.id) && slots > 0 {
            startItem(item.id)
            slots -= 1
        }
    }

    private func startItem(_ id: UUID) {
        guard !probeIDs.contains(id) else { return }
        guard let i = index(of: id) else { return }
        let item = items[i]
        if item.kind == .video { startVideo(item) }
        else if item.kind == .torrent { startTorrent(item) }
        else { startFile(item) }
    }

    private func startFile(_ item: DownloadItem) {
        let resumable = item.supportsRanges && item.totalBytes > 0 && !item.segments.isEmpty
            && FileManager.default.fileExists(atPath: item.partURL.path)
        var cfg = SegmentedDownloader.Configuration(
            url: item.url, headers: item.headers, partURL: item.partURL,
            segmentCount: item.requestedSegments > 0 ? item.requestedSegments : settings.segmentCount)
        if resumable {
            cfg.resumeSegments = item.segments
            cfg.resumeTotal = item.totalBytes
            cfg.resumeETag = item.etag
            cfg.resumeLastModified = item.lastModified
        }
        let dl = SegmentedDownloader(configuration: cfg)
        let id = item.id
        dl.onProbe = { [weak self, weak dl] probe in
            DispatchQueue.main.async {
                guard let self, self.downloaders[id] === dl else { return }
                self.handleProbe(id: id, probe)
            }
        }
        dl.onProgress = { [weak self, weak dl] received, segs in
            DispatchQueue.main.async {
                guard let self, self.downloaders[id] === dl else { return }
                self.update(id) {
                    $0.receivedBytes = received
                    $0.segments = segs
                    if $0.state == .probing { $0.state = .downloading }
                }
            }
        }
        dl.onFinish = { [weak self, weak dl] result in
            DispatchQueue.main.async {
                guard let self, self.downloaders[id] === dl else { return }
                self.handleFinish(id: id, result)
            }
        }
        downloaders[id] = dl
        update(id) {
            $0.state = resumable ? .downloading : .probing
            $0.errorMessage = nil
            $0.speed = 0
            if !resumable { $0.receivedBytes = 0; $0.segments = [] }
        }
        dl.start()
    }

    private func handleProbe(id: UUID, _ p: ProbeResult) {
        update(id) { item in
            item.totalBytes = p.totalBytes
            item.supportsRanges = p.supportsRanges
            item.state = .downloading
            item.etag = p.etag
            item.lastModified = p.lastModified
            if let n = p.suggestedFileName, !n.isEmpty {
                item.fileName = Self.sanitize(n)
            } else if let final = p.finalURL, item.fileName == Self.sanitize(Self.fileName(from: item.url)), final != item.url {
                let candidate = Self.fileName(from: final)
                if !(candidate as NSString).pathExtension.isEmpty { item.fileName = Self.sanitize(candidate) }
            }
            if (item.fileName as NSString).pathExtension.isEmpty,
               let ct = p.contentType, let ext = UTType(mimeType: ct)?.preferredFilenameExtension, ext != "bin" {
                item.fileName += "." + ext
            }
        }
    }

    private func handleFinish(id: UUID, _ result: Result<Void, Error>) {
        downloaders[id] = nil
        switch result {
        case .success:
            guard let i = index(of: id) else { return }
            var item = items[i]
            let destDir = destinationDirectory(for: item)
            let dest = Self.uniqueDestination(for: destDir.appendingPathComponent(item.fileName))
            do {
                try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: item.partURL, to: dest)
                Self.applyQuarantine(to: dest, source: item.url)
                item.fileName = dest.lastPathComponent
                item.finalPath = dest.path
                item.state = .completed
                item.completedAt = Date()
                item.speed = 0
                if item.totalBytes <= 0 { item.totalBytes = item.receivedBytes }
                items[i] = item
                notifyCompleted(item)
                DetailWindowManager.shared.didComplete(id: id, autoClose: settings.autoCloseDetail)
                // Beklenen hash varsa arka planda doğrula (ISO kontrolü).
                if item.expectedHash != nil { verifyHash(id) }
            } catch {
                item.state = .failed
                item.errorMessage = error.localizedDescription
                items[i] = item
            }
        case .failure(let e):
            if let h = e as? HTTPStatusError { update(id) { $0.lastHTTPStatus = h.status } }
            guard let item = items.first(where: { $0.id == id }), item.state != .paused, item.state != .cancelled else { break }
            update(id) {
                $0.state = .failed
                $0.errorMessage = e.localizedDescription
                $0.speed = 0
            }
            if Self.browserMightHelp(e) { offerBrowserHandOff(id) }
        }
        scheduleSave()
        pumpQueue()
    }

    // MARK: - Hand-off to the browser

    /// Server refusals and odd responses: a browser (its own cookies, one connection, the site's own flow) may succeed.
    /// Local problems (disk, no network) would fail there too.
    private static func browserMightHelp(_ error: Error) -> Bool {
        if error is HTTPStatusError { return true }
        let e = error as NSError
        if let f = error as? DownloadFailure { return !f.local }
        guard e.domain == NSURLErrorDomain else { return false }
        return ![NSURLErrorNotConnectedToInternet, NSURLErrorCancelled, NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotCreateFile, NSURLErrorCannotWriteToFile].contains(e.code)
    }

    /// Hosts the browser extensions must not capture right now (see `/ping`).
    var bypassHosts: [String] {
        let now = Date()
        browserBypass = browserBypass.filter { $0.value > now }
        return Array(browserBypass.keys)
    }

    /// The site a download belongs to: the page it was started from, else its own host.
    static func siteHost(of item: DownloadItem) -> String? {
        AppSettings.siteKey(item.referer?.host ?? item.url.host)
    }

    private func offerBrowserHandOff(_ id: UUID) {
        if !handOffQueue.contains(id) { handOffQueue.append(id) }
        guard !handOffPrompting else { return }
        handOffPrompting = true
        DispatchQueue.main.async { [weak self] in self?.promptNextHandOff() }
    }

    private func promptNextHandOff() {
        guard !handOffQueue.isEmpty else { handOffPrompting = false; return }
        let id = handOffQueue.removeFirst()
        guard let item = items.first(where: { $0.id == id }), item.state == .failed else { promptNextHandOff(); return }
        let site = Self.siteHost(of: item) ?? item.url.absoluteString
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.messageText = String(localized: "Download in the browser instead?")
        alert.informativeText = String(localized: "“\(item.fileName)” could not be downloaded: \(item.errorMessage ?? "")\n\nSome sites (for example WeTransfer) only allow their downloads in a browser. iDownload Manager can hand this download back to the browser.")
        alert.addButton(withTitle: String(localized: "Download in Browser"))
        alert.addButton(withTitle: String(localized: "Retry Here"))
        alert.addButton(withTitle: String(localized: "Close")).keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Always leave downloads from \(site) to the browser")
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let always = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn:
            if always { settings.setBrowserOnly(Self.siteHost(of: item), true) }
            handOffToBrowser(id)
        case .alertSecondButtonReturn:
            if always { settings.setBrowserOnly(Self.siteHost(of: item), true) }
            resume(id)
        default:
            if always { settings.setBrowserOnly(Self.siteHost(of: item), true) }
        }
        promptNextHandOff()
    }

    private static let browserBundleIDs = [
        "chrome": "com.google.Chrome", "brave": "com.brave.Browser", "opera": "com.operasoftware.Opera", "edge": "com.microsoft.edgemac",
        "firefox": "org.mozilla.firefox", "safari": "com.apple.Safari",
    ]

    /// Opens the download in the browser it came from and lets the extension pass it through for a few minutes.
    func handOffToBrowser(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let until = Date().addingTimeInterval(180)
        for host in [item.url.host, item.referer?.host] { if let k = AppSettings.siteKey(host) { browserBypass[k] = until } }
        // A refused signed link is usually spent (one-shot token): reopen the page so the site issues a fresh one.
        var target = item.url
        if let status = item.lastHTTPStatus, [401, 403, 404, 410].contains(status),
           let page = item.referer, ["http", "https"].contains(page.scheme?.lowercased() ?? "") {
            target = page
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let bid = item.sourceBrowser.flatMap({ Self.browserBundleIDs[$0] }),
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            NSWorkspace.shared.open([target], withApplicationAt: app, configuration: config)
        } else {
            NSWorkspace.shared.open(target)
        }
        remove(id)
    }

    // MARK: - Video (yt-dlp)

    private func startVideo(_ item: DownloadItem) {
        let id = item.id
        guard let exe = VideoDownloader.locateYtDlp(custom: settings.ytdlpPath) else {
            update(id) {
                $0.state = .failed
                $0.errorMessage = String(localized: "yt-dlp not found. Use “Install yt-dlp” in Settings ▸ Video.")
            }
            pumpQueue()
            return
        }
        if VideoDownloader.isYouTube(item.url), VideoDownloader.locateDeno() == nil,
           !settings.denoPromptSuppressed, !denoDeclinedThisLaunch {
            update(id) { $0.state = .downloading; $0.errorMessage = nil; $0.speed = 0; $0.stage = String(localized: "Waiting for the JavaScript runtime (deno)…") }
            if !denoWaiters.contains(id) { denoWaiters.append(id) }
            if !denoPrompting {
                denoPrompting = true
                DispatchQueue.main.async { [weak self] in self?.promptForDeno() }
            }
            return
        }
        let useCookies = !cookielessVideos.contains(id)
        update(id) {
            $0.state = .downloading; $0.errorMessage = nil; $0.receivedBytes = 0; $0.speed = 0; $0.totalBytes = -1
            $0.stage = String(localized: "Fetching video information…")
            if useCookies { $0.log = "" }   // keep the failed attempt's output visible above the retry
        }
        // Playlist üyeleri aynı kalitede iner (settings.ytdlpFormatArguments),
        // sadece playlist adında alt klasöre yazılır.
        var outDir = destinationDirectory(for: item)
        if let pt = item.playlistTitle, !pt.isEmpty {
            outDir = outDir.appendingPathComponent(Self.sanitize(pt), isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let proc = VideoDownloader.run(
            executable: exe, url: item.url, outputDir: outDir, formatArgs: settings.ytdlpFormatArguments,
            headers: item.headers, cookieFile: item.cookieFile, useCookies: useCookies,
            onProgress: { [weak self] p in
                DispatchQueue.main.async {
                    guard let self else { return }
                    var ph = self.videoPhase[id] ?? (0, 0, -1)
                    if p.downloaded < ph.lastDownloaded { ph.base += ph.lastDownloaded }   // new file started
                    ph.lastDownloaded = p.downloaded
                    self.videoPhase[id] = ph
                    let received = ph.base + p.downloaded
                    self.update(id) {
                        $0.receivedBytes = received
                        let phaseTotal = p.total > 0 ? ph.base + p.total : -1
                        $0.totalBytes = max(ph.approxTotal, phaseTotal, received)
                        $0.speed = p.speed
                    }
                }
            },
            onLine: { [weak self] line in
                DispatchQueue.main.async {
                    self?.update(id) {
                        $0.log = String(($0.log + line + "\n").suffix(6000))
                        if let st = VideoDownloader.stage(for: line) { $0.stage = st }
                        if line.hasPrefix("MCFMT|"), let n = Double(line.split(separator: "|", omittingEmptySubsequences: false).dropFirst(5).first ?? ""), n > 0 {
                            var ph = self?.videoPhase[id] ?? (0, 0, -1)
                            ph.approxTotal = Int64(n)
                            self?.videoPhase[id] = ph
                            if $0.totalBytes < Int64(n) { $0.totalBytes = Int64(n) }
                        }
                        if let r = line.range(of: "Destination: ") {
                            // Show the final title; strip yt-dlp's intermediate ".f137" format suffix.
                            var name = URL(fileURLWithPath: String(line[r.upperBound...])).lastPathComponent
                            if let m = name.range(of: "\\.f[0-9]+[-a-z0-9]*(?=\\.[a-z0-9]+$)", options: .regularExpression) { name.removeSubrange(m) }
                            $0.fileName = name
                        }
                        if line.hasPrefix("[Merger] Merging formats into \""), let q1 = line.firstIndex(of: "\""), let q2 = line.lastIndex(of: "\""), q1 < q2 {
                            $0.fileName = URL(fileURLWithPath: String(line[line.index(after: q1)..<q2])).lastPathComponent
                        }
                    }
                }
            },
            onFinish: { [weak self] result in
                DispatchQueue.main.async { self?.handleVideoFinish(id: id, result) }
            })
        videoProcesses[id] = proc
        videoPhase[id] = (0, 0, -1)
    }

    private func handleVideoFinish(id: UUID, _ result: Result<String?, Error>) {
        videoProcesses[id] = nil
        videoPhase[id] = nil
        guard let i = index(of: id) else { return }
        var item = items[i]
        guard item.state == .downloading else { return }   // kullanıcı duraklattı/iptal etti
        switch result {
        case .success(let path):
            item.state = .completed
            item.completedAt = Date()
            item.speed = 0
            if let path {
                item.finalPath = path
                item.fileName = URL(fileURLWithPath: path).lastPathComponent
                Self.applyQuarantine(to: URL(fileURLWithPath: path), source: item.url)
                if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 {
                    item.totalBytes = size
                    item.receivedBytes = size
                }
            } else if item.totalBytes > 0 {
                item.receivedBytes = item.totalBytes
            }
            items[i] = item
            notifyCompleted(item)
            DetailWindowManager.shared.didComplete(id: id, autoClose: settings.autoCloseDetail)
            if item.expectedHash != nil, item.finalPath != nil { verifyHash(id) }
        case .failure(let e):
            if !cookielessVideos.contains(id), VideoDownloader.isYouTube(item.url),
               VideoDownloader.isSignedInClientFailure(e.localizedDescription),
               VideoDownloader.hasCookies(itemCookies: item.cookieFile, targetHost: item.url.host) {
                cookielessVideos.insert(id)
                item.log += String(localized: "→ YouTube rejected the signed-in request; retrying without cookies…") + "\n"
                items[i] = item
                startVideo(item)
                return
            }
            item.state = .failed
            item.errorMessage = e.localizedDescription
            item.speed = 0
            items[i] = item
        }
        scheduleSave()
        pumpQueue()
    }

    // MARK: - Torrent (aria2c)

    private func torrentMetaURL(for id: UUID) -> URL {
        supportDir.appendingPathComponent("torrent-meta", isDirectory: true)
            .appendingPathComponent(".t-\(id.uuidString).torrent")
    }

    private func startTorrent(_ item: DownloadItem) {
        let id = item.id
        guard let exe = TorrentDownloader.locateAria2(custom: settings.aria2Path) else {
            update(id) {
                $0.state = .failed
                $0.errorMessage = String(localized: "aria2c not found. It ships with the app — reinstall it, or install with “brew install aria2” / set a custom path in Settings ▸ Torrent.")
            }
            pumpQueue()
            return
        }
        // http(s) .torrent bağlantısı: önce .torrent dosyasını çek, sonra aria2'ye ver.
        if !TorrentDownloader.isMagnet(item.url) {
            update(id) {
                $0.state = .downloading; $0.errorMessage = nil; $0.receivedBytes = 0; $0.speed = 0; $0.totalBytes = -1
                $0.stage = String(localized: "Fetching .torrent file…")
            }
            let meta = torrentMetaURL(for: id)
            try? FileManager.default.createDirectory(at: meta.deletingLastPathComponent(), withIntermediateDirectories: true)
            let cfg = SegmentedDownloader.Configuration(
                url: item.url, headers: item.headers, partURL: meta, segmentCount: 1)
            let dl = SegmentedDownloader(configuration: cfg)
            torrentFetching.insert(id)
            dl.onProgress = { [weak self, weak dl] received, _ in
                DispatchQueue.main.async {
                    guard let self, self.downloaders[id] === dl else { return }
                    self.update(id) { $0.receivedBytes = received }
                }
            }
            dl.onFinish = { [weak self, weak dl] result in
                DispatchQueue.main.async {
                    guard let self, self.downloaders[id] === dl else { return }
                    self.downloaders[id] = nil
                    self.torrentFetching.remove(id)
                    switch result {
                    case .failure(let e):
                        self.update(id) {
                            guard $0.state == .downloading else { return }
                            $0.state = .failed; $0.errorMessage = e.localizedDescription; $0.speed = 0
                        }
                        self.scheduleSave()
                        self.pumpQueue()
                    case .success:
                        self.launchTorrentAria2(id: id, exe: exe, target: meta.path)
                    }
                }
            }
            downloaders[id] = dl
            dl.start()
            return
        }
        launchTorrentAria2(id: id, exe: exe, target: item.url.absoluteString)
    }

    private func launchTorrentAria2(id: UUID, exe: String, target: String) {
        guard let i = index(of: id) else { return }
        let item = items[i]
        guard item.state == .downloading || item.state == .queued else { return }
        let outDir = destinationDirectory(for: item)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        update(id) {
            $0.state = .downloading; $0.errorMessage = nil; $0.speed = 0
            $0.stage = String(localized: "Waiting for peers…")
        }
        let proc = TorrentDownloader.run(
            executable: exe, target: target, outputDir: outDir,
            seedMinutes: settings.torrentSeedMinutes,
            onProgress: { [weak self] p in
                DispatchQueue.main.async {
                    self?.update(id) {
                        $0.receivedBytes = p.downloaded
                        $0.totalBytes = max($0.totalBytes, p.total, p.downloaded)
                        $0.speed = p.speed
                        $0.stage = TorrentDownloader.stage(for: p, finished: false)
                    }
                }
            },
            onLine: { [weak self] line in
                DispatchQueue.main.async {
                    self?.update(id) {
                        $0.log = String(($0.log + line + "\n").suffix(6000))
                    }
                }
            },
            onFinish: { [weak self] result in
                DispatchQueue.main.async { self?.handleTorrentFinish(id: id, result) }
            })
        torrentProcesses[id] = proc
    }

    private func handleTorrentFinish(id: UUID, _ result: Result<[String], Error>) {
        torrentProcesses[id] = nil
        guard let i = index(of: id) else { return }
        var item = items[i]
        guard item.state == .downloading else { return }   // kullanıcı duraklattı/iptal etti
        switch result {
        case .success(let paths):
            guard let first = paths.first else {
                item.state = .failed
                item.errorMessage = String(localized: "Torrent finished but produced no files.")
                item.speed = 0
                items[i] = item
                scheduleSave()
                pumpQueue()
                return
            }
            let finalURL = URL(fileURLWithPath: first)
            Self.applyQuarantineRecursively(to: finalURL, source: item.url)
            item.finalPath = first
            item.fileName = finalURL.lastPathComponent
            item.state = .completed
            item.completedAt = Date()
            item.speed = 0
            let size = Self.diskSize(of: finalURL)
            if size > 0 { item.totalBytes = size; item.receivedBytes = size }
            else if item.totalBytes > 0 { item.receivedBytes = item.totalBytes }
            items[i] = item
            notifyCompleted(item)
            DetailWindowManager.shared.didComplete(id: id, autoClose: settings.autoCloseDetail)
            // Klasör (çok dosyalı torrent) hash'lenemez; tek dosyada ISO kontrolü çalışır.
            if item.expectedHash != nil, !isDirectory(path: first) { verifyHash(id) }
        case .failure(let e):
            item.state = .failed
            item.errorMessage = e.localizedDescription
            item.speed = 0
            items[i] = item
        }
        scheduleSave()
        pumpQueue()
    }

    private func isDirectory(path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    static func applyQuarantineRecursively(to url: URL, source: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue,
           let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let f as URL in en {
                guard let vals = try? f.resourceValues(forKeys: [.isRegularFileKey]),
                      vals.isRegularFile == true else { continue }
                applyQuarantine(to: f, source: source)
            }
        }
        applyQuarantine(to: url, source: source)
    }

    /// Dosya/klasör boyutu (`.aria2` kontrol artıkları hariç).
    static func diskSize(of url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
        }
        var total: Int64 = 0
        if let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let f as URL in en {
                guard let vals = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      vals.isRegularFile == true, let s = vals.fileSize else { continue }
                if f.lastPathComponent.hasSuffix(".aria2") { continue }
                total += Int64(s)
            }
        }
        return total
    }

    /// Asks once whether to install deno, which yt-dlp needs for YouTube, then starts the waiting downloads.
    private func promptForDeno() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = String(localized: "Install the JavaScript runtime for YouTube?")
        alert.informativeText = String(localized: "YouTube now requires yt-dlp to run JavaScript (deno) to unlock video streams. Without it, YouTube downloads may fail with errors such as “The page needs to be reloaded” or “n challenge solving failed”.\n\niDownload Manager can download deno (\(ToolInstaller.denoDownloadSize)) from its official GitHub releases and keep it in its own Application Support folder.")
        alert.addButton(withTitle: String(localized: "Install deno"))
        alert.addButton(withTitle: String(localized: "Not Now")).keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don’t ask again")
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { settings.denoPromptSuppressed = true }
        guard response == .alertFirstButtonReturn else {
            denoDeclinedThisLaunch = true
            resumeDenoWaiters()
            return
        }
        for id in denoWaiters { update(id) { $0.stage = String(localized: "Installing deno…") } }
        ToolInstaller.shared.installDeno { [weak self] result in
            guard let self else { return }
            if case .failure(let e) = result {
                self.denoDeclinedThisLaunch = true   // don't loop on a failing install; Settings ▸ Video can retry
                for id in self.denoWaiters {
                    self.update(id) { $0.log += String(localized: "deno could not be installed: \(e.localizedDescription)") + "\n" }
                }
            }
            self.resumeDenoWaiters()
        }
    }

    private func resumeDenoWaiters() {
        denoPrompting = false
        let waiting = denoWaiters
        denoWaiters = []
        for id in waiting {
            guard let item = items.first(where: { $0.id == id }), item.state == .downloading else { continue }
            startVideo(item)
        }
    }

    // MARK: - Kullanıcı eylemleri

    func pause(_ id: UUID) {
        guard let i = index(of: id), items[i].state.isActive || items[i].state == .queued else { return }
        update(id) { $0.state = .paused; $0.speed = 0 }
        downloaders[id]?.stop()
        if let p = videoProcesses.removeValue(forKey: id) { p.terminate() }
        if let p = torrentProcesses.removeValue(forKey: id) { p.terminate() }
        torrentFetching.remove(id)
        scheduleSave()
        pumpQueue()
    }

    func resume(_ id: UUID) {
        guard let i = index(of: id), [.paused, .failed, .cancelled].contains(items[i].state) else { return }
        update(id) { $0.state = .queued; $0.errorMessage = nil; $0.lastHTTPStatus = nil }
        cookielessVideos.remove(id)
        pumpQueue()
    }

    /// Starts a download that is waiting in the queue (added while "Start new downloads immediately" is off),
    /// as soon as a connection slot is free.
    func start(_ id: UUID) {
        guard let i = index(of: id), items[i].state == .queued else { return }
        if activeCount < settings.maxConcurrent { startItem(id) }
    }

    func cancel(_ id: UUID) {
        guard let i = index(of: id) else { return }
        let item = items[i]
        if let dl = downloaders.removeValue(forKey: id) { dl.stop() }
        if let p = videoProcesses.removeValue(forKey: id) { p.terminate() }
        if let p = torrentProcesses.removeValue(forKey: id) { p.terminate() }
        torrentFetching.remove(id)
        try? FileManager.default.removeItem(at: item.partURL)
        try? FileManager.default.removeItem(at: torrentMetaURL(for: id))
        if item.kind == .video {
            // Süreç öldükten sonra yarım kalan yt-dlp dosyalarını temizle; bu arada
            // kullanıcı yeniden başlatırsa (state değişirse) temizliği iptal et.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, let it = self.items.first(where: { $0.id == id }), it.state == .cancelled else { return }
                self.removeVideoPartials(for: it)
            }
        }
        // Not: yarım torrent verisi durur (aynı torrent yeniden eklenirse kaldığı
        // yerden devam eder); hangi dosyaların bize ait olduğu bilinmeden silmek riskli.
        update(id) { $0.state = .cancelled; $0.speed = 0; $0.receivedBytes = 0; $0.segments = [] }
        scheduleSave()
        pumpQueue()
    }

    /// İptal/kaldırma sonrası yt-dlp'nin bıraktığı yarım dosyaları (`<ad>.part*`) siler.
    /// Duraklatmada çağrılmaz: yt-dlp aynı adla kaldığı yerden devam edebilsin.
    private func removeVideoPartials(for item: DownloadItem) {
        var dir = destinationDirectory(for: item)
        if let pt = item.playlistTitle, !pt.isEmpty {
            dir = dir.appendingPathComponent(Self.sanitize(pt), isDirectory: true)
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let prefix = item.fileName + ".part"
        for n in names where n.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
        }
    }

    func remove(_ id: UUID, deleteFile: Bool = false) {
        guard let i = index(of: id) else { return }
        let item = items[i]
        probeIDs.remove(id)
        if let dl = downloaders.removeValue(forKey: id) { dl.stop() }
        if let p = videoProcesses.removeValue(forKey: id) { p.terminate() }
        if let p = torrentProcesses.removeValue(forKey: id) { p.terminate() }
        torrentFetching.remove(id)
        try? FileManager.default.removeItem(at: item.partURL)
        try? FileManager.default.removeItem(at: torrentMetaURL(for: id))
        if let cf = item.cookieFile { try? FileManager.default.removeItem(atPath: cf) }
        if item.kind == .video { removeVideoPartials(for: item) }
        if deleteFile, let fp = item.finalPath, FileManager.default.fileExists(atPath: fp) {
            // Always move to Trash so the user can recover the file.
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: fp), resultingItemURL: nil)
        }
        items.remove(at: i)
        samples[id] = nil
        scheduleSave()
        pumpQueue()
    }

    func pauseAll() { items.filter { $0.state.isActive || $0.state == .queued }.forEach { pause($0.id) } }
    func resumeAll() {
        items.filter { [.paused, .failed].contains($0.state) }.forEach { resume($0.id) }
        pumpQueue()   // also starts downloads added while "Start new downloads immediately" is off
    }
    func clearFinished() {
        items.filter { [.completed, .cancelled].contains($0.state) }.forEach { remove($0.id) }
    }

    // MARK: - Hash doğrulama (ISO vb.)

    /// Bitmiş dosyanın hash'ini beklenen değerle karşılaştırır (arka planda).
    /// Eşleşmezse öğe `failed` olur ama dosya silinmez; kullanıcı yine açabilir.
    func verifyHash(_ id: UUID) {
        guard let i = index(of: id) else { return }
        let item = items[i]
        guard let path = item.finalPath,
              FileManager.default.fileExists(atPath: path),
              let expected = item.expectedHash, !expected.isEmpty,
              let algoRaw = item.hashAlgorithm,
              let algo = HashAlgorithm(rawValue: algoRaw) else { return }
        guard !item.hashChecking else { return }
        update(id) { $0.hashChecking = true; $0.hashVerified = nil; $0.errorMessage = nil }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result: Result<String, Error> = {
                do { return .success(try FileHash.compute(path: path, algorithm: algo)) }
                catch { return .failure(error) }
            }()
            DispatchQueue.main.async {
                guard let self, self.index(of: id) != nil else { return }
                switch result {
                case .success(let actual):
                    let ok = actual.lowercased() == expected.lowercased()
                    self.update(id) {
                        $0.hashChecking = false
                        $0.computedHash = actual
                        $0.hashVerified = ok
                        if !ok {
                            $0.state = .failed
                            $0.errorMessage = String(localized: "Hash mismatch (\(algo.displayName)): file may be corrupt. Expected \(String(expected.prefix(16)))…, got \(String(actual.prefix(16)))…")
                        }
                    }
                case .failure(let e):
                    self.update(id) {
                        $0.hashChecking = false
                        $0.hashVerified = nil
                        $0.errorMessage = e.localizedDescription
                    }
                }
                self.scheduleSave()
            }
        }
    }

    /// Beklenen hash yokken bile dosyanın hash'ini hesaplar (kopyala/karşılaştır için).
    /// Beklenen hash aynı algoritmadaysa otomatik doğrular.
    func computeHash(_ id: UUID, algorithm: HashAlgorithm) {
        guard let i = index(of: id) else { return }
        let item = items[i]
        guard let path = item.finalPath,
              FileManager.default.fileExists(atPath: path) else { return }
        guard !item.hashChecking else { return }
        update(id) { $0.hashChecking = true }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result: Result<String, Error> = {
                do { return .success(try FileHash.compute(path: path, algorithm: algorithm)) }
                catch { return .failure(error) }
            }()
            DispatchQueue.main.async {
                guard let self, self.index(of: id) != nil else { return }
                switch result {
                case .success(let actual):
                    self.update(id) {
                        $0.hashChecking = false
                        $0.computedHash = actual
                        $0.hashAlgorithm = algorithm.rawValue
                        if let exp = $0.expectedHash, !exp.isEmpty {
                            $0.hashVerified = (actual.lowercased() == exp.lowercased())
                        }
                    }
                case .failure(let e):
                    self.update(id) {
                        $0.hashChecking = false
                        $0.errorMessage = e.localizedDescription
                    }
                }
                self.scheduleSave()
            }
        }
    }

    func revealInFinder(_ item: DownloadItem) {
        if let fp = item.finalPath, FileManager.default.fileExists(atPath: fp) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: fp)])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([destinationDirectory(for: item)])
        }
    }

    func open(_ item: DownloadItem) {
        guard let fp = item.finalPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: fp))
    }

    func shutdown() {
        pauseAll()
        save()
    }

    // MARK: - Hız ölçümü

    private func tick() {
        let now = Date()
        var activeIDs = Set<UUID>()
        for i in items.indices where items[i].state == .downloading && items[i].kind == .file {
            let id = items[i].id
            activeIDs.insert(id)
            let bytes = items[i].receivedBytes
            if let s = samples[id] {
                let dt = now.timeIntervalSince(s.time)
                if dt > 0 {
                    let inst = max(0, Double(bytes - s.bytes) / dt)
                    items[i].speed = items[i].speed == 0 ? inst : items[i].speed * 0.6 + inst * 0.4
                }
            }
            samples[id] = (bytes, now)
        }
        samples = samples.filter { activeIDs.contains($0.key) }
        DetailWindowManager.shared.refreshTitles(items: items)
        tickCount += 1
        if !activeIDs.isEmpty, tickCount % 10 == 0 { save() }   // parça durumu 5 sn'de bir diske
    }

    // MARK: - Kalıcılık

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              var arr = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        for i in arr.indices {
            if arr[i].state.isActive || arr[i].state == .queued { arr[i].state = .paused }
            arr[i].speed = 0
        }
        items = arr
        cleanupOrphanParts()
        cleanupOrphanCookies()
        cleanupOrphanTorrentMeta()
    }

    /// Listede olmayan indirmelerden kalan `.dm-<id>.part` dosyalarını siler.
    private func cleanupOrphanParts() {
        let dir = URL(fileURLWithPath: settings.downloadDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let known = Set(items.map { ".dm-\($0.id.uuidString).part" })
        for n in names where n.hasPrefix(".dm-") && n.hasSuffix(".part") && !known.contains(n) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
        }
    }

    /// Çökme/kaldırma sonrası listede olmayan indirmelere ait cookie dosyalarını siler
    /// (oturum cookie'leri diskte kalmasın). Site-login jar'ı (`sites.txt`) dokunulmaz.
    private func cleanupOrphanCookies() {
        let dir = supportDir.appendingPathComponent("cookies", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let known = Set(items.map { $0.id.uuidString + ".txt" })
        for n in names where n.hasSuffix(".txt") && n != "sites.txt" && !known.contains(n) {
            if UUID(uuidString: (n as NSString).deletingPathExtension) != nil {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
            }
        }
    }

    /// Çökme sonrası listede olmayan torrentlere kalan `.torrent` meta dosyalarını siler.
    private func cleanupOrphanTorrentMeta() {
        let dir = supportDir.appendingPathComponent("torrent-meta", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let known = Set(items.map { ".t-\($0.id.uuidString).torrent" })
        for n in names where n.hasPrefix(".t-") && n.hasSuffix(".torrent") && !known.contains(n) {
            let stem = String(n.dropFirst(3).dropLast(".torrent".count))
            if UUID(uuidString: stem) != nil {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
            }
        }
    }

    private func save() {
        let persistable = items.filter { !probeIDs.contains($0.id) }
        guard let data = try? JSONEncoder().encode(persistable) else { return }
        try? data.write(to: storeURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    private func writeCookieFile(_ cookies: [[String: Any]], id: UUID) -> String? {
        // Netscape formatı sekme/newline ile bozulmasın diye kontrol karakterlerini temizle.
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        var lines = ["# Netscape HTTP Cookie File"]
        for c in cookies {
            guard let name = (c["name"] as? String).map(clean), !name.isEmpty,
                  let value = (c["value"] as? String).map(clean),
                  let domain = (c["domain"] as? String).map(clean), !domain.isEmpty else { continue }
            let path = clean(c["path"] as? String ?? "/")
            let secure = (c["secure"] as? Bool ?? false) ? "TRUE" : "FALSE"
            let exp = Int64((c["expirationDate"] as? Double) ?? 0)
            let flag = domain.hasPrefix(".") ? "TRUE" : "FALSE"
            lines.append([domain, flag, path, secure, String(exp), name, value].joined(separator: "\t"))
        }
        let dir = supportDir.appendingPathComponent("cookies", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(id.uuidString).txt")
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url.path
        } catch {
            return nil
        }
    }

    // MARK: - Bildirim

    private func notifyCompleted(_ item: DownloadItem) {
        guard settings.notifyOnComplete, Bundle.main.bundleIdentifier != nil,
              Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Download completed")
        content.body = item.fileName
        content.sound = .default
        let req = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// Tags a downloaded file like a browser download would, so Gatekeeper/XProtect assess it on first open.
    static func applyQuarantine(to file: URL, source: URL) {
        var target = file
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload,
            kLSQuarantineAgentNameKey as String: "iDownload Manager",
            kLSQuarantineDataURLKey as String: source.absoluteString,
        ]
        try? target.setResourceValues(values)
    }

    // MARK: - Dosya adı yardımcıları

    static func fileName(from url: URL) -> String {
        var name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        if name.isEmpty || name == "/" { name = url.host ?? "download" }
        return name
    }

    static func sanitize(_ s: String) -> String {
        var n = s.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if n.hasPrefix(".") { n = "_" + n }
        if n.count > 200 {
            let ext = (n as NSString).pathExtension
            let base = String((n as NSString).deletingPathExtension.prefix(180))
            n = ext.isEmpty ? base : base + "." + ext
        }
        return n.isEmpty ? "download" : n
    }

    static func uniqueDestination(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
