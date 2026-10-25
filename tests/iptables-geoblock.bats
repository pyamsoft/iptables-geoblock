#!/usr/bin/env bats
#
# $ bats tests/iptables-geoblock.bats

# Using flags on run warning
bats_require_minimum_version 1.5.0

load test_helper

setup() {
  if ! gb_can_unshare; then
    skip "unprivileged user namespaces (unshare --user) are not available"
  fi

  if ! gb_has_xtables_addons; then
    skip "iptables, ip6tables and xtables-addons (${GB_HOST_GEOIP_DIR}) must be installed"
  fi

  ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="${ROOT}/iptables-geoblock"

  export CONFIG_DIR="${BATS_TEST_TMPDIR}/config"
  mkdir -p "${CONFIG_DIR}"

  export GEOIP_DIR="${BATS_TEST_TMPDIR}/xt_geoip"
  mkdir -p "${GEOIP_DIR}"
  for _cc in US CA DE; do
    gb_add_geoip "${_cc}"
  done

  gb_ns_start "${GEOIP_DIR}"
}

teardown() {
  gb_ns_stop
}

@test "refuses to run as non-root" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "run this suite as non-root (use bin/test)"
  fi

  run --separate-stderr "${SCRIPT}" 4 apply

  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"Must run as root."* ]]
}

@test "rejects missing IP version" {
  run --separate-stderr gb_ns "${SCRIPT}"

  [ "${status}" -eq 3 ]
  [[ "${stderr}" == *'Must specify one of "4" "6"'* ]]
}

@test "rejects unknown IP version" {
  run --separate-stderr gb_ns "${SCRIPT}" 5 apply

  [ "${status}" -eq 3 ]
  [[ "${stderr}" == *'Must specify one of "4" "6": 5'* ]]
}

@test "rejects missing command" {
  run --separate-stderr gb_ns "${SCRIPT}" 4

  [ "${status}" -eq 3 ]
  [[ "${stderr}" == *'Must specify one of "apply" "clear"'* ]]
}

@test "rejects unknown command" {
  run --separate-stderr gb_ns "${SCRIPT}" 4 flush

  [ "${status}" -eq 3 ]
  [[ "${stderr}" == *'Must specify one of "apply" "clear": flush'* ]]
}

@test "fails when iptables or iptables-restore is missing" {
  _minimal="${BATS_TEST_TMPDIR}/minimal"
  mkdir -p "${_minimal}"
  for _bin in id tr awk cat; do
    ln -s "$(command -v "${_bin}")" "${_minimal}/${_bin}"
  done

  run --separate-stderr gb_ns env PATH="${_minimal}" "${SCRIPT}" 4 apply
  [ "${status}" -eq 3 ]
  [[ "${stderr}" == *'Must have "iptables" installed.'* ]]

  ln -s "$(command -v iptables)" "${_minimal}/iptables"
  run --separate-stderr gb_ns env PATH="${_minimal}" "${SCRIPT}" 4 apply
  [ "${status}" -eq 3 ]
  [[ "${stderr}" == *'Must have "iptables-restore" installed.'* ]]
}

@test "apply IPv4 with no configuration installs default rules" {
  run --separate-stderr gb_ns "${SCRIPT}" 4 apply

  [ "${status}" -eq 0 ]
  [[ "${stderr}" == *"No Countries to allow"* ]]

  [ "$(gb_rules 4 INPUT)" = "$(gb_expect 4 <<<'-j IPTABLES_GEOBLOCK')" ]
  [ "$(gb_rules 4 IPTABLES_GEOBLOCK)" = "$(
    gb_expect 4 <<'EOF'
-m conntrack --ctstate INVALID -j DROP
-m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-i lo -j RETURN
-j IPTABLES_GEOBLOCK-LOGDROP
EOF
  )" ]
  [ "$(gb_rules 4 IPTABLES_GEOBLOCK-LOGDROP)" = "$(
    gb_expect 4 <<'EOF'
-m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "[IPTABLES_GEOBLOCK]: "
-j DROP
EOF
  )" ]
  run ! gb_ns ip6tables -S IPTABLES_GEOBLOCK
}

