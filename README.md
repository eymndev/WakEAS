# WakEAS

Gözlerin kapanınca çalışan, iPhone ve Mac için bir uyanma alarmı.

Ön kamera yüzü izler. Gözler seçilen süre boyunca kapalı kalırsa alarm açılır. Alarm yalnızca ekrandaki **×** ile durur.

## Alarm

- ABD EAS tarzı 853 Hz + 960 Hz dikkat tonu
- Japon tarzı sentetik ikaz
- Apple Music kitaplığından seçilen parça
- Sarı, siyah veya kırmızı ikaz ekranı
- Açılış, uyarı ve kapanış için ayrı TTS metni ve dili

Parça seçildiğinde müzik alarm boyunca çalar. iPhone’da konuşma sırasında müzik durmaz, sesi kısılır.

## Mac ve iPhone

Ayarlardan bağlantıyı aç. Mac yakındaki iPhone’u bulur; iPhone daveti kabul eder. Her iki uygulamanın da açık kalması gerekir. Mac alarmı başlayınca iPhone bildirim ve ikaz ekranı gösterir. Bildirim sesi ABD EAS tarzı iki tonu kullanır.

## Derleme

```sh
xcodebuild -project WakEAS.xcodeproj -scheme WakEAS -destination 'generic/platform=macOS' build
xcodebuild -project WakEAS.xcodeproj -scheme WakEAS -destination 'generic/platform=iOS Simulator' build
```

Apple Music’in gerçek cihazda çalması için App ID’de MusicKit hizmeti açık olmalıdır.
