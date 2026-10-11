import Foundation

enum DownloadKind: String, Codable {
    case file
    case video
}

enum DownloadState: String, Codable {
    case queued, probing, downloading, paused, completed, failed, cancelled

    var isActive: Bool { self == .probing || self == .downloading }

    var label: String {
        switch self {
        case .queued: return String(localized: "Queued")
        case .probing: return String(localized: "Connecting")
        case .downloading: return String(localized: "Downloading")
        case .paused: return String(localized: "Paused")
        case .completed: return String(localized: "Completed")
        case .failed: return String(localized: "Error")
        case .cancelled: return String(localized: "Cancelled")
        }
    }
}

struct SegmentInfo: Codable, Equatable {
    var start: Int64
    var end: Int64          // inclusive
    var received: Int64 = 0

    var length: Int64 { end - start + 1 }
    var isDone: Bool { received >= length }
}

struct DownloadItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var url: URL
    var fileName: String
    var directory: URL
    var kind: DownloadKind = .file
    var state: DownloadState = .queued
    var totalBytes: Int64 = -1
    var receivedBytes: Int64 = 0
    var supportsRanges = false
    var segments: [SegmentInfo] = []
    var headers: [String: String] = [:]
    var cookieFile: String? = nil
    var errorMessage: String? = nil
    var createdAt = Date()
    var completedAt: Date? = nil
    var finalPath: String? = nil
    var requestedSegments: Int = 0      // 0 = ayarlardaki değer
    // Hash doğrulama (ISO vb.): beklenen hash + hesaplanan hash + sonuç.
    var expectedHash: String? = nil     // normalize edilmiş hex (küçük harf)
    var hashAlgorithm: String? = nil    // HashAlgorithm.rawValue
    var computedHash: String? = nil
    var hashVerified: Bool? = nil       // nil = kontrol edilmedi

    // Kalıcı olmayan alanlar
    var speed: Double = 0
    var log: String = ""
    var stage: String = ""      // yt-dlp: current phase (downloading video/audio, merging…)
    var hashChecking: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, url, fileName, directory, kind, state, totalBytes, receivedBytes, supportsRanges,
             segments, headers, cookieFile, errorMessage, createdAt, completedAt, finalPath, requestedSegments,
             expectedHash, hashAlgorithm, computedHash, hashVerified
    }

    init(id: UUID = UUID(), url: URL, fileName: String, directory: URL, kind: DownloadKind = .file,
         state: DownloadState = .queued, totalBytes: Int64 = -1, receivedBytes: Int64 = 0,
         supportsRanges: Bool = false, segments: [SegmentInfo] = [], headers: [String: String] = [:],
         cookieFile: String? = nil, errorMessage: String? = nil, createdAt: Date = Date(),
         completedAt: Date? = nil, finalPath: String? = nil, requestedSegments: Int = 0,
         expectedHash: String? = nil, hashAlgorithm: String? = nil,
         computedHash: String? = nil, hashVerified: Bool? = nil) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.directory = directory
        self.kind = kind
        self.state = state
        self.totalBytes = totalBytes
        self.receivedBytes = receivedBytes
        self.supportsRanges = supportsRanges
        self.segments = segments
        self.headers = headers
        self.cookieFile = cookieFile
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.finalPath = finalPath
        self.requestedSegments = requestedSegments
        self.expectedHash = expectedHash
        self.hashAlgorithm = hashAlgorithm
        self.computedHash = computedHash
        self.hashVerified = hashVerified
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        fileName = try c.decode(String.self, forKey: .fileName)
        directory = try c.decode(URL.self, forKey: .directory)
        kind = try c.decodeIfPresent(DownloadKind.self, forKey: .kind) ?? .file
        state = try c.decodeIfPresent(DownloadState.self, forKey: .state) ?? .queued
        totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? -1
        receivedBytes = try c.decodeIfPresent(Int64.self, forKey: .receivedBytes) ?? 0
        supportsRanges = try c.decodeIfPresent(Bool.self, forKey: .supportsRanges) ?? false
        segments = try c.decodeIfPresent([SegmentInfo].self, forKey: .segments) ?? []
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        cookieFile = try c.decodeIfPresent(String.self, forKey: .cookieFile)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        finalPath = try c.decodeIfPresent(String.self, forKey: .finalPath)
        requestedSegments = try c.decodeIfPresent(Int.self, forKey: .requestedSegments) ?? 0
        expectedHash = try c.decodeIfPresent(String.self, forKey: .expectedHash)
        hashAlgorithm = try c.decodeIfPresent(String.self, forKey: .hashAlgorithm)
        computedHash = try c.decodeIfPresent(String.self, forKey: .computedHash)
        hashVerified = try c.decodeIfPresent(Bool.self, forKey: .hashVerified)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(url, forKey: .url)
        try c.encode(fileName, forKey: .fileName)
        try c.encode(directory, forKey: .directory)
        try c.encode(kind, forKey: .kind)
        try c.encode(state, forKey: .state)
        try c.encode(totalBytes, forKey: .totalBytes)
        try c.encode(receivedBytes, forKey: .receivedBytes)
        try c.encode(supportsRanges, forKey: .supportsRanges)
        try c.encode(segments, forKey: .segments)
        try c.encode(headers, forKey: .headers)
        try c.encodeIfPresent(cookieFile, forKey: .cookieFile)
        try c.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(finalPath, forKey: .finalPath)
        try c.encode(requestedSegments, forKey: .requestedSegments)
        try c.encodeIfPresent(expectedHash, forKey: .expectedHash)
        try c.encodeIfPresent(hashAlgorithm, forKey: .hashAlgorithm)
        try c.encodeIfPresent(computedHash, forKey: .computedHash)
        try c.encodeIfPresent(hashVerified, forKey: .hashVerified)
    }

    var destinationURL: URL { directory.appendingPathComponent(fileName) }
    /// Parça dosyası: ad değişse bile sabit kalsın diye id tabanlı.
    var partURL: URL { directory.appendingPathComponent(".dm-\(id.uuidString).part") }
    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }
    var eta: TimeInterval? {
        guard totalBytes > 0, speed > 1 else { return nil }
        return Double(totalBytes - receivedBytes) / speed
    }
}

