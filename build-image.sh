#!/bin/bash
set -e

# ============================================================
# Build Armbian Trixie Image with WiFi Driver Injected
# Target: B860H / HG680P (Amlogic S905X)
# Kernel: 6.12.112-ophub
# ============================================================

OPHUB_URL="https://github.com/ophub/amlogic-s9xxx-armbian/releases/download/Armbian_trixie_arm64_server_2026.10"
BASE_IMAGE="Armbian_26.11.0_amlogic_s905l-mg101_trixie_6.12.111_server_2026.10.01.img.gz"
DRIVER_URL="https://github.com/monw/amlogic-s9xxx-armbian/releases/download/Armbian_trixie_b860av11t_2026.10/8189fs-6.12.111-ophub.ko"
QUICK_INSTALL_URL="https://raw.githubusercontent.com/jhopan/Armbian-Wifi-on/main/quick-install.sh"
KVER="6.12.111-ophub"

echo "=========================================================="
echo "  Build Armbian Trixie WiFi-ON Image"
echo "  Kernel: ${KVER}"
echo "=========================================================="

# 1. Install dependencies
echo "[1/7] Installing dependencies..."
apt-get update -qq
apt-get install -y -qq wget gzip parted

# 2. Download base image
echo "[2/7] Downloading base image..."
wget -q "${OPHUB_URL}/${BASE_IMAGE}" -O armbian-base.img.gz
echo "  Downloaded: $(ls -lh armbian-base.img.gz | awk '{print $5}')"

# 3. Download driver
echo "[3/7] Downloading WiFi driver..."
wget -q "${DRIVER_URL}" -O 8189fs.ko
echo "  Downloaded: 8189fs.ko ($(ls -lh 8189fs.ko | awk '{print $5}'))"

# 4. Download quick-install script
echo "[4/7] Downloading quick-install script..."
wget -q "${QUICK_INSTALL_URL}" -O quick-install-v2.sh

# 5. Decompress image
echo "[5/7] Decompressing image..."
gunzip -f armbian-base.img.gz
IMG_FILE="armbian-base.img"
echo "  Decompressed: $(ls -lh ${IMG_FILE} | awk '{print $5}')"

# 6. Setup loop device and mount
echo "[6/7] Mounting image partitions..."
LOOP_DEV=$(losetup -P -f --show "${IMG_FILE}")
echo "  Loop device: ${LOOP_DEV}"

# Cari partisi rootfs (biasanya p2)
ROOTFS_PART="${LOOP_DEV}p2"
mkdir -p /mnt/armbian
mount "${ROOTFS_PART}" /mnt/armbian

# Mount boot partition juga
BOOT_PART="${LOOP_DEV}p1"
mkdir -p /mnt/armbian/boot
mount "${BOOT_PART}" /mnt/armbian/boot

# 7. Inject driver
echo "[7/7] Injecting driver and locking kernel..."

# Buat direktori tujuan
mkdir -p "/mnt/armbian/lib/modules/${KVER}/kernel/drivers/net/wireless/realtek/rtl8189fs"

# Copy driver
cp 8189fs.ko "/mnt/armbian/lib/modules/${KVER}/kernel/drivers/net/wireless/realtek/rtl8189fs/8189fs.ko"

# Auto-load config
echo "8189fs" > "/mnt/armbian/etc/modules-load.d/8189fs.conf"

# quick-install script ke /root/
cp quick-install-v2.sh "/mnt/armbian/root/quick-install.sh"
chmod +x "/mnt/armbian/root/quick-install.sh"

# Catatan: Tidak bisa langsung jalankan apt-mark hold karena loop mount
# Gunakan hook first-boot untuk hold kernel dan depmod
cat > "/mnt/armbian/root/first-boot-fixup.sh" << 'FIRSTBOOT'
#!/bin/bash
# Hold kernel packages agar tidak auto-update
apt-mark hold linux-image-* linux-headers-* linux-dtb-* 2>/dev/null || true
# Regenerate module dependencies
depmod -a
# Hapus script ini setelah jalan
rm -f /root/first-boot-fixup.sh
# Disable auto-update kernel ophub
systemctl mask armbian-flexidoor.service 2>/dev/null || true
FIRSTBOOT
chmod +x "/mnt/armbian/root/first-boot-fixup.sh"

# Buat systemd service untuk first-boot-fixup
cat > "/mnt/armbian/etc/systemd/system/wifion-firstboot.service" << 'SVC'
[Unit]
Description=WiFi-ON First Boot Fixup
After=network.target

[Service]
Type=oneshot
ExecStart=/root/first-boot-fixup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVC

# Enable service dengan symlink
mkdir -p "/mnt/armbian/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/wifion-firstboot.service "/mnt/armbian/etc/systemd/system/multi-user.target.wants/wifion-firstboot.service"

# Catatan untuk users
echo ""
echo "=========================================================="
echo "  Image siap! Compressing..."
echo "=========================================================="

# Buat file panduan DTB di /root/
cat > "/mnt/armbian/root/README-WifiON.txt" << 'GUIDE'
==========================================================
  CARA GANTI DTB UNTUK STB BERBEDA (B860H / HG680P)
==========================================================

Image ini defaultnya untuk B860H.
Jika Anda menggunakan HG680P, ikuti langkah berikut:

[ WINDOWS / SEBELUM FLASH ]
1. Flash image ke SD card
2. Buka partisi BOOT (FAT32) di Windows Explorer
3. Edit file uEnv.txt dengan Notepad
4. Ganti baris FDT:
   DARI: FDT=/dtb/amlogic/meson-gxl-s905x-b860h.dtb
   JADI: FDT=/dtb/amlogic/meson-gxl-s905x-p212.dtb
5. Simpan, eject SD card, colok ke HG680P

[ LINUX / SETELAH BOOT ]
Jika STB sudah booting tapi layar hitam / tidak muncul apa-apa,
kemungkinan DTB salah. Edit dari PC:
1. Cabut SD card, colok ke PC
2. Edit /boot/uEnv.txt di partisi FAT32
3. Ganti FDT=/dtb/amlogic/meson-gxl-s905x-b860h.dtb
   JADI FDT=/dtb/amlogic/meson-gxl-s905x-p212.dtb
4. Simpan, colok lagi ke STB

==========================================================
  RINGKASAN DTB
==========================================================
  B860H  → FDT=/dtb/amlogic/meson-gxl-s905x-b860h.dtb
  HG680P → FDT=/dtb/amlogic/meson-gxl-s905x-p212.dtb
==========================================================
GUIDE

# Unmount
sync
umount /mnt/armbian/boot 2>/dev/null || true
umount /mnt/armbian 2>/dev/null || true
losetup -d "${LOOP_DEV}" 2>/dev/null || true

# Rename dan compress
mv "${IMG_FILE}" "Armbian-Trixie-6.12.112-WifiON-MG101.img"
gzip -9 "Armbian-Trixie-6.12.112-WifiON-MG101.img"

echo "Done!"
ls -lh "Armbian-Trixie-6.12.112-WifiON-MG101.img.gz"
