#!/bin/sh

GB_HOST_GEOIP_DIR="/usr/share/xt_geoip"

##
# Check that we can unshare, by actually attempting to unshare lol
gb_can_unshare() {
  unshare --user --map-root-user --net --mount -- true >/dev/null 2>&1
}

##
# iptables cannot load geoip rules without xtables-addons
gb_has_xtables_addons() {
  command -v iptables >/dev/null 2>&1 &&
    command -v ip6tables >/dev/null 2>&1 &&
    [ -d "${GB_HOST_GEOIP_DIR}" ]
}

##
# Run as a fake root in a throwaway user namespace
gb_root() {
  unshare --user --map-root-user -- "$@"
}

##
# Add fake GeoIP data holding a single empty range
# $1 country code
gb_add_geoip() {
  head -c 8 /dev/zero >"${GEOIP_DIR}/$1.iv4"
  head -c 32 /dev/zero >"${GEOIP_DIR}/$1.iv6"
}

##
# Add GeoIP data that iptables refuses to load
# $1 country code
gb_add_corrupt_geoip() {
  head -c 7 /dev/zero >"${GEOIP_DIR}/$1.iv4"
  head -c 31 /dev/zero >"${GEOIP_DIR}/$1.iv6"
}

##
# Start a long lived namespace so rules survive between script runs in one test
# $1 GeoIP fixture directory
gb_ns_start() {
  # shellcheck disable=SC2016
  unshare --user --map-root-user --net --mount -- sh -c '
    mount --bind "$1" "$2" || exit 99
    exec sleep infinity
  ' __gb_ns__ "$1" "${GB_HOST_GEOIP_DIR}" </dev/null >/dev/null 2>&1 3>&- &
  GB_NS_PID="$!"

  while [ "$(cat "/proc/${GB_NS_PID}/comm" 2>/dev/null)" != "sleep" ]; do
    kill -0 "${GB_NS_PID}" 2>/dev/null || return 1
    sleep 0.1
  done

  return 0
}

gb_ns_stop() {
  if [ -n "${GB_NS_PID}" ]; then
    kill "${GB_NS_PID}" 2>/dev/null
  fi

  unset GB_NS_PID
  return 0
}

##
# Run as root inside the test namespace
gb_ns() {
  nsenter --target "${GB_NS_PID}" --user --net --mount -- "$@"
}

##
# $1 IP version
gb_iptables() {
  if [ "$1" = "6" ]; then
    printf -- 'ip6tables'
  else
    printf -- 'iptables'
  fi
}

##
# Print the rules of a chain without the "-A CHAIN" prefix
# $1 IP version
# $2 chain
gb_rules() {
  gb_ns "$(gb_iptables "$1")" -S "$2" | sed -n "s/^-A $2 //p"
}

##
# Print the expected rules from stdin as iptables would print them back
# $1 IP version
gb_expect() {
  gb_expect__bin="$(gb_iptables "$1")"

  {
    printf -- '*filter\n:GB_EXPECTED - [0:0]\n'
    sed 's/^/-A GB_EXPECTED /'
    printf -- 'COMMIT\n'
  } | gb_ns "${gb_expect__bin}-restore" --noflush || {
    unset gb_expect__bin
    return 1
  }

  gb_rules "$1" GB_EXPECTED
  gb_ns "${gb_expect__bin}" --flush GB_EXPECTED
  gb_ns "${gb_expect__bin}" --delete-chain GB_EXPECTED

  unset gb_expect__bin
  return 0
}

##
# Print the IPTABLES_GEOBLOCK rules that come from configuration
# $1 IP version
gb_geoblock_rules() {
  gb_geoblock_rules__fixed="$(
    {
      printf -- '%s\n' \
        '-m conntrack --ctstate INVALID -j DROP' \
        '-m conntrack --ctstate RELATED,ESTABLISHED -j RETURN' \
        '-i lo -j RETURN' \
        '-j IPTABLES_GEOBLOCK-LOGDROP'
      if [ "$1" = "6" ]; then
        printf -- '%s\n' \
          '-s fe80::/10 -p udp --sport 547 --dport 546 -j RETURN' \
          '-p ipv6-icmp --icmpv6-type 135 -j RETURN' \
          '-p ipv6-icmp --icmpv6-type 136 -j RETURN' \
          '-s fe80::/10 -p ipv6-icmp --icmpv6-type 134 -j RETURN' \
          '-s fe80::/10 -p ipv6-icmp --icmpv6-type 137 -j RETURN'
      fi
    } | gb_expect "$1"
  )"

  gb_rules "$1" IPTABLES_GEOBLOCK | grep -Fxv -e "${gb_geoblock_rules__fixed}"

  unset gb_geoblock_rules__fixed
  return 0
}
