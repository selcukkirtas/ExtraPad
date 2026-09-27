# ExtraPad

Eski bir iPad'i Mac'e **kablosuz ikinci ekran** yapar. Duet / Sidecar'in yaptigi
isi yapar, ucretsizdir ve iPad'e hicbir sey kurmaniz gerekmez.

Mac'te gercek bir sanal ekran olusturulur (Sistem Ayarlari onu normal bir monitor
gibi gorur, pencereleri surukleyebilirsiniz), bu ekran yakalanir ve iPad'in
Safari'sine canli goruntu olarak akitilir.

## Neden bu mimari

iPad iOS 9-11 uzerinde oldugu icin native bir iPad uygulamasi **yazilamaz**:
guncel Xcode iOS 15 altina kod imzalayip yukleyemez. Dolayisiyla iPad tarafi
Safari'dir. Bu da kodek secimini belirler:

| Yol | iOS 9-11 Safari'de durumu |
|---|---|
| WebRTC | Yok (Safari'ye iOS 11'de geldi, oncesinde hic yok) |
| H.264 + Media Source Extensions | Yok (MSE iOS'a cok sonra geldi) |
| **MJPEG (`multipart/x-mixed-replace`)** | **Calisir** - Safari kendi JPEG decoder'i ile cozer |

Bu yuzden her kare ayri bir JPEG olarak gonderilir. JavaScript piksellere hic
dokunmaz; goruntu dogrudan bir `<img>` etiketinin icine akar.

## Kurulum

```bash
cd ExtraPad
./scripts/build-app.sh        # build/ExtraPad.app olusturur
open build/ExtraPad.app
```

Ilk caliştirmada macOS **Ekran Kaydi** izni isteyecek:
Sistem Ayarlari > Gizlilik ve Guvenlik > Ekran ve Sistem Sesi Kaydi > ExtraPad.
Izni verdikten sonra uygulamayi bir kez yeniden baslatin.

## Kullanim

1. Menu cubugundaki ekran simgesine tiklayin, `http://192.168.x.x:8777/` adresini gorun.
2. iPad'de Safari'yi acip o adrese gidin.
3. Safari'de **Paylas > Ana Ekrana Ekle** yapin; boylece adres cubugu olmadan tam ekran calisir.
4. Mac ve iPad **ayni Wi-Fi agında** olmali. 5 GHz bandi gecikmeyi ciddi sekilde dusurur.

iPad'in ekrani kararmasin diye: iPad > Ayarlar > Ekran ve Parlaklik > Otomatik Kilit > Asla.

### Secenekler

```bash
build/ExtraPad.app/Contents/MacOS/ExtraPad --help
```

| Secenek | Varsayilan | Not |
|---|---|---|
| `--size WxH` | `1024x768` | Eski 9.7" iPad'ler Safari'ye 1024x768 bildirir |
| `--fps N` | `24` | Eski iPad'ler 1024x768'te ~20-30 kare/sn cozebilir |
| `--quality Q` | `0.6` | 0.45 altinda yazilar bulanmaya baslar |
| `--scale 1\|2` | `1` | 2 = HiDPI; Retina olmayan iPad'de gereksiz yuk |
| `--position YON` | `right` | `left`/`right`/`above`/`below`; menuden de degistirilir, hatirlanir |
| `--port N` | `8777` | |
| `--mirror` | kapali | Sanal ekran yerine ana ekrani yansitir |

Log gormek icin uygulamayi paket icinden dogrudan calistirin:
`build/ExtraPad.app/Contents/MacOS/ExtraPad`

### Ucnokta uclari

- `/` - iPad istemcisi
- `/stream` - MJPEG akisi
- `/snapshot` - tek kare JPEG (test icin: `curl -o t.jpg http://localhost:8777/snapshot`)
- `/info` - JSON durum (kare sayisi, bagli cihaz sayisi)

## Bant genisligi

Bu makinede olculdu (1024x768, hareketli icerik):

| Ayar | Kare | Bant genisligi |
|---|---|---|
| `--fps 24 --quality 0.6` (varsayilan) | 82 KB | **15.0 Mbit/s** |
| `--fps 12 --quality 0.45` | 57 KB | **5.6 Mbit/s** |

Hareketsiz ekranda trafik ~0'a iner: ScreenCaptureKit degismeyen kareyi hic
gondermez.

**2.4 GHz Wi-Fi kullaniyorsaniz** varsayilan ayar sinirda kalir; `--fps 12
--quality 0.45` ile baslayin. 5 GHz'de varsayilan rahat calisir.

## Bilinen sinirlar

- **Dokunma girisi yok.** Sadece goruntu. iPad'den Mac'i kontrol etmek ayri bir
  istemci ve Erisilebilirlik izni gerektirir.
- **Kablolu baglanti yok.** Safari USB uzerinden Mac'e ulasamaz. Tek istisna:
  iPad hucresel modelse USB tethering ile daha kararli bir IP baglantisi kurulabilir.
  Gercek kablolu destek native bir iPad uygulamasi ister, o da iOS 15+ demek.
- **Bluetooth bir alternatif degil.** Uc ayri sebeple: (1) iOS Safari'de Bluetooth
  API'si hic yok, yani istemcimizin erisebilecegi bir yol mevcut degil; (2) o nesil
  iPad'de BLE pratikte ~0.1-0.3 Mbit/s tasir, ihtiyacimiz olan 15 Mbit/s'in 50-150
  kati altinda; (3) Bluetooth da 2.4 GHz bandinda calistigi icin ayni anda
  kullanilan Wi-Fi baglantisini bozar.
- **Gecikme.** MJPEG sikistirmasi kare-arasi fark kullanmadigi icin H.264'ten cok
  daha fazla bant genisligi yer. Metin/kod icin fazlasiyla iyi, video izlemek icin degil.
- **Sanal ekran private API kullanir** (`CGVirtualDisplay`). macOS 27'de dogrulandi;
  bir macOS guncellemesi bunu bozarsa uygulama cokmez, `--mirror` moduna duser.

## Yol haritasi

- Faz 1 (bitti): sanal ekran + MJPEG akisi + Safari istemcisi
- Faz 2: degisen bolgeleri gonderme (kare basina tam JPEG yerine serit/blok guncelleme)
- Faz 3: iPad iOS 15+ olursa native istemci - H.264 donanim decode, USB uzerinden baglanti, dokunma girisi

Detaylar: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
