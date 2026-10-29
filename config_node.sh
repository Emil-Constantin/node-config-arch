#!/usr/bin/env bash

set -euo pipefail

SSID="${1:?SSID required}"
PASSWORD="${2:?Password required}"
HOSTNAME="${3:?Hostname required}"

USERNAME="${HOSTNAME//-/_}_root"

echo "==> Ensuring NetworkManager is running"

sudo systemctl enable --now NetworkManager

echo "==> Connecting to Wi-Fi"

if nmcli -t -f NAME connection show | grep -Fxq "$SSID"; then
    echo "Connection profile already exists"

    nmcli connection modify "$SSID" \
        connection.autoconnect yes

    nmcli connection up "$SSID" || true
else
    nmcli device wifi connect "$SSID" \
        password "$PASSWORD" \
        name "$SSID"
fi

echo "==> Waiting for network connectivity"

until ping -c1 archlinux.org >/dev/null 2>&1; do
    sleep 2
done

ACTIVE_CONN="$(nmcli -t -f NAME connection show --active | head -n1)"

nmcli connection modify "$ACTIVE_CONN" connection.autoconnect yes
nmcli connection modify "$ACTIVE_CONN" connection.autoconnect-priority 100

echo "==> Setting hostname"

CURRENT_HOSTNAME="$(hostnamectl --static)"

if [[ "$CURRENT_HOSTNAME" != "$HOSTNAME" ]]; then
    sudo hostnamectl set-hostname "$HOSTNAME"
fi

echo "==> Updating keyring"

sudo pacman -Sy --noconfirm archlinux-keyring

echo "==> Updating system"

sudo pacman -Syu --noconfirm

echo "==> Installing required packages"

sudo pacman -S --needed --noconfirm \
    openssh \
    avahi \
    nss-mdns \
    sudo

echo "==> Creating sudo user"

if ! id "$USERNAME" &>/dev/null; then
    sudo useradd -m -G wheel -s /bin/bash "$USERNAME"

    echo "${USERNAME}:${HOSTNAME}" | sudo chpasswd
fi

echo "==> Configuring sudo"

if [[ ! -f /etc/sudoers.d/wheel ]]; then
    echo '%wheel ALL=(ALL:ALL) ALL' | sudo tee /etc/sudoers.d/wheel >/dev/null
    sudo chmod 440 /etc/sudoers.d/wheel
fi

echo "==> Configuring mDNS"

if ! grep -q "mdns_minimal" /etc/nsswitch.conf; then
    sudo sed -i \
        's/^hosts:.*/hosts: files mymachines mdns_minimal [NOTFOUND=return] resolve dns/' \
        /etc/nsswitch.conf
fi

echo "==> Disabling SSH root login"

sudo sed -i \
    's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
    /etc/ssh/sshd_config

echo "==> Enabling services"

sudo systemctl enable --now avahi-daemon.service
sudo systemctl enable --now sshd.service

echo "==> Configuring Wi-Fi autoconnect"

nmcli connection modify "$SSID" \
    connection.autoconnect yes \
    connection.autoconnect-priority 100

echo "==> Validating services"

systemctl is-active --quiet avahi-daemon
systemctl is-active --quiet sshd

echo
echo "========================================="
echo "           SETUP COMPLETE"
echo "========================================="
echo
echo "Hostname : $HOSTNAME"
echo "Username : $USERNAME"
echo "Password : $HOSTNAME"
echo
echo "SSH:"
echo "  ssh ${USERNAME}@${HOSTNAME}.local"
echo
echo "Checks:"
echo "  ping ${HOSTNAME}.local"
echo "  systemctl status avahi-daemon"
echo "  systemctl status sshd"
echo

if command -v avahi-resolve-host-name >/dev/null 2>&1; then
    avahi-resolve-host-name "${HOSTNAME}.local" || true
fi
