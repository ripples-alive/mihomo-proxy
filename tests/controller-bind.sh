#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

run_case() {
    local name="$1"
    local controller_bind="$2"
    local fixture="$TEST_TMP/$name"
    local fake_bin="$fixture/bin"
    local log="$fixture/wget.log"

    mkdir -p "$fixture" "$fake_bin/providers"
    cp "$ROOT/meta-env" "$ROOT/meta-config" "$fixture/"
    cat >"$fixture/remote.yaml" <<'EOF'
secret: old-secret
external-controller: 127.0.0.1:9090
dns:
  enable: true
  listen: 127.0.0.1:53
proxies:
proxy-groups:
EOF

    cat >"$fake_bin/ip" <<'EOF'
#!/bin/bash
exit 0
EOF
    cat >"$fake_bin/wget" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"$WGET_LOG"
if [[ "${1:-}" == "-O" && "${2:-}" == "remote.yaml" ]]; then
    if [[ "$REMOTE_CONFIG" != "$PWD/remote.yaml" ]]; then
        cp "$REMOTE_CONFIG" remote.yaml
    fi
    exit 0
fi
printf '{}\n'
EOF
    chmod +x "$fake_bin/ip" "$fake_bin/wget"

    local controller_args=()
    if [[ -n "$controller_bind" ]]; then
        controller_args=("CONTROLLER_BIND=$controller_bind")
    fi
    (
        cd "$fixture"
        env \
            "PATH=$fake_bin:$PATH" \
            "WGET_LOG=$log" \
            "REMOTE_CONFIG=$fixture/remote.yaml" \
            "CONFIG_URL=https://example.invalid/subscription" \
            "PASSWORD=rendered-secret" \
            "OWNER=$(id -u)" \
            "DEFAULT_ROUTE=" \
            "DEFAULT_GATEWAY=192.0.2.1" \
            "WAN_IF=eth0" \
            "GATEWAY_IP=192.0.2.2" \
            "LAN_CIDRS=198.51.100.0/24" \
            "BIND=127.0.0.1" \
            "DNS_BIND=127.0.0.1" \
            "PROXY_USERS=" \
            "PROXY_USER_IDS=" \
            "${controller_args[@]}" \
            bash ./meta-config >/dev/null 2>&1
    )

    if [[ -n "$controller_bind" ]]; then
        grep -Fxq 'external-controller: 192.0.2.5:9090' "$fixture/config.yaml"
        grep -Fq 'http://192.0.2.5:9090/configs?force=true' "$log"
        grep -Fq 'http://192.0.2.5:9090/upgrade/ui' "$log"
    else
        grep -Fxq 'external-controller: 127.0.0.1:9090' "$fixture/config.yaml"
        grep -Fq 'http://127.0.0.1:9090/configs?force=true' "$log"
        grep -Fq 'http://127.0.0.1:9090/upgrade/ui' "$log"
    fi
    grep -Fxq 'secret: rendered-secret' "$fixture/config.yaml"
}

run_case separate-controller 192.0.2.5
run_case legacy-fallback ''

echo "controller bind tests passed"
