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
    local force_mode="$3"
    local force_proxy_ips="$4"
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
        "LAN_CIDRS=198.51.100.0/24"
        "BIND=127.0.0.1"
        "DNS_BIND=127.0.0.1"
        "CHAIN_NAME=meta"
        "MARK_VALUE=1"
        "ROUTE_TABLE=99"
        "TPROXY_IP=127.0.0.1"
        "TAILSCALE_CIDR="
        "NO_PROXY_IPS=203.0.113.0/25"
        "PROXY_CLIENT_IPS=192.0.2.0/25"
        "NAT_CLIENT_IPS=192.0.2.0/25"
        "PROXY_DOCKER_LANS="
        "PROXY_USERS="
        "PROXY_USER_IDS=1001"
    )

    if [ "$force_mode" = absent ]; then
        unset_options+=(-u FORCE_PROXY_IPS)
    else
        environment+=("FORCE_PROXY_IPS=$force_proxy_ips")
    fi

    : >"$command_log"
    if ! env "${unset_options[@]}" "${environment[@]}" bash "$FIXTURE/meta-$action" >/dev/null 2>&1; then
        fail "meta-$action failed for $name"
    fi
    printf '%s\n' "$command_log"
}

absent_log=$(run_meta up absent absent "")
empty_log=$(run_meta up empty present "")
cmp -s "$absent_log" "$empty_log" || fail "absent and empty settings emitted different commands"
assert_not_contains 'iptables|-t|mangle|-A|meta|-d|' "$absent_log"
assert_not_contains 'iptables|-t|nat|-A|meta|-d|' "$absent_log"

force_list='198.51.100.42,198.51.100.128/25:203.0.113.64/26'
configured_log=$(run_meta up configured present "$force_list")
mangle_bypass='iptables|-t|mangle|-A|meta|-m|set|--match-set|meta_bypass|dst|-j|RETURN'
nat_bypass='iptables|-t|nat|-A|meta|-m|set|--match-set|meta_bypass|dst|-j|RETURN'
mangle_returns=(
    'iptables|-t|mangle|-A|meta|-p|udp|--sport|41641|-j|RETURN'
    'iptables|-t|mangle|-A|meta|-p|udp|--dport|41641|-j|RETURN'
    'iptables|-t|mangle|-A|meta|-p|udp|--dport|3478|-j|RETURN'
)
nat_returns=(
    'iptables|-t|nat|-A|meta|-p|udp|--sport|41641|-j|RETURN'
    'iptables|-t|nat|-A|meta|-p|udp|--dport|41641|-j|RETURN'
    'iptables|-t|nat|-A|meta|-p|udp|--dport|3478|-j|RETURN'
)

for destination in 198.51.100.42 198.51.100.128/25 203.0.113.64/26; do
    mangle_udp="iptables|-t|mangle|-A|meta|-d|$destination|-p|udp|-j|TPROXY|--on-ip|127.0.0.1|--on-port|7893|--tproxy-mark|1"
    mangle_tcp="iptables|-t|mangle|-A|meta|-d|$destination|-p|tcp|-j|TPROXY|--on-ip|127.0.0.1|--on-port|7893|--tproxy-mark|1"
    nat_udp="iptables|-t|nat|-A|meta|-d|$destination|-p|udp|-j|REDIRECT|--to-ports|7892"
    nat_tcp="iptables|-t|nat|-A|meta|-d|$destination|-p|tcp|-j|REDIRECT|--to-ports|7892"

    assert_line_count 1 "$mangle_udp" "$configured_log"
    assert_line_count 1 "$mangle_tcp" "$configured_log"
    assert_line_count 1 "$nat_udp" "$configured_log"
    assert_line_count 1 "$nat_tcp" "$configured_log"
    assert_before "$mangle_udp" "$mangle_bypass" "$configured_log"
    assert_before "$mangle_tcp" "$mangle_bypass" "$configured_log"
    assert_before "$nat_udp" "$nat_bypass" "$configured_log"
    assert_before "$nat_tcp" "$nat_bypass" "$configured_log"
    for return_rule in "${mangle_returns[@]}"; do
        assert_before "$mangle_udp" "$return_rule" "$configured_log"
        assert_before "$mangle_tcp" "$return_rule" "$configured_log"
    done
    for return_rule in "${nat_returns[@]}"; do
        assert_before "$nat_udp" "$return_rule" "$configured_log"
        assert_before "$nat_tcp" "$return_rule" "$configured_log"
    done
