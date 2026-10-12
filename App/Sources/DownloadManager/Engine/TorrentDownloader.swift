import Foundation

/// aria2c sarmalayıcısı: magnet ve .torrent indirmeleri.
/// Mimari VideoDownloader ile aynı: uygulama `aria2c` ikilisini bulur (sistem/Homebrew
/// veya özel yol), her indirme için bir `Process` başlatır, konsol çıktısını parse eder.
/// Kalıcılık/resume aria2'nin `.aria2` kontrol dosyalarıyla olur: duraklatınca proses
/// öldürülür, sürdürünce aynı klasörde yeniden başlatılır ve kaldığı yerden devam eder.
enum TorrentDownloader {

    static var helpersDirectory: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
    }

    static func locateAria2(custom: String) -> String? {
        let candidates = [
            custom,
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("MC Download Manager/bin/aria2c").path,
            helpersDirectory.appendingPathComponent("aria2c").path,
            "/opt/homebrew/bin/aria2c",
            "/usr/local/bin/aria2c",
            NSHomeDirectory() + "/.local/bin/aria2c",
        ]
        for c in candidates where !c.isEmpty && FileManager.default.isExecutableFile(atPath: c) { return c }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let p = "\(dir)/aria2c"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func isMagnet(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "magnet"
    }

    /// Magnet URI'leri genelde `dn=` (görünen ad) taşır; listede anlamlı bir ad görünsün diye.
    static func displayName(from url: URL) -> String? {
        guard isMagnet(url),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems else { return nil }
        // Magnet sorgularında boşluk bazen ham "+" ile kodlanır.
        if let dn = items.first(where: { $0.name.lowercased() == "dn" })?.value?
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !dn.isEmpty {
            return dn
        }
        if let xt = items.first(where: { $0.name.lowercased() == "xt" })?.value,
           let range = xt.range(of: "btih:", options: .caseInsensitive) {
            let hash = String(xt[range.upperBound...]).prefix(12)
            if !hash.isEmpty { return "Torrent \(hash)" }
        }
        return nil
    }

    struct Progress {
        var downloaded: Int64
        var total: Int64
        var speed: Double
        var percent: Int
    }

    // MARK: - aria2 konsol çıktısı ayrıştırma

    /// "1.2MiB", "10.0GiB", "512KiB", "0B", "4.0KiB/s" gibi değerleri bayta çevirir.
    static func parseSize(_ s: String) -> Int64 {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasSuffix("/s") { t = String(t.dropLast(2)) }
        let lower = t.lowercased()
        let mult: Double
        let num: String
        if lower.hasSuffix("tib") { mult = 1024*1024*1024*1024; num = String(t.dropLast(3)) }
        else if lower.hasSuffix("gib") { mult = 1024*1024*1024; num = String(t.dropLast(3)) }
        else if lower.hasSuffix("mib") { mult = 1024*1024; num = String(t.dropLast(3)) }
        else if lower.hasSuffix("kib") { mult = 1024; num = String(t.dropLast(3)) }
        else if lower.hasSuffix("tb") { mult = 1e12; num = String(t.dropLast(2)) }
        else if lower.hasSuffix("gb") { mult = 1e9; num = String(t.dropLast(2)) }
        else if lower.hasSuffix("mb") { mult = 1e6; num = String(t.dropLast(2)) }
        else if lower.hasSuffix("kb") { mult = 1e3; num = String(t.dropLast(2)) }
        else if lower.hasSuffix("b") { mult = 1; num = String(t.dropLast(1)) }
        else { mult = 1; num = t }
        return Int64((Double(num.trimmingCharacters(in: .whitespaces)) ?? -1) * mult)
    }

    /// `[#edd2d7 19MiB/235MiB(8%) CN:5 SD:9 DL:568KiB]` satırını ayrıştırır.
    /// Boyutlar bilinmiyorsa (metadata aşaması: `0B/0B`) nil döner.
    static func parseReadout(_ line: String) -> Progress? {
        // [#<gid> <indirilen>/<toplam>(<%>) ...]
        guard let hash = line.firstIndex(of: "#") else { return nil }
        let rest = line[line.index(after: hash)...]
        let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let sizes = parts[1].split(separator: "/", maxSplits: 1)
        guard sizes.count == 2 else { return nil }
        let downloaded = parseSize(String(sizes[0]))
        var totalPart = String(sizes[1])
        var percent = -1
        if let paren = totalPart.firstIndex(of: "("), let end = totalPart.firstIndex(of: ")"), paren < end {
            let pctStr = totalPart[totalPart.index(after: paren)..<end].replacingOccurrences(of: "%", with: "")
            percent = Int(pctStr) ?? -1
            totalPart = String(totalPart[..<paren])
        }
        let total = parseSize(totalPart)
        guard downloaded >= 0, total > 0 else { return nil }
        var speed: Double = 0
        // "DL:<hız>" belirteci köşeli parantezin içinde herhangi bir yerde olabilir.
        if let dlRange = line.range(of: "DL:") {
            let tail = line[dlRange.upperBound...].split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if let first = tail.first {
                let v = parseSize(String(first).replacingOccurrences(of: "]", with: ""))
                if v >= 0 { speed = Double(v) }
            }
        }
        return Progress(downloaded: downloaded, total: total, speed: speed, percent: percent)
    }

    /// Kullanıcıya görünen aşama metni.
    static func stage(for progress: Progress?, finished: Bool) -> String {
        if finished { return String(localized: "Seeding…") }
        guard let p = progress else { return String(localized: "Waiting for peers…") }
        if p.percent >= 100 { return String(localized: "Seeding…") }
        if p.total > 0 { return String(localized: "Downloading…") }
        return String(localized: "Fetching metadata…")
    }

    // MARK: - Çalıştırma

    /// - Parameters:
    ///   - target: magnet URI veya yerel `.torrent` dosya yolu.
    ///   - outputDir: içeriğin yazılacağı klasör (çok dosyalı torrent kendi alt klasörünü açar).
    ///   - seedMinutes: tamamlanınca tohumlanacak süre (0 = bitince çık).
    @discardableResult
    static func run(executable: String,
                    target: String,
                    outputDir: URL,
                    seedMinutes: Int,
                    onProgress: @escaping (Progress) -> Void,
                    onLine: @escaping (String) -> Void,
                    onFinish: @escaping (Result<[String], Error>) -> Void) -> Process {
        let fm = FileManager.default
        let before = Set((try? fm.contentsOfDirectory(atPath: outputDir.path)) ?? [])

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = [
            "--no-conf=true",
            "--dir=\(outputDir.path)",
            "--seed-time=\(max(0, seedMinutes))",
            "--bt-stop-timeout=0",
            "--allow-overwrite=true",
            "--auto-file-renaming=false",
            "--continue=true",
            "--check-integrity=true",
            "--bt-hash-check-seed=true",
            "--bt-remove-unselected-file=true",
            "--max-concurrent-downloads=1",
            "--file-allocation=none",
            "--summary-interval=1",
            "--show-console-readout=true",
            "--enable-dht=true",
            "--bt-enable-lpd=true",
            "--listen-port=6881-6999",
            target,
        ]
        p.currentDirectoryURL = outputDir

        let out = Pipe()
        p.standardOutput = out
        p.standardError = out

        let lock = NSRecursiveLock()
        var outBuf = Data()
        var lastError: String?

        func handle(line raw: String) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return }
            if let prog = parseReadout(line) {
                onProgress(prog)
            }
            if line.localizedCaseInsensitiveContains("error") || line.hasPrefix("Exception") {
                lock.lock(); lastError = line; lock.unlock()
            }
            onLine(line)
        }

        func drain(_ incoming: Data) {
            lock.lock(); defer { lock.unlock() }
            outBuf.append(incoming)
            while let nl = outBuf.firstIndex(of: 0x0A) {
                let lineData = outBuf[outBuf.startIndex..<nl]
                outBuf.removeSubrange(outBuf.startIndex...nl)
                if let s = String(data: lineData, encoding: .utf8) { handle(line: s) }
            }
        }

        let eof = DispatchGroup()
        eof.enter()
        out.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty { fh.readabilityHandler = nil; eof.leave(); return }
            drain(d)
        }

        p.terminationHandler = { proc in
            _ = eof.wait(timeout: .now() + 3)
            out.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            drain(Data([0x0A]))
            let errText = lastError
            lock.unlock()
            guard proc.terminationStatus == 0 else {
                onFinish(.failure(DownloadFailure(message: errText ?? String(localized: "aria2c exited with code \(proc.terminationStatus)"))))
                return
            }
            // Sonuç: klasöre yeni eklenen üst-düzey girdi (tek torrent → tek girdi).
            // `.aria2` kontrol artıkları sonuca dahil edilmez.
            let after = Set((try? fm.contentsOfDirectory(atPath: outputDir.path)) ?? [])
            let added = after.subtracting(before).filter { !$0.hasSuffix(".aria2") }.sorted()
            onFinish(.success(added.map { outputDir.appendingPathComponent($0).path }))
        }

        do {
            try p.run()
        } catch {
            onFinish(.failure(error))
        }
        return p
    }
}
