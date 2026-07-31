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
PROXY_DOCKER_LANS=
TAILSCALE_CIDR=100.64.0.0/10
```

`FORCE_PROXY_IPS` defaults to empty and accepts comma- or colon-separated IPv4
hosts and CIDRs, for example `192.0.2.42,198.51.100.128/25`. Dedicated
Tailscale transport exceptions (`UDP` source or destination port `41641` and
STUN destination port `3478`) are emitted before these forced destination
rules, so a Tailscale endpoint inside a forced range is not sent through the
application-layer TProxy. This ordering also avoids `EADDRINUSE` when a local
wildcard listener owns the original UDP port needed for a transparent reply.
Forced rules still precede the ordinary private destination bypass and general
UDP/TCP interception, but only traffic already
eligible through the existing `PROXY_CLIENT_IPS` or TCP-only local-user entry
paths is considered. Mihomo still decides the final DIRECT, REJECT, proxy, or
other outbound. After changing the list, restart Mihomo to rebuild the rules;
to roll back, remove or empty the setting and restart again.

`NO_PROXY_IPS` is destination CIDRs that normally bypass the proxy. The scripts
automatically add `LAN_CIDRS`, `DEFAULT_GATEWAY`, `GATEWAY_IP`, and
`TAILSCALE_CIDR`.

`PROXY_CLIENT_IPS` is client source CIDRs that should enter TProxy. It defaults
to `LAN_CIDRS`, with `TAILSCALE_CIDR` added automatically.

`NAT_CLIENT_IPS` is client source CIDRs that should get forwarding NAT. It
defaults to `PROXY_CLIENT_IPS`, with `TAILSCALE_CIDR` filtered out.

Every source CIDR in `PROXY_CLIENT_IPS` gets two rules inserted at the start of
`filter/FORWARD` while Mihomo is running. One accepts traffic from the client;
the other accepts traffic back to the client only when conntrack identifies it
as part of an `ESTABLISHED` or `RELATED` connection. Together they let
configured proxy clients pass through hosts whose default `FORWARD` policy is
`DROP`, including traffic that bypasses TProxy. The source rule accepts all
forwarded IPv4 traffic from each configured client, so only add trusted
networks. `meta-down` removes both rules again.

`PROXY_DOCKER_LANS` defaults to empty and accepts comma- or colon-separated
IPv4 CIDRs, for example `192.0.2.0/26,198.51.100.0/26`. Each listed network
gets a TCP-only TProxy entry from `mangle/PREROUTING` and a marked return route
through the main routing table. TCP packets in the conntrack `REPLY` direction
return before `FORCE_PROXY_IPS`, so replies for connections initiated toward a
container are not treated as new transparent-proxy connections. Ordinary
private destinations still use the existing bypass, while forced destinations
continue to take precedence for container-initiated connections.

The scripts do not discover Docker networks or depend on `docker0`; list every
network that should be proxied explicitly. This setting does not proxy Docker
UDP and does not add `filter/FORWARD` or `POSTROUTING` masquerade rules. Docker
remains responsible for forwarding its networks. Add a network separately to
the complete `NAT_CLIENT_IPS` list only when this project should provide NAT for
it.

Do not configure equal or overlapping CIDRs in `PROXY_DOCKER_LANS` and
`PROXY_CLIENT_IPS`. Doing so would combine the Docker TCP-only path with the
ordinary TCP/UDP client path, return-route rules, and default client NAT.

Set `TAILSCALE_CIDR=` to disable the default Tailscale handling.

## Bind Overrides

The default bind values are:

```env
BIND=0.0.0.0
DNS_BIND=${GATEWAY_IP}
```

Set `BIND` or `DNS_BIND` only when you need a fixed listen address.

## Tests

Run the command-mock regression tests without changing host networking:

```bash
tests/force-proxy-whitelist.sh
tests/proxy-docker-lans.sh
```

## Update

```bash
./meta-config
```

`meta-config` reloads the generated configuration, then refreshes all proxy and
rule providers found from the controller API. If the controller provider list is
unavailable, proxy providers are inferred from `/proxies`, then both provider
types fall back to the generated YAML sections.