@test "apply IPv4 orders allowlist, blocklist, countries, then drop" {
  printf -- '# home\n10.0.0.0/8\n\n192.168.1.0/24 172.16.0.0/12\n' >"${CONFIG_DIR}/lan.allow.4"
  printf -- '203.0.113.7' >"${CONFIG_DIR}/bad.block.4"
  printf -- '# countries\nUS\nCA\n' >"${CONFIG_DIR}/home.allow.country"
  printf -- '2001:db8::/32\n' >"${CONFIG_DIR}/ignored.allow.6"

  run gb_ns "${SCRIPT}" 4 apply

  [ "${status}" -eq 0 ]
  [ "$(gb_rules 4 IPTABLES_GEOBLOCK)" = "$(
    gb_expect 4 <<'EOF'
-m conntrack --ctstate INVALID -j DROP
-m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-i lo -j RETURN
-s 10.0.0.0/8 -j RETURN
-s 192.168.1.0/24 -j RETURN
-s 172.16.0.0/12 -j RETURN
-s 203.0.113.7 -j IPTABLES_GEOBLOCK-LOGDROP
-m geoip --src-cc US -j RETURN
-m geoip --src-cc CA -j RETURN
-j IPTABLES_GEOBLOCK-LOGDROP
EOF
  )" ]
}

@test "apply merges multiple config files of the same kind" {
  printf -- '10.0.0.1\n' >"${CONFIG_DIR}/a.allow.4"
  printf -- '10.0.0.2\n' >"${CONFIG_DIR}/b.allow.4"
  printf -- 'US\n' >"${CONFIG_DIR}/a.allow.country"
  printf -- 'DE\n' >"${CONFIG_DIR}/b.allow.country"

  run gb_ns "${SCRIPT}" 4 apply

  [ "${status}" -eq 0 ]
  [ "$(gb_geoblock_rules 4)" = "$(
    gb_expect 4 <<'EOF'
-s 10.0.0.1 -j RETURN
-s 10.0.0.2 -j RETURN
-m geoip --src-cc US -j RETURN
-m geoip --src-cc DE -j RETURN
EOF
  )" ]
}

@test "apply IPv6 installs DHCPv6 and NDP rules and ignores IPv4 config" {
  printf -- '2001:db8::/32\n' >"${CONFIG_DIR}/lan.allow.6"
  printf -- '2001:db8:bad::/48\n' >"${CONFIG_DIR}/bad.block.6"
  printf -- '10.0.0.0/8\n' >"${CONFIG_DIR}/ignored.allow.4"
  printf -- 'US\n' >"${CONFIG_DIR}/home.allow.country"

  run gb_ns "${SCRIPT}" 6 apply

  [ "${status}" -eq 0 ]
  [ "$(gb_rules 6 INPUT)" = "$(gb_expect 6 <<<'-j IPTABLES_GEOBLOCK')" ]
  [ "$(gb_rules 6 IPTABLES_GEOBLOCK)" = "$(
    gb_expect 6 <<'EOF'
-m conntrack --ctstate INVALID -j DROP
-m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-i lo -j RETURN
-s fe80::/10 -p udp --sport 547 --dport 546 -j RETURN
-p ipv6-icmp --icmpv6-type 135 -j RETURN
-p ipv6-icmp --icmpv6-type 136 -j RETURN
-s fe80::/10 -p ipv6-icmp --icmpv6-type 134 -j RETURN
-s fe80::/10 -p ipv6-icmp --icmpv6-type 137 -j RETURN
-s 2001:db8::/32 -j RETURN
-s 2001:db8:bad::/48 -j IPTABLES_GEOBLOCK-LOGDROP
-m geoip --src-cc US -j RETURN
-j IPTABLES_GEOBLOCK-LOGDROP
EOF
  )" ]
  run ! gb_ns iptables -S IPTABLES_GEOBLOCK
}

