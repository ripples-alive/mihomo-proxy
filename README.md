# Usage

## Setup

install dependencies

```bash
sudo apt update
sudo apt install iptables ipset
```

clone repo to `/etc/mihomo`

create `.env`

```
MIHOMO_SUFFIX=
CONFIG_URL=
PASSWORD=
BIND=
DNS_BIND=
PROXY_LAN_IPS=
PROXY_USERS=
```

init config and enable service

```bash
./meta-config
sudo ./meta-init
```

## Update

```bash
./meta-config
```
