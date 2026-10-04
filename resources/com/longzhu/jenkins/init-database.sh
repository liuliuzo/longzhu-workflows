#!/usr/bin/env bash
# 运行位置：Jenkins agent（由 vars/longzhuInitDatabase.groovy 调用），需要 mysql 客户端。
# 职责：空库初始化。按产品仓 sql/ 依次执行 DDL.sql → DML.sql → <env>/DML.sql。
#
# 只接受空库：目标库里已有任何表就拒绝，绝不 DROP、绝不覆盖现有数据。
# 开发环境推倒重建：先跑 clean database，再跑本 Job。
#
# 必需环境变量：
#   LZ_ENV        dev / prod
#   LZ_HOSTS_KEY  产品键，如 LONGZHU（读 <KEY>_DB_HOST / <KEY>_DB_PORT / <KEY>_DB_NAME）
#   LZ_HOSTS_FILE 主机清单（Jenkins 凭据 longzhu-<env>-hosts）
#   LZ_SQL_ROOT   产品仓 sql/ 目录
#   MYSQL_USER MYSQL_PASSWORD  Jenkins 凭据 longzhu-<env>-mysql（日志中已脱敏）
set -euo pipefail
set +x

: "${LZ_ENV:?LZ_ENV is required}"
: "${LZ_HOSTS_KEY:?LZ_HOSTS_KEY is required}"
: "${LZ_HOSTS_FILE:?LZ_HOSTS_FILE is required（Jenkins 凭据 longzhu-<env>-hosts 未配置?）}"
: "${LZ_SQL_ROOT:?LZ_SQL_ROOT is required}"
: "${MYSQL_USER:?MYSQL_USER is required（Jenkins 凭据 longzhu-<env>-mysql 未配置?）}"
: "${MYSQL_PASSWORD:?MYSQL_PASSWORD is required（Jenkins 凭据 longzhu-<env>-mysql 未配置?）}"

log() { printf '[init-db] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

command -v mysql >/dev/null 2>&1 || die 'Jenkins agent 缺少 mysql 客户端（Debian/Ubuntu: apt-get install -y default-mysql-client）'

# shellcheck source=/dev/null
. <(tr -d '\r' < "${LZ_HOSTS_FILE}")
host_var="${LZ_HOSTS_KEY}_DB_HOST"
port_var="${LZ_HOSTS_KEY}_DB_PORT"
name_var="${LZ_HOSTS_KEY}_DB_NAME"
DB_HOST="${!host_var:-}"
DB_PORT="${!port_var:-3306}"
DB_NAME="${!name_var:-}"
[[ -n "${DB_HOST}" ]] || die "主机清单缺少 ${host_var}（Jenkins 凭据 longzhu-${LZ_ENV}-hosts）"
[[ "${DB_PORT}" =~ ^[0-9]+$ ]] || die "${port_var} 必须是整数（当前 ${DB_PORT}）"
[[ "${DB_NAME}" =~ ^[A-Za-z][A-Za-z0-9_]*$ && ${#DB_NAME} -le 64 ]] || die "${name_var} 必须是合法的 MySQL 库名"

SQL_FILES=("${LZ_SQL_ROOT}/DDL.sql" "${LZ_SQL_ROOT}/DML.sql" "${LZ_SQL_ROOT}/${LZ_ENV}/DML.sql")
for sql_file in "${SQL_FILES[@]}"; do
  [[ -s "${sql_file}" ]] || die "缺少或为空：${sql_file}"
  # SQL 自己写 CREATE DATABASE / USE 时，库名必须就是主机清单里的 <KEY>_DB_NAME，不允许写到别的库。
  while IFS= read -r named; do
    [[ -z "${named}" || "${named}" == "${DB_NAME}" ]] \
      || die "${sql_file} 指定了库 ${named}，与 ${name_var}=${DB_NAME} 不一致"
  done < <(tr -d '\r' < "${sql_file}" | sed -n -E \
    -e 's/^[[:space:]]*USE[[:space:]]+`?([A-Za-z0-9_]+)`?[[:space:]]*;.*/\1/Ip' \
    -e 's/^[[:space:]]*CREATE[[:space:]]+DATABASE[[:space:]]+(IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+)?`?([A-Za-z0-9_]+)`?.*/\2/Ip')
done

# 口令写进 0600 临时配置文件，不进命令行、不进环境变量。
MYCNF="$(mktemp)"
trap 'rm -f "${MYCNF}"' EXIT
chmod 600 "${MYCNF}"
# 选项文件里的双引号值支持反斜杠转义：先转义反斜杠，再转义双引号。
escaped_pw="${MYSQL_PASSWORD//\\/\\\\}"
escaped_pw="${escaped_pw//\"/\\\"}"
{
  printf '[client]\n'
  printf 'user=%s\n' "${MYSQL_USER}"
  printf 'password="%s"\n' "${escaped_pw}"
} > "${MYCNF}"
MYSQL=(mysql --defaults-extra-file="${MYCNF}" --protocol=TCP --host="${DB_HOST}" --port="${DB_PORT}" --default-character-set=utf8mb4 --connect-timeout=15)

log "目标 ${DB_HOST}:${DB_PORT} 库 ${DB_NAME}（环境 ${LZ_ENV}）"
tables="$("${MYSQL[@]}" --batch --skip-column-names \
  --execute="SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}'")"
if [[ "${tables}" != "0" ]]; then
  die "库 ${DB_NAME} 已有 ${tables} 张表，拒绝初始化（本 Job 只接受空库，绝不 DROP）。要重建请先备份、清库，再重跑。"
fi

"${MYSQL[@]}" --execute="CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci"
for sql_file in "${SQL_FILES[@]}"; do
  log "执行 ${sql_file#"${LZ_SQL_ROOT}/"}"
  "${MYSQL[@]}" --database="${DB_NAME}" < "${sql_file}"
done

created="$("${MYSQL[@]}" --batch --skip-column-names \
  --execute="SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}'")"
log "完成：库 ${DB_NAME} 现有 ${created} 张表。"
