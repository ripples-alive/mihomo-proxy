#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
FIXTURE=$TEST_TMP/fixture
FAKE_BIN=$TEST_TMP/bin
trap 'rm -rf "$TEST_TMP"' EXIT

mkdir -p "$FIXTURE" "$FAKE_BIN"
cp "$ROOT/meta-env" "$ROOT/meta-up" "$ROOT/meta-down" "$FIXTURE/"
cat >"$FAKE_BIN/command-mock" <<'EOF'
#!/bin/bash
{
    printf '%s' "$(basename "$0")"
    printf '|%s' "$@"
    printf '\n'
} >>"$COMMAND_LOG"
EOF
chmod +x "$FAKE_BIN/command-mock"
for command in ip ipset iptables sleep; do
    ln -s command-mock "$FAKE_BIN/$command"
done

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local expected="$1"
    local file="$2"

    grep -Fq -- "$expected" "$file" || fail "missing '$expected' in $file"
}

assert_not_contains() {
    local unexpected="$1"
    local file="$2"

    if grep -Fq -- "$unexpected" "$file"; then
        fail "unexpected '$unexpected' in $file"
    fi
}

assert_line_count() {
    local expected_count="$1"
    local expected_line="$2"
    local file="$3"
    local actual_count

    actual_count=$(grep -Fxc -- "$expected_line" "$file" || true)
    [ "$actual_count" -eq "$expected_count" ] ||
        fail "expected $expected_count copies of '$expected_line', found $actual_count"
}

assert_before() {
    local earlier="$1"
    local later="$2"
    local file="$3"
    local earlier_line later_line

    earlier_line=$(grep -Fnx -- "$earlier" "$file" | head -n 1 | cut -d: -f1 || true)
    later_line=$(grep -Fnx -- "$later" "$file" | head -n 1 | cut -d: -f1 || true)
    [ -n "$earlier_line" ] || fail "missing earlier command '$earlier'"
    [ -n "$later_line" ] || fail "missing later command '$later'"
    [ "$earlier_line" -lt "$later_line" ] || fail "'$earlier' must precede '$later'"
}

run_meta() {
    local action="$1"
    local name="$2"
    local bridge_mode="$3"
    local bridge_lans="$4"
    local command_log="$TEST_TMP/$name.commands"
    local -a unset_options=()
    local -a environment=(
        "PATH=$FAKE_BIN:$PATH"
        "COMMAND_LOG=$command_log"
        "DIR_NAME=$FIXTURE"
        "OWNER=0"
        "CONFIG_URL="
        "DEFAULT_ROUTE=default via 192.0.2.1 dev eth0 src 192.0.2.2"
        "DEFAULT_GATEWAY=192.0.2.1"
        "WAN_IF=eth0"
        "GATEWAY_IP=192.0.2.2"
        "LAN_CIDRS=198.51.100.128/25"
        "BIND=127.0.0.1"
        "DNS_BIND=127.0.0.1"
        "CHAIN_NAME=meta"
        "MARK_VALUE=7"
        "ROUTE_TABLE=99"
        "TPROXY_IP=127.0.0.1"
        "TAILSCALE_CIDR=203.0.113.192/26"
        "FORCE_PROXY_IPS=192.0.2.192/26"
        "NO_PROXY_IPS=203.0.113.0/26"
        "PROXY_CLIENT_IPS=203.0.113.64/26"
        "NAT_CLIENT_IPS=203.0.113.64/26"
        "PROXY_USERS="
        "PROXY_USER_IDS=1001"
    )

    if [ "$bridge_mode" = absent ]; then
        unset_options+=(-u PROXY_BRIDGE_LANS)
    else
        environment+=("PROXY_BRIDGE_LANS=$bridge_lans")
    fi

    : >"$command_log"
    if ! env "${unset_options[@]}" "${environment[@]}" bash "$FIXTURE/meta-$action" >/dev/null 2>&1; then
        fail "meta-$action failed for $name"
    fi
    printf '%s\n' "$command_log"
}