done

duplicate_log=$(run_meta up duplicate present '198.51.100.42,198.51.100.42')
assert_line_count 2 'iptables|-t|mangle|-A|meta|-d|198.51.100.42|-p|udp|-j|TPROXY|--on-ip|127.0.0.1|--on-port|7893|--tproxy-mark|1' "$duplicate_log"
assert_line_count 2 'iptables|-t|mangle|-A|meta|-d|198.51.100.42|-p|tcp|-j|TPROXY|--on-ip|127.0.0.1|--on-port|7893|--tproxy-mark|1' "$duplicate_log"
assert_line_count 2 'iptables|-t|nat|-A|meta|-d|198.51.100.42|-p|udp|-j|REDIRECT|--to-ports|7892' "$duplicate_log"
assert_line_count 2 'iptables|-t|nat|-A|meta|-d|198.51.100.42|-p|tcp|-j|REDIRECT|--to-ports|7892' "$duplicate_log"

for log in "$absent_log" "$configured_log"; do
    assert_line_count 1 'ip|rule|add|fwmark|1|lookup|99' "$log"
    assert_line_count 1 'ip|route|add|local|0.0.0.0/0|dev|lo|table|99' "$log"
    assert_line_count 1 'ip|rule|add|fwmark|1|to|192.0.2.0/25|lookup|main' "$log"
    assert_line_count 1 'iptables|-t|mangle|-I|PREROUTING|-s|192.0.2.0/25|!|-d|192.0.2.0/25|-j|meta' "$log"
    assert_line_count 1 'iptables|-I|FORWARD|-s|192.0.2.0/25|-j|ACCEPT' "$log"
    assert_line_count 1 'iptables|-I|FORWARD|-d|192.0.2.0/25|-m|conntrack|--ctstate|ESTABLISHED,RELATED|-j|ACCEPT' "$log"
    assert_line_count 1 'iptables|-t|nat|-I|OUTPUT|-m|owner|--uid-owner|1001|-p|tcp|-j|meta' "$log"
    assert_not_contains 'iptables|-t|nat|-I|OUTPUT|-m|owner|--uid-owner|1001|-p|udp|' "$log"
    assert_line_count 1 'iptables|-t|mangle|-N|meta' "$log"
    assert_line_count 1 'iptables|-t|nat|-N|meta' "$log"
    assert_not_contains 'meta_force' "$log"
    assert_not_contains 'force-handoff' "$log"
    assert_not_contains 'ip|rule|show' "$log"
    assert_not_contains '|fwmark|0x' "$log"
done

absent_down_log=$(run_meta down absent-down absent "")
configured_down_log=$(run_meta down configured-down present "$force_list")
cmp -s "$absent_down_log" "$configured_down_log" || fail "FORCE_PROXY_IPS changed teardown commands"
assert_contains 'iptables|-t|mangle|-F|meta' "$configured_down_log"
assert_contains 'iptables|-t|mangle|-X|meta' "$configured_down_log"
assert_contains 'iptables|-t|nat|-F|meta' "$configured_down_log"
assert_contains 'iptables|-t|nat|-X|meta' "$configured_down_log"
assert_line_count 1 'iptables|-D|FORWARD|-s|192.0.2.0/25|-j|ACCEPT' "$configured_down_log"
assert_line_count 1 'iptables|-D|FORWARD|-d|192.0.2.0/25|-m|conntrack|--ctstate|ESTABLISHED,RELATED|-j|ACCEPT' "$configured_down_log"
assert_contains 'ip|rule|del|fwmark|1|lookup|99' "$configured_down_log"
assert_contains 'ip|route|flush|table|99' "$configured_down_log"
assert_not_contains 'meta_force' "$configured_down_log"
assert_not_contains 'force-handoff' "$configured_down_log"
assert_not_contains 'ip|rule|show' "$configured_down_log"

echo "force-proxy whitelist tests passed"
