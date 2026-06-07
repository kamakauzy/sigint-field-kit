#!/usr/bin/env bash
#
# KrakenSDR Pi SD Card Prep
#
# Run this BEFORE first boot on a freshly flashed Raspberry Pi OS SD card.
# Mount the boot and rootfs partitions, then run:
#
#   sudo ./prep_pi_sdcard.sh /media/you/bootfs /media/you/rootfs
#
# What it does:
#   1. Enables SSH on first boot
#   2. Sets static IP 192.168.1.120 on eth0
#   3. Configures USB max current for KrakenSDR (Pi 4 only)
#   4. Sets hostname to "kraken-pi"
#   5. Creates a firstboot script that sets timezone + expands filesystem
#
# After prep: eject card → insert in Pi → boot → SSH to pi@192.168.1.120
# Then run: install_kraken_pi.sh
#
set -euo pipefail

usage() {
    echo "Usage: sudo $0 <boot_partition> <rootfs_partition>"
    echo ""
    echo "  boot_partition:  mounted boot/bootfs partition (contains config.txt)"
    echo "  rootfs_partition: mounted rootfs partition (contains etc/)"
    echo ""
    echo "On Linux after inserting SD card:"
    echo "  lsblk                          # find partitions"
    echo "  sudo mount /dev/sdb1 /mnt/boot"
    echo "  sudo mount /dev/sdb2 /mnt/root"
    echo "  sudo $0 /mnt/boot /mnt/root"
    echo ""
    echo "On Windows (WSL):"
    echo "  Mount SD card partitions in WSL or use this as a reference"
    echo "  for manual edits on the SD card."
    exit 1
}

