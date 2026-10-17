<p align="center">
  <img src="docs/icon.png" width="128" alt="iDownload Manager simgesi">
</p>

<h1 align="center">iDownload Manager</h1>

<p align="center">
  macOS için hızlı, açık kaynaklı bir indirme yöneticisi.<br>
  Safari, Chrome ve Firefox indirmelerini yakalar, 16'ya kadar paralel bağlantıyla hızlandırır ve sayfalardaki videoları indirir.
</p>

<p align="center">
  <a href="README.md">🇬🇧 English</a> · <a href="https://github.com/adeministratorr/i-download-manager/releases">Sürümler</a> · <a href="#kurulum">Homebrew</a>
</p>

<p align="center">
  <a href="https://youtu.be/Set5DFC5xmg"><img src="docs/video-tr.png" width="720" alt="1 dakikalık iDownload Manager tanıtım videosunu YouTube'da izleyin"></a><br>
  <sub>▶ <a href="https://youtu.be/Set5DFC5xmg">1 dakikalık tanıtımı izleyin</a> · <a href="https://youtu.be/SsHWR9UFCM0">English video</a></sub>
</p>

---

Her şey tek bir `.app` içinde gelir: Safari uzantısı, Chrome ve Firefox eklentileri, `yt-dlp` ve `ffmpeg` uygulamaya gömülüdür.
DMG'yi açıp uygulamayı *Applications* klasörüne sürüklemek yeterlidir. Arayüz **İngilizce** ve **Türkçe**dir (sistem dilini izler).

## Özellikler

- **Çok parçalı indirme** — dosya HTTP `Range` isteklerine bölünür (varsayılan 8 bağlantı, 1–16 arası ayarlanabilir).
  Sunucu `Range` desteklemiyorsa tek akışa düşer; `429`/`503` sınırlamalarında bağlantı sayısı adaptif olarak azaltılır.
- **Duraklat / sürdür** — parça durumları diske yazılır; uygulama yeniden açılsa bile kaldığı yerden devam eder.
- **Tarayıcı entegrasyonu** — Safari, Google Chrome, Brave ve Firefox için tek kaynaklı WebExtension. Adım adım kurulum sihirbazı her tarayıcıyı
  tek tek ele alır (eklenti dosyaları `~/Downloads/iDownload Manager/Browser Plugins/` altına yerleştirilir).
  Tarayıcıdaki indirme iptal edilip çerezler, `Referer` ve `User-Agent` ile birlikte uygulamaya iletilir; yakalanan dosya türleri ayarlanabilir.
  Uygulama çalışmıyorsa eklenti onu başlatır (native messaging) ve açılınca indirmeyi teslim eder; başlatamazsa indirme tarayıcıda devam eder.
- **Video indirme** — sayfadaki `<video>`, `.m3u8` ve `.mpd` akışları yakalanır; "Bu sayfadaki videoyu indir" gömülü yt-dlp'yi
  (ffmpeg ile birleştirme dahil) kullanır. Varsayılan çıktı en fazla 1080p MP4'tür (kapsayıcı ve çözünürlük ayarlanabilir). Tarayıcı çerezleri
  yt-dlp'ye aktarılır; yaş doğrulamalı videolar için uygulama içi giriş penceresi vardır. yt-dlp tek tıkla GitHub'dan güncellenebilir.
- **Pano** — bir bağlantı kopyaladığınızda uygulama indirmek isteyip istemediğinizi sorar; ana pencereye ⌘V ile bağlantı yapıştırabilirsiniz.
- **Arayüz** — kenar çubuğunda kategoriler (Resim, Müzik, Video, Uygulama, Belge, Arşiv…), sıralanabilir tablo, arama,
  IDM tarzı dosya özelinde pencere (bağlantı tablosu, parça çubuğu, otomatik kapat seçeneği), menü çubuğu simgesi, bildirimler.
