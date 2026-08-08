# HP ProBook 4430s -- coreboot port (Ivy Bridge / Gen3 on HM65)

**Ringkasan (Indonesian):** Laptopmu saat ini mati (no POST) karena BIOS patch
microcode Ivy Bridge yang kita buat sebelumnya belum cukup — HM65 butuh mod
hardware (pin/tape mod di PCH 6-series) agar mau menjalankan CPU Ivy Bridge.
Dokumen ini berisi: (1) cara memulihkan laptop, (2) penjelasan mod HM65→IVB,
(3) hasil ekstraksi firmware EC KBC1126 (sudah divalidasi checksum), dan
(4) cara build + flash coreboot. Build TIDAK bisa dilakukan di mesin ini
(virtualisasi WSL dimatikan), jadi harus di-build di Linux/WSL2.

---

## 0. Status saat ini

| Item | Status |
|------|--------|
| EC firmware (KBC1126) `ec_fw1.bin` / `ec_fw2.bin` | **Sudah diekstrak & divalidasi** (SYSV checksum OK) |
| Variant `4430s` (file port) | **Sudah dibuat** (basis `hp/2560p`, 4 MB ROM) |
| Build coreboot | **Via GitHub Actions** (gratis, tanpa Linux — lihat §4b) |
| GPIO / VBT / subsystem ID / SPD | **Perkiraan awal** — perlu verifikasi boardview |
| Mod pin/tape HM65→IVB | **Wajib** untuk CPU Ivy Bridge |

---

## 1. Memulihkan laptop yang "brick" (PRIORITAS)

Kamu mem-flash `hp4430s_bios_IVB_patched.bin` dengan CPU Ivy Bridge → no boot.
Penyebab: microcode saja tidak cukup; chipset HM65 menolak CPU IVB tanpa mod
hardware. Untuk pulih:

**Opsi A — pasang kembali CPU Sandy Bridge (paling aman):**
1. Ganti CPU kembali ke Sandy Bridge (mis. i3-2310M bawaan).
2. Flash kembali backup asli dengan programmer SPI:
   `backup 4430s normal bios 28 7 2026.bin` (4 MB).
3. Laptop harus POST normal. Simpan backup ini sebagai recovery permanen.

**Opsi B — lakukan pin/tape mod HM65→IVB (lihat §2), lalu:**
1. Bisa flash coreboot (§4) ATAU backup asli (dengan microcode IVB via OS).
2. Tanpa mod ini, CPU Ivy Bridge tidak akan POST di HM65, apa pun BIOS-nya.

> JANGAN mem-flash ulang tanpa programmer SPI (CH341A + klip SOIC8). Tombol
> "Win+B" (HP Crisis Recovery) butuh file bertanda tangan HP, bukan image kita.

---

## 2. Mod HM65 → Ivy Bridge (wajib untuk CPU Gen3)

HM65 adalah PCH 6-series (Cougar Point) yang resminya hanya untuk Sandy Bridge.
Agar mau menjalankan Ivy Bridge (Gen3, CPUID 0x306A9) diperlukan salah satu:

- **Pin/tape mod di socket CPU (rPGA988B / G2):** menutup/insulasi pin tertentu
  agar strapping CPU terbaca benar, atau
- **Resistor/strap mod di PCH:** mengubah ID chipset agar dilaporkan sebagai
  7-series (Panther Point).

Coreboot **tidak** menggantikan mod ini — MRC/coreboot tetap butuh chipset yang
"sudah" mengenali CPU IVB. Setelah mod dilakukan, coreboot menangani sisanya
(microcode 306A9, training memori, inisialisasi EC) secara native.

Referensi yang biasa dipakai komunitas (cari "HM65 Ivy Bridge mod",
"6-series PCH Ivy Bridge pinmod", "T420 QM67 Ivy Bridge mod", "4x40s IVB mod"):
- ThinkPad T420 (QM67, 6-series) + Ivy Bridge quad-core = working di coreboot
  SETELAH pinmod.
- HP 4x40s / 6x40s series serupa dengan 4430s (HM65/HM67).
- Butuh **boardview/schematic 4430s** untuk titik solder yang tepat.

> Mod hardware berisiko. Pastikan punya programmer SPI dan backup sebelum menyolder.
> Jika ragu, Opsi A (CPU Sandy Bridge) adalah jalur paling aman.

---

## 3. Hasil ekstraksi firmware EC (KBC1126)

