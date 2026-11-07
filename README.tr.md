# CorePilot

Windows 11 için güvenli ve geri alınabilir ayarlar; PowerShell ile yazıldı. Kurulum yok, `.exe` yok, internetten hiçbir şey indirilip çalıştırılmaz.

CorePilot, **[Win11Debloat](https://github.com/raphire/win11debloat)** (MIT) projesinden esinlenmiştir ve benzer özellikleri hedefler; kodu, verisi ve güvenlik modeli kendisine aittir. O projeden kod veya veri dosyası kopyalanmadı.

## Durum: Aşama 3 + uygulama kaldırma (Aşama 5, 1-2. adımlar)

On kategoride (Gizlilik, Görev çubuğu, Dosya Gezgini, Başlat, Arama, Görünüm, Çoklu görev, Oyun, Yapay zekâ, Giriş) 50 kullanıcı düzeyi (HKCU) ayar, Ayarlar ve Uygulamalar görünümlü pencere (WPF, kategori kartları) ve komut satırı aracı, listelenmiş 49 Store uygulamasını kaldırma (pencere ve komut satırı), İngilizce ve Türkçe metinler, 165 otomatik test. Sıradaki işler için [docs/ROADMAP.md](docs/ROADMAP.md).

## Kullanım

Windows 11 ile gelen Windows PowerShell 5.1 yeterli. Mevcut özellikler için yönetici hakkı gerekmez.

**Pencere:** `CorePilot.cmd` dosyasına çift tıklayın (veya `.\CorePilot.ps1 -Gui`). Ayarlar kategori kartlarında toplanır. İstediklerinizi işaretleyin, bir ayarın üzerine gelerek açıklamasını ve dokunduğu her kayıt defteri değerini (şimdi -> yeni) görün, sonra **Seçilenleri uygula** düğmesine basın. Bir şey yazılmadan önce, değişecek her özelliği (aramayla gizlenmiş işaretliler dahil) listeleyen bir soru gelir. **Seçilenleri geri al** kaydedilen özgün değerleri geri koyar. **Hızlı seçim** yalnızca henüz uygulanmamış düşük riskli ayarları işaretler. Pencereyi açmak hiçbir şeyi değiştirmez. İndirilmiş olduğu için Windows betiği engellerse dosyalara bir kez `Unblock-File` uygulayın.

`CorePilot.cmd` okunabilir üç satırdır: `powershell.exe`'yi `conhost.exe --headless` (bir Windows bileşeni) ile başlatır, böylece uygulamanın arkasında açık bir konsol penceresi kalmaz. Pencere açılamazsa bir mesaj kutusu nedenini söyler ve `%LOCALAPPDATA%\CorePilot\gui-error.log` yazılır. Güvenlik yazılımları gizli PowerShell başlatıcılarını bazen sevmez; sizinki `CorePilot.cmd` dosyasını silerse veya engellerse pencereyi `powershell -STA -File CorePilot.ps1 -Gui` ile başlatın (o zaman bir konsol açık kalır).

**Komut satırı:**

```powershell
.\CorePilot.ps1                                          # tüm özellikleri ve uygulanıp uygulanmadığını listeler (yalnızca okur)
.\CorePilot.ps1 -Feature explorer.show-file-extensions   # önizleme: ne değişecek (yalnızca okur)
.\CorePilot.ps1 -Feature 'privacy.*' -Apply              # önizler, sorar, uygular
.\CorePilot.ps1 -Feature 'privacy.*' -Apply -Yes         # aynısı, soru sormadan
.\CorePilot.ps1 -Feature 'privacy.*' -Undo               # kaydedilen özgün değerleri geri koyar
.\CorePilot.ps1 -History                                 # CorePilot'un neleri değiştirdiği ve yarıda kalan çalışmalar
.\CorePilot.ps1 -Language tr-TR                          # tr-TR veya en-US (varsayılan: Windows dilini izler)
```

Betikler engelleniyorsa pencere başına bir kez: `Set-ExecutionPolicy -Scope Process Bypass`.

**Store uygulamalarını kaldırma:** pencerede **Ayarlar**'ın yanındaki **Uygulamalar**'a basın. Listedeki Store uygulamalarından sizin için yüklü olanlar üç grupta (Güvenli / İsteğe bağlı / Güvensiz) görünür; yüklü olmayanlar gösterilmez. İstediklerinizi işaretleyip **Seçilenleri kaldır**'a basın. Çıkan soru her uygulamanın adını yazar ve CorePilot'un kaldırmayı geri alamayacağını söyler; Güvensiz uygulamalar için ikinci bir soru gelir. Veya komut satırından:

```powershell
.\CorePilot.ps1 -App '*'                                  # bilinen 49 uygulamayı, güvenlik etiketini ve yüklü olup olmadığını listeler (yalnızca okur)
.\CorePilot.ps1 -App app.clipchamp,app.bing-news          # iki uygulama için aynısı (yalnızca okur)
.\CorePilot.ps1 -App app.clipchamp,app.bing-news -Remove  # listeler, sorar, kaldırır, doğrular
.\CorePilot.ps1 -App app.xbox-tcui -Remove -AllowUnsafe   # Güvensiz uygulamalar ayrıca -AllowUnsafe (veya ikinci bir evet) ister
```

Yalnızca `Data/Apps.json` içindeki uygulamalar, tam paket adıyla ve yalnızca geçerli kullanıcı için kaldırılabilir. Her birinin etiketi var: **Güvenli** (kimsenin bağımlı olmadığı fazlalıklar), **İsteğe bağlı** (birçok kişi için yararlı) veya **Güvensiz** (Store'u veya Xbox girişini bozabilir). Windows'un kaldırılamaz işaretlediği paketler, çerçeve paketleri ve sistem paketleri her zaman reddedilir. Kaldırmayı CorePilot **geri alamaz**; uygulamayı Microsoft Store'dan yeniden kurabilirsiniz (komut bağlantıyı yazar). Tasarım ve sınırlar: [docs/APPS-DESIGN.md](docs/APPS-DESIGN.md).

## Nasıl güvende tutar

- Okuma ve önizleme hiçbir şey yazmaz.
- Değişiklikten önce özgün değer (veya "yoktu" bilgisi) `%LOCALAPPDATA%\CorePilot\records` altına kaydedilir.
- Yazdıktan sonra her değer geri okunup doğrulanır; bir sorun varsa o özelliğin tüm değerleri geri alınır.
- `-Undo` tam olarak kaydedileni geri koyar. Kayıt, yalnızca o özelliğin kendi kayıt defteri değerlerini anlatıyorsa kullanılır.
- Yalnızca `HKEY_CURRENT_USER`, yalnızca `Data/Features.json` içindeki değerler, yalnızca DWord ve String türleri. Gerisi reddedilir.
- Yarıda kalan çalışma listede ve `-History` içinde görünür; `-Undo` işi tamamlar.

## Henüz doğrulanmayanlar

- Gerçek kayıt defteri yazıcısı (`Src/Registry.ps1` içindeki `Set`/`Remove`) bir kez geçici bir `HKCU\Software\CorePilotTest-*` anahtarında denendi (DWord/String yazma, üzerine yazma, tür değiştirme, negatif değer, silme, olmayan anahtar/değer, reddedilen türler; anahtar sonra silindi). Sonra gerçek ayar değerlerinde bir kez kullanıldı: pencereden 22 özellik uygulandı (her değer geri okunup doğrulandı), `-Undo` ile geri alındı; 31 kayıt defteri değerinin hepsi kaydedilen özgün değere döndü ve genel durum sayıları öncekiyle aynı çıktı. Otomatik yazma testleri hâlâ bellekteki sahte bir kayıt defteriyle çalışır. Okuma, Windows 11 derleme 26200 olan gerçek bir bilgisayarda denendi: 50 özelliğin 35'inin değer adları orada var. Diğer 15'te en az bir değer yok (Windows varsayılanı); bu durum adı ne doğrular ne çürütür.
- Pencere gerçek bir bilgisayarda yalnızca okuma olarak açılıp sürüldü (durumlar, süzme, onay kutuları, dil değiştirme, geçmiş paneli, ekran görüntüleri); uygula/geri al akışı sahte kayıt defteriyle aynı kod yollarından test edildi. Uygula düğmesine gerçek fare tıkı ve gerçek onay penceresi bir kez çalıştı (22 özellik); Geri al düğmesine gerçek tık denenmedi (geri alma komut satırından yapıldı). Koyu modda kaydırma çubukları Windows'un varsayılan açık görünümünde kalır.
- Her ayarın hemen mi, Gezgin yeniden başlayınca mı, oturum kapanınca mı etkinleştiği gerçek uygulamada doğrulanmadı. "Gezgini yeniden başlatın" / "oturumu kapatın" ipuçları en iyi tahmindir.
- Uygulama kaldırma yalnızca bellekteki sahte bir paket listesiyle ve gerçek listeye karşı salt okunur denendi (Windows 11 derleme 26200 bir bilgisayarda `-App '*'`, `-WhatIf` ve penceredeki Uygulamalar görünümünü açma). CorePilot ile henüz gerçek bir uygulama kaldırılmadı. Gerçek `Remove-AppxPackage` çağrısı, hata iletileri (örneğin kaldırılan uygulamaya başka bir uygulama bağlıysa) ve kaldırılan uygulamaların bir Windows özellik güncellemesinden sonra geri gelip gelmediği denenmedi.
- Klasik (Windows 10 tarzı) sağ tık menüsü henüz yok: varsayılan değer yazmayı ve geri almada kayıt defteri anahtarını silmeyi gerektirir, motor bunu henüz desteklemiyor.
- Bazı ayarlar yeni Windows sürümlerinde yok sayılabilir veya sıfırlanabilir. Uyguladıktan sonra sonucu Windows'ta kontrol edin.

## Geliştirme

```powershell
Import-Module Pester
Invoke-Pester -Path .\Tests
```

Kurallar için [CLAUDE.md](CLAUDE.md). Kısaca: her `.ps1` dosyası yalnızca ASCII, metinler `Locales/*.json` içinde, testler gerçek kayıt defterine veya gerçek veri klasörüne dokunmaz.

## Lisans

MIT, bkz. [LICENSE](LICENSE). Kullanım sorumluluğu size aittir.
