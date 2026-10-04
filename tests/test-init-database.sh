#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT
mkdir -p "${TEMP_DIR}/bin" "${TEMP_DIR}/sql/dev"
printf 'LONGZHU_DB_HOST=192.168.0.217\nLONGZHU_DB_PORT=3306\nLONGZHU_DB_NAME=longzhu\n' > "${TEMP_DIR}/hosts.env"
printf 'CREATE TABLE demo (id INT);\n' > "${TEMP_DIR}/sql/DDL.sql"
printf 'INSERT INTO demo VALUES (1);\n' > "${TEMP_DIR}/sql/DML.sql"
printf 'INSERT INTO demo VALUES (2);\n' > "${TEMP_DIR}/sql/dev/DML.sql"
cat > "${TEMP_DIR}/bin/mysql" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *"information_schema.tables"* ]]; then
  printf '%s\n' "${TEST_TABLE_COUNT:-0}"
elif [[ " $* " == *'CREATE DATABASE IF NOT EXISTS `longzhu`'* ]]; then
  printf 'create\n' >> "${TEST_CALLS}"
elif [[ " $* " == *"--database=longzhu"* ]]; then
  cat > /dev/null
  printf 'apply\n' >> "${TEST_CALLS}"
else
  exit 1
fi
EOF
chmod +x "${TEMP_DIR}/bin/mysql"
export PATH="${TEMP_DIR}/bin:${PATH}"
export LZ_ENV=dev LZ_HOSTS_KEY=LONGZHU LZ_HOSTS_FILE="${TEMP_DIR}/hosts.env"
export LZ_SQL_ROOT="${TEMP_DIR}/sql" MYSQL_USER=test MYSQL_PASSWORD=test
export TEST_CALLS="${TEMP_DIR}/calls"
bash "${ROOT}/resources/com/longzhu/jenkins/init-database.sh" > /dev/null
[[ "$(cat "${TEST_CALLS}")" == $'create\napply\napply\napply' ]]
: > "${TEST_CALLS}"
export TEST_TABLE_COUNT=1
if bash "${ROOT}/resources/com/longzhu/jenkins/init-database.sh" > /dev/null 2>&1; then
  exit 1
fi
[[ ! -s "${TEST_CALLS}" ]]
export TEST_TABLE_COUNT=0
printf 'CREATE DATABASE IF NOT EXISTS `longzhu`;\nUSE `longzhu`;\nCREATE TABLE demo (id INT);\n' > "${TEMP_DIR}/sql/DDL.sql"
: > "${TEST_CALLS}"
bash "${ROOT}/resources/com/longzhu/jenkins/init-database.sh" > /dev/null
[[ "$(cat "${TEST_CALLS}")" == $'create\napply\napply\napply' ]]
: > "${TEST_CALLS}"
printf 'USE another_database;\n' > "${TEMP_DIR}/sql/DDL.sql"
if bash "${ROOT}/resources/com/longzhu/jenkins/init-database.sh" > /dev/null 2>&1; then
  exit 1
fi
[[ ! -s "${TEST_CALLS}" ]]
printf 'PASS: init database 使用指定库、允许 SQL 写同名库，拒绝非空库和写到别的库的 SQL\n'