absent_up_log=$(run_meta up absent-up absent "")
empty_up_log=$(run_meta up empty-up present "")
cmp -s "$absent_up_log" "$empty_up_log" || fail "absent and empty settings emitted different commands"
assert_not_contains '|conntrack|--ctdir|REPLY|' "$absent_up_log"
assert_line_count 1 'ip|rule|add|fwmark|7|to|203.0.113.64/26|lookup|main' "$absent_up_log"
assert_line_count 1 'iptables|-t|mangle|-I|PREROUTING|-s|203.0.113.64/26|!|-d|203.0.113.64/26|-j|meta' "$absent_up_log"
assert_line_count 1 'iptables|-I|FORWARD|-s|203.0.113.64/26|-j|ACCEPT' "$absent_up_log"
assert_line_count 1 'iptables|-I|FORWARD|-d|203.0.113.64/26|-m|conntrack|--ctstate|ESTABLISHED,RELATED|-j|ACCEPT' "$absent_up_log"
assert_line_count 1 'iptables|-I|FORWARD|-s|203.0.113.192/26|-j|ACCEPT' "$absent_up_log"
assert_line_count 1 'iptables|-I|FORWARD|-d|203.0.113.192/26|-m|conntrack|--ctstate|ESTABLISHED,RELATED|-j|ACCEPT' "$absent_up_log"

bridge_lans='192.0.2.0/26,198.51.100.0/26:203.0.113.128/26'
configured_up_log=$(run_meta up configured-up present "$bridge_lans")
force_udp='iptables|-t|mangle|-A|meta|-d|192.0.2.192/26|-p|udp|-j|TPROXY|--on-ip|127.0.0.1|--on-port|7893|--tproxy-mark|1'
force_tcp='iptables|-t|mangle|-A|meta|-d|192.0.2.192/26|-p|tcp|-j|TPROXY|--on-ip|127.0.0.1|--on-port|7893|--tproxy-mark|1'

for bridge_lan in 192.0.2.0/26 198.51.100.0/26 203.0.113.128/26; do
    reply_rule="iptables|-t|mangle|-A|meta|-s|$bridge_lan|-p|tcp|-m|conntrack|--ctdir|REPLY|-j|RETURN"
    return_rule="ip|rule|add|fwmark|7|to|$bridge_lan|lookup|main"
    prerouting_rule="iptables|-t|mangle|-I|PREROUTING|-s|$bridge_lan|!|-d|$bridge_lan|-p|tcp|-j|meta"

    assert_line_count 1 "$reply_rule" "$configured_up_log"
    assert_line_count 1 "$return_rule" "$configured_up_log"
    assert_line_count 1 "$prerouting_rule" "$configured_up_log"
    assert_not_contains "iptables|-I|FORWARD|-s|$bridge_lan|" "$configured_up_log"
    assert_not_contains "iptables|-I|FORWARD|-d|$bridge_lan|" "$configured_up_log"
    assert_before "$reply_rule" "$force_udp" "$configured_up_log"
    assert_before "$reply_rule" "$force_tcp" "$configured_up_log"
    assert_not_contains "iptables|-t|mangle|-I|PREROUTING|-s|$bridge_lan|!|-d|$bridge_lan|-p|udp" "$configured_up_log"
    assert_not_contains "iptables|-t|mangle|-I|PREROUTING|-s|$bridge_lan|!|-d|$bridge_lan|-j|meta" "$configured_up_log"
    assert_not_contains "iptables|-t|nat|-I|POSTROUTING|-s|$bridge_lan|" "$configured_up_log"
    assert_not_contains "iptables|-t|nat|-A|meta|-s|$bridge_lan|" "$configured_up_log"
done

