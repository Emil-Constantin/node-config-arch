#!/usr/bin/env bash

set -euo pipefail

SSID="${1:?SSID required}"
PASSWORD="${2:?Password required}"
HOSTNAME="${3:?Hostname required}"

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

echo "==> Setting hostname"

CURRENT_HOSTNAME="$(hostnamectl --static)"

if [[ "$CURRENT_HOSTNAME" != "$HOSTNAME" ]]; then
    sudo hostnamectl set-hostname "$HOSTNAME"
fi

echo "==> Updating system"

sudo pacman -Syu --noconfirm

echo "==> Installing required packages"

sudo pacman -S --needed --noconfirm \
    openssh \
    avahi \
    nss-mdns \
    sudo

echo "==> Creating sudo user"

USERNAME="${HOSTNAME}_root"
if ! id "$USERNAME" &>/dev/null; then
    useradd -m -G wheel -s /bin/bash "$USERNAME"

    echo "${USERNAME}:${HOSTNAME}" | chpasswd
fi

echo "==> Configuring sudo"

if ! sudo grep -q '^%wheel ALL=(ALL:ALL) ALL' /etc/sudoers; then
    sudo sed -i \
        's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' \
        /etc/sudoers
fi

echo "==> Configuring nsswitch for mDNS"

if ! grep -q "mdns_minimal" /etc/nsswitch.conf; then
    sudo sed -i \
        's/^hosts:.*/hosts: files mymachines mdns_minimal [NOTFOUND=return] resolve dns/' \
        /etc/nsswitch.conf
fi

echo "==> Enabling services"

sudo systemctl enable avahi-daemon.service
sudo systemctl enable sshd.service

sudo systemctl restart avahi-daemon.service
sudo systemctl restart sshd.service

echo "==> Ensuring Wi-Fi autoconnect"

nmcli connection modify "$SSID" \
    connection.autoconnect yes \
    connection.autoconnect-priority 100

echo
echo "Setup complete"
echo
echo "Hostname:"
echo "  $HOSTNAME"
echo
echo "SSH:"
echo "  ssh ${USERNAME}@${HOSTNAME}.local"
echo
echo "Check:"
echo "  ping ${HOSTNAME}.local"
echo "  systemctl status avahi-daemon sshd"