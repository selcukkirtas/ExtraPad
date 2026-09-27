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

1. Menu cubugundaki ekran simgesine tiklayin; adres anahtariyla birlikte orada
   yazar (`http://192.168.x.x:8777/?k=...`). Tiklayinca panoya kopyalanir.
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
| `--fps N` | `24` | Hatirlanir. Delta modunda tasiyabileceginizden yuksek tutmak zararsiz |
| `--quality Q` | `0.8` | Hatirlanir. Delta modunda 0.95'e kadar cikabilir, cunku yalnizca degisen bolgeler gonderilir |
| `--scale 1\|2` | `1` | 2 = HiDPI; Retina olmayan iPad'de gereksiz yuk |
| `--position YON` | `right` | `left`/`right`/`above`/`below`; menuden de degistirilir, hatirlanir |

Konum, kalite ve kare hizi **hatirlanir**: ister bayrakla ister `/set` ile
degistirin, bir sonraki acilista ayni ayarla baslar. Sanal ekran her acilista
yeniden olusturuldugu icin macOS bunlari kendisi hatirlayamiyor.
| `--port N` | `8777` | |
| `--no-input` | giris acik | iPad'den dokunma girisini kapatir |
| `--no-auth` | anahtar acik | Erisim anahtarini kapatir (yalnizca guvendiginiz agda) |
| `--mirror` | kapali | Sanal ekran yerine ana ekrani yansitir |

Log gormek icin uygulamayi paket icinden dogrudan calistirin:
`build/ExtraPad.app/Contents/MacOS/ExtraPad`

### Ucnokta uclari

- `/` - iPad istemcisi (delta modu)
- `/mjpeg` + `/stream` - yedek MJPEG istemcisi ve akisi
- `/ws` - delta akisi (WebSocket)
- `/snapshot` - tek kare JPEG (test icin: `curl -o t.jpg http://localhost:8777/snapshot`)
- `/info` - JSON durum: uretilen kare, istemci basina **gonderilen/atlanan kare**,
  bayt ve gerceklesen fps. Darbogaz teshisi icin asil arac budur.
- `/set?quality=0.3&fps=12` - yayin ayarlarini **calisirken** degistirir; istemciler
  bagli kalir, sayfayi yenilemek gerekmez

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

### Gercek bir baglantida olculen tavan (iPad 2, A1395)

`/info` ile iPad'e *gercekten* giden kareler sayilarak olculdu.

**En onemli bulgu ayar degil, ag topolojisi.** Mac ve iPad ayni telsiz radyoyu
paylastigi surece her bayt havayi iki kez kullanir (Mac -> router, router -> iPad),
ve yavas olan cihaz butun ortamin hizini belirler. iPad 2 gibi tek akisli eski bir
istemci varken bu tek basina hizi yariya indiriyor:

| Topoloji | Tavan | Kalite 0.25-0.3'te iPad |
|---|---|---|
| Mac 5 GHz + iPad ayni 5 GHz radyoda | 8-9 Mbit/s | 12-13 fps |
| **Mac 5 GHz + iPad 2.4 GHz (ayri radyo)** | **15 Mbit/s** | **27 fps** |

Yani once ikisini **ayri radyolara** alin; ayar kurcalamaktan cok daha fazla
kazandiriyor. Eski iPad'lerde 802.11n cogu zaman sadece 2.4 GHz'de calisir, 5 GHz'de
802.11a'ya duserler - bu cihazlar icin 2.4 GHz *daha hizli* bant olabilir.

Ayri radyo kurulumunda, fps 30 sabitken:

| Kalite | iPad'in aldigi | Kare | Aktarim |
|---|---|---|---|
| 0.25 | 27.4 fps | 67 KB | 15.1 Mbit/s |
| **0.35** | **16.2 fps** | 85 KB | 11.3 Mbit/s |
| 0.45 | 12.4 fps | 110 KB | 11.2 Mbit/s |
| 0.55 | 5.8 fps | 138 KB | 6.5 Mbit/s |