- **Menü çubuğunda yaşar** — oturum açıldığında başlar (ilk kurulumdan sonra otomatik etkinleşir), pencere ve Dock simgesi olmadan açılır; tarayıcı köprüsü hep açık olduğundan eklentiler uygulamayı açmanızı beklemez. Pencereyi kapatmak uygulamayı kapatmaz; çıkmak için menü çubuğu simgesini kullanın.

<p align="center">
  <img src="docs/main-tr.png" width="720" alt="Ana pencere"><br>
  <img src="docs/detail.png" width="520" alt="İndirme penceresi">
</p>

## Kurulum

**Homebrew**

```bash
brew install --cask adeministratorr/tap/i-download-manager
```

Güncellemek için `brew upgrade --cask i-download-manager`. Ardından aşağıdaki tarayıcı adımlarıyla (2 ve 3) devam edin.

**Elle kurulum**

1. [Sürümler](https://github.com/adeministratorr/i-download-manager/releases) sayfasından DMG'yi indirin, açın ve **iDownload Manager.app**'i *Applications*'a sürükleyin.
   - Notarize edilmemiş derlemelerde ilk açılışta macOS uyarı verir: *Sistem Ayarları ▸ Gizlilik ve Güvenlik ▸ "Yine de Aç"*.
2. **Safari:** *Safari ▸ Ayarlar ▸ Uzantılar ▸ iDownload Manager* → etkinleştirin ve tüm web sitelerine izin verin.
   - Ad-hoc imzalı derlemelerde Safari ayrıca *Geliştirici ▸ İmzasız uzantılara izin ver* seçeneğini ister (Developer ID ile imzalı sürümlerde gerekmez).
3. **Chrome:** `chrome://extensions` ▸ *Geliştirici modu* ▸ *Paketlenmemiş öğe yükle* ▸ uygulama içindeki
   *Ayarlar ▸ Tarayıcı ▸ "Klasörü Göster"* ile açılan `ChromeExtension` klasörünü seçin.
4. **Firefox:** *Ayarlar ▸ Tarayıcı Eklentileri ▸ Kurulum Sihirbazını Aç… ▸ Firefox'a Ekle*. Eklenti Mozilla tarafından imzalıdır ve
   uygulamayla birlikte gelir; Firefox bir kez onay ister ve eklentiyi kalıcı olarak kurar (Firefox 140 veya üstü).

Uygulama `127.0.0.1:48213` üzerinde yalnızca tarayıcı uzantılarından (`Origin` denetimi) istek kabul eden küçük bir HTTP köprüsü çalıştırır.

## Kaynaktan derleme

Gereksinimler: macOS 13+, Xcode 15+, [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
scripts/fetch-tools.sh   # universal yt-dlp ve ffmpeg (arm64 + x86_64) ikililerini Tools/ içine indirir
scripts/build.sh         # Release derler, imzalar ve build/iDownload Manager <sürüm>.dmg üretir
```

Geliştirme için `xcodegen generate` çalıştırıp `iDownloadManager.xcodeproj`'yi Xcode'da açın.

Developer ID ile imzalama ve notarizasyon:

```bash
CODESIGN_IDENTITY="Developer ID Application: Ad Soyad (TEAMID)" NOTARY_PROFILE=notary scripts/build.sh
```

GitHub Actions iş akışı (`.github/workflows/build.yml`) her push'ta ad-hoc imzalı bir DMG üretir ve workflow artifact'i olarak yükler. Release DMG'leri yerelde `scripts/build.sh` ile (Developer ID ile imzalı ve notarized) üretilir.

### Homebrew cask'ini güncelleme

Bir sürümün DMG'si yüklendikten sonra `scripts/update-cask.sh`, [adeministratorr/homebrew-tap](https://github.com/adeministratorr/homebrew-tap) içindeki
`Casks/i-download-manager.rb` dosyasını `project.yml`'deki sürüme getirir (sağlama toplamı sürüm dosyasından alınır).

### Chrome eklentisini Web Store'da yayınlama

Chrome, eklentileri yalnızca Chrome Web Store'dan sessizce kurar; eklenti yayınlanana kadar uygulama kullanıcıyı
*Geliştirici modu ▸ Paketlenmemiş öğe yükle* adımlarıyla yönlendirir. Yayınlamak için:

```bash
scripts/pack-extension.sh      # → build/i-download-manager-chrome-<sürüm>.zip
```

Zip'i [Chrome Web Store geliştirici konsoluna](https://chrome.google.com/webstore/devconsole) yükleyin, ardından
`BrowserIntegration.chromeWebStoreURL` değerini mağaza sayfası yapın; "Kur" doğrudan mağazayı açar.

### Firefox eklentisini imzalama

Firefox'un normal sürümü yalnızca Mozilla tarafından imzalanmış eklentileri kurar. `scripts/build.sh`, `scripts/pack-firefox.sh`
betiğini çalıştırır: bu betik manifest'in Firefox sürümünü (`background.scripts`, `browser_specific_settings.gecko`) üretir ve
[AMO API anahtarları](https://addons.mozilla.org/developers/addon/api/key/) varsa eklentiyi listelenmemiş (unlisted) olarak
imzalatıp (her sürüm için bir kez) `FirefoxExtension.xpi` adıyla uygulamaya ekler. Anahtarları anahtar zincirine kaydedin:

```bash
security add-generic-password -s i-download-manager-amo -a issuer -w 'user:…'
security add-generic-password -s i-download-manager-amo -a secret -w '…'
```

Anahtar yoksa imzasız eklenti eklenir; Firefox onu yalnızca `about:debugging` üzerinden geçici olarak yükleyebilir.

## Köprü API'si

| Uç nokta | Açıklama |
|---|---|
| `GET /ping` | sürüm, yt-dlp durumu, aktif indirme sayısı |
| `POST /download` | `{url, filename?, referer?, userAgent?, cookieHeader?, cookies?[], kind: "file"\|"video"\|"torrent", segments?, expectedHash?, hashAlgorithm?, playlist?}` |
| `GET /downloads` | son 50 indirmenin durumu |
| `POST /action` | `{id, action: "pause"\|"resume"\|"cancel"\|"remove"}` |

CORS ön kontrolü dışındaki her köprü isteği, uygulamada *Ayarlar ▸ Tarayıcı ▸ Köprü anahtarı* altında gösterilen ve her eklentinin ayarlarına bir kez yapıştırılan `X-MCDM-Token` başlığını taşımalıdır; anahtarsız istekler bu Mac'ten gelse bile reddedilir. Köprü yalnızca `Origin` değeri tarayıcı eklentisi kaynağı olan (`chrome-extension://`, `safari-web-extension://`, `moz-extension://`) ya da — Chrome'un `Origin` göndermediği GET'lerde — `Origin` içermeyip `X-MCDM-Extension` başlığı taşıyan ve `Host` değeri yerel adres olan isteklere yanıt verir; sıradan web sayfalarından gelen istekler (`Origin: null` dahil) reddedilir, CORS başlıkları yalnızca eklenti kaynaklarına gönderilir. Döngü adresi, link-local (`169.254.x.x`) ve bulut metadata (`100.100.100.200`) hedefleri ile kullanıcı bilgisi içeren URL'ler indirme hedefi olarak reddedilir; `Cookie`/`Authorization`/`Range`/`Host` başlıkları `headers` ile enjekte edilemez ve yalnızca `http(s)` URL'leri kabul edilir.

## Katkı

Issue ve pull request'ler memnuniyetle karşılanır. Çeviriler `App/Resources/Localizable.xcstrings` ve `Extension/_locales/` içindedir.

## Lisans

Kod MIT lisanslıdır (bkz. `LICENSE`). Gömülü ikililer kendi lisanslarına tabidir:
[yt-dlp](https://github.com/yt-dlp/yt-dlp) (Unlicense) ve [FFmpeg](https://ffmpeg.org) (martin-riedl.de statik derlemesi, GPL).
GPL'li ffmpeg ikilisi ile dağıtım yapıyorsanız kaynak erişimi yükümlülüğünü göz önünde bulundurun ya da `scripts/fetch-tools.sh` içindeki URL'yi LGPL bir derlemeyle değiştirin.