@test "apply is idempotent and deduplicates entries" {
  printf -- '10.0.0.0/8\n10.0.0.0/8\n' >"${CONFIG_DIR}/lan.allow.4"
  printf -- 'US\nus\n' >"${CONFIG_DIR}/home.allow.country"

  run gb_ns "${SCRIPT}" 4 apply
  [ "${status}" -eq 0 ]
  _first="$(gb_ns iptables -S)"

  run gb_ns "${SCRIPT}" 4 apply
  [ "${status}" -eq 0 ]

  [ "$(gb_ns iptables -S)" = "${_first}" ]
  [ "$(gb_rules 4 INPUT)" = "$(gb_expect 4 <<<'-j IPTABLES_GEOBLOCK')" ]
  [ "$(gb_geoblock_rules 4)" = "$(
    gb_expect 4 <<'EOF'
-s 10.0.0.0/8 -j RETURN
-m geoip --src-cc US -j RETURN
EOF
  )" ]
}

@test "apply preserves other INPUT rules and jumps first" {
  gb_ns iptables -A INPUT -p tcp --dport 22 -j ACCEPT

  run gb_ns "${SCRIPT}" 4 apply

  [ "${status}" -eq 0 ]
  [ "$(gb_rules 4 INPUT)" = "$(
    gb_expect 4 <<'EOF'
-j IPTABLES_GEOBLOCK
-p tcp --dport 22 -j ACCEPT
EOF
  )" ]
}

@test "apply re-reads configuration and drops stale entries" {
  printf -- '10.0.0.1\n' >"${CONFIG_DIR}/lan.allow.4"
  run gb_ns "${SCRIPT}" 4 apply
  [ "${status}" -eq 0 ]

  printf -- '10.0.0.2\n' >"${CONFIG_DIR}/lan.allow.4"
  run gb_ns "${SCRIPT}" 4 apply
  [ "${status}" -eq 0 ]

  [ "$(gb_geoblock_rules 4)" = "$(gb_expect 4 <<<'-s 10.0.0.2 -j RETURN')" ]
}

@test "config strips inline comments, indented comments and CRLF" {
  printf -- '  # indented comment\n10.0.0.1 # home router\r\n10.0.0.2\r\n\t\n' >"${CONFIG_DIR}/lan.allow.4"
  printf -- 'US # home\r\n' >"${CONFIG_DIR}/home.allow.country"

  run gb_ns "${SCRIPT}" 4 apply

  [ "${status}" -eq 0 ]
  [ "$(gb_geoblock_rules 4)" = "$(
    gb_expect 4 <<'EOF'
-s 10.0.0.1 -j RETURN
-s 10.0.0.2 -j RETURN
-m geoip --src-cc US -j RETURN
EOF
  )" ]
}

@test "config accepts interface entries" {
  cat >"${CONFIG_DIR}/trusted.allow.4" <<'EOF'
-i tailscale0
--in-interface wg0 10.8.0.0/24 10.9.0.0/24
-i veth+
10.0.0.1 -i br-lan
EOF
  printf -- '%s\n' '-i guest0' >"${CONFIG_DIR}/guest.block.4"
  printf -- '%s\n' '-i eth1 DE' >"${CONFIG_DIR}/wan.allow.country"

  run gb_ns "${SCRIPT}" 4 apply

  [ "${status}" -eq 0 ]
  [ "$(gb_geoblock_rules 4)" = "$(
    gb_expect 4 <<'EOF'
-i tailscale0 -j RETURN
-i wg0 -s 10.8.0.0/24 -j RETURN
-i wg0 -s 10.9.0.0/24 -j RETURN
-i veth+ -j RETURN
-i br-lan -s 10.0.0.1 -j RETURN
-i guest0 -j IPTABLES_GEOBLOCK-LOGDROP
-i eth1 -m geoip --src-cc DE -j RETURN
EOF
  )" ]
}