Aktarimin yuksek kalitede *dusmesi* dikkat cekici: bu saf bant genisligi siniri
degil. Buyuk kareler 2.4 GHz'de daha cok yeniden iletime ugrar ve bir kare
uzadikca o sirada uretilen kareler atlanir. Kareyi kucuk tutmanin getirisi
dogrusaldan fazla.

`--fps`'i tasiyabileceginizden yuksek tutmak ise zararsiz, hatta faydali: istemci
alabildigini alir, gerisi atlanir. `framesSkipped` sayisinin yuksek olmasi hata
degil, geri baskinin calistiginin isaretidir - kareler kuyruklanmadigi icin
goruntu gecikmeli degil yalnizca seyrek olur.

## Sonuc: iPad 2 uzerinde olculen son durum

Cihazin kendi olctugu degerler (`/` sayfasindaki serit), 1024x768, kalite 0.95:

| | Ilk calisan surum (MJPEG) | Son durum (delta) |
|---|---|---|
| iPad'in aldigi | 4.8 fps | **42 fps** |
| Aktarim | 8.3 Mbit/s | **0.90 Mbit/s** |
| Kalite | 0.6 | **0.95** |
| iPad'de cizim suresi | - | 10 ms/kare |
| Istemci kuyrugu | - | 0 |
| Baglanti tavaninin kullanimi | %55 | **%6** |

Yani 9 kat kare hizi, 9 kat az bant genisligi, ustelik daha yuksek kalitede.

## Iki yayin modu

| Adres | Yol | Kullanim |
|---|---|---|
| `/` (ve `/delta`) | Sadece degisen dikdortgenler, WebSocket + canvas | **Varsayilan.** Ayni kalitede cok daha az bant genisligi ve cok daha yuksek kare hizi |
| `/mjpeg` | Tam kare MJPEG, `<img>` icinde | Yedek yol: WebSocket, canvas ya da JS gerektirmez, delta'nin calismadigi yerde calisir |

Delta modunda ekran 32px'lik karolarla onceki kareyle karsilastirilir, degisen
karolar birkac buyuk dikdortgene birlestirilir ve yalnizca onlar JPEG'lenip
gonderilir. Ekranin yarisindan fazlasi degistiyse tek bir tam kare gondermek daha
ucuz oldugu icin keyframe'e dusulur.

Uyarlanabilir kalite ve kademeli tazeleme devreye girmeden once, sabit yuksek
kalitede gercek kullanimda olculen tablo suydu: kareler icinde keyframe orani
%5, ama **toplam baytin %60'i**. Ortalama keyframe 270 KB, ortalama delta 10 KB.
Duzeltmelerden sonra ayni testte keyframe 66 KB'ye, delta 2.5 KB'ye, esik
asimindan kaynaklanan keyframe sayisi 72'den 0'a dustu.

Ayni makinede, ayni kalitede (0.6) olculdu:

