import Foundation

struct ProbeResult {
    var totalBytes: Int64
    var supportsRanges: Bool
    var suggestedFileName: String?
    var contentType: String?
    var finalURL: URL?
    var etag: String?
    var lastModified: String?
}

/// Tek bir dosyayı N paralel HTTP Range isteğiyle indirir.
/// Tüm durum değişiklikleri `delegateQueue` (seri) üzerinde yapılır; kilit gerekmez.
final class SegmentedDownloader: NSObject, URLSessionDataDelegate {

    struct Configuration {
        var url: URL
        var headers: [String: String]
        var partURL: URL
        var segmentCount: Int
        var minSegmentSize: Int64 = 512 * 1024
        var resumeSegments: [SegmentInfo] = []
        var resumeTotal: Int64 = -1
        var resumeETag: String? = nil
        var resumeLastModified: String? = nil
    }

    private enum Mode { case idle, probing, multi, single }

    var onProbe: ((ProbeResult) -> Void)?
    var onProgress: ((Int64, [SegmentInfo]) -> Void)?
    var onFinish: ((Result<Void, Error>) -> Void)?

    private let config: Configuration
    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "dm.segmented-downloader"
        return q
    }()

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpMaximumConnectionsPerHost = 32
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 7 * 24 * 3600
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.waitsForConnectivity = true
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: c, delegate: self, delegateQueue: delegateQueue)
    }()

    private var mode: Mode = .idle
    private var requestURL: URL
    private var segments: [SegmentInfo] = []
    private var segmentTasks: [Int: (task: URLSessionDataTask, index: Int)] = [:]
    private var retries: [Int: Int] = [:]
    private var pending: [Int] = []          // başlatılmayı bekleyen parça indeksleri
    private var activeLimit = 1              // aynı anda açık bağlantı üst sınırı (429/503'te düşer)
    private var throttledUntil = Date.distantPast
    private static let maxAttempts = 12
    private var probeTask: URLSessionDataTask?
    private var singleTask: URLSessionDataTask?
    private var singleReceived: Int64 = 0
    private var singleTotal: Int64 = -1
    private var fileHandle: FileHandle?
    private var stopped = false
    private var finished = false
    private var fallbackDone = false
    private var freshRetried = false
    private var sendIfRange = false
    private var pendingResume: (segments: [SegmentInfo], total: Int64, etag: String?)? = nil
    private var lastReport = Date.distantPast

    init(configuration: Configuration) {
        config = configuration
        requestURL = configuration.url
        super.init()
    }

    // MARK: - Kontrol

    func start() {
        delegateQueue.addOperation { [self] in
            // Bozuk resume durumunu ele: sınır dışı segmentler sessizce bozuk dosya üretirdi.
            let boundsOK = !config.resumeSegments.isEmpty
                && config.resumeSegments.allSatisfy {
                    $0.start >= 0 && $0.start <= $0.end && $0.end < config.resumeTotal
                    && $0.received >= 0 && $0.received <= $0.length
                }
            let canResume = config.resumeTotal > 0 && boundsOK
                && FileManager.default.fileExists(atPath: config.partURL.path)
            if canResume {
                // Boyut/ETag'i probe ile yeniden doğrula; dosya değiştiyse taze başlat.
                pendingResume = (segments: config.resumeSegments, total: config.resumeTotal,
                                 etag: config.resumeETag)
                sendIfRange = (config.resumeETag ?? config.resumeLastModified) != nil
                probe()
            } else {
                if !config.resumeSegments.isEmpty || config.resumeTotal > 0 {
                    try? FileManager.default.removeItem(at: config.partURL)
                }
                probe()
            }
        }
    }

    /// Duraklat veya iptal et. Son parça durumu `onProgress` ile bildirilir.
    func stop() {
        delegateQueue.addOperation { [self] in
            guard !finished, !stopped else { return }
            stopped = true
            session.invalidateAndCancel()
            closeFile()
            onProgress?(currentReceived(), segments)
        }
    }

    // MARK: - Yardımcılar

    private func currentReceived() -> Int64 {
        mode == .single ? singleReceived : segments.reduce(0) { $0 + $1.received }
    }

    private static let credentialHeaders: Set<String> = ["cookie", "authorization", "proxy-authorization"]

    /// Credentials (Cookie/Authorization) are only sent to the host the download was requested for,
    /// never to a host reached through a redirect. Port da dahildir.
    private func sameOrigin(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.host?.lowercased() == config.url.host?.lowercased()
            && url.scheme?.lowercased() == config.url.scheme?.lowercased()
            && Self.defaultPort(url.scheme, explicit: url.port) == Self.defaultPort(config.url.scheme, explicit: config.url.port)
    }

    private static func defaultPort(_ scheme: String?, explicit: Int?) -> Int? {
        if let explicit { return explicit }
        switch scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private func makeRequest(range: String?) -> URLRequest {
        var r = URLRequest(url: requestURL)
        r.httpMethod = "GET"
        r.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let allowCredentials = sameOrigin(requestURL)
        for (k, v) in config.headers where allowCredentials || !Self.credentialHeaders.contains(k.lowercased()) {
            r.setValue(v, forHTTPHeaderField: k)
        }
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range { r.setValue(range, forHTTPHeaderField: "Range") }
        // Resume ederken If-Range gönder: sunucudaki dosya değiştiyse sunucu 200
        // döner, biz de fallbackToSingle ile taze başlarız (sessiz bozulma olmaz).
        if range != nil, sendIfRange, let tag = config.resumeETag ?? config.resumeLastModified, !tag.isEmpty {
            r.setValue(tag, forHTTPHeaderField: "If-Range")
        }
        return r
    }

    private func probe() {
        mode = .probing
        let t = session.dataTask(with: makeRequest(range: "bytes=0-0"))
        probeTask = t
        t.resume()
    }

    private func handleProbe(_ http: HTTPURLResponse) {
        let status = http.statusCode
        guard (200...299).contains(status) else { fail(HTTPStatusError(status: status)); return }

        var total: Int64 = -1
        var ranges = false
        if status == 206,
           let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = cr.lastIndex(of: "/"),
           let t = Int64(cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespaces)) {
            total = t
            ranges = true
        } else {
            if let cl = http.value(forHTTPHeaderField: "Content-Length"), let n = Int64(cl) {
                total = n
            } else if http.expectedContentLength > 0 {
                total = http.expectedContentLength
            }
            let accept = http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() ?? ""
            ranges = total > 0 && accept.contains("bytes")
        }
        if let u = http.url { requestURL = u }

        let name = Self.fileName(fromContentDisposition: http.value(forHTTPHeaderField: "Content-Disposition"))
        let ctype = http.value(forHTTPHeaderField: "Content-Type")?
            .components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespaces)
        let freshETag = http.value(forHTTPHeaderField: "ETag")
        let freshLM = http.value(forHTTPHeaderField: "Last-Modified")
        onProbe?(ProbeResult(totalBytes: total, supportsRanges: ranges,
                             suggestedFileName: name, contentType: ctype, finalURL: http.url,
                             etag: freshETag, lastModified: freshLM))

        // Resume doğrulaması: boyut veya ETag tutmuyorsa artığı sil, bu probe ile taze devam et.
        if let pr = pendingResume {
            pendingResume = nil
            let etagMatch: Bool = {
                guard let saved = pr.etag, !saved.isEmpty,
                      let fresh = freshETag, !fresh.isEmpty else { return true }
                return saved == fresh
            }()
            if total > 0, total == pr.total, etagMatch {
                segments = pr.segments
                guard openFile(create: false, preallocate: nil) else { return }
                mode = .multi
                launchPendingSegments()
                return
            }
            try? FileManager.default.removeItem(at: config.partURL)
            segments = []
            sendIfRange = false
        }

        let count = ranges ? max(1, min(config.segmentCount, Int(total / config.minSegmentSize))) : 1
        if ranges && count > 1 {
            segments = Self.makeSegments(total: total, count: count)
            guard openFile(create: true, preallocate: total) else { return }
            mode = .multi
            launchPendingSegments()
        } else {
            singleTotal = total
            guard openFile(create: true, preallocate: nil) else { return }
            mode = .single
            launchSingle()
        }
    }

    static func makeSegments(total: Int64, count: Int) -> [SegmentInfo] {
        let size = total / Int64(count)
        return (0..<count).map { i in
            let start = Int64(i) * size
            let end = i == count - 1 ? total - 1 : start + size - 1
            return SegmentInfo(start: start, end: end, received: 0)
        }
    }

    private func openFile(create: Bool, preallocate: Int64?) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: config.partURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // `.part` bir symlink ise takip etmeden sil: indirme dizinine önceden
            // symlink koyan yerel bir aktör keyfi dosyayı ezdiremesin.
            if fm.fileExists(atPath: config.partURL.path),
               (try? fm.destinationOfSymbolicLink(atPath: config.partURL.path)) != nil {
                try fm.removeItem(at: config.partURL)
            }
            if create || !fm.fileExists(atPath: config.partURL.path) {
                guard fm.createFile(atPath: config.partURL.path, contents: nil) else {
                    throw DownloadFailure(message: String(localized: "Could not create file: \(config.partURL.path)"))
                }
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.partURL.path)
            }
            let fh = try FileHandle(forWritingTo: config.partURL)
            if let preallocate, preallocate > 0 { try fh.truncate(atOffset: UInt64(preallocate)) }
            fileHandle = fh
            return true
        } catch {
            fail(error)
            return false
        }
    }

    private func closeFile() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func launchPendingSegments() {
        pending = segments.indices.filter { !segments[$0].isDone }
        activeLimit = max(1, config.segmentCount)
        if pending.isEmpty { finishSuccess() } else { fillSlots() }
    }

    /// Bekleyen parçaları, açık bağlantı sınırını aşmadan başlatır.
    private func fillSlots() {
        guard !stopped, !finished, mode == .multi else { return }
        let wait = throttledUntil.timeIntervalSinceNow
        if wait > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + wait + 0.05) { [weak self] in
                self?.delegateQueue.addOperation { self?.fillSlots() }
            }
            return
        }
        while segmentTasks.count < activeLimit, !pending.isEmpty {
            let i = pending.removeFirst()
            if segments[i].isDone { continue }
            launchSegment(i)
        }
        if segmentTasks.isEmpty, pending.isEmpty { checkAllDone() }
    }

    /// Sunucu sınırlaması (429/503): bağlantı sayısını düşür, parçayı kuyruğa geri koy.
    private func throttle(segment i: Int, status: Int) {
        activeLimit = max(1, min(activeLimit, segmentTasks.count) - 1)
        let attempt = retries[i, default: 0] + 1
        retries[i] = attempt
        guard attempt <= Self.maxAttempts else {
            fail(HTTPStatusError(status: status))
            return
        }
        throttledUntil = Date().addingTimeInterval(min(15, 1.5 * Double(attempt)))
        if !pending.contains(i) { pending.insert(i, at: 0) }
        fillSlots()
    }

    private func launchSegment(_ i: Int) {
        let seg = segments[i]
        let t = session.dataTask(with: makeRequest(range: "bytes=\(seg.start + seg.received)-\(seg.end)"))
        segmentTasks[t.taskIdentifier] = (t, i)
        t.resume()
    }

    private func launchSingle() {
        singleReceived = 0
        let t = session.dataTask(with: makeRequest(range: nil))
        singleTask = t
        t.resume()
    }

    /// Sunucu Range'i yok sayıp 200 döndürdüyse tek akışa geç.
    private func fallbackToSingle() {
        guard !fallbackDone else { return }
        fallbackDone = true
        sendIfRange = false
        let old = segmentTasks
        segmentTasks = [:]
        old.values.forEach { $0.task.cancel() }
        segments = []
        closeFile()
        guard openFile(create: true, preallocate: nil) else { return }
        mode = .single
        launchSingle()
    }

    private func retrySegment(_ i: Int, after error: Error?) {
        let attempt = retries[i, default: 0] + 1
        retries[i] = attempt
        guard attempt <= Self.maxAttempts else {
            fail(error ?? DownloadFailure(message: String(localized: "Segment \(i + 1) could not be completed")))
            return
        }
        throttledUntil = max(throttledUntil, Date().addingTimeInterval(min(10, Double(attempt))))
        if !pending.contains(i) { pending.append(i) }
        fillSlots()
    }

    private func checkAllDone() {
        if !segments.isEmpty, segments.allSatisfy(\.isDone) { finishSuccess() }
    }

    private func finishSuccess() {
        guard !finished, !stopped else { return }
        finished = true
        closeFile()
        session.finishTasksAndInvalidate()
        onProgress?(currentReceived(), segments)
        onFinish?(.success(()))
    }

    private func fail(_ error: Error) {
        guard !finished, !stopped else { return }
        finished = true
        closeFile()
        session.invalidateAndCancel()
        onProgress?(currentReceived(), segments)
        onFinish?(.failure(error))
    }

    private func reportProgress() {
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.2 else { return }
        lastReport = now
        onProgress?(currentReceived(), segments)
    }

    private static func isCancelled(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // SSRF koruması: engelli host'a yönlendirmeyi izleme.
        if let u = request.url, NetGuard.isBlockedDownloadURL(u) {
            completionHandler(nil)
            fail(DownloadFailure(message: String(localized: "Blocked redirect target")))
            return
        }
        // https→http kırılmayı engelle (kimlik bilgisi + içerik düz metne düşmesin).
        if requestURL.scheme?.lowercased() == "https", request.url?.scheme?.lowercased() == "http" {
            completionHandler(nil)
            fail(DownloadFailure(message: String(localized: "Refused insecure redirect (https → http)")))
            return
        }
        var req = request
        if !sameOrigin(req.url) {
            for h in Self.credentialHeaders { req.setValue(nil, forHTTPHeaderField: h) }
        }
        completionHandler(req)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !stopped, !finished else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            fail(DownloadFailure(message: String(localized: "Invalid server response")))
            return
        }

        if dataTask == probeTask {
            completionHandler(.cancel)
            handleProbe(http)
            return
        }

        if let entry = segmentTasks[dataTask.taskIdentifier] {
            switch http.statusCode {
            case 206:
                completionHandler(.allow)
                retries[entry.index] = 0
            case 200:
                completionHandler(.cancel)
                fallbackToSingle()
            case 408, 425, 429, 500, 502, 503, 504:
                completionHandler(.cancel)
                segmentTasks[dataTask.taskIdentifier] = nil
                throttle(segment: entry.index, status: http.statusCode)
            case 404, 416:
                // Bayat resume (sunucuda dosya değişti/küçüldü): artığı silip bir kez taze dene.
                // Eskiden bu durum kalıcı fail döngüsüne girerdi. Resume ile ilgisizse
                // anında fail (koşul case etiketinde değil burada; `where` çok desenli
                // case'lerde yalnızca son desene uygulanır, 404 koşulsuz eşleşirdi).
                guard !config.resumeSegments.isEmpty && !freshRetried else {
                    completionHandler(.cancel)
                    fail(HTTPStatusError(status: http.statusCode))
                    return
                }
                completionHandler(.cancel)
                freshRetried = true
                sendIfRange = false
                for (_, e) in segmentTasks { e.task.cancel() }
                segmentTasks = [:]
                retries = [:]
                pending = []
                try? FileManager.default.removeItem(at: config.partURL)
                segments = []
                probe()
            default:
                completionHandler(.cancel)
                fail(HTTPStatusError(status: http.statusCode))
            }
            return
        }

        if dataTask == singleTask {
            guard (200...299).contains(http.statusCode) else {
                completionHandler(.cancel)
                fail(HTTPStatusError(status: http.statusCode))
                return
            }
            // The real GET may differ from the probe (dynamic responses); trust its Content-Length.
            singleTotal = http.expectedContentLength > 0 ? http.expectedContentLength : -1
            completionHandler(.allow)
            return
        }
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !stopped, !finished, let fh = fileHandle else { return }
        do {
            if let entry = segmentTasks[dataTask.taskIdentifier] {
                var seg = segments[entry.index]
                let remaining = seg.length - seg.received
                guard remaining > 0 else { return }
                let chunk = Int64(data.count) > remaining ? data.prefix(Int(remaining)) : data
                try fh.seek(toOffset: UInt64(seg.start + seg.received))
                try fh.write(contentsOf: chunk)
                seg.received += Int64(chunk.count)
                segments[entry.index] = seg
            } else if dataTask == singleTask {
                try fh.seek(toOffset: UInt64(singleReceived))
                try fh.write(contentsOf: data)
                singleReceived += Int64(data.count)
            } else {
                return
            }
        } catch {
            fail(error)
            return
        }
        reportProgress()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !stopped, !finished else { return }

        if task == probeTask {
            // Yanıt hiç gelmediyse (bağlantı hatası) başarısız say.
            if mode == .probing, let error { fail(error) }
            return
        }

        if let entry = segmentTasks.removeValue(forKey: task.taskIdentifier) {
            let i = entry.index
            if let error, Self.isCancelled(error) { return }
            if segments[i].isDone {
                activeLimit = min(config.segmentCount, activeLimit + 1)
                fillSlots()
            } else {
                retrySegment(i, after: error)
            }
            return
        }

        if task == singleTask {
            if let error {
                if !Self.isCancelled(error) { fail(error) }
                return
            }
            if singleTotal > 0, singleReceived < singleTotal {
                fail(DownloadFailure(message: String(localized: "Connection closed early (\(singleReceived)/\(singleTotal) bytes)")))
                return
            }
            finishSuccess()
        }
    }

    // MARK: - Content-Disposition

    static func fileName(fromContentDisposition header: String?) -> String? {
        guard let header, !header.isEmpty else { return nil }
        // RFC 5987: filename*=UTF-8''dosya%20adi.zip
        if let r = header.range(of: "filename\\*\\s*=\\s*[^']*'[^']*'[^;]+", options: [.regularExpression, .caseInsensitive]) {
            let m = String(header[r])
            if let q = m.range(of: "''") {
                let enc = String(m[q.upperBound...]).trimmingCharacters(in: .whitespaces)
                if let d = enc.removingPercentEncoding, !d.isEmpty {
                    return d.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
        }
        if let r = header.range(of: "filename\\s*=\\s*\"[^\"]*\"", options: [.regularExpression, .caseInsensitive]) {
            let m = String(header[r])
            if let q1 = m.firstIndex(of: "\""), let q2 = m.lastIndex(of: "\""), q1 < q2 {
                let v = String(m[m.index(after: q1)..<q2])
                return v.isEmpty ? nil : v
            }
        }
        if let r = header.range(of: "filename\\s*=\\s*[^;]+", options: [.regularExpression, .caseInsensitive]) {
            let m = String(header[r])
            if let eq = m.firstIndex(of: "=") {
                let v = String(m[m.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }
}