@test "config accepts valid IPv6 notations" {
  cat >"${CONFIG_DIR}/lan.allow.6" <<'EOF'
::
::1
fe80::/10
2001:DB8:0:0:0:0:0:1/128
::ffff:192.0.2.1
2001:db8::1:2:3:4:5
EOF

  run gb_ns "${SCRIPT}" 6 apply

  [ "${status}" -eq 0 ]
  for _address in :: ::1 fe80::/10 2001:db8::1/128 ::ffff:192.0.2.1 2001:db8::1:2:3:4:5; do
    gb_ns ip6tables -C IPTABLES_GEOBLOCK -s "${_address}" -j RETURN
  done
}

@test "invalid IPv4 entries fail with file and line" {
  for _entry in 2001:db8::1 home '*' '1.2.3.4;reboot' '"1.2.3.4"'; do
    printf -- '10.0.0.1\n%s\n' "${_entry}" >"${CONFIG_DIR}/lan.allow.4"

    run --separate-stderr gb_ns "${SCRIPT}" 4 apply

    [ "${status}" -eq 3 ]
    [[ "${stderr}" == *"lan.allow.4:2: invalid IPv4 address: ${_entry}"* ]]
  done
  run ! gb_ns iptables -S IPTABLES_GEOBLOCK
}

@test "invalid IPv6 entries fail" {
  for _entry in 10.0.0.1 host fe80::1%eth0 '*' '::1;reboot'; do
    printf -- '%s\n' "${_entry}" >"${CONFIG_DIR}/lan.allow.6"

    run --separate-stderr gb_ns "${SCRIPT}" 6 apply

    [ "${status}" -eq 3 ]
    [[ "${stderr}" == *"lan.allow.6:1: invalid IPv6 address: ${_entry}"* ]]
  done
  run ! gb_ns ip6tables -S IPTABLES_GEOBLOCK
}

@test "invalid interface entries fail" {
  for _entry in '-i' '-i -j' '-i eth0;reboot' '-i abcdefghijklmnop' '-i eth+0' '-i a -i b' '-j ACCEPT' '-s 10.0.0.1' '! -i eth0'; do
    printf -- '%s\n' "${_entry}" >"${CONFIG_DIR}/lan.allow.4"

    run --separate-stderr gb_ns "${SCRIPT}" 4 apply

    [ "${status}" -eq 3 ]
    [[ "${stderr}" == *"lan.allow.4:1: "* ]]
  done
  run ! gb_ns iptables -S IPTABLES_GEOBLOCK
}

@test "invalid or unknown country entries fail" {
  for _entry in USA U '-i eth0' 'U$'; do
    printf -- '%s\n' "${_entry}" >"${CONFIG_DIR}/home.allow.country"

    run --separate-stderr gb_ns "${SCRIPT}" 4 apply

    [ "${status}" -eq 3 ]
    [[ "${stderr}" == *"home.allow.country:1: "* ]]
  done

  printf -- 'FR\n' >"${CONFIG_DIR}/home.allow.country"
  run --separate-stderr gb_ns "${SCRIPT}" 4 apply
  [ "${status}" -eq 3 ]
  [[ "${stderr}" == *"no GeoIP data for FR at ${GEOIP_DIR}/FR.iv4, run update-geoblock"* ]]

  run ! gb_ns iptables -S IPTABLES_GEOBLOCK
}

@test "invalid configuration leaves existing rules unchanged" {
  printf -- '10.0.0.1\n' >"${CONFIG_DIR}/lan.allow.4"
  printf -- 'US\n' >"${CONFIG_DIR}/home.allow.country"
  run gb_ns "${SCRIPT}" 4 apply
  [ "${status}" -eq 0 ]
  _before="$(gb_ns iptables -S)"

  printf -- '10.0.0.2\nnot-an-ip\n' >"${CONFIG_DIR}/lan.allow.4"
  run --separate-stderr gb_ns "${SCRIPT}" 4 apply

  [ "${status}" -eq 3 ]
  [[ "${stderr}" == *"Existing rules left unchanged."* ]]
  [ "$(gb_ns iptables -S)" = "${_before}" ]
}

