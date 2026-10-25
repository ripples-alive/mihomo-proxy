#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
FAKE_BIN=$TEST_TMP/bin
REAL_TIMEOUT=$(command -v timeout)
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/timeout" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ "${MOCK_MODE:-}" == download-timeout && "$*" == *https://example.invalid/subscription* ]]; then
    printf '%s\n' "$*" >>"$TIMEOUT_LOG"
    exit 124
fi
exec "$REAL_TIMEOUT" "$@"
EOF
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
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "${http_proxy:-}" "${https_proxy:-}" "${all_proxy:-}" \
            "${HTTP_PROXY:-}" "${HTTPS_PROXY:-}" "${ALL_PROXY:-}" \
            "${no_proxy:-}" "${NO_PROXY:-}" "$*" >>"$DOWNLOAD_ENV_LOG"
        count=$(cat "$DOWNLOAD_COUNTER" 2>/dev/null || echo 0)
        count=$((count + 1))
        printf '%s\n' "$count" >"$DOWNLOAD_COUNTER"
        if [[ "${MOCK_MODE:-}" == network-failure || ( "${MOCK_MODE:-}" == network-flaky && "$count" == 1 ) || ( "${MOCK_MODE:-}" == network-twice && "$count" -le 2 ) ]]; then
            printf 'partial download, not a config\n' >"$output"
            exit 4
        fi
        [ "${MOCK_MODE:-}" != certificate-failure ] || exit 5
        [ "${MOCK_MODE:-}" != empty-download ] || { : >"$output"; exit 0; }
        [ "${MOCK_MODE:-}" != download-failure ] || { echo 'secret-url-and-body' >&2; exit 8; }
        [ "${MOCK_MODE:-}" != download-slow ] || sleep 4
        [ "${MOCK_MODE:-}" != download-valid-slow ] || sleep 28
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
            REAL_TIMEOUT="$REAL_TIMEOUT" TIMEOUT_LOG="$FIXTURE/timeout.log" \
            DOWNLOAD_COUNTER="$FIXTURE/download-count" \
            DOWNLOAD_ENV_LOG="$FIXTURE/download-env.log" \
            http_proxy="${TEST_PROXY:-}" https_proxy="${TEST_PROXY:-}" all_proxy="${TEST_PROXY:-}" \
            HTTP_PROXY="${TEST_PROXY:-}" HTTPS_PROXY="${TEST_PROXY:-}" ALL_PROXY="${TEST_PROXY:-}" \
            no_proxy=skip.invalid NO_PROXY=skip.invalid \
            REMOTE_CONFIG="$FIXTURE/source.yaml" MOCK_MODE="$mode" \
            CONFIG_URL=https://example.invalid/subscription PASSWORD=dummy-password \
            OWNER="$(id -u)" DEFAULT_GATEWAY=192.0.2.1 WAN_IF=eth0 GATEWAY_IP=192.0.2.2 \
            LAN_CIDRS=198.51.100.0/24 BIND=127.0.0.1 CONTROLLER_BIND=192.0.2.5 \
            DNS_BIND=127.0.0.1 PROXY_USERS= PROXY_USER_IDS= \
            timeout --kill-after=1s 40s bash ./meta-config "$@" >stdout 2>stderr
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
[ "$(cat "$FIXTURE/download-count")" -eq 1 ] || fail 'HTTP errors must not be retried'

new_fixture transient-network
run_meta network-flaky --generate-only
expect_rc 0
[ "$(cat "$FIXTURE/download-count")" -eq 2 ] || fail 'network failure was not retried'
cmp "$FIXTURE/source.yaml" "$FIXTURE/remote.yaml"
grep -Fq '"attempt":1,"failure_class":"network"' "$FIXTURE/stdout"
grep -Fq '"attempt":2,"failure_class":""' "$FIXTURE/stdout"
absent ':9090/'

