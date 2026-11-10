#!/usr/bin/env bash
#
# config_node_dietpi.sh — DietPi port of config_node.sh (the Arch Linux one).
#
# Takes a fresh DietPi node (Pi Zero / Pi Zero 2 W in this project) to a state
# where it is reachable over SSH from the LAN:
#   * joins Wi-Fi and brings it back at boot — DietPi uses wpa_supplicant +
#     ifupdown (/etc/wpa_supplicant/wpa_supplicant.conf and
#     /etc/network/interfaces.d/<iface>.conf), NOT NetworkManager, so the
#     nmcli parts of the Arch script have no DietPi equivalent
#   * sets the hostname through DietPi's own helper, which also fixes
#     /etc/hosts and /boot/dietpi.txt (hostnamectl alone does neither)
#   * avahi-daemon + libnss-mdns so the node answers to <hostname>.local
#   * OpenSSH as the SSH server: DietPi ships Dropbear on port 22 by default,
#     so it has to be disabled or sshd never gets the socket
#   * a non-root sudoer, and root login over SSH turned off
#
# Run it ON the node — HDMI + keyboard, or the serial console, ideally with
# Ethernet attached as well. The Wi-Fi step bounces wlan0, so running this from
# a Wi-Fi SSH session kills the session halfway through the script.
#
#   sudo bash scripts/config_node_dietpi.sh <SSID> <WPA-key> <hostname> [iface] [wifi-country]
#   sudo bash scripts/config_node_dietpi.sh "HomeNet" hunter2 scrcpy-zero-01 wlan0 RO
#
# Environment overrides:
#   NODE_USER=<name>      user to create   (default: hostname with '-'→'_' + "_root")
#   NODE_PASSWORD=<pw>    its password     (default: the hostname, as in the Arch script)
#   NODE_GROUPS=<list>    comma separated  (default: sudo; add plugdev,dialout for adb/USB)
#   SKIP_UPDATE=1         skip apt-get dist-upgrade (it is slow on a Zero W)
#   PURGE_DROPBEAR=1      purge Dropbear instead of only disabling it
#
# Fully unattended, no login at all: edit /boot/dietpi.txt (+ /boot/dietpi-wifi.txt)
# on the boot partition before the first boot — recipe at the bottom of this file.
#
set -euo pipefail

SSID="${1:?SSID required}"
PASSWORD="${2:?Password required}"
HOSTNAME="${3:?Hostname required}"
IFACE="${4:-wlan0}"
COUNTRY="${5:-}"

WPA_CONF=/etc/wpa_supplicant/wpa_supplicant.conf
DIETPI_DIR=/boot/dietpi
DIETPI_TXT=/boot/dietpi.txt
NODE_USER="${NODE_USER:-${HOSTNAME//-/_}_root}"
NODE_PASSWORD="${NODE_PASSWORD:-$HOSTNAME}"
NODE_GROUPS="${NODE_GROUPS:-sudo}"

