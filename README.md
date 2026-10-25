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
UDP_BYPASS_PORTS=
NO_PROXY_IPS=
PROXY_CLIENT_IPS=
NAT_CLIENT_IPS=
PROXY_BRIDGE_LANS=
TAILSCALE_CIDR=100.64.0.0/10
```

`FORCE_PROXY_IPS` defaults to empty and accepts comma- or colon-separated IPv4
hosts and CIDRs, for example `192.0.2.42,198.51.100.128/25`.
`UDP_BYPASS_PORTS` defaults to empty and accepts comma- or colon-separated UDP
ports between 1 and 65535. Each configured port gets both source-port and
destination-port exceptions in the mangle and nat proxy chains. Use it for
transport protocols such as Tailscale, STUN, or WireGuard that must not enter
the application-layer TProxy; for example, a service deployment may provide
`UDP_BYPASS_PORTS=3478,41641,43188`.

These transport exceptions are emitted before the forced destination rules, so
an endpoint inside a forced range is not sent through the application-layer
TProxy. This ordering also avoids `EADDRINUSE` when a local wildcard listener
owns the original UDP port needed for a transparent reply. Forced rules still
precede the ordinary private destination bypass and general UDP/TCP
interception, but only traffic already eligible through the existing
`PROXY_CLIENT_IPS`, `PROXY_BRIDGE_LANS`, or TCP-only local-user entry paths is
considered. Mihomo still decides the final DIRECT, REJECT, proxy, or other
outbound. After changing the list, restart Mihomo to rebuild the rules; to roll
back, remove or empty the setting and restart again.

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

`PROXY_BRIDGE_LANS` defaults to empty and accepts comma- or colon-separated
IPv4 CIDRs, for example `192.0.2.0/26,198.51.100.0/26`. Each listed bridge
network gets a TCP-only TProxy entry from `mangle/PREROUTING` and a marked
return route through the main routing table. TCP packets in the conntrack
`REPLY` direction return before `FORCE_PROXY_IPS`, so replies for connections
initiated toward a bridge guest are not treated as new transparent-proxy
connections. Ordinary private destinations still use the existing bypass,
while forced destinations continue to take precedence for guest-initiated TCP.

Bridge network owners remain responsible for their own forwarding and NAT.
`PROXY_BRIDGE_LANS` does not proxy UDP and does not add `filter/FORWARD` or
`POSTROUTING` masquerade rules. Add a network separately to the complete
`NAT_CLIENT_IPS` list only when this project should provide NAT for it.

Automatic LAN discovery excludes interfaces whose names start with `lo`,
`docker`, `tailscale`, `wg`, `br-`, `virbr`, or `lxd`.

Do not configure equal or overlapping CIDRs in `PROXY_BRIDGE_LANS` and
`PROXY_CLIENT_IPS`. Doing so would combine the bridge TCP-only path with the
ordinary TCP/UDP client path, return-route rules, and default client NAT.

Set `TAILSCALE_CIDR=` to disable the default Tailscale handling.

## Bind Overrides

The default bind values are:

```env
BIND=0.0.0.0
DNS_BIND=${GATEWAY_IP}
CONTROLLER_BIND=${BIND}
```

`BIND` controls the proxy listeners. `CONTROLLER_BIND` controls the Mihomo
external controller on port 9090 and may be different from `BIND`. The
controller API URL used by the helper scripts is derived from this value;
`0.0.0.0` is probed through `127.0.0.1`. Set `BIND`, `DNS_BIND`, or
`CONTROLLER_BIND` only when you need a fixed listen address.

## Tests

Run the command-mock regression tests without changing host networking:

```bash
tests/force-proxy-whitelist.sh
tests/proxy-bridge-lans.sh
```

## Update

```bash
./meta-config
```

`meta-config` reloads the generated configuration, then refreshes all proxy and
rule providers and attempts a UI update. HTTP providers are discovered from the
controller API; synthetic Compatible providers (including selectors) are skipped.
If discovery is unavailable, the generated YAML provider sections are used as a
fallback and the incomplete discovery is reported.

Deployment tools can separate configuration generation from runtime updates:

```bash
./meta-config --generate-only
# Validate the generated configuration, then start/restart Mihomo as needed.
./meta-config --refresh-providers-only --request-timeout 10 --refresh-timeout 120
```

`--generate-only` downloads the subscription, applies the local configuration
hook and permissions, and returns without accessing the controller or updating
the UI. A failed or empty download preserves the previous configuration and
downloaded source. A generator/hook failure remains a nonzero exit.
The main subscription download allows up to three transport attempts within a
190-second budget: each attempt has a 60-second wall-clock ceiling, with 2- and
5-second backoffs. The final attempt is shortened if necessary to keep both
backoff and the two-second forced-kill grace inside the shared budget. Only
network failures and timeouts are retried; HTTP error responses, certificate
verification failures, authentication errors and empty responses fail immediately.
Every attempt writes to a temporary file, so exhausted retries preserve the old
configuration and source. Deployment callers should use one 210-second outer
guard for the entire generation command, including local hooks and permissions.
Do not wrap the command in another retry loop.

`--download-direct-fallback` opts into direct access after the first transport
failure: with a configured proxy the sequence is proxy, direct, direct; without
a configured proxy all three attempts are direct. Direct requests disable Wget
proxy use explicitly, and fallback clears all upper/lower-case proxy variables
only for that request. The default manual invocation retries using its original
proxy environment and does not opt into direct fallback.

`--refresh-providers-only` never generates or reloads configuration, changes
configuration permissions, or updates the UI. Controller requests bypass proxy
environment variables and have a single attempt, a 10-second wall-clock limit
per request and a shared 120-second refresh budget by default. The two timeout
options accept positive integer seconds (1–999); GNU `timeout` is required.
Exit status is `0` for complete refresh and `2` for incomplete discovery or
refresh, including exhaustion of the budget. The caller must separately inspect
the controller's required providers before treating an incomplete refresh as a
warning: this exit status alone does not prove cached data is usable.

Stage records use the `META_CONFIG_STATUS ` prefix followed by JSON containing
`stage`, `result`, `rc`, elapsed seconds, provider `kind`, and a URI-encoded
`provider` name. Download records additionally carry an `attempt` number,
`route` (`proxy` or `direct`), `attempt_elapsed` seconds and an allow-listed
`failure_class`; older interface-v1 consumers can ignore these
additional fields. They contain no subscription URL, password or HTTP response
body. Other command output may still be sensitive and should remain protected.
An external timeout can exit `124` (or `137` after a forced kill).

Consumers must check the exact source line `# meta-config-interface: 1` before
executing these modes. Do not probe an older script by passing new flags or
`--help`: older versions ignore arguments and execute the full workflow. Publish
the compatible script revision before enabling the new deployment calls.
Before using `--download-direct-fallback`, also require the exact source marker
`# meta-config-download-interface: 1` without executing the script.

Local Linux regression tests (requests and firewall commands are mocked):

```bash
bash tests/config-stages.sh
bash tests/controller-bind.sh
bash tests/force-proxy-whitelist.sh
bash tests/proxy-bridge-lans.sh
```
