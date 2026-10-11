import Foundation

/// Loopback/bulut-metadata hedeflerine indirme yapılmasını engeller.
/// Eklenti köprüsü saldırgan sayfanın linkiyle sürülebilir (tıklama gaspı), bu yüzden
/// `169.254.169.254` (bulut kimlik bilgileri) ve loopback'e istek atılmamalı.
/// RFC1918 (192.168.x, 10.x) bilerek serbest: NAS/kamera gibi yerel cihazlardan
/// indirme meşru kullanım. `file://` zaten köprüde scheme kontrolüyle reddediliyor.
enum NetGuard {
    /// `user`/`password` içeren URL'ler (userinfo hilesi) her zaman reddedilir.
    static func hasUserinfo(_ url: URL) -> Bool {
        url.user != nil
    }

    static func isBlockedDownloadHost(_ host: String?) -> Bool {
        guard var h = host?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty else { return true }
        if h.hasSuffix(".") { h = String(h.dropLast()) }   // "localhost." === "localhost"
        if h == "localhost" { return true }
        // Bulut metadata servisleri (kimlik bilgileri verir).
        if h == "metadata.google.internal" || h == "metadata.goog" { return true }
        // IPv6 literalleri: köşeli parantezleri soy.
        var bare = h
        if bare.hasPrefix("[") && bare.hasSuffix("]") { bare = String(bare.dropFirst().dropLast()) }
        if bare.contains(":") {
            // ::1, :: (unspecified), fe80::/10 (link-local). ULA (fc00::/7) serbest (LAN dengi).
            if bare == "::1" || bare == "::" { return true }
            let first = bare.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if first.lowercased().hasPrefix("fe80") { return true }
            return false
        }
        let parts = bare.split(separator: ".")
        guard parts.count == 4 else { return false }
        var nums: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isNumber), let n = Int(String(p)), (0...255).contains(n) else { return false }
            nums.append(n)
        }
        if nums[0] == 127 { return true }                   // loopback 127/8
        if nums[0] == 0 { return true }                     // 0.0.0.0/8
        if nums[0] == 169 && nums[1] == 254 { return true } // link-local (bulut metadata dahil)
        return false
    }

    static func isBlockedDownloadURL(_ url: URL) -> Bool {
        if hasUserinfo(url) { return true }
        return isBlockedDownloadHost(url.host)
    }

    /// Köprüden gelen keyfi başlıklarda kimlik/taşıyıcı alanları temizler.
    /// `Cookie`/`Authorization` yalnızca köprünün kendi `cookieHeader` alanından
    /// ve yalnızca istenen host'a gönderilir (SegmentedDownloader.sameOrigin).
    private static let forbiddenHeaderFields: Set<String> = [
        "cookie", "authorization", "proxy-authorization", "proxy-authenticate",
        "host", "content-length", "transfer-encoding", "range", "if-range",
        "if-unmodified-since", "connection", "upgrade", "trailer", "te",
    ]

    static func sanitizedExtraHeaders(_ h: [String: String]) -> [String: String] {
        h.filter { !forbiddenHeaderFields.contains($0.key.lowercased()) }
    }
}
