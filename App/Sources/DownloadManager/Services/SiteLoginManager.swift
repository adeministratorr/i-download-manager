import AppKit
import Foundation
import WebKit

/// In-app login window (WKWebView). Cookies from the session are exported to a Netscape cookie file
/// that yt-dlp uses, so age-restricted / members-only videos can be downloaded.
final class SiteLoginManager: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = SiteLoginManager()

    @Published var cookieCount = 0
    @Published var savedAt: Date?
    @Published var domains: [String] = []

    private var window: NSWindow?
    private var webView: WKWebView?
    private var statusLabel: NSTextField?
    /// Oturum penceresinde gezilen kayıtlı alan adları (eTLD+1). Dışa aktarım yalnızca
    /// bu alan adlarının cookie'lerini yazar; ilgisiz/izleyici cookie'ler jar'a girmez.
    private var visitedDomains: Set<String> = []

    static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static var cookieFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("iDownload Manager/cookies/sites.txt")
    }

    /// Path of the shared cookie file if it exists.
    static var cookieFilePath: String? {
        FileManager.default.fileExists(atPath: cookieFileURL.path) ? cookieFileURL.path : nil
    }

    override init() {
        super.init()
        loadStatus()
    }

    // MARK: Window

    func openLogin(url: URL = URL(string: "https://accounts.google.com/ServiceLogin?continue=https://www.youtube.com/")!) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            webView?.load(URLRequest(url: url))
            return
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 640), configuration: config)
        web.customUserAgent = Self.safariUA
        web.navigationDelegate = self

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 700))
        web.frame = NSRect(x: 0, y: 60, width: 960, height: 640)
        web.autoresizingMask = [.width, .height]
        container.addSubview(web)

        let bar = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 60))
        bar.autoresizingMask = [.width, .maxYMargin]
        let label = NSTextField(labelWithString: String(localized: "Sign in to your account, then click “Save Cookies”."))
        label.frame = NSRect(x: 16, y: 22, width: 560, height: 18)
        label.autoresizingMask = [.width]
        label.textColor = .secondaryLabelColor
        bar.addSubview(label)
        statusLabel = label

        let save = NSButton(title: String(localized: "Save Cookies"), target: self, action: #selector(saveCookies))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: 960 - 16 - 140, y: 14, width: 140, height: 32)
        save.autoresizingMask = [.minXMargin]
        bar.addSubview(save)

        let yt = NSButton(title: "YouTube", target: self, action: #selector(goYouTube))
        yt.bezelStyle = .rounded
        yt.frame = NSRect(x: 960 - 16 - 140 - 110, y: 14, width: 100, height: 32)
        yt.autoresizingMask = [.minXMargin]
        bar.addSubview(yt)
        container.addSubview(bar)

        let w = NSWindow(contentRect: container.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = String(localized: "Site Login")
        w.contentView = container
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        webView = web
        web.load(URLRequest(url: url))
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func goYouTube() {
        webView?.load(URLRequest(url: URL(string: "https://www.youtube.com/")!))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let host = webView.url?.host { visitedDomains.insert(Self.registrableDomain(host)) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let host = webView.url?.host {
            visitedDomains.insert(Self.registrableDomain(host))
            statusLabel?.stringValue = String(localized: "Signed-in pages: \(host). Click “Save Cookies” when done.")
        }
    }

    /// eTLD+1'in kaba hali (son iki etiket). co.uk gibi çok parçalı suffix'lerde tam
    /// değildir ama kullanımı yalnızca "jar bu alan adına eklensin mi" kararıdır; asıl
    /// cookie gönderimi yt-dlp'nin kendi domain eşleştirmesiyle yapılır.
    private static func registrableDomain(_ host: String) -> String {
        var s = host.lowercased()
        if s.hasPrefix(".") { s.removeFirst() }
        let parts = s.split(separator: ".")
        return parts.count >= 2 ? parts.suffix(2).joined(separator: ".") : s
    }

    // MARK: Cookies

    @objc func saveCookies() {
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { [weak self] cookies in
            guard let self else { return }
            // Yalnızca bu pencerede gezilen alan adlarının cookie'leri dışa aktarılır.
            // (Hiç sayfa yüklenemediyse eski davranış: tümü — jar zaten boş olur.)
            let scoped = self.visitedDomains.isEmpty
                ? cookies
                : cookies.filter { self.visitedDomains.contains(Self.registrableDomain($0.domain)) }
            self.write(cookies: scoped)
            self.loadStatus()
            self.statusLabel?.stringValue = String(localized: "Saved \(scoped.count) cookies. yt-dlp will use them for video downloads.")
        }
    }

    private func write(cookies: [HTTPCookie]) {
        // Netscape formatı sekme/newline ile bozulmasın diye kontrol karakterlerini temizle.
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        var lines = ["# Netscape HTTP Cookie File", "# Exported by iDownload Manager"]
        for c in cookies {
            let flag = c.domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let secure = c.isSecure ? "TRUE" : "FALSE"
            let exp = Int64(c.expiresDate?.timeIntervalSince1970 ?? 0)
            lines.append([clean(c.domain), flag, clean(c.path), secure, String(exp), clean(c.name), clean(c.value)].joined(separator: "\t"))
        }
        let url = Self.cookieFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func clear() {
        try? FileManager.default.removeItem(at: Self.cookieFileURL)
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { }
        loadStatus()
    }

    private func loadStatus() {
        guard let text = try? String(contentsOf: Self.cookieFileURL, encoding: .utf8) else {
            cookieCount = 0; savedAt = nil; domains = []; return
        }
        let rows = text.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }
        cookieCount = rows.count
        let hosts = Set(rows.compactMap { $0.split(separator: "\t").first }.map { Self.registrableDomain(String($0)) })
        domains = hosts.sorted()
        savedAt = (try? FileManager.default.attributesOfItem(atPath: Self.cookieFileURL.path))?[.modificationDate] as? Date
    }
}
