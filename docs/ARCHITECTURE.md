# Mimari

## Veri akisi

```
CGVirtualDisplay (private CoreGraphics API)
        │  macOS'a "ikinci monitor" olarak kaydolur, displayID doner
        ▼
ScreenCaptureKit (SCStream)
        │  BGRA CVPixelBuffer, saniyede fps kare
        ▼
CIContext.jpegRepresentation
        │  GPU'da JPEG, kalite ayarli
        ▼
FrameBroadcaster
        │  son-kare-kazanir dagitim, birikme yok
        ▼
MJPEGServer (Network.framework)
        │  multipart/x-mixed-replace
        ▼
iPad Safari <img src="/stream">
```

## Dosyalar

| Dosya | Sorumluluk |
|---|---|
| `Sources/VirtualDisplayBridge/` | `CGVirtualDisplay*` private siniflarinin Objective-C bildirimi. Ornekler `NSClassFromString` ile alinir, alanlar KVC ile yazilir; boylece Apple bir alani degistirirse tek alan atlanir, surec cokmez. |
| `Sources/ExtraPad/AppController.swift` | Menu cubugu uygulamasi, boru hattinin kurulumu, izin akisi |
| `Sources/ExtraPad/ScreenStreamer.swift` | ScreenCaptureKit yakalama + JPEG kodlama |
| `Sources/ExtraPad/FrameBroadcaster.swift` | Tek yakalama callback'inden N istemciye dagitim |
| `Sources/ExtraPad/MJPEGServer.swift` | Elle yazilmis HTTP/1.1 sunucu (bagimlilik yok) |
| `Sources/ExtraPad/WebClient.swift` | iPad tarafi sayfa, ES5 |
| `Sources/ExtraPad/Config.swift` | CLI secenekleri |

## Tasarim kararlari

### Neden private API
macOS'ta bir ekran eklemenin public bir yolu yok. `CGVirtualDisplay`, BetterDisplay
gibi araclarin da kullandigi yol. Risk, bildirimleri runtime'a tasiyarak sinirlandi:
sinif yoksa `EPVirtualDisplay.supported` false doner ve uygulama `--mirror` moduna
duser.

### Neden bagimliligi olmayan bir HTTP sunucusu
Tek ihtiyacimiz iki ucnokta ve bir multipart akis. Network.framework bunu ~150
satirda veriyor; bir paket eklemek derleme suresini ve tedarik zinciri yuzeyini
bosa buyutur.

### Neden geri baski (backpressure) onemli
Eski bir iPad ureteceginiz her kareyi cozemez. Kare basina tek gonderim kurali var:
onceki gonderim bitmediyse yeni kare atlanir (`Atomic` bayragi). Bu olmadan
gecikme sinirsiz birikir - MJPEG'de en sik yapilan hata.

Ayni mantik kodlama tarafinda da var: `ScreenStreamer` bir kare kodlanirken gelen
kareyi atlar ve sayar (`droppedFrames`, menude gorunur).

### Neden `scale = 1`
iOS 9-11'de kalan iPad'lerin buyuk kismi Retina degil ya da Retina olsa bile
Safari'ye 1024x768 CSS pikseli bildirir. 2048x1536 kodlamak Mac'te GPU, agda bant
genisligi ve iPad'de decode suresi harcar, karsiliginda gorunur bir sey vermez.

## Faz 2 icin notlar: degisen bolge gonderimi

Su an her kare tam JPEG. Tipik masaustu kullaniminda ekranin %90'i degismez.
Plan:
1. Onceki kareyi sakla, 64x64 bloklar halinde karsilastir (Accelerate/vImage).
2. Degisen bloklarin sinirlayici dikdortgenlerini birlestir.
3. Sadece o bolgeleri JPEG yap, `/patch` uzerinden koordinatla gonder.
4. iPad tarafinda `<img>` yerine `<canvas>` + `drawImage(x, y)`.

Bunun bedeli: canvas yolu JavaScript'e girer ve eski Safari'de `<img>` kadar hizli
degil. Once olcum, sonra karar - Faz 1 metin/kod icin yeterliyse gerek yok.

## Faz 3: native istemci
iPad iOS 15+ olursa mimari ciddi sekilde iyilesir: VideoToolbox ile H.264/HEVC
donanim decode, bant genisligi ~10 kat asagi, USB (usbmuxd / peertalk) uzerinden
kablolu baglanti ve dokunma girisinin geri kanali. Mac tarafindaki sanal ekran ve
yakalama katmani aynen kalir; degisen sadece kodlayici ve tasima.
