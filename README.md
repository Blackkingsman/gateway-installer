# VPN Gateway Installer

Turns a Linux machine or Raspberry Pi into a VPN gateway for the whole network. Point other devices' gateway at it, and all their traffic goes through the VPN.

## What the script does

1. Detects the architecture (x86_64 or ARM) and picks the matching installer
2. Checks internet and DNS before changing anything
3. Installs the Private Internet Access (PIA) client if it's missing, then logs in
4. Turns on IP forwarding (now and across reboots)
5. Sets up iptables NAT so LAN traffic is masqueraded out the VPN interface
6. Saves the firewall rules with `netfilter-persistent` so they survive a reboot
7. Installs a `pia-gateway` systemd service that redoes the setup at boot
8. Installs a `pia-watchdog` service that checks the VPN interface every few seconds and restores routing if it drops

`--uninstall` stops and removes both services, clears the NAT rules, and empties the saved iptables config.

## Requirements

- Debian-based Linux, x86_64 or ARM (e.g. Raspberry Pi)
- `sudo`
- A PIA account

## Usage

```bash
chmod +x gateway-installer.sh
./gateway-installer.sh             # install and configure
./gateway-installer.sh --uninstall # remove
```

Then set other devices' default gateway (or your router's DHCP gateway) to this machine's IP.

## Tech

Bash, iptables, netfilter-persistent, systemd, PIA CLI