Dilakukan dengan menerapkan logika `util/kbc1126/kbc1126_ec_dump` di Python:
baca 8 byte pointer di `ROM_end - 0x100`, lalu ekstrak dua blob (`len` 2-byte +
`cksum` 2-byte + payload), validasi dengan SYSV checksum.

| Blob | Offset file (4 MB) | Ukuran | SYSV cksum |
|------|--------------------|--------|------------|
| `ec_fw1.bin` (FW1 / cfg) | `0x3FF700` | 2048 B (2044 payload) | `0x3EC1` ✅ |
| `ec_fw2.bin` (FW2 / rom) | `0x380000` | 64400 B (64396 payload) | `0x0EE5` ✅ |

Kedua checksum **valid** → ini adalah firmware EC asli HP, bukan tebakan.
File ada di `coreboot_board/3rdparty/blobs/mainboard/hp/4430s/`.
Field pointer `0xFFF700` / `0xF80000` sudah dimasukkan ke `Kconfig`
(`KBC1126_FW1_OFFSET` / `FW2_OFFSET`) sehingga coreboot menaruhnya di offset
file yang sama dengan firmware HP asli dan EC akan menemukannya.

Cara alternatif (di Linux, di dalam tree coreboot):
```sh
make -C util/kbc1126
util/kbc1126/kbc1126_ec_dump <backup_asli.bin>
# -> menghasilkan <backup>.fw1 / <backup>.fw2
```

---

## 4. Build di Linux / WSL2 (lokal)

Kalau kamu punya host Linux (native) atau WSL2 **dengan "Virtual Machine Platform"
aktif**, build di mesin sendiri:
- `git`, `gcc`/`g++`, `make`, `curl`, `python3`, `iasl`, `ncurses` (untuk nconfig).
- ~2–3 GB ruang + koneksi internet (submodule 3rdparty/blobs).

```sh
git clone <repo port ini> 4430s-port
cd 4430s-port/coreboot_board
chmod +x build_4430s.sh
CBDIR=$HOME/coreboot ./build_4430s.sh
```
Script akan: clone coreboot (tag `26.06`) → pasang variant `4430s` → daftarkan
di Kconfig → taruh EC blob → `make olddefconfig` → build crossgcc → build
`coreboot.rom`. Hasil: `build/coreboot.rom` (4 MB).

> Mesin persiapan ini TIDAK bisa compile (virtualisasi WSL dimatikan di firmware,
> dan tidak ada compiler). Pakai jalur §4b di bawah.

---

## 4b. Build TANPA Linux — GitHub Actions (gratis)  ← jalur untuk kamu

Kamu bilang "aku gak punya linux" dan "build di linux server kamu bisa gak?".
Jawabannya: saya tidak punya server sendiri, tapi **GitHub punya server Linux
gratis** (GitHub Actions) yang bisa kita pakai untuk compile. Kamu cuma perlu
buat repo kosong di GitHub, upload port ini, lalu download hasilnya.

**Langkah (semua di browser, tidak perlu install apa-apa):**

1. Buat repo baru di https://github.com/new — nama mis. `coreboot-4430s`,
   **biarkan kosong** (jangan centang README/.gitignore), visibility = Public
   (Private juga bisa, tapi Public gratis untuk Actions).
2. Di komputer kamu (Windows), buka folder port yang sudah saya siapkan:
   `work/4430s_bios/coreboot_board/`. Upload SEMUA isinya ke repo tadi
   (drag-drop di halaman repo GitHub, atau pakai GitHub Desktop).
   Pastikan struktur di repo jadi:
   ```
   .github/workflows/build.yml
   ci_build.sh
   build_4430s.sh
   4430s_defconfig
   README_COREBOOT_4430s.md
   src/mainboard/hp/snb_ivb_laptops/...
   3rdparty/blobs/mainboard/hp/4430s/...
   ```
3. Buka tab **Actions** di repo → pilih workflow "Build coreboot for HP ProBook
   4430s" → klik **Run workflow** (atau otomatis jalan saat push ke `main`).
4. Tunggu ~20–40 menit (build crossgcc + coreboot pertama kali paling lama).
   Lihat log kalau ada error.
5. Kalau hijau ✅, buka job → section **Artifacts** → download
   `coreboot-4430s` → dapat file `coreboot.rom` (4 MB).

File yang di-download ITULAH yang akan di-flash (lihat §5).

> Mau ganti versi coreboot? Set environment `COREBOOT_REF=25.12` saat jalanin,
> atau edit `COREBOOT_REF` di `ci_build.sh` (default `26.06`).

