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
CONFIG_URL=
PASSWORD=
LAN_IPS=
PROXY_USERS=
BIND=
DNS_BIND=
TPROXY_IP=
MIHOMO_SUFFIX=
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