n(){   printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m!! %s\033[0m\n' "$*" >&2; }
die(){  printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || die "run as root: sudo bash $0 $SSID <pw> $HOSTNAME"

# DietPi sanity check + input validation: fail before touching anything.
if [ ! -d "$DIETPI_DIR" ] && ! grep -qi dietpi /etc/os-release 2>/dev/null; then
    warn "no $DIETPI_DIR and no DietPi in /etc/os-release — continuing anyway, but this script assumes DietPi"
fi
case $SSID in *[\"\\]*) die 'SSID must not contain " or \ (wpa_supplicant block handling)';; esac
[[ $HOSTNAME =~ ^[[:alnum:]][[:alnum:].-]*[[:alnum:]]$ ]] || die "invalid hostname '$HOSTNAME' (see https://dietpi.com/docs/)"
[[ -z $COUNTRY || $COUNTRY =~ ^[A-Z][A-Z]$ ]] || die "wifi-country must be two capital letters, e.g. RO"
if [ -n "$PASSWORD" ] && (( ${#PASSWORD} < 8 )); then
    die "WPA key must be 8-63 characters (this one is ${#PASSWORD}); pass \"\" for an open network"
fi

export DEBIAN_FRONTEND=noninteractive
APT='-o DPkg::Lock::Timeout=300'   # DietPi's own apt timer can be holding the lock

# ---------------------------------------------------------------------------
n "Wi-Fi ($IFACE)"
# ---------------------------------------------------------------------------
using_nm=0
command -v nmcli > /dev/null 2>&1 && systemctl is-active --quiet NetworkManager && using_nm=1

if [ "$using_nm" = 1 ]; then
    # Someone installed NetworkManager on this node: then the Arch code path works as-is.
    if nmcli -t -f NAME connection show | grep -Fxq "$SSID"; then
        nmcli connection modify "$SSID" connection.autoconnect yes connection.autoconnect-priority 100
        nmcli connection up "$SSID" || true
    else
        nmcli device wifi connect "$SSID" password "$PASSWORD" name "$SSID" ifname "$IFACE"
    fi
else
    [ -e "/sys/class/net/$IFACE" ] || die "no interface $IFACE — check 'ip link' and pass the right one as 4th argument"

    # wpasupplicant (which ships wpa_passphrase and the ifupdown hooks), iw and
    # wireless-regdb are already in the DietPi base. Only reach for apt when
    # something is genuinely missing, so a first run with no network yet — the
    # usual case for a Wi-Fi-only Zero W — still writes the credentials.
    if ! command -v wpa_passphrase > /dev/null 2>&1 || ! command -v iw > /dev/null 2>&1; then
        apt-get update -qq $APT || warn "apt-get update failed (no network yet?), continuing with what is installed"
        apt-get install -y -qq $APT wpasupplicant wireless-regdb iw ||
            warn "could not install wpasupplicant/wireless-regdb/iw — using whatever is already present"
    fi

    # Find the stanza ifupdown already uses for this interface. dietpi-network
    # keeps one file per interface (/etc/network/interfaces.d/<iface>.conf), but
    # images made before that may still carry the stanza in the main file, and
    # older ones reference /etc/wpa_supplicant.conf instead of the subdirectory.
    IFCFG=
    for f in "/etc/network/interfaces.d/$IFACE.conf" /etc/network/interfaces.d/* /etc/network/interfaces; do
        [ -f "$f" ] || continue
        grep -qE "^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]]+$IFACE([[:space:]]|\$)" "$f" && { IFCFG=$f; break; }
    done
    if [ -n "$IFCFG" ]; then
        ref=$(awk -v ifc="$IFACE" '
            $0 ~ ("^[[:space:]]*iface[[:space:]]+" ifc "([[:space:]]|$)") { st=1; next }
            st && /^[[:space:]]*(iface|auto|allow-hotplug)[[:space:]]/ { st=0 }
            st && /^[[:space:]]*wpa-(conf|roam)[[:space:]]+/ { print $2; exit }
        ' "$IFCFG")
        [ -n "$ref" ] && [ -f "$ref" ] && WPA_CONF=$ref
    fi

    if [ ! -f "$WPA_CONF" ]; then
        install -m 600 /dev/null "$WPA_CONF"
        # the same header dietpi-wifidb writes; the country line is set below
        printf 'ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev\nupdate_config=1\n' > "$WPA_CONF"
    fi

    if [ -n "$COUNTRY" ]; then
        # DietPi's own helper also syncs dietpi.txt and reloads the regdomain.
        if [ -x "$DIETPI_DIR/func/dietpi-set_hardware" ]; then
            "$DIETPI_DIR/func/dietpi-set_hardware" wificountrycode "$COUNTRY" || warn "country code not applied"
        else
            grep -q '^country=' "$WPA_CONF" || sed -i '1i country=XX' "$WPA_CONF"
            sed -i "s/^country=.*/country=$COUNTRY/" "$WPA_CONF"
        fi
    fi

    # Replace any block for this SSID, then append a fresh one. wpa_passphrase
    # hashes the key (hex psk) and escapes the SSID; its comment lines carry the
    # plaintext key, so they are dropped. The block shape matches what
    # dietpi-wifidb writes, and priority= is the stand-in for NetworkManager's
    # autoconnect-priority (which DietPi has no equivalent of).
    if grep -qE "^[[:space:]]*ssid=\"$SSID\"([\"[:space:]]|$)" "$WPA_CONF"; then
        awk -v ssid="$SSID" '
            /^[[:space:]]*network[[:space:]]*=[[:space:]]*\{/ { inb=1; buf=$0 ORS; next }
            inb { buf = buf $0 ORS; if ($0 ~ /^[[:space:]]*\}/) { if (buf !~ ("ssid=\"" ssid "\"")) printf "%s", buf; inb=0; buf="" }; next }
            { print }
        ' "$WPA_CONF" > "$WPA_CONF.tmp"
        cat "$WPA_CONF.tmp" > "$WPA_CONF"; rm -f "$WPA_CONF.tmp"
    fi
    {
        printf 'network={\n'
        if [ -n "$PASSWORD" ]; then
            if command -v wpa_passphrase > /dev/null 2>&1; then
                wpa_passphrase "$SSID" "$PASSWORD" | grep -vE '^[[:space:]]*#' | grep -E '^[[:space:]]*(ssid|psk)='
            else
                # offline + no wpasupplicant: quoted literal psk, with escaping
                esc=${PASSWORD//\\/\\\\}; esc=${esc//\"/\\\"}
                printf '\tssid="%s"\n\tpsk="%s"\n' "$SSID" "$esc"
            fi
            printf '\tkey_mgmt=WPA-PSK\n'
        else
            printf '\tssid="%s"\n\tkey_mgmt=NONE\n' "$SSID"
        fi
        printf '\tscan_ssid=1\n\tpriority=10\n}\n'
    } >> "$WPA_CONF"
    chmod 600 "$WPA_CONF"
    if [ -f /var/lib/dietpi/dietpi-wifi.db ]; then
        warn "DietPi keeps its own WiFi list in /var/lib/dietpi/dietpi-wifi.db and rewrites $WPA_CONF from it (dietpi-config menu 7 / dietpi-wifidb) — add this SSID there too if you use those tools"
    fi

    # Interface config: extend the stanza found above, or add a DHCP drop-in in
    # the shape dietpi-network writes (incl. the Wi-Fi power-save lines it adds).
    if [ -z "$IFCFG" ]; then
        mkdir -p /etc/network/interfaces.d
        grep -qE '^[[:space:]]*source[[:space:]]+(/etc/)?interfaces\.d/' /etc/network/interfaces 2>/dev/null ||
            printf '\nsource interfaces.d/*\n' >> /etc/network/interfaces
        IFCFG=/etc/network/interfaces.d/$IFACE.conf
        printf 'allow-hotplug %s\niface %s inet dhcp\n wpa-conf %s\n pre-up iw dev %s set power_save off || true\n post-down iw dev %s set power_save on || true\n' \
            "$IFACE" "$IFACE" "$WPA_CONF" "$IFACE" "$IFACE" > "$IFCFG"
    else
        grep -qE "^[[:space:]]*(auto|allow-hotplug)[[:space:]]+$IFACE([[:space:]]|\$)" "$IFCFG" ||
            printf 'allow-hotplug %s\n' "$IFACE" >> "$IFCFG"
        grep -qE "^[[:space:]]*wpa-(conf|roam)[[:space:]]+" "$IFCFG" ||
            { awk -v ifc="$IFACE" -v wpa=" wpa-conf $WPA_CONF" '
                  { print }
                  $0 ~ ("^[[:space:]]*iface[[:space:]]+" ifc "[[:space:]]") { print wpa }
              ' "$IFCFG" > "$IFCFG.tmp"; cat "$IFCFG.tmp" > "$IFCFG"; rm -f "$IFCFG.tmp"; }
    fi
    mode=$(sed -n "s/^[[:space:]]*iface[[:space:]]\+$IFACE[[:space:]]\+inet[[:space:]]\+\([a-z]*\).*/\1/p" "$IFCFG" | head -1)
    [ -z "$mode" ] || [ "$mode" = dhcp ] || warn "$IFACE is configured '$mode' in $IFCFG — the credentials still apply; for DHCP: dietpi-network"

    n "reconnecting $IFACE (a Wi-Fi SSH session would now drop)"
    pkill -f "wpa_supplicant.*$IFACE" 2>/dev/null || true
    ifdown "$IFACE" 2>/dev/null || true
    sleep 2
    ifup "$IFACE" || warn "ifup $IFACE failed — the config is written; reboot to apply"
fi

# ---------------------------------------------------------------------------
n "waiting for connectivity"
# ---------------------------------------------------------------------------
# Bounded loop, and an IP-literal ping first so a broken DNS does not hang it
# forever (the Arch script looped on archlinux.org with no exit).
up=0
for _ in $(seq 1 30); do
    ip -4 addr show scope global 2>/dev/null | grep -q 'inet ' && up=1 && break
    sleep 2
done
[ "$up" = 1 ] || warn "no IPv4 address yet on any interface"
for _ in $(seq 1 15); do
    ping -c1 -W3 1.1.1.1 > /dev/null 2>&1 && break
    sleep 2
done
ping -c1 -W3 1.1.1.1 > /dev/null 2>&1 || die "no route to the internet — check SSID/key, country code, and router MAC filtering"
getent hosts dietpi.com > /dev/null 2>&1 || warn "DNS is not resolving yet; apt may need a retry"
ip -4 -br addr

# ---------------------------------------------------------------------------
n "hostname -> $HOSTNAME"
# ---------------------------------------------------------------------------
if [ "$(cat /proc/sys/kernel/hostname)" != "$HOSTNAME" ]; then
    if [ -x "$DIETPI_DIR/func/change_hostname" ]; then
        # the DietPi helper: hostname + /etc/hostname + 127.0.1.1 in /etc/hosts
        # + AUTO_SETUP_NET_HOSTNAME in dietpi.txt. hostnamectl does only the first.
        "$DIETPI_DIR/func/change_hostname" "$HOSTNAME"
    else
        hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || hostname "$HOSTNAME"
        printf '%s\n' "$HOSTNAME" > /etc/hostname
        grep -q '^127\.0\.1\.1' /etc/hosts &&
            sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $HOSTNAME/" /etc/hosts ||
            printf '127.0.1.1 %s\n' "$HOSTNAME" >> /etc/hosts
    fi
else
    echo "already set"
fi

# ---------------------------------------------------------------------------
n "apt update + dist-upgrade (skip with SKIP_UPDATE=1)"
# ---------------------------------------------------------------------------
apt-get update -qq $APT || die "apt-get update failed — check the mirror (dietpi-config > Network Options: Misc)"
if [ "${SKIP_UPDATE:-0}" != 1 ]; then
    apt-get dist-upgrade -y -qq $APT \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold ||
        die "dist-upgrade failed — inspect: cat /var/lib/dietpi/logs/*  /var/log/apt/term.log"
else
    echo "skipped (SKIP_UPDATE=1)"
fi
# DietPi itself is updated separately: sudo dietpi-update

n "packages"
# Debian package names differ from Arch: openssh→openssh-server, avahi→avahi-daemon,
# nss-mdns→libnss-mdns, and the avahi CLI tools are split out into avahi-utils.
# No --no-install-recommends: openssh-server only Recommends openssh-sftp-server,
# and without it scp/sftp against the node break.
apt-get install -y -qq $APT \
    openssh-server avahi-daemon avahi-utils libnss-mdns sudo iputils-ping

# ---------------------------------------------------------------------------
n "SSH server: Dropbear -> OpenSSH"
# ---------------------------------------------------------------------------
if dpkg-query -W -f='${Status}' dropbear 2>/dev/null | grep -q 'install ok installed'; then
    systemctl disable --now dropbear 2>/dev/null || true
    if [ "${PURGE_DROPBEAR:-0}" = 1 ]; then
        apt-get purge -y -qq $APT dropbear || warn "purge dropbear failed (it stays disabled only)"
        apt-get autoremove -y -qq $APT || true
    fi
    [ -f "$DIETPI_TXT" ] && sed -i 's/^AUTO_SETUP_SSH_SERVER_INDEX=.*/AUTO_SETUP_SSH_SERVER_INDEX=-2/' "$DIETPI_TXT"
    echo "Dropbear disabled (it listens on 22 too, so sshd could not bind); OpenSSH is now the SSH server"
fi

# ---------------------------------------------------------------------------
n "sudo user: $NODE_USER"
# ---------------------------------------------------------------------------
if ! id "$NODE_USER" > /dev/null 2>&1; then
    g=
    for grp in ${NODE_GROUPS//,/ }; do
        getent group "$grp" > /dev/null 2>&1 || groupadd "$grp"
        g="$g,$grp"
    done
    useradd -m -G "${g#,}" -s /bin/bash "$NODE_USER"
    printf '%s:%s\n' "$NODE_USER" "$NODE_PASSWORD" | chpasswd
    echo "created, password = \$NODE_PASSWORD (default: the hostname)"
else
    echo "already exists, password left untouched"
fi
# Debian has no wheel group: /etc/sudoers already ships "%sudo ALL=(ALL:ALL) ALL",
# which is why the wheel drop-in from the Arch script is not needed here.
grep -hErq '^[[:space:]]*%sudo[[:space:]]' /etc/sudoers /etc/sudoers.d/* 2>/dev/null || {
    printf '%%sudo ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/90-node-sudo
    chmod 440 /etc/sudoers.d/90-node-sudo
    visudo -cf /etc/sudoers.d/90-node-sudo > /dev/null
}
id "$NODE_USER" -Gn | tr ',' ' ' | sed 's/^/groups: /'

# ---------------------------------------------------------------------------
n "mDNS: <hostname>.local"
# ---------------------------------------------------------------------------
# Arch uses mdns_minimal + systemd's mymachines. Debian's libnss-mdns gives
# mdns4_minimal (IPv4), mymachines is not installed, and libnss-myhostname is:
if ! grep -qE '^[[:space:]]*hosts:.*(mdns4?_minimal|mdns_minimal)' /etc/nsswitch.conf; then
    if grep -qE '^[[:space:]]*hosts:' /etc/nsswitch.conf; then
        sed -i 's/^\([[:space:]]*hosts:\).*/\1 files mdns4_minimal [NOTFOUND=return] dns myhostname/' /etc/nsswitch.conf
    else
        printf 'hosts: files mdns4_minimal [NOTFOUND=return] dns myhostname\n' >> /etc/nsswitch.conf
    fi
fi
grep -E '^[[:space:]]*hosts:' /etc/nsswitch.conf | sed 's/^/   /'

# ---------------------------------------------------------------------------
n "sshd: no root login"
# ---------------------------------------------------------------------------
if [ -d /etc/ssh/sshd_config.d ]; then
    # OpenSSH keeps the FIRST value it reads, and Debian/Ubuntu sshd_config
    # includes sshd_config.d/*.conf before the body. DietPi manages its own
    # drop-in (dietpi.conf), so ours is named 00-* to sort ahead of it.
    printf '# managed by config_node_dietpi.sh — beats DietPi'\''s dietpi.conf drop-in\nPermitRootLogin no\nPasswordAuthentication yes\n' \
        > /etc/ssh/sshd_config.d/00-node.conf
    chmod 600 /etc/ssh/sshd_config.d/00-node.conf
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
else
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
fi
systemctl unmask ssh > /dev/null 2>&1 || true
systemctl enable ssh > /dev/null 2>&1 || true
mkdir -p -m 0755 /run/sshd          # ssh.service creates it; sshd -t outside the unit does not
sshd -t || die "sshd config test failed — not restarting ssh, previous config still active"
systemctl restart ssh 2>/dev/null || systemctl restart sshd
[ -f /etc/ssh/sshd_config.d/dietpi.conf ] && { echo "DietPi's own drop-in:"; grep -E '^[^#]' /etc/ssh/sshd_config.d/dietpi.conf | sed 's/^/   /'; }
eff=$(sshd -T 2>/dev/null | awk '$1=="permitrootlogin"{print $2; exit}')
[ "$eff" = no ] || warn "effective permitrootlogin is '$eff', not 'no' — check /etc/ssh/sshd_config.d/"

# ---------------------------------------------------------------------------
n "services"
# ---------------------------------------------------------------------------
systemctl enable avahi-daemon > /dev/null 2>&1 || true
systemctl restart avahi-daemon
systemctl is-active --quiet avahi-daemon || die "avahi-daemon not running: journalctl -u avahi-daemon -b --no-pager | tail -20"
systemctl is-active --quiet ssh || systemctl is-active --quiet sshd || die "ssh not running: systemctl status ssh"

echo
echo "========================================="
echo "           SETUP COMPLETE"
echo "========================================="
echo
echo "Hostname  : $HOSTNAME"
echo "User      : $NODE_USER   (sudo)"
echo "Password  : \$NODE_PASSWORD (default: $HOSTNAME)"
echo "IPv4      : $(ip -4 -br addr | awk '$1!="lo"{print $3}' | tr '\n' ' ')"
echo
echo "SSH:"
echo "  ssh ${NODE_USER}@${HOSTNAME}.local"
echo "  (Windows OpenSSH has no mDNS: use the IPv4 above, or add Bonjour)"
echo
echo "Checks:"
echo "  ping ${HOSTNAME}.local"
echo "  systemctl status avahi-daemon ssh"
echo "  sshd -T | grep -i permitrootlogin"
command -v avahi-resolve-host-name > /dev/null 2>&1 && avahi-resolve-host-name -4 "$HOSTNAME.local" || true
echo
echo "DietPi notes:"
echo "  dietpi-config menu 7 = network, menu 6 = security; CLI: dietpi-network"
echo "  root and 'dietpi' both still answer with the DietPi default password:"
echo "      sudo /boot/dietpi/func/dietpi-set_software password"
echo "  DietPi updates: sudo dietpi-update ; logs: /var/lib/dietpi/logs/"
echo

# ---------------------------------------------------------------------------
# Fully unattended first boot instead of running this script by hand: edit the
# files on the boot partition and boot; DietPi applies them once, logging to
# /var/lib/dietpi/logs/dietpi-firstrun-setup.log (the pre-script logs to
# /var/lib/dietpi/logs/dietpi-firstboot.log).
#
#   /boot/dietpi.txt
#       AUTO_SETUP_AUTOMATED=1                     # no prompts at all
#       AUTO_SETUP_GLOBAL_PASSWORD=<pw>            # sets root AND the 'dietpi' user
#       AUTO_SETUP_NET_HOSTNAME=scrcpy-zero-01
#       AUTO_SETUP_NET_ETHERNET_ENABLED=1          # 0 = Wi-Fi only
#       AUTO_SETUP_NET_WIFI_ENABLED=1
#       AUTO_SETUP_NET_WIFI_COUNTRY_CODE=RO
#       AUTO_SETUP_SSH_SERVER_INDEX=-2             # -2 = OpenSSH | -1 = Dropbear (default) | 0 = none
#       AUTO_SETUP_APT_INSTALLS=avahi-daemon avahi-utils libnss-mdns
#       #AUTO_SETUP_SSH_PUBKEY=ssh-ed25519 AAAA... node-key   # root + dietpi authorized_keys
#       SOFTWARE_DISABLE_SSH_PASSWORD_LOGINS=1     # only together with a pubkey above!
#
#   /boot/dietpi-wifi.txt — sourced as bash, moved to /var/lib/dietpi/dietpi-wifi.db,
#   five slots 0..4 (the key may also be the 64-hex digest from wpa_passphrase):
#       aWIFI_SSID[0]='MySSID'
#       aWIFI_KEY[0]='MyKey'
#       aWIFI_KEYMGR[0]='WPA-PSK'
#
#   /boot/Automation_Custom_Script.sh — with the default AUTO_SETUP_CUSTOM_SCRIPT_EXEC=0
#   this file is executed right after the first-boot installs. Put the user
#   creation, sshd hardening and nsswitch parts of this script in it, or copy
#   this script to the boot partition and call it from there (skip the Wi-Fi
#   block, dietpi-wifi.txt already joined the network by then).
# ---------------------------------------------------------------------------
