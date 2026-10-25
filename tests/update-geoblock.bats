#!/usr/bin/env bats
#
# $ bats tests/update-geoblock.bats

# Using flags on run warning
bats_require_minimum_version 1.5.0

load test_helper

setup() {
  if ! gb_can_unshare; then
    skip "unprivileged user namespaces (unshare --user) are not available"
  fi

  ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="${ROOT}/update-geoblock"

  STUBS="${BATS_TEST_TMPDIR}/stubs"
  mkdir -p "${STUBS}"
  ln -s "$(command -v false)" "${STUBS}/systemctl"
  PATH="${STUBS}:${PATH}"

  export XTABLES_ADDONS_DIR="${BATS_TEST_TMPDIR}/xtables-addons"
  export GEOIP_DIR="${BATS_TEST_TMPDIR}/share/xt_geoip"
  export CALLS="${BATS_TEST_TMPDIR}/calls"
  mkdir -p "${XTABLES_ADDONS_DIR}"

  cat >"${XTABLES_ADDONS_DIR}/xt_geoip_dl" <<'EOF'
#!/bin/sh
printf -- 'dl %s\n' "$(pwd)" >>"${CALLS}"
[ -n "${FAIL_DL}" ] && exit 1
[ -n "${EMPTY_DL}" ] && : >dbip-country-lite.csv && exit 0
printf -- '1.0.0.0,1.0.0.255,JP\n' >dbip-country-lite.csv
EOF

  cat >"${XTABLES_ADDONS_DIR}/xt_geoip_build" <<'EOF'
#!/bin/sh
printf -- 'build %s\n' "$*" >>"${CALLS}"
[ -n "${FAIL_BUILD}" ] && : >"$2/JP.iv4" && exit 1
[ -n "${EMPTY_BUILD}" ] && exit 0
[ -r dbip-country-lite.csv ] || exit 1
printf -- 'new' >"$2/JP.iv4"
printf -- 'new' >"$2/JP.iv6"
printf -- 'new' >"$2/US.iv4"
EOF

  chmod 755 "${XTABLES_ADDONS_DIR}"/xt_geoip_*
}

existing_database() {
  mkdir -p "${GEOIP_DIR}"
  printf -- 'old' >"${GEOIP_DIR}/JP.iv4"
  printf -- 'old' >"${GEOIP_DIR}/ZZ.iv4"
}

assert_clean() {
  [ -z "$(find "${GEOIP_DIR}" -name '.staging.*')" ]
  if [ -e "${CALLS}" ]; then
    _workdir="$(sed -n 's/^dl //p' "${CALLS}")"
    [ ! -e "${_workdir}" ]
  fi
}

@test "refuses to run as non-root" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "run this suite as non-root (use bin/test)"
  fi

  run --separate-stderr "${SCRIPT}"

  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"Must run as root."* ]]
  [ ! -e "${CALLS}" ]
}

@test "fails when xtables-addons tools are missing" {
  _missing="${BATS_TEST_TMPDIR}/missing"

  run --separate-stderr gb_root env XTABLES_ADDONS_DIR="${_missing}" "${SCRIPT}"

  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"Missing xt_geoip_dl in ${_missing}"* ]]
  [ ! -e "${GEOIP_DIR}" ]
}

@test "downloads in a temporary directory, installs the database and cleans up" {
  run gb_root "${SCRIPT}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"GeoIP database is updated in ${GEOIP_DIR}"* ]]

  _workdir="$(sed -n 's/^dl //p' "${CALLS}")"
  [ -n "${_workdir}" ]
  [ "${_workdir}" != "${XTABLES_ADDONS_DIR}" ]
  [[ "$(sed -n 's/^build //p' "${CALLS}")" == "-D ${GEOIP_DIR}/.staging."*" dbip-country-lite.csv" ]]

  [ "$(cat "${GEOIP_DIR}/JP.iv4")" = "new" ]
  [ "$(cat "${GEOIP_DIR}/JP.iv6")" = "new" ]
  [ "$(cat "${GEOIP_DIR}/US.iv4")" = "new" ]
  [ "$(stat -c '%a' "${GEOIP_DIR}")" = "755" ]
  [ "$(stat -c '%a' "${GEOIP_DIR}/JP.iv4")" = "644" ]
  [ ! -e "${XTABLES_ADDONS_DIR}/dbip-country-lite.csv" ]
  assert_clean
}

@test "replaces existing data and removes stale countries only" {
  existing_database
  printf -- 'keep' >"${GEOIP_DIR}/README"

  run gb_root "${SCRIPT}"

  [ "${status}" -eq 0 ]
  [ "$(cat "${GEOIP_DIR}/JP.iv4")" = "new" ]
  [ ! -e "${GEOIP_DIR}/ZZ.iv4" ]
  [ "$(cat "${GEOIP_DIR}/README")" = "keep" ]
}

@test "fixes permissions on an existing database directory" {
  mkdir -p "${GEOIP_DIR}"
  chmod 700 "${GEOIP_DIR}"

  run gb_root "${SCRIPT}"

  [ "${status}" -eq 0 ]
  [ "$(stat -c '%a' "${GEOIP_DIR}")" = "755" ]
}

@test "failed download keeps the existing database" {
  existing_database

  run --separate-stderr gb_root env FAIL_DL=1 "${SCRIPT}"

  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"Failed to download latest geoip using xt_geoip_dl"* ]]
  run ! grep -q '^build' "${CALLS}"
  [ "$(cat "${GEOIP_DIR}/JP.iv4")" = "old" ]
  assert_clean
}

@test "empty download keeps the existing database" {
  existing_database

  run --separate-stderr gb_root env EMPTY_DL=1 "${SCRIPT}"

  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"dbip-country-lite.csv is missing or empty."* ]]
  [ "$(cat "${GEOIP_DIR}/JP.iv4")" = "old" ]
  assert_clean
}

@test "failed build keeps the existing database and prints the Debian hint" {
  existing_database

  run --separate-stderr gb_root env FAIL_BUILD=1 "${SCRIPT}"

  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"Failed to convert CSV to GEO-IP using xt_geoip_build"* ]]
  [[ "${stderr}" == *"libtext-csv-xs-perl"* ]]
  [ "$(cat "${GEOIP_DIR}/JP.iv4")" = "old" ]
  [ -e "${GEOIP_DIR}/ZZ.iv4" ]
  assert_clean
}

@test "build without output keeps the existing database" {
  existing_database

  run --separate-stderr gb_root env EMPTY_BUILD=1 "${SCRIPT}"

  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"xt_geoip_build did not produce any database files."* ]]
  [ "$(cat "${GEOIP_DIR}/JP.iv4")" = "old" ]
  [ -e "${GEOIP_DIR}/ZZ.iv4" ]
  assert_clean
}
