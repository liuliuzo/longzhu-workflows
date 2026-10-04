#!/usr/bin/env bash
# 运行位置：Jenkins agent（由 vars/longzhuCleanDatabase.groovy 调用），需要 mysql 客户端。
# 职责：清库。DROP DATABASE IF EXISTS <库名>，不建表、不灌数据、不动应用。
#
# 开发环境全量发布的第一步：clean database → init database → deploy。
# 只允许 dev：LZ_ENV 不是 dev 直接拒绝，生产库不经本脚本删除。
#
# 必需环境变量：
#   LZ_ENV        dev
#   LZ_HOSTS_KEY  产品键，如 LONGZHU（读 <KEY>_DB_HOST / <KEY>_DB_PORT / <KEY>_DB_NAME）
#   LZ_HOSTS_FILE 主机清单（Jenkins 凭据 longzhu-<env>-hosts）
#   MYSQL_USER MYSQL_PASSWORD  Jenkins 凭据 longzhu-<env>-mysql（日志中已脱敏）
set -euo pipefail
set +x

: "${LZ_ENV:?LZ_ENV is required}"
: "${LZ_HOSTS_KEY:?LZ_HOSTS_KEY is required}"
: "${LZ_HOSTS_FILE:?LZ_HOSTS_FILE is required（Jenkins 凭据 longzhu-<env>-hosts 未配置?）}"
: "${MYSQL_USER:?MYSQL_USER is required（Jenkins 凭据 longzhu-<env>-mysql 未配置?）}"
: "${MYSQL_PASSWORD:?MYSQL_PASSWORD is required（Jenkins 凭据 longzhu-<env>-mysql 未配置?）}"

log() { printf '[clean-db] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

[[ "${LZ_ENV}" == "dev" ]] || die "只允许清理开发库（当前环境 ${LZ_ENV}）。生产库不经 Jenkins 删除。"
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
case "${DB_NAME,,}" in
  mysql|sys|information_schema|performance_schema) die "拒绝删除系统库 ${DB_NAME}" ;;
esac

# 口令写进 0600 临时配置文件，不进命令行、不进环境变量。
MYCNF="$(mktemp)"
trap 'rm -f "${MYCNF}"' EXIT
chmod 600 "${MYCNF}"
escaped_pw="${MYSQL_PASSWORD//\\/\\\\}"
escaped_pw="${escaped_pw//\"/\\\"}"
{
  printf '[client]\n'
  printf 'user=%s\n' "${MYSQL_USER}"
  printf 'password="%s"\n' "${escaped_pw}"
} > "${MYCNF}"
MYSQL=(mysql --defaults-extra-file="${MYCNF}" --protocol=TCP --host="${DB_HOST}" --port="${DB_PORT}" --default-character-set=utf8mb4 --connect-timeout=15)

tables="$("${MYSQL[@]}" --batch --skip-column-names \
  --execute="SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}'")"
log "目标 ${DB_HOST}:${DB_PORT} 库 ${DB_NAME}（环境 ${LZ_ENV}），现有 ${tables} 张表"
"${MYSQL[@]}" --execute="DROP DATABASE IF EXISTS \`${DB_NAME}\`"

left="$("${MYSQL[@]}" --batch --skip-column-names \
  --execute="SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='${DB_NAME}'")"
[[ "${left}" == "0" ]] || die "DROP 之后库 ${DB_NAME} 仍然存在"
log "完成：库 ${DB_NAME} 已删除。下一步跑 init database。"
