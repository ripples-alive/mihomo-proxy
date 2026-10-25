#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
FAKE_BIN=$TEST_TMP/bin
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/ip" <<'EOF'
#!/bin/bash
exit 0
EOF
cat >"$FAKE_BIN/wget" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"$WGET_LOG"
args=("$@")
url=${args[-1]}
output=/dev/stdout
for ((i=0; i<${#args[@]}; i++)); do
    case "${args[i]}" in
        -O) output=${args[i+1]} ;;
        --output-document=*) output=${args[i]#*=} ;;
    esac
done
case "$url" in
    https://example.invalid/subscription)
        [ "${MOCK_MODE:-}" != download-failure ] || { echo 'secret-url-and-body' >&2; exit 8; }
        [ "${MOCK_MODE:-}" != download-slow ] || sleep 4
        cp "$REMOTE_CONFIG" "$output"
        ;;
    */providers/proxies)
        [ "${MOCK_MODE:-}" != discovery-slow ] || sleep 4
        printf '{"providers":{"entry":{"vehicleType":"HTTP"},"selector":{"vehicleType":"Compatible"}}}\n' >"$output"
        ;;
    */providers/rules)
        [ "${MOCK_MODE:-}" != discovery-slow ] || sleep 4
        printf '{"providers":{"rules":{"vehicleType":"HTTP"}}}\n' >"$output"
        ;;
    */providers/proxies/entry|*/providers/rules/rules)
        [ "${MOCK_MODE:-}" != refresh-slow ] || sleep 4
        [ "${MOCK_MODE:-}" != refresh-failure ] || exit 8
        printf '{}\n' >"$output"
        ;;
    *) printf '{}\n' >"$output" ;;
esac
EOF
chmod +x "$FAKE_BIN/"*

new_fixture() {
    FIXTURE=$TEST_TMP/$1
    mkdir -p "$FIXTURE/providers"
    cp "$ROOT/meta-env" "$ROOT/meta-config" "$FIXTURE/"
    cat >"$FIXTURE/source.yaml" <<'EOF'
secret: old
external-controller: 127.0.0.1:9090
dns:
  listen: 127.0.0.1:53
proxy-providers:
  entry:
    type: http
rule-providers:
  rules:
    type: http
proxy-groups: []
EOF
    cp "$FIXTURE/source.yaml" "$FIXTURE/config.yaml"
    cp "$FIXTURE/source.yaml" "$FIXTURE/remote.yaml"
    printf 'echo "# local hook" >> config.yaml\n' >"$FIXTURE/meta-config.local"
    : >"$FIXTURE/wget.log"
}
run_meta() {
    local mode=$1
    shift
    set +e
    (
        cd "$FIXTURE"
        env PATH="$FAKE_BIN:$PATH" WGET_LOG="$FIXTURE/wget.log" \
            REMOTE_CONFIG="$FIXTURE/source.yaml" MOCK_MODE="$mode" \
            CONFIG_URL=https://example.invalid/subscription PASSWORD=dummy-password \
            OWNER="$(id -u)" DEFAULT_GATEWAY=192.0.2.1 WAN_IF=eth0 GATEWAY_IP=192.0.2.2 \
            LAN_CIDRS=198.51.100.0/24 BIND=127.0.0.1 CONTROLLER_BIND=192.0.2.5 \
            DNS_BIND=127.0.0.1 PROXY_USERS= PROXY_USER_IDS= \
            timeout --kill-after=1s 12s bash ./meta-config "$@" >stdout 2>stderr
    )
    RC=$?
    set -e
}
fail() { echo "FAIL: $*" >&2; exit 1; }
expect_rc() { [ "$RC" -eq "$1" ] || fail "expected rc $1, got $RC ($FIXTURE)"; }
absent() { if grep -Fq -- "$1" "$FIXTURE/wget.log"; then fail "unexpected request $1"; fi; }

new_fixture generate
run_meta refresh-slow --generate-only
expect_rc 0
grep -Fxq 'secret: dummy-password' "$FIXTURE/config.yaml"
grep -Fxq '# local hook' "$FIXTURE/config.yaml"
grep -Fq '"stage":"generate","result":"ok"' "$FIXTURE/stdout"
absent ':9090/'

new_fixture manual
run_meta fast
expect_rc 0
for path in '/configs?force=true' '/providers/proxies/entry' '/providers/rules/rules' '/upgrade/ui'; do
    grep -Fq "$path" "$FIXTURE/wget.log"
done
absent '/providers/proxies/selector'

new_fixture refresh
run_meta fast --refresh-providers-only
expect_rc 0
cmp "$FIXTURE/source.yaml" "$FIXTURE/config.yaml"
absent '/subscription'
absent '/configs?force=true'
absent '/upgrade/ui'
grep -F '/providers/' "$FIXTURE/wget.log" | grep -Fq -- '--no-proxy'

new_fixture slow
started=$SECONDS
run_meta refresh-slow --refresh-providers-only --request-timeout 1 --refresh-timeout 2
expect_rc 2
[ "$((SECONDS - started))" -le 6 ] || fail 'refresh exceeded global budget'
grep -Fq '"rc":124' "$FIXTURE/stdout"
cmp "$FIXTURE/source.yaml" "$FIXTURE/config.yaml"

new_fixture failed-refresh
run_meta refresh-failure --refresh-providers-only
expect_rc 2
grep -Fq '"rc":8' "$FIXTURE/stdout"
absent '/configs?force=true'

new_fixture slow-discovery
run_meta discovery-slow --refresh-providers-only --request-timeout 1 --refresh-timeout 2
expect_rc 2
grep -Fq '"rc":124' "$FIXTURE/stdout"
grep -Fq '"kind":"proxies","provider":""' "$FIXTURE/stdout"

new_fixture failed-download
run_meta download-failure --generate-only
expect_rc 8
cmp "$FIXTURE/source.yaml" "$FIXTURE/config.yaml"
cmp "$FIXTURE/source.yaml" "$FIXTURE/remote.yaml"
grep -Fq '"stage":"download","result":"failed","rc":8' "$FIXTURE/stdout"
absent ':9090/'
[ -z "$(find "$FIXTURE" -name '.remote.yaml.*' -print)" ] || fail 'download temporary file leaked'

new_fixture failed-hook
echo 'exit 42' >"$FIXTURE/meta-config.local"
run_meta fast --generate-only
expect_rc 42
grep -Fq '"stage":"render","result":"failed","rc":42' "$FIXTURE/stdout"
absent ':9090/'

new_fixture bad-flag
run_meta fast --unsupported
expect_rc 64
[ ! -s "$FIXTURE/wget.log" ] || fail 'unsupported flag caused network access'
run_meta fast --generate-only --refresh-providers-only
expect_rc 64
run_meta fast --refresh-timeout 0
expect_rc 64

echo 'config stage tests passed (11 cases)'