new_fixture persistent-network
run_meta network-failure --generate-only
expect_rc 4
[ "$(cat "$FIXTURE/download-count")" -eq 3 ] || fail 'network retry count is not bounded at three'
cmp "$FIXTURE/source.yaml" "$FIXTURE/config.yaml"
cmp "$FIXTURE/source.yaml" "$FIXTURE/remote.yaml"
grep -Fq '"attempt":3,"failure_class":"network"' "$FIXTURE/stdout"
absent ':9090/'

new_fixture certificate-error
run_meta certificate-failure --generate-only
expect_rc 5
[ "$(cat "$FIXTURE/download-count")" -eq 1 ] || fail 'certificate errors must not be retried'
cmp "$FIXTURE/source.yaml" "$FIXTURE/config.yaml"
grep -Fq '"failure_class":"certificate"' "$FIXTURE/stdout"

new_fixture download-deadline
run_meta download-timeout --generate-only
expect_rc 124
[ "$(wc -l <"$FIXTURE/timeout.log")" -eq 3 ] || fail 'timeout retry count is not bounded'
grep -Fq -- '--kill-after=2s 60s wget' "$FIXTURE/timeout.log"
grep -Fq '"attempt":3,"failure_class":"timeout"' "$FIXTURE/stdout"
cmp "$FIXTURE/source.yaml" "$FIXTURE/config.yaml"
cmp "$FIXTURE/source.yaml" "$FIXTURE/remote.yaml"

new_fixture empty-response
run_meta empty-download --generate-only
expect_rc 65
[ "$(cat "$FIXTURE/download-count")" -eq 1 ] || fail 'empty response was retried'
cmp "$FIXTURE/source.yaml" "$FIXTURE/config.yaml"
grep -Fq '"failure_class":"empty_response"' "$FIXTURE/stdout"

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

new_fixture slow-valid-download
started=$SECONDS
run_meta download-valid-slow --generate-only
expect_rc 0
[ "$((SECONDS - started))" -ge 28 ] || fail 'slow download was not exercised'
cmp "$FIXTURE/source.yaml" "$FIXTURE/remote.yaml"
absent ':9090/'

new_fixture proxy-direct-fallback
TEST_PROXY=http://127.0.0.1:9 run_meta network-twice --generate-only --download-direct-fallback
expect_rc 0
[ "$(cat "$FIXTURE/download-count")" -eq 3 ] || fail 'shared three-attempt budget was not used'
head -n 1 "$FIXTURE/download-env.log" | grep -Fq 'http://127.0.0.1:9'
tail -n 2 "$FIXTURE/download-env.log" | while IFS= read -r line; do
    [[ "$line" == '||||||||'* ]] || fail 'proxy environment leaked into direct fallback'
    [[ "$line" == *--no-proxy* ]] || fail 'direct fallback allows wgetrc proxy'
done
grep -Fq '"attempt":1,"failure_class":"network","route":"proxy"' "$FIXTURE/stdout"
grep -Fq '"attempt":2,"failure_class":"network","route":"direct"' "$FIXTURE/stdout"
grep -Fq '"attempt":3,"failure_class":"","route":"direct"' "$FIXTURE/stdout"
cmp "$FIXTURE/source.yaml" "$FIXTURE/remote.yaml"

new_fixture manual-keeps-proxy
TEST_PROXY=http://127.0.0.1:9 run_meta network-flaky --generate-only
expect_rc 0
[ "$(grep -Fc 'http://127.0.0.1:9' "$FIXTURE/download-env.log")" -eq 2 ] || fail 'manual retry unexpectedly bypassed proxy'

new_fixture bounded-download-time
# Shorten only this fixture's clock constants, keeping the real timeout utility.
sed -i -e 's/SECONDS + 190/SECONDS + 8/' -e 's/limit=60/limit=2/' \
    -e 's/delay=2/delay=1/' -e 's/delay=5/delay=1/' "$FIXTURE/meta-config"
started=$SECONDS
run_meta download-slow --generate-only
expect_rc 124
[ "$((SECONDS - started))" -le 9 ] || fail 'download exceeded shared budget'
cmp "$FIXTURE/source.yaml" "$FIXTURE/config.yaml"
cmp "$FIXTURE/source.yaml" "$FIXTURE/remote.yaml"

echo 'config stage tests passed (20 cases)'
