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

    /// IPv6 literalini bayt seviyesinde denetler: yazımdan bağımsız olarak `::`, `::1`,
    /// IPv4-mapped/compatible gösterimlerin gömülü IPv4'ü ve fe80::/10 yakalanır.
    /// `0:0:0:0:0:0:0:1` / `::ffff:7f00:1` gibi kanonik olmayan yazımlar da böylece geçemez.
    /// Ayrıştırılamayan metin için nil döner (çağıran string kontrollerine devam eder).
    private static func blockedIPv6Literal(_ s: String) -> Bool? {
        var bare = s
        if let pct = bare.firstIndex(of: "%") { bare = String(bare[..<pct]) }   // zone id ("%en0") inet_pton'ı bozar
        guard bare.contains(":") else { return nil }
        var addr = in6_addr()
        guard bare.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
        let b = withUnsafeBytes(of: addr) { Array($0) }
        if b.allSatisfy({ $0 == 0 }) { return true }                       // ::
        if b[0..<15].allSatisfy({ $0 == 0 }), b[15] == 1 { return true }   // ::1
        // ::ffff:0:0/96 (mapped) ve ::/96 (compatible): gömülü IPv4'ü denetle.
        if b[0..<10].allSatisfy({ $0 == 0 }), (b[10] == 0xff && b[11] == 0xff) || (b[10] == 0 && b[11] == 0) {
            return isBlockedDownloadHost("\(b[12]).\(b[13]).\(b[14]).\(b[15])")
        }
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }           // fe80::/10 link-local
        return false
    }

    static func isBlockedDownloadHost(_ host: String?) -> Bool {
        guard var h = host?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty else { return true }
        if h.hasSuffix(".") { h = String(h.dropLast()) }   // "localhost." === "localhost"
        if h == "localhost" { return true }
        // Bulut metadata servisleri (kimlik bilgileri verir).
        if h == "metadata.google.internal" || h == "metadata.goog" { return true }
        if h == "100.100.100.200" { return true }   // Alibaba Cloud metadata
        // Alternatif sayısal IPv4 gösterimleri noktalı dörtlüye indirip öyle denetle.
        if let dotted = normalizedIPv4(h), dotted != h { return isBlockedDownloadHost(dotted) }
        // IPv6 literalleri: köşeli parantezleri soy.
        var bare = h
        if bare.hasPrefix("[") && bare.hasSuffix("]") { bare = String(bare.dropFirst().dropLast()) }
        if bare.contains(":") {
            // ULA (fc00::/7) serbest (LAN dengi); yukarıdaki bayt denetimi gerisini kapsar.
            return blockedIPv6Literal(bare) ?? false
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
