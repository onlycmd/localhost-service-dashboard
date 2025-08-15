# Localhost Service Dashboard (LSD)

A tiny, colorful, interactive terminal dashboard for your local machine — Renkli, küçük ve etkileşimli bir terminal kontrol paneli.
Lists listening services (ports, PIDs) and lets you manage them — Dinleyen servisleri (portlar, PID'ler) listeler ve yönetmenizi sağlar.

## Features — Özellikler
- Colorful, auto-sized table (port, proto, type, process, PID, user, command) — Renkli, otomatik boyutlanan tablo (port, protokol, tür, süreç, PID, kullanıcı, komut)
- Smart service-type detection (HTTP/HTTPS/DB/Infra) — Akıllı servis türü tespiti (HTTP/HTTPS/DB/Altyapı)
- Interactive menu: kill by PID/port, start background command, filter, toggle UDP, change interval, details — Etkileşimli menü: PID/port ile sonlandır, arka planda komut başlat, filtrele, UDP aç/kapat, yenileme süresi, detaylar
- Works with lsof, ss or netstat (fallbacks) — lsof, ss veya netstat ile çalışır (yedekli)
- Minimal deps, zero daemon overhead — Minimum bağımlılık, ek servis yükü yok

## Requirements — Gereksinimler
- Bash 4+
- One of: lsof, ss (iproute2), or netstat (net-tools) — Bunlardan biri: lsof, ss (iproute2) veya netstat (net-tools)
- Common tools: awk, grep, ps, tput, nohup — Yaygın araçlar: awk, grep, ps, tput, nohup
- Linux or macOS (Windows via WSL) — Linux veya macOS (Windows için WSL)

## Installation — Kurulum
Clone or copy the script, then make it executable — Betiği kopyalayın ve çalıştırılabilir yapın:
```bash
chmod +x localhost_service_dashboard.sh
```
Optionally put it on PATH — İsteğe bağlı olarak PATH'e alın:
```bash
sudo mv localhost_service_dashboard.sh /usr/local/bin/lsd && chmod +x /usr/local/bin/lsd
```

## Quick Start — Hızlı Başlangıç
```bash
./localhost_service_dashboard.sh
```
If installed on PATH — PATH'e kuruluysa:
```bash
lsd
```

## Keyboard Shortcuts — Klavye Kısayolları
- k: Kill by PID — PID ile sonlandır
- p: Kill by Port — Port ile sonlandır
- s: Start command in background — Komutu arka planda başlat (loglar: /tmp/lsd-logs)
- f: Set/clear filter — Filtre ayarla/temizle
- u: Toggle UDP — UDP aç/kapat
- t: Set refresh interval — Yenileme süresi
- d: Show details — Detayları göster
- r: Refresh — Yenile
- q: Quit — Çık

## Configuration (Env Vars) — Yapılandırma (Ortam Değişkenleri)
- REFRESH_INTERVAL_SECONDS: refresh rate (default: 2) — yenileme süresi (varsayılan: 2)
- SHOW_UDP: show UDP sockets (0/1; default: 0) — UDP soketleri (0/1; varsayılan: 0)
- NO_COLOR: disable colors if set — renkleri kapatır
- LSD_LOG_DIR: background logs directory (default: /tmp/lsd-logs) — arka plan log dizini

Example — Örnek:
```bash
REFRESH_INTERVAL_SECONDS=1 SHOW_UDP=1 LSD_LOG_DIR=/tmp/lsd-logs ./localhost_service_dashboard.sh
```

## Service Detection — Servis Tespiti
Heuristics for ports and process names — Port ve süreç adına göre sezgisel eşleme:
- HTTP-ish — HTTP benzeri: 80, 8080, 8000, 8008, 8081, 8888, 5000, 3000, 3001, 3002, 5173, 4200; nginx/apache/httpd, node, python (uvicorn/gunicorn), java (tomcat/jetty)
- HTTPS: 443
- DB/Infra — Veritabanı/Altyapı: MySQL/MariaDB (3306), PostgreSQL (5432), MongoDB (27017), Redis (6379), Memcached (11211), Elasticsearch (9200/9300), RabbitMQ (5672/15672), Cassandra (9042), MSSQL (1433), Oracle (1521)

## Platform Notes — Platform Notları
- Linux/macOS: fully supported — tam destek
- Windows: use WSL (Ubuntu/Debian) — Windows için WSL önerilir (Ubuntu/Debian). Git Bash sınırlı olabilir.

### Install Dependencies — Bağımlılık Kurulumu
Debian/Ubuntu:
```bash
sudo apt update
sudo apt install -y lsof iproute2 net-tools
```
Fedora/RHEL/CentOS:
```bash
sudo dnf install -y lsof iproute
sudo dnf install -y net-tools # optional
```
macOS (Homebrew):
```bash
brew install lsof iproute2mac # ss alternative
brew install net-tools        # optional, for netstat
```

## Logging & Background Jobs — Loglama ve Arka Plan İşleri
- Starting via key 's' runs the command detached — 's' ile başlatma, komutu terminalden ayırır.
- Logs go to LSD_LOG_DIR (default /tmp/lsd-logs) — Loglar LSD_LOG_DIR'e yazılır (varsayılan /tmp/lsd-logs).
- Files: `cmd-YYYYMMDD-HHMMSS.out` and `.err` — İki dosya olarak yazılır: `.out` ve `.err`.

## Permissions & Security — İzinler ve Güvenlik
- You may need sudo to see all PIDs — Tüm PID'leri görmek için sudo gerekebilir.
- Kill escalates if gentle signal fails — Kapatma önce nazik, sonra gerekirse zorlayıcı sinyal gönderir.
- Be careful when terminating processes — Süreç sonlandırırken dikkatli olun.

## Troubleshooting — Sorun Giderme
- "lsof/ss/netstat not found": install one — Yüklü değilse birini kurun (yukarıya bakın).
- Missing PIDs/Permission denied: try sudo — PID yoksa/izin hatası: sudo ile deneyin.
- Colors odd: set `NO_COLOR=1` — Renkler bozuksa `NO_COLOR=1`.
- Narrow terminal: widen window — Terminal darsa pencereyi genişletin.

## Why LSD? — Neden LSD?
Quick view of listening services and control without heavy tooling — Dinleyen servisleri hızlıca görüp yönetmek için hafif bir araç.

## Contributing — Katkı
Issues and PRs are welcome — Hata bildirimleri ve PR'lar kabul edilir.

## License — Lisans
MIT License — MIT Lisansı.