| | `/` (MJPEG) | `/delta` |
|---|---|---|
| Hareketsiz ekran | ~0 | 0 |
| Imlec hareketi | 8.3 Mbit/s | **1.1 Mbit/s** |
| Teslim | 6.8 fps | ~72 bolge/sn (≈30 fps) |
| Ortalama gonderim | 158 KB/kare | 1.9 KB/bolge (ekranin %0.9'u) |

Delta modunun tasarimini eski iPad belirledi:

- **Kare basina tek goruntu.** Degisen dikdortgenler tek bir JPEG'e dikey olarak
  paketlenir (atlas), istemci bir kez cozer ve her bolgeyi ucuz, senkron bir
  `drawImage` ile yerine blitler. Ilk surumde her bolge ayri bir goruntuydu; bu,
  bolge basina bir Blob -> objectURL -> Image -> decode turu demekti ve iOS 9'da
  her tur 10-20 ms tutuyor. Saniyede onlarca bolgede istemci geri kaliyor,
  goruntu farenin arkasinda suruklenmeye basliyordu - sunucu ise hicbir geri
  baski gormuyordu, cunku Safari soketi kendi tamponuna bosaltmaya devam ediyor.
- **Kuyruk kisa tutulur (en fazla 3 kare).** Kuyrukta bekleyen sey zaten bayat
  goruntudur; uzun kuyruk dogrudan gecikme demektir. Tasarken kuyruk atilir ve
  baglanti yenilenir, bu da sunucudan taze bir tam kare getirir.
- **Hicbir guncelleme atlanamaz.** Kacirilan bir guncelleme, bir sonraki
  keyframe'e kadar ekranda bayat bir dikdortgen birakir. Yetisemeyen istemci bu
  yuzden yarim guncelleme almak yerine tamamen atlanir.
- **Kalite hareketle birlikte otomatik ayarlanir.** Ekranin buyuk bolumu
  degisirken kalite dusurulur; detay zaten hareketle bulaniyor, ama 270 KB'lik
  bir tam kare gondermek istemciyi geride birakiyor. Ekran durulunca, bosta
  kalan bant genisligi kullanilarak dusuk kalitede gonderilmis karolar kare kare
  tazelenir ve goruntu bir saniyeden kisa surede eski keskinligine doner.
- **Istemci bozuldugunda baglantiyi kapatmaz, acik soketten tazeleme ister.**
  Onceki hali yeniden baglaniyordu ve bu bir dongu uretiyordu: yeniden baglanmak
  keyframe istiyor, keyframe kuyrugu tasiriyor, tasan kuyruk yeniden
  baglaniyordu.
- **Keyframe istegi zaman esikli, "bekleyen istek" kilidi degil.** Kilit bir
  cikmaza giriyor: beklenen keyframe istemciye ulasamazsa (geldigi anda istemci
  hala mesgulse) kilit hic acilmiyor, istemci sonsuza kadar sessizce atlaniyor
  ve ekran donuyor. Belirti sinsi: sunucu kare uretmeye devam eder, atlanan
  sayaci bile artmaz. Simdi istek en fazla 0.75 saniyede bir tekrarlanabiliyor,
  yani kurtulus her zaman mumkun.
- **Tamamlanmayan gonderim icin saat var.** Bir gonderim 5 saniyede bitmezse
  baglanti dusurulur; istemci yeniden baglanir, donmus goruntuye bakmaz.
- **Geri kalan istemci tek bir keyframe ister, her karede degil.** Keyframe bir
  delta'nin on katidir; her karede istemek, zaten zorlanan istemciyi bogar.
  Olcumde bu hata 145 karede 17 keyframe ve 6.45 Mbit/s uretiyordu; duzeltince
  3 keyframe ve 1.27 Mbit/s'e dustu.

## Erisim anahtari

Port'a ulasabilen herkes ekrani izleyebilir ve - dokunma girisi geldiginden beri
- fareyi surebilir. Bu yuzden her yol bir anahtarin arkasinda.

Adres kisa: `http://192.168.0.x:8777`. Sirri adrese yazmiyorsunuz - sayfa alti
haneli bir kod soruyor ve iOS o alan icin sayi klavyesi aciyor. Uzun bir anahtari
eski bir iPad'in URL cubuguna yazmak eziyet oldugu icin boyle.

Kod dogrulaninca sunucu bir cerez verir; sonraki istekler - sayfa, akis,
WebSocket - o cerezle gecer, yani kodu bir kez girersiniz. Ana ekran kisayolu da
kisa adresi tasidigi icin sonrasinda dogrudan acilir.

Kod alti hane, yani kucuk bir uzay: her yanlis deneme gecikmeyle cezalandirilir
ve 20 yanlistan sonra kod kendiliginden degisir. Kaba kuvvet o noktada yeni bir
koda ihtiyac duyar, onu da yalnizca Mac'in basindaki kisi gorebilir. Uzun anahtar
hala `?k=...` ile de kullanilabilir.

Bu sekli iOS 9 dayatti: Safari'nin o surumunde fetch yok, modern kripto yok ve
JavaScript bir WebSocket el sikismasina baslik ekleyemiyor. Cerez ise var ve
tarayici onu ayni kaynakli WebSocket yukseltmelerine kendisi ekliyor.

Menuden **Yeni erisim anahtari uret** ile anahtar degistirilebilir; o an bagli
cihazlar duser ve kisayollarin yenilenmesi gerekir. Guvendiginiz bir agda
tamamen kapatmak icin `--no-auth`.

### Cihaz onayi

Anahtar "bu istemci sirri biliyor mu" sorusunu cevaplar. "Bu benim cihazim mi"
sorusunu cevaplamaz - ve dokunma girisi geldiginden beri asil onemli soru bu.

**Kodu dogru giren cihaz dogrudan iceri alinir** - sir o anda dogrulanmistir,
ayni seyi bir de Mac'te onaylatmak guvenlik degil surtunme olurdu.

Onay penetsi, asil tasarlandigi durum icin duruyor: elinde gecerli bir cerezle
gelen ama hic kod girmemis bir cihaz. Boyle bir cihaz "Mac'te onay bekleniyor"
sayfasini gorur ve ekrani ancak siz **Izin Ver** dedikten sonra alir. Kararlar
hatirlanir; menuden **Cihaz izinlerini sil** ile sifirlanir.

Cihaz, kendisine verilen rastgele bir cerez kimligiyle hatirlanir. Bu bir kimlik
degil bir yetkidir - ama anahtar ve insan onayiyla birlestiginde sizdirilmis bir
anahtarin tek basina ise yaramamasini saglar.

**Neden iCloud hesabi eslestirilmiyor:** Safari bir web sayfasina Apple ID
hakkinda hicbir sey vermiyor, ve CloudKit uzerinden hesap eslestirmek native bir
uygulama gerektiriyor - o da iOS 15+ demek. Bu iPad iOS 9'da, yani o yol kapali.
Mac'te insan onayi, ayni amaci bu kisitlar altinda daha iyi karsiliyor.

**Bunun ne oldugu konusunda net olalim:** duz HTTP uzerinde, yerel agda paylasilan
bir sir. Adresi bilen birini durdurur. Ag trafiginizi okuyabilen birini
durdurmaz, cunku hem anahtar hem ekran goruntusu sifresiz gider. Bunu TLS
cozerdi, ama iOS 9'da kendinden imzali sertifika kurmanin bedeli bu isin
getirisinden buyuk.

## Dokunma girisi

iPad'deki tek parmak Mac'in imlecini surer: dokunmak tiklar, kaydirmak surukler.
Uc parmakla dokunmak ustteki bilgi seridini acip kapatir - tek parmak artik giris
oldugu icin serit oraya tasindi.

Koordinatlar acik olan ayni WebSocket uzerinden metin olarak doner
(`D`/`M`/`U` + x + y), sanal ekranin kendi piksel uzayinda. Sunucu bunlari
ekranin global duzendeki konumuyla toplayip `CGEvent` olarak gonderir. Konum her
seferinde yeniden okunur, cunku ekrani menuden tasiyabiliyorsunuz.

**Erisilebilirlik izni gerekir.** Izin yoksa macOS gonderilen olaylari sessizce
yutar, yani uygulama bozuk gorunur ama hata vermez. Bu yuzden ilk calistirmada
izin istenir ve eksikse menu cubugunda "Dokunma girisi icin Erisilebilirlik
iznini ac..." satiri belirir. Durumu `/info` icindeki `input.permitted`
alanindan da gorebilirsiniz.

Sadece goruntu isteyenler icin `--no-input`.

Iki ince nokta:

- **Hareket mesajlari ~60/sn ile sinirlanir.** Mac zaten yakalama hizindan
  fazlasini kullanamiyor ve her mesajin bedelini iPad oduyor.
- **Baglanti parmak basiliyken koparsa dugme birakilir.** Aksi halde Mac'te
  basili kalmis bir fare dugmesiyle kalirdiniz.

## Bilinen sinirlar

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
