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
FORCE_PROXY_IPS=
NO_PROXY_IPS=
PROXY_CLIENT_IPS=
NAT_CLIENT_IPS=
TAILSCALE_CIDR=100.64.0.0/10
```

`FORCE_PROXY_IPS` defaults to empty and accepts comma- or colon-separated IPv4
hosts and CIDRs, for example `192.0.2.42,198.51.100.128/25`. Matching rules run
before the gateway bypass and UDP-return rules, but only for traffic already
eligible through the existing `PROXY_CLIENT_IPS` or TCP-only local-user entry
paths; Mihomo still decides the final DIRECT, REJECT, proxy, or other outbound.
After changing the list, restart Mihomo to rebuild the rules; to roll back,
remove or empty the setting and restart again.

`NO_PROXY_IPS` is destination CIDRs that normally bypass the proxy. The scripts
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

`meta-config` reloads the generated configuration, then refreshes all proxy and
rule providers found from the controller API. If the controller provider list is
unavailable, proxy providers are inferred from `/proxies`, then both provider
types fall back to the generated YAML sections.