assert_line_count 1 'iptables|-t|nat|-I|POSTROUTING|-s|203.0.113.64/26|!|-d|203.0.113.64/26|-o|eth0|-j|MASQUERADE' "$configured_up_log"
assert_line_count 1 'iptables|-t|mangle|-I|PREROUTING|-s|203.0.113.64/26|!|-d|203.0.113.64/26|-j|meta' "$configured_up_log"
assert_line_count 1 'iptables|-I|FORWARD|-s|203.0.113.64/26|-j|ACCEPT' "$configured_up_log"
assert_line_count 1 'iptables|-I|FORWARD|-d|203.0.113.64/26|-m|conntrack|--ctstate|ESTABLISHED,RELATED|-j|ACCEPT' "$configured_up_log"
assert_line_count 1 'iptables|-I|FORWARD|-s|203.0.113.192/26|-j|ACCEPT' "$configured_up_log"
assert_line_count 1 'iptables|-I|FORWARD|-d|203.0.113.192/26|-m|conntrack|--ctstate|ESTABLISHED,RELATED|-j|ACCEPT' "$configured_up_log"
assert_line_count 1 'iptables|-t|nat|-I|OUTPUT|-m|owner|--uid-owner|1001|-p|tcp|-j|meta' "$configured_up_log"

absent_down_log=$(run_meta down absent-down absent "")
empty_down_log=$(run_meta down empty-down present "")
cmp -s "$absent_down_log" "$empty_down_log" || fail "absent and empty teardown settings emitted different commands"
assert_not_contains '|conntrack|--ctdir|REPLY|' "$absent_down_log"
assert_line_count 1 'iptables|-D|FORWARD|-s|203.0.113.64/26|-j|ACCEPT' "$absent_down_log"
assert_line_count 1 'iptables|-D|FORWARD|-d|203.0.113.64/26|-m|conntrack|--ctstate|ESTABLISHED,RELATED|-j|ACCEPT' "$absent_down_log"
assert_line_count 1 'iptables|-D|FORWARD|-s|203.0.113.192/26|-j|ACCEPT' "$absent_down_log"
assert_line_count 1 'iptables|-D|FORWARD|-d|203.0.113.192/26|-m|conntrack|--ctstate|ESTABLISHED,RELATED|-j|ACCEPT' "$absent_down_log"

configured_down_log=$(run_meta down configured-down present "$bridge_lans")
for bridge_lan in 192.0.2.0/26 198.51.100.0/26 203.0.113.128/26; do
    assert_line_count 1 "ip|rule|del|fwmark|7|to|$bridge_lan|lookup|main" "$configured_down_log"
    assert_line_count 1 "iptables|-t|mangle|-D|PREROUTING|-s|$bridge_lan|!|-d|$bridge_lan|-p|tcp|-j|meta" "$configured_down_log"
    assert_not_contains "iptables|-D|FORWARD|-s|$bridge_lan|" "$configured_down_log"
    assert_not_contains "iptables|-D|FORWARD|-d|$bridge_lan|" "$configured_down_log"
    assert_not_contains "iptables|-t|mangle|-D|PREROUTING|-s|$bridge_lan|!|-d|$bridge_lan|-p|udp" "$configured_down_log"
    assert_not_contains "iptables|-t|nat|-D|POSTROUTING|-s|$bridge_lan|" "$configured_down_log"
done

assert_line_count 1 'iptables|-D|FORWARD|-s|203.0.113.64/26|-j|ACCEPT' "$configured_down_log"
assert_line_count 1 'iptables|-D|FORWARD|-d|203.0.113.64/26|-m|conntrack|--ctstate|ESTABLISHED,RELATED|-j|ACCEPT' "$configured_down_log"
assert_line_count 1 'iptables|-D|FORWARD|-s|203.0.113.192/26|-j|ACCEPT' "$configured_down_log"
assert_line_count 1 'iptables|-D|FORWARD|-d|203.0.113.192/26|-m|conntrack|--ctstate|ESTABLISHED,RELATED|-j|ACCEPT' "$configured_down_log"
assert_contains 'iptables|-t|mangle|-F|meta' "$configured_down_log"
assert_contains 'iptables|-t|mangle|-X|meta' "$configured_down_log"
assert_contains 'ip|rule|del|fwmark|7|lookup|99' "$configured_down_log"
assert_contains 'ip|route|flush|table|99' "$configured_down_log"

echo "proxy bridge LAN tests passed"