struct DownloadFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct HTTPStatusError: LocalizedError {
    let status: Int
    var errorDescription: String? { String(localized: "Server returned HTTP \(status)") }
}

// MARK: - Kategori

enum FileCategory: String, CaseIterable, Identifiable, Codable {
    case image, music, video, apps, document, compressed, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .image: return String(localized: "Images")
        case .music: return String(localized: "Music")
        case .video: return String(localized: "Video")
        case .apps: return String(localized: "Apps")
        case .document: return String(localized: "Documents")
        case .compressed: return String(localized: "Archives")
        case .other: return String(localized: "Other")
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .music: return "music.note"
        case .video: return "film"
        case .apps: return "app.badge"
        case .document: return "doc.text"
        case .compressed: return "doc.zipper"
        case .other: return "doc"
        }
    }

    private static let table: [FileCategory: Set<String>] = [
        .image: ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif", "svg", "psd", "ai", "raw", "cr2", "nef", "ico"],
        .music: ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "wma", "aiff", "alac"],
        .video: ["mp4", "m4v", "mkv", "webm", "mov", "avi", "flv", "wmv", "mpg", "mpeg", "ts", "m3u8", "3gp"],
        .apps: ["dmg", "pkg", "app", "exe", "msi", "apk", "ipa", "deb", "rpm", "appimage", "jar", "xpi", "crx"],
        .document: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "odt", "ods", "odp", "epub", "mobi", "csv", "md", "pages", "numbers", "key"],
        .compressed: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "iso", "img", "cab"],
    ]

    static func detect(fileName: String, kind: DownloadKind) -> FileCategory {
        if kind == .video { return .video }
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .other }
        for (cat, exts) in table where exts.contains(ext) { return cat }
        return .other
    }
}

extension DownloadItem {
    var category: FileCategory { FileCategory.detect(fileName: fileName, kind: kind) }
    var isFinished: Bool { state == .completed }
}
