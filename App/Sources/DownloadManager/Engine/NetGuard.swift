import Foundation
import Darwin

/// Loopback/bulut-metadata hedeflerine indirme yapılmasını engeller.
/// Eklenti köprüsü saldırgan sayfanın linkiyle sürülebilir (tıklama gaspı), bu yüzden
/// `169.254.169.254` (bulut kimlik bilgileri) ve loopback'e istek atılmamalı.
/// RFC1918 (192.168.x, 10.x) bilerek serbest: NAS/kamera gibi yerel cihazlardan
/// indirme meşru kullanım. `file://` zaten köprüde scheme kontrolüyle reddediliyor.
enum NetGuard {

    /// Host string'i noktalı dörtlüye çevirir; inet_aton'un kabul ettiği alternatif
    /// gösterimler (tek sayı `2130706433`, onaltılık `0x7f000001`, sekizlik `0177.0.0.1`,
    /// kısa biçim `127.1`) hepsi loopback/metadata olarak çözülür ama string kontrolünden
    /// kaçardı. Sayısal olmayan host adlarında nil döner.
    private static func normalizedIPv4(_ host: String) -> String? {
        var addr = in_addr()
        guard host.withCString({ inet_aton($0, &addr) }) == 1 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buf)
    }

    static func isBlockedDownloadHost(_ host: String?) -> Bool {
        guard var h = host?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty else { return true }
        if h.hasSuffix(".") { h = String(h.dropLast()) }   // "localhost." === "localhost"
        if h == "localhost" { return true }
        // Bulut metadata servisleri (kimlik bilgileri verir).
        if h == "metadata.google.internal" || h == "metadata.goog" { return true }
        // Alternatif sayısal IPv4 gösterimleri noktalı dörtlüye indirip öyle denetle.
        if let dotted = normalizedIPv4(h), dotted != h { return isBlockedDownloadHost(dotted) }
        // IPv6 literalleri: köşeli parantezleri soy.
        var bare = h
        if bare.hasPrefix("[") && bare.hasSuffix("]") { bare = String(bare.dropFirst().dropLast()) }
        if bare.contains(":") {
            // ::1, :: (unspecified), fe80::/10 (link-local). ULA (fc00::/7) serbest (LAN dengi).
            if bare == "::1" || bare == "::" { return true }
            // Gömülü IPv4 (örn. ::ffff:127.0.0.1): son segment noktalı dörtlüyse onu denetle.
            if let lastColon = bare.lastIndex(of: ":"), lastColon < bare.index(before: bare.endIndex) {
                let tail = String(bare[bare.index(after: lastColon)...])
                if tail.contains("."), let dotted = normalizedIPv4(tail) {
                    return isBlockedDownloadHost(dotted)
                }
            }
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
        // Magnet'in host'u yoktur (DHT üzerinden çözülür); engel listesine girmez.
        if url.scheme?.lowercased() == "magnet" { return false }
        if hasUserinfo(url) { return true }
        return isBlockedDownloadHost(url.host)
    }

    /// Host adını DNS'te çözer ve dönen tüm adresleri denetler. Sayısal olmayan adlar
    /// (rebinding ile loopback'e çözen alan adları) yalnızca burada yakalanabilir.
    /// Engelleme kararını hızlı tutmak için köprüde değil, indirme motorunda (arka planda)
    /// çağrılır. Çözümleme başarısızsa engellemez (indirme zaten başarısız olur). Not:
    /// URLSession bağlanırken kendi çözümlemesini yapar; çözümleme anı ile bağlanma anı
    /// arasında değişen kayıt (klasik rebinding TOCTOU) tam koruma dışıdır.
    static func resolvesToBlockedAddress(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return false }
        defer { freeaddrinfo(res) }
        var blocked = false
        var cur: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cur, !blocked {
            let family = ai.pointee.ai_family
            if family == AF_INET || family == AF_INET6, let sa = ai.pointee.ai_addr {
                let rendered: String?
                if family == AF_INET {
                    rendered = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin -> String? in
                        var addr = sin.pointee.sin_addr
                        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        return inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil ? String(cString: buf) : nil
                    }
                } else {
                    rendered = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 -> String? in
                        var addr = sin6.pointee.sin6_addr
                        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                        return inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil ? String(cString: buf) : nil
                    }
                }
                if let rendered, isBlockedDownloadHost(rendered) { blocked = true }
            }
            cur = ai.pointee.ai_next
        }
        return blocked
    }

    /// `user`/`password` içeren URL'ler (userinfo hilesi) her zaman reddedilir.
    static func hasUserinfo(_ url: URL) -> Bool {
        url.user != nil
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
