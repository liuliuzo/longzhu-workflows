#!/usr/bin/env bash
# clean-database.sh：只删主机清单指定的库、只允许 dev、拒绝系统库。用假 mysql，不连任何库。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/resources/com/longzhu/jenkins/clean-database.sh"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT
mkdir -p "${TEMP_DIR}/bin"
printf 'LONGZHU_DB_HOST=192.168.0.217\nLONGZHU_DB_PORT=3306\nLONGZHU_DB_NAME=longzhu\n' > "${TEMP_DIR}/hosts.env"
cat > "${TEMP_DIR}/bin/mysql" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *"information_schema.tables"* ]]; then
  printf '27\n'
elif [[ " $* " == *'DROP DATABASE IF EXISTS `longzhu`'* ]]; then
  printf 'drop\n' >> "${TEST_CALLS}"
elif [[ " $* " == *"information_schema.schemata"* ]]; then
  printf '%s\n' "${TEST_LEFT:-0}"
else
  exit 1
fi
EOF
chmod +x "${TEMP_DIR}/bin/mysql"
export PATH="${TEMP_DIR}/bin:${PATH}"
export LZ_ENV=dev LZ_HOSTS_KEY=LONGZHU LZ_HOSTS_FILE="${TEMP_DIR}/hosts.env" MYSQL_USER=test MYSQL_PASSWORD=test
export TEST_CALLS="${TEMP_DIR}/calls"

bash "${SCRIPT}" > /dev/null
[[ "$(cat "${TEST_CALLS}")" == 'drop' ]]

# DROP 后库仍在：必须失败。
: > "${TEST_CALLS}"
if TEST_LEFT=1 bash "${SCRIPT}" > /dev/null 2>&1; then echo 'DROP 后库仍在应当失败' >&2; exit 1; fi

# 非 dev：不发任何 SQL。
: > "${TEST_CALLS}"
if LZ_ENV=prod bash "${SCRIPT}" > /dev/null 2>&1; then echo 'prod 应当被拒绝' >&2; exit 1; fi
[[ ! -s "${TEST_CALLS}" ]]

# 系统库：不发任何 SQL。
printf 'LONGZHU_DB_HOST=192.168.0.217\nLONGZHU_DB_NAME=mysql\n' > "${TEMP_DIR}/sys.env"
if LZ_HOSTS_FILE="${TEMP_DIR}/sys.env" bash "${SCRIPT}" > /dev/null 2>&1; then echo '系统库应当被拒绝' >&2; exit 1; fi
[[ ! -s "${TEST_CALLS}" ]]

printf 'PASS: clean database 只删指定开发库，拒绝 prod 与系统库\n'
