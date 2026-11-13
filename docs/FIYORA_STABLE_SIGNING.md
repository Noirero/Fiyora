# FIYORA Stable — Keystore dan Candidate APK (manual)

**Identitas Android Stable:** `com.noirero.fiyora`. 
**Sertifikat signing produksi (SHA-256):** `dfcb5468d7e280befbe5ffdb0b4fe04cc0ced10810abb5c5fdc7a4dd48d02935`. Sidik jari publik ini dipatok pada kedua workflow Stable.

## GitHub repository secrets (empat nama khusus FIYORA)
Gunakan **Settings → Secrets and variables → Actions → Secrets → New repository secret** dan buat keempat nama berikut, satu per satu:

1. `FIYORA_STABLE_KEYSTORE_BASE64` — isi Base64 satu baris dari keystore JKS.
2. `FIYORA_STABLE_KEY_ALIAS` — alias kunci (keystore saat ini: `fiyora-stable`).
3. `FIYORA_STABLE_KEY_PASSWORD` — password private key.
4. `FIYORA_STABLE_STORE_PASSWORD` — password keystore.

**Nilai** disimpan oleh owner secara privat, tidak pernah disimpan di Git atau dokumentasi ini. Keempat repository secrets ini dipakai **hanya** untuk FIYORA Stable dan Stable Candidate. NFile Original tetap memakai `KEYSTORE_BASE64`, `KEY_ALIAS`, `KEY_PASSWORD`, `STORE_PASSWORD`; FIYORA Beta tetap memakai `MRARE_*`.

## Cara validasi tanpa rilis publik

1. **Actions → Fiyora Stable Candidate (manual) → Run workflow → main.**
2. Workflow memverifikasi commit `main`, `applicationId`, label aplikasi, menjalankan `flutter test`, membangun signed APK ABI-split menggunakan keystore produksi FIYORA, memverifikasi package ID + sertifikat, kemudian mengunggah APK dan obfuscation symbols sebagai **Actions artifacts**.
3. Download ZIP di halaman completed run → **Artifacts**. Uji APK di perangkat fisik. Catat run ID, commit SHA, versi, fingerprint signing, dan hasil tes.
4. **Jangan** menjalankan **Fiyora Stable (manual)** untuk pengujian: workflow itu akan memublikasikan public GitHub Release bila sukses dan hanya boleh dijalankan setelah perintah eksplisit owner.

## Keamanan / keterbatasan
- Keystore produksi hanya boleh disimpan di lokasi privat terenkripsi dan di-backup dengan aman. Base64 bukan enkripsi.
- Keystore harus dipertahankan untuk semua update APK `com.noirero.fiyora` berikutnya. Jika kehilangan atau mengganti key tanpa strategi migrasi, upgrade APK yang terpasang bisa gagal.
- Sertifikat fingerprint publik di workflow mencegah APK tertandatangani oleh kunci lain tanpa perubahan yang direview.
- CI PR menggunakan keystore sementara yang **bukan** production signing; hasil CI hijau tidak membuktikan konfigurasi secrets atau perangkat fisik.
- APK Candidate dan APK public release dibangun dalam run berbeda; hasilnya tidak dijamin byte-identical. Validasi dan release tetap harus memiliki SHA dan versi yang ditinjau.
- Jangan menaruh keystore, Base64 keystore, atau password di code, commit, PR, issue, atau log.