[[ $# -lt 2 ]] && usage
BOOT="$1"
ROOT="$2"

# Validate paths
[[ ! -d "$BOOT" ]] && echo "[ERROR] Boot partition not found: $BOOT" && exit 1
[[ ! -d "$ROOT" ]] && echo "[ERROR] Root partition not found: $ROOT" && exit 1

# Check for config.txt to confirm it's really the boot partition
if [[ ! -f "$BOOT/config.txt" ]] && [[ ! -f "$BOOT/firmware/config.txt" ]]; then
    echo "[WARN] config.txt not found in $BOOT — are you sure this is the boot partition?"
    read -rp "Continue anyway? [y/N] " ans
    [[ "$ans" != "y" && "$ans" != "Y" ]] && exit 1
fi

CONFIG_TXT="$BOOT/config.txt"
[[ -f "$BOOT/firmware/config.txt" ]] && CONFIG_TXT="$BOOT/firmware/config.txt"

echo "═══ KrakenSDR Pi SD Card Prep ═══"
echo "  Boot: $BOOT"
echo "  Root: $ROOT"
echo ""

# 1. Enable SSH
echo "[1/5] Enabling SSH..."
touch "$BOOT/ssh"
echo "  Created $BOOT/ssh"

# 2. Static IP for eth0
echo "[2/5] Setting static IP 192.168.1.120..."
DHCPCD_CONF="$ROOT/etc/dhcpcd.conf"
if [[ -f "$DHCPCD_CONF" ]]; then
    # Append static config if not already present
    if ! grep -q "interface eth0" "$DHCPCD_CONF" 2>/dev/null; then
        cat >> "$DHCPCD_CONF" << 'DHCP_EOF'

# KrakenSDR static IP — added by prep_pi_sdcard.sh
interface eth0
static ip_address=192.168.1.120/24
static routers=192.168.1.1
static domain_name_servers=192.168.1.1 8.8.8.8
DHCP_EOF
        echo "  Appended static IP config to dhcpcd.conf"
    else
        echo "  Static IP already configured in dhcpcd.conf"
    fi
else
    # Newer Pi OS uses NetworkManager; create a connection file
    NM_DIR="$ROOT/etc/NetworkManager/system-connections"
    if [[ -d "$ROOT/etc/NetworkManager" ]]; then
        mkdir -p "$NM_DIR"
        cat > "$NM_DIR/eth0-static.nmconnection" << 'NM_EOF'
[connection]
id=eth0-static
type=ethernet
interface-name=eth0
autoconnect=true

[ipv4]
method=manual
address1=192.168.1.120/24,192.168.1.1
dns=192.168.1.1;8.8.8.8;

[ipv6]
method=auto
NM_EOF
        chmod 600 "$NM_DIR/eth0-static.nmconnection"
        echo "  Created NetworkManager connection file"
    else
        echo "  [WARN] Neither dhcpcd.conf nor NetworkManager found."
        echo "         You'll need to set static IP manually after first boot."
    fi
fi

# 3. USB max current (KrakenSDR draws >600mA)
echo "[3/5] Enabling USB max current for KrakenSDR..."
if ! grep -q "max_usb_current=1" "$CONFIG_TXT" 2>/dev/null; then
    echo "" >> "$CONFIG_TXT"
    echo "# KrakenSDR: enable max USB current" >> "$CONFIG_TXT"
    echo "max_usb_current=1" >> "$CONFIG_TXT"
    echo "  Added max_usb_current=1 to config.txt"
else
    echo "  max_usb_current already set"
fi

# Also ensure USB quirks don't interfere
CMDLINE="$BOOT/cmdline.txt"
if [[ -f "$CMDLINE" ]]; then
    # Don't add if already there
    if ! grep -q "usbcore.autosuspend=-1" "$CMDLINE" 2>/dev/null; then
        # cmdline.txt must be a single line; append to existing
        sed -i 's/$/ usbcore.autosuspend=-1/' "$CMDLINE"
        echo "  Disabled USB autosuspend in cmdline.txt"
    fi
fi

# 4. Set hostname
echo "[4/5] Setting hostname to kraken-pi..."
echo "kraken-pi" > "$ROOT/etc/hostname"
# Update /etc/hosts
if [[ -f "$ROOT/etc/hosts" ]]; then
    sed -i 's/raspberrypi/kraken-pi/g' "$ROOT/etc/hosts"
fi
echo "  Hostname set to kraken-pi"

# 5. First-boot script (timezone + fs expand)
echo "[5/5] Creating first-boot script..."
cat > "$ROOT/etc/rc.local.kraken" << 'FIRSTBOOT_EOF'
#!/bin/bash
# KrakenSDR first-boot setup — runs once then removes itself
set -e

# Set timezone to UTC (change if needed)
timedatectl set-timezone UTC 2>/dev/null || ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# Expand filesystem to fill SD card
raspi-config --expand-rootfs 2>/dev/null || true

# Disable kernel messages to console (cleaner logs)
dmesg -n 1 2>/dev/null || true

# Self-destruct
rm -f /etc/rc.local.kraken
sed -i '/rc.local.kraken/d' /etc/rc.local

echo "[KrakenSDR] First-boot setup complete. Rebooting..."
reboot
FIRSTBOOT_EOF
chmod +x "$ROOT/etc/rc.local.kraken"

# Hook into rc.local if it exists
if [[ -f "$ROOT/etc/rc.local" ]]; then
    if ! grep -q "rc.local.kraken" "$ROOT/etc/rc.local" 2>/dev/null; then
        sed -i '/^exit 0/i /etc/rc.local.kraken' "$ROOT/etc/rc.local"
        echo "  Hooked first-boot script into rc.local"
    fi
else
    cat > "$ROOT/etc/rc.local" << 'RC_EOF'
#!/bin/bash
/etc/rc.local.kraken
exit 0
RC_EOF
    chmod +x "$ROOT/etc/rc.local"
    echo "  Created rc.local with first-boot hook"
fi

echo ""
echo "═══ SD Card Prep Complete ═══"
echo ""
echo "  Hostname:   kraken-pi"
echo "  Static IP:  192.168.1.120/24"
echo "  Gateway:    192.168.1.1"
echo "  SSH:        Enabled"
echo "  USB power:  Max current enabled"
echo ""
echo "Next steps:"
echo "  1. Safely eject/unmount the SD card"
echo "  2. Insert into Raspberry Pi 4"
echo "  3. Connect KrakenSDR via USB"
echo "  4. Connect ethernet cable"
echo "  5. Power on → wait 60-90 seconds for first boot"
echo "  6. ssh pi@192.168.1.120 (default password: raspberry)"
echo "  7. Change password: passwd"
echo "  8. Run: git clone https://github.com/kamakauzy/sigint-field-kit.git"
echo "  9. Run: cd sigint-field-kit && sudo bash kraken/install_kraken_pi.sh"
echo ""
