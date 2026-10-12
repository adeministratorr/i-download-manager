import AppKit
import Foundation

/// Checks GitHub Releases for a newer version and notifies the user.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    static let repo = "adeministratorr/i-download-manager"
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!

    @Published var latestVersion: String?
    @Published var checking = false
    @Published var lastCheck: Date?
    @Published var lastError: String?

    private var timer: Timer?
    private weak var store: DownloadStore?
    private weak var settings: AppSettings?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start(store: DownloadStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard let settings, settings.checkForUpdates else { return }
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 20 * 3600 else { return }
        check(interactive: false)
    }

    struct Release {
        let version: String
        let page: URL
        let dmg: URL?
        let notes: String
    }

    func check(interactive: Bool) {
        guard !checking else { return }
        checking = true
        lastError = nil
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                self.lastCheck = Date()
                UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
                guard let data, let http = resp as? HTTPURLResponse, http.statusCode == 200,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = obj["tag_name"] as? String else {
                    self.lastError = error?.localizedDescription ?? String(localized: "No release information available yet.")
                    if interactive { self.showNoUpdate(error: self.lastError) }
                    return
                }
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let page = URL(string: obj["html_url"] as? String ?? "") ?? Self.releasesPage
                let assets = obj["assets"] as? [[String: Any]] ?? []
                let dmg = assets.compactMap { a -> URL? in
                    guard let name = a["name"] as? String, name.lowercased().hasSuffix(".dmg"),
                          let u = a["browser_download_url"] as? String else { return nil }
                    return URL(string: u)
                }.first
                let notes = (obj["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                self.latestVersion = version
                let release = Release(version: version, page: page, dmg: dmg, notes: notes)
                if Self.isNewer(version, than: Self.currentVersion) {
                    let skipped = UserDefaults.standard.string(forKey: "skippedVersion")
                    if interactive || skipped != version { self.showUpdate(release) }
                } else if interactive {
                    self.showNoUpdate(error: nil)
                }
            }
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func showUpdate(_ r: Release) {
        let alert = NSAlert()
        alert.messageText = String(localized: "iDownload Manager \(r.version) is available")
        var info = String(localized: "You are using version \(Self.currentVersion).")
        if !r.notes.isEmpty { info += "\n\n" + String(r.notes.prefix(600)) }
        alert.informativeText = info
        alert.addButton(withTitle: r.dmg != nil ? String(localized: "Download Update") : String(localized: "Open Release Page"))
        alert.addButton(withTitle: String(localized: "Later"))
        alert.addButton(withTitle: String(localized: "Skip This Version"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let dmg = r.dmg, let store {
                var req = NewDownloadRequest(url: dmg)
                req.fileName = dmg.lastPathComponent
                store.add(req)
            } else {
                NSWorkspace.shared.open(r.page)
            }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(r.version, forKey: "skippedVersion")
        default:
            break
        }
    }

    private func showNoUpdate(error: String?) {
        let alert = NSAlert()
        if let error {
            alert.messageText = String(localized: "Could not check for updates")
            alert.informativeText = error
        } else {
            alert.messageText = String(localized: "You're up to date")
            alert.informativeText = String(localized: "iDownload Manager \(Self.currentVersion) is the latest version.")
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
