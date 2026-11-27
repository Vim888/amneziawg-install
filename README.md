# AmneziaWG Automatic Server Installer

**This project is a bash script that aims to setup a [AmneziaWG](https://docs.amnezia.org/ru/documentation/amnezia-wg/) VPN on a Linux server, as easily as possible!**

## Requirements

Supported distributions:

- Debian 13

## Changes from original repo

- Full checked and verifed success runs all systemd services and route traffic on Debian 13
- Default private IPs changed from 10.66.66.1 to 10.xx.yy.1 where xx.yy - last bits from original server IP

## Usage

In first check server ip on cheburcheck.ru or similary source

Before installation it is strictly recommended to upgrade your system to the latest available version and perform the reboot afterwards.

Use curl or wget to download the script:
```bash
apt update && apt upgrade -y && apt install nano fail2ban curl sudo net-tools ipcalc qrencode jq traceroute dnsutils -y
cd ~
mkdir ~/.aw
cd ~/.aw
curl https://raw.githubusercontent.com/vim888/amneziawg-install/main/amneziawg-install.sh -o aw.sh
```

Set permissions:
```bash
chmod +x ~/.aw/aw.sh
```

And execute:
```bash
bash ~/.aw/aw.sh
```

Answer the questions asked by the script and it will take care of the rest.

It will install AmneziaWG (kernel module and tools) on the server, configure it, create a systemd service and a client configuration file.

Run the script again to add or remove clients!
