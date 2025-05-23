#!/bin/bash
set -e

# --- Architecture check ---
ARCH=$(uname -m)
echo "🔍 System architecture: $ARCH"

case "$ARCH" in
    x86_64)
        PIA_INSTALLER="pia-installer.run"
        ;;
    aarch64|armv7l)
        PIA_INSTALLER="pia-installer-arm.run"
        ;;
    *)
        echo "❌ Unsupported architecture: $ARCH"
        echo "This script only supports x86_64 and ARM-based systems."
        exit 1
        ;;
esac

echo "🔧 Starting PIA VPN Gateway Setup..."

# --- Step 0: Check internet and DNS ---
echo "🌐 Checking internet connectivity..."
if ! ping -c 1 1.1.1.1 >/dev/null 2>&1; then
    echo "❌ No internet connection detected. Please connect and try again."
    exit 1
fi

# --- Step 1: Check/install PIA if missing ---
echo "📦 Checking for PIA VPN client..."
if ! command -v piactl >/dev/null; then
    echo "📥 PIA not found. Installing from local repo copy..."
    if [[ ! -f "$PIA_INSTALLER" ]]; then
        echo "❌ Installer file $PIA_INSTALLER not found in current directory. Aborting."
        exit 1
    fi
    chmod +x "$PIA_INSTALLER"
    ./$PIA_INSTALLER --quiet
    if ! command -v piactl >/dev/null; then
        echo "❌ Failed to install PIA. Aborting."
        exit 1
    fi
else
    echo "✅ PIA is already installed."
fi

# --- Step 2: Login (only if not already connected) ---
if [[ "$(piactl get connectionstate)" != "Connected" ]]; then
    echo ""
    echo "🔐 PIA VPN Login"
    echo "Please enter your PIA credentials below."
    echo "Username should start with 'p' (e.g. p1234567)"
    echo ""

    read -rp "PIA Username: " PIA_USER
    read -rsp "PIA Password: " PIA_PASS
    echo ""

    LOGIN_FILE=$(mktemp)
    echo "$PIA_USER" > "$LOGIN_FILE"
    echo "$PIA_PASS" >> "$LOGIN_FILE"

    echo "🔓 Logging in to PIA..."
    piactl login "$LOGIN_FILE" || echo "🔓 Already logged in or login succeeded."
    rm -f "$LOGIN_FILE"

    echo "🌐 Connecting to VPN..."
    piactl connect

    echo "⏳ Waiting for VPN to connect..."
    while [[ "$(piactl get connectionstate)" != "Connected" ]]; do
        sleep 2
    done
else
    echo "🔓 Already connected to PIA. Continuing with setup..."
fi

# --- Step 3: Detect interfaces ---
VPN_IF=$(ip -br link | awk '/tun[0-9]+/ {print $1; exit}')
LAN_IF=$(ip route get 1 | awk '{print $5; exit}')

if [[ -z "$VPN_IF" || -z "$LAN_IF" ]]; then
    echo "❌ Could not detect VPN or LAN interface. Aborting."
    exit 1
fi

echo "🌍 VPN interface: $VPN_IF"
echo "🏠 LAN interface: $LAN_IF"

# --- Step 4: Enable IP forwarding ---
echo "🏗 Enabling IP forwarding..."
sudo sysctl -w net.ipv4.ip_forward=1
sudo sed -i 's/#*net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf

# --- Step 5: Set up iptables rules ---
echo "📡 Setting up iptables NAT rules..."
sudo iptables -t nat -F
sudo iptables -F

sudo iptables -t nat -A POSTROUTING -o "$VPN_IF" -j MASQUERADE
sudo iptables -A FORWARD -i "$LAN_IF" -o "$VPN_IF" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
sudo iptables -A FORWARD -i "$VPN_IF" -o "$LAN_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# --- Step 6: Save iptables rules ---
echo "💾 Saving iptables rules..."
echo "📦 Ensuring iptables-persistent is installed..."
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent resolvconf
sudo netfilter-persistent save

# --- Step 7: Auto-run on boot (systemd) ---
echo "🪄 Creating systemd service to restore VPN gateway on boot..."

cat <<EOF | sudo tee /etc/systemd/system/pia-gateway.service > /dev/null
[Unit]
Description=PIA VPN Gateway Auto Setup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash /usr/local/bin/pia-gateway.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

sudo cp "$0" /usr/local/bin/pia-gateway.sh
sudo chmod +x /usr/local/bin/pia-gateway.sh
sudo systemctl enable pia-gateway.service

# --- Step 8: Set up watchdog service to monitor VPN connection ---
echo "👁 Setting up VPN watchdog service..."

cat <<'EOF' | sudo tee /usr/local/bin/pia-watchdog.sh > /dev/null
#!/bin/bash

LAST_IF=""
while true; do
  VPN_IF=$(ip -br link | awk '/tun[0-9]+/ {print $1; exit}')
  LAN_IF=$(ip route get 1 | awk '{print $5; exit}')

  if [[ "$VPN_IF" != "$LAST_IF" && -n "$VPN_IF" && -n "$LAN_IF" ]]; then
    echo "🔄 VPN interface changed to $VPN_IF. Reapplying iptables..."

    iptables -t nat -F
    iptables -F
    iptables -t nat -A POSTROUTING -o "$VPN_IF" -j MASQUERADE
    iptables -A FORWARD -i "$LAN_IF" -o "$VPN_IF" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
    iptables -A FORWARD -i "$VPN_IF" -o "$LAN_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    echo 'nameserver 1.1.1.1' > /etc/resolv.conf

    LAST_IF="$VPN_IF"
  fi

  sleep 5
done
EOF

sudo chmod +x /usr/local/bin/pia-watchdog.sh

# Create systemd service

# Enable logging to journal
sudo sed -i '/^ExecStart=/a StandardOutput=journal
StandardError=journal' /etc/systemd/system/pia-watchdog.service
cat <<EOF | sudo tee /etc/systemd/system/pia-watchdog.service > /dev/null
[Unit]
Description=PIA VPN Interface Watchdog
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/pia-watchdog.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable pia-watchdog.service

echo ""
echo "✅ All done!"
echo "📄 To monitor the watchdog logs, run:"
echo "   journalctl -fu pia-watchdog.service"
echo "🔁 Reboot your machine to start routing traffic through the PIA VPN gateway."
