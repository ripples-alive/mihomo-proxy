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
```

init config and enable service

```bash
HTTPS_PROXY= ./meta-config
sudo ./meta-init
```

## Update

```bash
./meta-config
```