> **Catatan build (tag `26.06`):** SeaBIOS BUKAN submodule lagi di `26.06` — dia
> di-clone otomatis oleh `make` (`payloads/external/SeaBIOS/Makefile` menjalankan
> `git clone …/seabios.git`). Script `ci_build.sh` / `build_4430s.sh` sudah
> disesuaikan: hanya meng-init submodule `3rdparty/blobs`, `3rdparty/intel-microcode`,
> dan `3rdparty/libgfxinit`, lalu memakai mirror GitHub (`github.com/coreboot/seabios`)
> supaya clone SeaBIOS lebih handal di runner CI. Build gagal sebelumnya persis
> karena baris `git submodule update … payloads/seabios` (submodule itu sudah tiada).

---

## 5. Flash

Gunakan programmer SPI (CH341A + klip SOIC8). **Sangat penting:** image
`coreboot.rom` kita BELUM berisi Intel ME / IFD / GBE milik HP. HM65 (6-series)
butuh region ME untuk bisa POST, jadi **jangan flash seluruh 4 MB begitu saja**
pada percobaan pertama — bisa brick. Cara aman:

```sh
# 1) baca isi chip saat ini (ATAU pakai backup pabrik yang sudah kamu punya)
flashrom -p ch341a_spi -r current.bin

# 2) ekstrak region BIOS dari hasil build kita
ifdtool -x build/coreboot.rom            # -> bios.bin (region BIOS)

# 3) sisipkan region BIOS kita ke dalam dump HP (IFD/ME/GBE tetap milik HP)
cp current.bin toflash.bin
ifdtool -i bios:bios.bin toflash.bin     # (atau manual: dd region BIOS ke current.bin)

# 4) flash HANYA region BIOS
flashrom -p ch341a_spi -i bios -w toflash.bin
```

Alternatif lebih simpel tapi sedikit berisiko: flash seluruh 4 MB jika kamu
sudah yakin layout coreboot sudah menyertakan IFD+ME stub. Untuk first-boot,
**selalu pakai cara region BIOS** di atas dan simpan `current.bin` sebagai
recovery.

---

## 6. Yang masih harus diverifikasi (TODO)

Port ini adalah **first-pass scaffold** yang perlu iterasi di hardware:
1. **GPIO** (`gpio.c`) — diwariskan dari 2560p; 4430s punya layout beda.
   Pin yang salah bisa gagal POST / tidak ada layar. Ambil dari boardview 4430s.
2. **VBT** (`data.vbt`) — diwariskan dari 2560p; panel 4430s (LVDS) mungkin beda
   resolusi/backlight. Bisa diekstrak dari backup dengan UEFITool.
3. **Subsystem ID** — pakai `0x103c/0x1631` (perkiraan); verifikasi via DMI.
4. **SPD memori** — build memakai `hynix_4g` (warisan generic). Jika 4430s pakai
   SO-DIMM lain, ganti atau biarkan native raminit baca dari DIMM.
5. **Pin/tape mod HM65→IVB** — lihat §2, wajib untuk CPU Gen3.
6. **Payload** — default SeaBIOS; ganti `CONFIG_PAYLOAD_EDK2` untuk UEFI/Windows.

---

## 7. Manifest file

```
coreboot_board/
├── ci_build.sh                         # build script untuk GitHub Actions / Linux
├── build_4430s.sh                      # build script lokal (Linux/WSL)
├── 4430s_defconfig                     # coreboot .config
├── README_COREBOOT_4430s.md            # dokumen ini
├── .github/workflows/build.yml         # GitHub Actions: build + upload artifact
├── src/mainboard/hp/snb_ivb_laptops/
│   ├── Kconfig                         # (MODIFIKASI) + entri 4430s + EC offset
│   ├── Kconfig.name                    # (MODIFIKASI) + "ProBook 4430s"
│   └── variants/4430s/
│       ├── board_info.txt
│       ├── early_init.c                # init EC KBC1126
│       ├── gpio.c                      # PERKIRAAN (dari 2560p)
│       ├── hda_verb.c                  # PERKIRAAN (codec IDT)
│       ├── gma-mainboard.ads           # libgfxinit: LVDS + DP1/HDMI1/Analog
│       ├── overridetree.cb             # device tree (HM65 / bd82x6x)
│       └── data.vbt                    # PERKIRAAN (dari 2560p)
└── 3rdparty/blobs/mainboard/hp/4430s/
    ├── ec_fw1.bin                      # EC FW1 (2 KB)  -- divalidasi
    └── ec_fw2.bin                      # EC FW2 (63 KB) -- divalidasi
```
