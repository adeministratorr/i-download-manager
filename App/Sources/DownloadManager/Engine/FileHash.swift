import CryptoKit
import Foundation

/// Desteklenen dosya hash algoritmaları (ISO doğrulama vb. için).
enum HashAlgorithm: String, CaseIterable, Codable {
    case sha256
    case sha1
    case md5

    var displayName: String {
        switch self {
        case .sha256: return "SHA-256"
        case .sha1: return "SHA-1"
        case .md5: return "MD5"
        }
    }

    /// Hex string uzunluğu (SHA-256: 64, SHA-1: 40, MD5: 32).
    var hexLength: Int {
        switch self {
        case .sha256: return 64
        case .sha1: return 40
        case .md5: return 32
        }
    }

    /// Kullanıcı girdisini normalize eder: boşlukları/kırılmaları siler, küçük harfe çevirir.
    /// "0x" öneki ve ":"/"-" ayraçları da tolere edilir.
    static func normalize(_ s: String) -> String {
        var n = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if n.hasPrefix("0x") { n = String(n.dropFirst(2)) }
        n = n.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        return n
    }

    static func isHex(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isHexDigit }
    }

    /// Hash uzunluğuna bakarak algoritmayı tahmin eder (belirsizse nil).
    static func detect(_ hash: String) -> HashAlgorithm? {
        let n = normalize(hash)
        guard isHex(n) else { return nil }
        switch n.count {
        case 64: return .sha256
        case 40: return .sha1
        case 32: return .md5
        default: return nil
        }
    }
}

/// Büyük dosyaları belleğe sığdırmadan parça parça hash'leyen yardımcı.
/// ISO (birkaç GB) dosyalar için 1 MB'lık okumalar yapar.
enum FileHash {
    static let chunkSize = 1024 * 1024

    static func compute(path: String, algorithm: HashAlgorithm) throws -> String {
        let url = URL(fileURLWithPath: path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        switch algorithm {
        case .sha256:
            var hasher = SHA256()
            try readChunks(handle: handle) { hasher.update(data: $0) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        case .sha1:
            var hasher = Insecure.SHA1()
            try readChunks(handle: handle) { hasher.update(data: $0) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        case .md5:
            var hasher = Insecure.MD5()
            try readChunks(handle: handle) { hasher.update(data: $0) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func readChunks(handle: FileHandle, body: (Data) -> Void) throws {
        while true {
            guard let data = try handle.read(upToCount: chunkSize) else { break }
            if data.isEmpty { break }
            body(data)
        }
    }
}

struct HashVerificationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
