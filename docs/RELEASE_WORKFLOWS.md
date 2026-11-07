# FIYORA — Tiga workflow rilis manual

Definisi workflow tersedia di default branch `main` agar muncul di GitHub Actions. Workflow `beta.yml` juga tersedia di `apk-beta` supaya **eksekusi Beta benar-benar berjalan dari branch `apk-beta`**, bukan dari `main`. Ketiganya hanya memiliki pemicu `workflow_dispatch`, sehingga commit tidak otomatis menerbitkan GitHub Release. Buka **Actions → pilih workflow → Run workflow** dan gunakan branch sesuai tabel. Workflow `build.yml` pada `main` hanya memvalidasi perubahan dan tidak menerbitkan APK.

| Workflow di Actions | Pilih branch saat Run workflow | Source yang dibuild | Hasil |
|---|---|---|---|
| `main` (`.github/workflows/main.yml`) | `main` | HEAD `main` saat dispatch | Fiyora stable **draft**, perlu uji kandidat dan publish manual |
| `beta` (`.github/workflows/beta.yml`) | `apk-beta` | commit `apk-beta` yang di-dispatch | Fiyora preview ARM64, **prerelease manual** |
| `apk-build` (`.github/workflows/apk-build.yml`) | `main` | snapshot NFile original `00dcc955bbb0af0c0b0d963f644e6980d1ed67e5` | NFile original ABI-split, **prerelease manual** |

## Menghilangkan auto-build beta lama

Workflow legacy `.github/workflows/apk-build.yml` pada `apk-beta` sudah tidak ada di HEAD branch yang diverifikasi. Workflow bernama sama pada `main` adalah workflow NFile original yang dijalankan manual. **Branch `apk-build` tidak diubah.**

## Signing

- Beta: `MRARE_KEYSTORE_BASE64`, `MRARE_KEY_ALIAS`, `MRARE_KEY_PASSWORD`, `MRARE_STORE_PASSWORD` (nama legacy dipertahankan).
- Stable & original: `KEYSTORE_BASE64`, `KEY_ALIAS`, `KEY_PASSWORD`, `STORE_PASSWORD`.
- Semua job gagal jika secret signing tidak ada, dan memverifikasi identitas APK serta checksum. Keystore tidak masuk ke Git.

## Proses rilis

1. Edit dan commit pada `apk-beta`. Buka Actions → `beta` → Run workflow, **pilih branch `apk-beta`** (bukan `main`). Workflow checkout commit yang di-dispatch, verifikasi package `com.noirero.fiyora.preview`, build, signing, checksum, dan menerbitkan GitHub prerelease dengan tag yang menunjuk commit beta tersebut. Uji APK tersebut di perangkat.
2. Setelah uji beta disetujui, review perubahan dan promosikan source beta teruji menuju `main`. Pastikan identitas produksi dan branding sesuai sebelum merge; jangan memindahkan `applicationId` beta ke stable tanpa review.
3. Jalankan `main` manual, masukkan **tag prerelease beta yang diuji**, lalu centang **device_test_approved**. CI memverifikasi tag, keberhasilan workflow beta manual, riwayat commit beta ke main, identitas stable, dan tidak adanya tag stable duplikat.
4. Workflow menghasilkan APK stable bertanda tangan, checksum, serta GitHub Release **draft**. Uji **APK stable candidate persis itu** di perangkat dan **publish draft secara manual** setelah lolos.
5. Untuk APK original, jalankan `apk-build` manual dari `main`. Workflow mengecek `apk-build` belum berubah dari commit frozen, lalu checkout langsung commit asli. Tidak menyentuh source NFile.

## Batasan yang perlu disadari

- Sekarang `main` masih berlabel NFile; PR rebranding #1 belum di-merge. Workflow stable sengaja menolak hingga `main` beridentitas Fiyora yang sah.
- Stable (`com.rubex.nfile`) dan NFile original (`com.rubex.nfile`) memakai package ID sama untuk menjaga kompatibilitas upgrade yang sudah ada; keduanya **tidak dapat hidup berdampingan** sebagai dua aplikasi. Beta (`com.noirero.fiyora.preview`) bisa dipasang berdampingan.
- Membiarkan original source tidak diubah **tidak menjamin APK hasil build byte-identical**, karena dependency, toolchain, signing, dan timestamp dapat berbeda.
- PR workflow #2 dan PR rebranding #1 sama-sama mengedit `build.yml`. Selesaikan konflik itu sebelum merge; masing-masing CI hijau bukan bukti integrasi keduanya.
- Jangan auto-merge, auto-publish draft stable atau mengubah branch original tanpa persetujuan pemilik.

## Kontrak pemilihan branch

- Menjalankan workflow `beta` dengan pilihan branch `main` **gagal sebelum checkout/build/publish**.
- Beta memakai `apk-beta` sebagai branch resmi untuk saat ini; nama `beta` pada menu Actions adalah **nama workflow**, bukan nama branch.
- GitHub prerelease disimpan pada tingkat repository, tetapi release tag dan `Source commit` harus menunjuk commit `apk-beta`, bukan `main`.
- Stable promotion menerima run Beta sukses dari branch `apk-beta` **dengan `head_sha` tepat sama** dengan beta tag. Legacy beta run yang dispatch-nya dari `main` tidak memenuhi gate baru dan harus diuji ulang dari workflow Beta baru sebelum promosi.
