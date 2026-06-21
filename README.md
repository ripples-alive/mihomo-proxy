# Usage

## Setup

Install dependencies:

```bash
sudo apt update
sudo apt install iptables ipset
```

Clone this repo to `/etc/mihomo`.

Create `.env` when you need to override defaults:

```env
CONFIG_URL=
PASSWORD=password
PROXY_USERS=
```

`CONFIG_URL` is required when running `meta-config` to download the remote
configuration. The other values can usually be omitted.

Generate config and enable the service:

```bash
./meta-config
sudo ./meta-init
```

## Network Defaults

The network-related variables are optional. By default, the scripts detect:

```env
DEFAULT_ROUTE=
DEFAULT_GATEWAY=
WAN_IF=
GATEWAY_IP=
LAN_CIDRS=
```

`WAN_IF` is used for forwarding NAT. `GATEWAY_IP` is also used as the default
`DNS_BIND`, so DNS binds to the detected gateway address instead of `0.0.0.0`.

Client and bypass policy can be overridden with:

```env
NO_PROXY_IPS=
PROXY_CLIENT_IPS=
NAT_CLIENT_IPS=
TAILSCALE_CIDR=100.64.0.0/10
```

`NO_PROXY_IPS` is destination CIDRs that should never be proxied. The scripts
automatically add `LAN_CIDRS`, `DEFAULT_GATEWAY`, `GATEWAY_IP`, and
`TAILSCALE_CIDR`.

`PROXY_CLIENT_IPS` is client source CIDRs that should enter TProxy. It defaults
to `LAN_CIDRS`, with `TAILSCALE_CIDR` added automatically.

`NAT_CLIENT_IPS` is client source CIDRs that should get forwarding NAT. It
defaults to `PROXY_CLIENT_IPS`, with `TAILSCALE_CIDR` filtered out.

Set `TAILSCALE_CIDR=` to disable the default Tailscale handling.

## Bind Overrides

The default bind values are:

```env
BIND=0.0.0.0
DNS_BIND=${GATEWAY_IP}
```

Set `BIND` or `DNS_BIND` only when you need a fixed listen address.

## Update

```bash
./meta-config
```