@test "failed restore leaves existing rules unchanged" {
  printf -- '10.0.0.1\n' >"${CONFIG_DIR}/lan.allow.4"
  run gb_ns "${SCRIPT}" 4 apply
  [ "${status}" -eq 0 ]
  _before="$(gb_ns iptables -S)"

  gb_add_corrupt_geoip FR
  printf -- '10.0.0.2\n' >"${CONFIG_DIR}/lan.allow.4"
  printf -- 'FR\n' >"${CONFIG_DIR}/home.allow.country"
  run --separate-stderr gb_ns "${SCRIPT}" 4 apply

  [ "${status}" -eq 3 ]
  [[ "${stderr}" == *"Failed to apply ruleset. Existing rules left unchanged."* ]]
  [ "$(gb_ns iptables -S)" = "${_before}" ]
}

@test "failed first restore does not leave partial rules" {
  gb_add_corrupt_geoip FR
  printf -- 'FR\n' >"${CONFIG_DIR}/home.allow.country"

  run --separate-stderr gb_ns "${SCRIPT}" 4 apply

  [ "${status}" -eq 3 ]
  [ -z "$(gb_rules 4 INPUT)" ]
  run ! gb_ns iptables -S IPTABLES_GEOBLOCK
  run ! gb_ns iptables -S IPTABLES_GEOBLOCK-LOGDROP
}

@test "clear removes the INPUT jump and both chains" {
  gb_ns iptables -A INPUT -p tcp --dport 22 -j ACCEPT
  run gb_ns "${SCRIPT}" 4 apply
  [ "${status}" -eq 0 ]

  run gb_ns "${SCRIPT}" 4 clear

  [ "${status}" -eq 0 ]
  [ "$(gb_rules 4 INPUT)" = "$(gb_expect 4 <<<'-p tcp --dport 22 -j ACCEPT')" ]
  run ! gb_ns iptables -S IPTABLES_GEOBLOCK
  run ! gb_ns iptables -S IPTABLES_GEOBLOCK-LOGDROP
}

@test "clear is idempotent" {
  run gb_ns "${SCRIPT}" 4 clear
  [ "${status}" -eq 0 ]

  run gb_ns "${SCRIPT}" 4 apply
  [ "${status}" -eq 0 ]
  run gb_ns "${SCRIPT}" 4 clear
  [ "${status}" -eq 0 ]
  run gb_ns "${SCRIPT}" 4 clear
  [ "${status}" -eq 0 ]
}

@test "clear reports failures" {
  run gb_ns "${SCRIPT}" 4 apply
  [ "${status}" -eq 0 ]
  gb_ns iptables -A FORWARD -j IPTABLES_GEOBLOCK

  run --separate-stderr gb_ns "${SCRIPT}" 4 clear

  [ "${status}" -eq 3 ]
  [[ "${stderr}" == *"Failed to clear iptables rules."* ]]
}

@test "clear only touches the requested IP version" {
  run gb_ns "${SCRIPT}" 4 apply
  [ "${status}" -eq 0 ]
  run gb_ns "${SCRIPT}" 6 apply
  [ "${status}" -eq 0 ]

  run gb_ns "${SCRIPT}" 6 clear

  [ "${status}" -eq 0 ]
  gb_ns iptables -S IPTABLES_GEOBLOCK
  run ! gb_ns ip6tables -S IPTABLES_GEOBLOCK
}

@test "works when the configuration directory does not exist" {
  run gb_ns env CONFIG_DIR="${BATS_TEST_TMPDIR}/missing" "${SCRIPT}" 4 apply

  [ "${status}" -eq 0 ]
  [ "$(gb_rules 4 IPTABLES_GEOBLOCK | tail -n 1)" = "$(gb_expect 4 <<<'-j IPTABLES_GEOBLOCK-LOGDROP')" ]
}
