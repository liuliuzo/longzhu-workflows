#!/usr/bin/env bash
# 运行位置：Jenkins agent（由 vars/longzhuDeploy.groovy 调用）。
# 职责：把 Jenkins 凭据与主机清单翻译成目标机需要的参数 → 只读端口预检 → 把 remote-deploy.sh
#       放到目标机 → 经 SSH stdin 喂 remote-build.sh，让目标机就地构建并部署 → 原样上报退出码。
# Jenkins 这一侧不构建、不上传 jar。
#
# 必需环境变量（longzhuDeploy 注入）：
#   LZ_HOSTS_KEY            主机清单键前缀，如 LONGZHU_USER
#   LZ_HOSTS_FILE           主机清单文件（Jenkins Secret file 落盘位置）
#   LZ_REMOTE_BUILD_SCRIPT  remote-build.sh 在工作区的路径
#   LZ_REMOTE_DEPLOY_SCRIPT remote-deploy.sh 在工作区的路径
#   LZ_GITHUB_OWNER LZ_GITHUB_REPO LZ_MODULE_PREFIX LZ_SOURCE_REF LZ_END
#   APP_NAME APP_PROFILE     如 longzhu-user / dev
#   SSH_USER SSHPASS GIT_TOKEN（Jenkins 凭据，日志中已脱敏）
# 可选：
#   LZ_PACKAGE_MANAGER LZ_FRONTEND_SCRIPT
#   LZ_DEFAULT_APP_PORT LZ_DEFAULT_HEALTH_SCHEME LZ_DEFAULT_HEALTH_PATH
#   NET_RETRY_DELAY_SECONDS  预检 SSH 建连失败的重试间隔，默认 15
#   LZ_WRAPPER_PRINT_PLAN   非空则只打印解析结果后退出，不连目标机（tests/ 与人工核对主机清单用）
#
# 主机清单里可按端点覆盖的键（<KEY> = LZ_HOSTS_KEY）：
#   <KEY>_HOST（必填） <KEY>_SSH_PORT <KEY>_KNOWN_HOSTS <KEY>_APP_DIR <KEY>_SERVICE <KEY>_PORT
#   <KEY>_BIND_ADDRESS <KEY>_HEALTH_PATH <KEY>_HEALTH_SCHEME <KEY>_HEALTH_TIMEOUT_SECONDS
#   <KEY>_RESTART_CMD <KEY>_NET_MAX_ATTEMPTS <KEY>_SRC_ROOT <KEY>_BUILD_TIMEOUT_SECONDS
#   <KEY>_BUILD_SKIP_TESTS <KEY>_MIN_FREE_MB <KEY>_MAVEN_OPTS <KEY>_NODE_OPTIONS
#   <KEY>_MAVEN_MIRROR_URL <KEY>_KEEP_RELEASES
set -euo pipefail
# 绝不开 xtrace：SSHPASS / GIT_TOKEN 就在环境里。
set +x

: "${LZ_HOSTS_KEY:?LZ_HOSTS_KEY is required}"
: "${LZ_HOSTS_FILE:?LZ_HOSTS_FILE is required（Jenkins 凭据 longzhu-<env>-hosts 未配置?）}"
: "${APP_NAME:?APP_NAME is required}"
: "${APP_PROFILE:?APP_PROFILE is required}"
: "${LZ_GITHUB_OWNER:?LZ_GITHUB_OWNER is required}"
: "${LZ_GITHUB_REPO:?LZ_GITHUB_REPO is required}"
: "${LZ_MODULE_PREFIX:?LZ_MODULE_PREFIX is required}"
: "${LZ_SOURCE_REF:?LZ_SOURCE_REF is required}"
: "${LZ_END:?LZ_END is required}"

# 固定的目标机布局，只用自己的目录，与同机的其他应用互不干扰。
LZ_ROOT=/opt/longzhu
LZ_ETC=/etc/longzhu

# 主机清单是 KEY=VALUE 的 bash 赋值文件。从 Windows 上传时常带 CRLF，先剥掉再 source。
if [[ -n "$(tr -dc '\r' < "${LZ_HOSTS_FILE}")" ]]; then
  echo "[wrapper] WARNING: 主机清单是 CRLF 行尾，已按 LF 解析；请以 LF 重新上传 longzhu-${APP_PROFILE}-hosts" >&2
fi
# shellcheck source=/dev/null
. <(tr -d '\r' < "${LZ_HOSTS_FILE}")

# lookup <后缀> <缺省值>：读 ${LZ_HOSTS_KEY}_<后缀>，未设置或为空取缺省值。
lookup() {
  local var_name="${LZ_HOSTS_KEY}_$1"
  local value="${!var_name:-}"
  if [[ -n "${value}" ]]; then
    printf '%s' "${value}"
  else
    printf '%s' "$2"
  fi
}

SSH_HOST="$(lookup HOST '')"
if [[ -z "${SSH_HOST}" ]]; then
  echo "[wrapper] ERROR: 主机清单缺少 ${LZ_HOSTS_KEY}_HOST。" >&2
  echo "[wrapper] 在 Jenkins 凭据 longzhu-${APP_PROFILE}-hosts 里补上；模板见 jenkins/credentials/longzhu-hosts.${APP_PROFILE}.env.example。" >&2
  exit 1
fi
SSH_PORT="$(lookup SSH_PORT 22)"
SSH_KNOWN_HOSTS="$(lookup KNOWN_HOSTS '')"
APP_DIR="$(lookup APP_DIR "${LZ_ROOT}/${APP_NAME}")"
SERVICE_NAME="$(lookup SERVICE "${APP_NAME}")"
APP_PORT="$(lookup PORT "${LZ_DEFAULT_APP_PORT:-8080}")"
APP_BIND_ADDRESS="$(lookup BIND_ADDRESS '')"
HEALTH_PATH="$(lookup HEALTH_PATH "${LZ_DEFAULT_HEALTH_PATH:-/}")"
HEALTH_SCHEME="$(lookup HEALTH_SCHEME "${LZ_DEFAULT_HEALTH_SCHEME:-http}")"
HEALTH_TIMEOUT_SECONDS="$(lookup HEALTH_TIMEOUT_SECONDS '')"
RESTART_CMD="$(lookup RESTART_CMD '')"
NET_MAX_ATTEMPTS="$(lookup NET_MAX_ATTEMPTS 3)"
NET_RETRY_DELAY_SECONDS="${NET_RETRY_DELAY_SECONDS:-15}"

# 同一台机上两端各占一个回环地址（如 127.0.0.2 / 127.0.0.3）共用 8080 时，端口检查与健康探测
# 只看本端地址。只接受 127.0.0.1 至 127.0.0.254，不认识的地址直接失败，绝不退回按整个端口清进程。
if [[ -n "${APP_BIND_ADDRESS}" ]] && ! [[ "${APP_BIND_ADDRESS}" =~ ^127\.0\.0\.([1-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-4])$ ]]; then
  echo "[wrapper] ERROR: ${LZ_HOSTS_KEY}_BIND_ADDRESS 只能是 127.0.0.1 到 127.0.0.254（当前 ${APP_BIND_ADDRESS}）" >&2
  exit 1
fi
HEALTH_HOST="${APP_BIND_ADDRESS:-127.0.0.1}"
for numeric in NET_MAX_ATTEMPTS NET_RETRY_DELAY_SECONDS SSH_PORT APP_PORT; do
  [[ "${!numeric}" =~ ^[0-9]+$ ]] || { echo "[wrapper] ERROR: ${numeric} 必须是整数（当前 ${!numeric}）" >&2; exit 1; }
done
(( NET_MAX_ATTEMPTS >= 1 )) || { echo '[wrapper] ERROR: NET_MAX_ATTEMPTS 至少为 1' >&2; exit 1; }

echo "[wrapper] ${APP_NAME} -> ${SSH_USER:-<ssh-user>}@${SSH_HOST}:${SSH_PORT}"
echo "[wrapper]   app_dir=${APP_DIR} service=${SERVICE_NAME} profile=${APP_PROFILE}"
echo "[wrapper]   source=${LZ_GITHUB_OWNER}/${LZ_GITHUB_REPO}@${LZ_SOURCE_REF} module=${LZ_MODULE_PREFIX}-${LZ_END}"
echo "[wrapper]   health=${HEALTH_SCHEME}://${HEALTH_HOST}:${APP_PORT}${HEALTH_PATH}"

if [[ -n "${LZ_WRAPPER_PRINT_PLAN:-}" ]]; then
  exit 0
fi

: "${SSH_USER:?SSH_USER is required（Jenkins 凭据 longzhu-<env>-ssh 未配置?）}"
: "${SSHPASS:?SSHPASS is required（Jenkins 凭据 longzhu-<env>-ssh 未配置?）}"
: "${GIT_TOKEN:?GIT_TOKEN is required（Jenkins 凭据 longzhu-github 未配置?）}"
: "${LZ_REMOTE_BUILD_SCRIPT:?LZ_REMOTE_BUILD_SCRIPT is required}"
: "${LZ_REMOTE_DEPLOY_SCRIPT:?LZ_REMOTE_DEPLOY_SCRIPT is required}"
for f in "${LZ_REMOTE_BUILD_SCRIPT}" "${LZ_REMOTE_DEPLOY_SCRIPT}"; do
  [[ -f "${f}" ]] || { echo "[wrapper] ERROR: 找不到 ${f}" >&2; exit 1; }
done
if ! command -v sshpass >/dev/null 2>&1; then
  echo '[wrapper] ERROR: Jenkins agent 缺少 sshpass（Debian/Ubuntu: apt-get install -y sshpass）' >&2
  exit 1
fi
export SSHPASS

KNOWN_HOSTS_FILE=""
cleanup() {
  if [[ -n "${KNOWN_HOSTS_FILE}" && -f "${KNOWN_HOSTS_FILE}" ]]; then
    rm -f "${KNOWN_HOSTS_FILE}"
  fi
}
trap cleanup EXIT

# ServerAlive*：链路悄悄断掉时约 60 秒内报错，而不是永久挂住。
if [[ -n "${SSH_KNOWN_HOSTS}" ]]; then
  KNOWN_HOSTS_FILE="$(mktemp)"
  printf '%s\n' "${SSH_KNOWN_HOSTS}" > "${KNOWN_HOSTS_FILE}"
  SSH_OPTS=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${KNOWN_HOSTS_FILE}" -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -p "${SSH_PORT}")
  SCP_OPTS=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${KNOWN_HOSTS_FILE}" -o ConnectTimeout=15 -P "${SSH_PORT}")
else
  echo "[wrapper] WARNING: 未配置 ${LZ_HOSTS_KEY}_KNOWN_HOSTS，主机指纹校验关闭（建议用 ssh-keyscan 结果补上）" >&2
  SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -p "${SSH_PORT}")
  SCP_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 -P "${SSH_PORT}")
fi
remote() { sshpass -e ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "$@"; }

# ---- 1. 只读端口预检 ----
# 在十几分钟的构建开始之前，先确认目标端口没被别的服务占着。只读：不停服务、不杀进程、不建目录。
# remote-deploy.sh 在真正重启前还会再查一次，防止预检与重启之间发生变化。
REMOTE_PREFLIGHT_SCRIPT="$(cat <<'REMOTE_PREFLIGHT'
set -euo pipefail
APP_NAME="$1"; APP_DIR="$2"; SERVICE_NAME="$3"; APP_PORT="$4"; APP_BIND_ADDRESS="${5:-}"; LZ_ROOT="$6"
log() { printf '[preflight][%s] %s\n' "${APP_NAME}" "$*"; }

port_listener_pids() {
  if [[ -n "${APP_BIND_ADDRESS:-}" ]]; then
    local listeners
    command -v ss >/dev/null 2>&1 || { echo 'APP_BIND_ADDRESS requires ss' >&2; return 1; }
    listeners="$(ss -H -ltnp "sport = :${APP_PORT}")" || return 1
    printf '%s\n' "${listeners}" | awk -v address="${APP_BIND_ADDRESS}" -v port="${APP_PORT}" \
      '$4 == address ":" port || $4 == "[::ffff:" address "]:" port || $4 == "::ffff:" address ":" port || $4 == "[::ffff:0.0.0.0]:" port || $4 == "::ffff:0.0.0.0:" port || $4 == "0.0.0.0:" port || $4 == "*:" port || $4 == "[::]:" port || $4 == ":::" port' \
      | grep -oP 'pid=\K[0-9]+' | sort -u || true
    return 0
  fi
  local pids=""
  if command -v ss >/dev/null 2>&1; then
    pids="$(ss -ltnp "sport = :${APP_PORT}" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u || true)"
  fi
  if [[ -z "${pids}" ]] && command -v lsof >/dev/null 2>&1; then
    pids="$(lsof -tiTCP:"${APP_PORT}" -sTCP:LISTEN 2>/dev/null | sort -u || true)"
  fi
  echo ${pids}
}

foreign_owner_of_pid() {
  local pid="$1" unit="" cmd=""
  if [[ -r "/proc/${pid}/cgroup" ]]; then
    unit="$(grep -oE '[A-Za-z0-9@._-]+\.service' "/proc/${pid}/cgroup" 2>/dev/null | head -1 || true)"
  fi
  if [[ -n "${unit}" && "${unit}" != "${SERVICE_NAME}.service" ]]; then
    printf 'systemd unit %s (pid %s)' "${unit}" "${pid}"
    return 0
  fi
  if [[ -r "/proc/${pid}/cmdline" ]]; then
    cmd="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
  fi
  if [[ "${cmd}" == *"${LZ_ROOT}/"* && "${cmd}" != *"${APP_DIR}"* ]]; then
    printf '%s (pid %s)' "$(printf '%s' "${cmd}" | grep -oE "${LZ_ROOT}/[^ ]+" | head -1 || true)" "${pid}"
    return 0
  fi
  return 1
}

pids="$(port_listener_pids)"
for pid in ${pids}; do
  if owner="$(foreign_owner_of_pid "${pid}")"; then
    log "ERROR: 已取消：端口 ${APP_PORT} 被其它服务占用：${owner}"
    log "请核对主机清单；映射无误时，先人工停掉目标机上的那个服务（systemctl disable --now <单元名>）。预检未修改远端任何状态。"
    exit 42
  fi
done
if [[ -n "${pids// /}" ]]; then
  log "ok: 端口 ${APP_PORT} 当前由本服务占用"
else
  log "ok: 端口 ${APP_PORT} 当前空闲"
fi
REMOTE_PREFLIGHT
)"
preflight_cmd="$(printf 'bash -s -- %q %q %q %q %q %q' \
  "${APP_NAME}" "${APP_DIR}" "${SERVICE_NAME}" "${APP_PORT}" "${APP_BIND_ADDRESS}" "${LZ_ROOT}")"

# 只对 ssh 自身的建连失败（退出码 255）重试；远端脚本给出的结论（尤其 42 端口被占）直接上报。
attempt=1
while :; do
  rc=0
  printf '%s\n' "${REMOTE_PREFLIGHT_SCRIPT}" | remote "${preflight_cmd}" || rc=$?
  (( rc == 0 )) && break
  (( rc != 255 )) && exit "${rc}"
  if (( attempt >= NET_MAX_ATTEMPTS )); then
    echo "[wrapper] ERROR: 连不上 ${SSH_USER}@${SSH_HOST}:${SSH_PORT}（已试 ${attempt} 次）。这是网络 / 主机问题，不是构建问题；远端未被改动。" >&2
    exit "${rc}"
  fi
  echo "[wrapper] WARNING: SSH 建连失败，第 ${attempt}/${NET_MAX_ATTEMPTS} 次，${NET_RETRY_DELAY_SECONDS}s 后重试" >&2
  sleep "${NET_RETRY_DELAY_SECONDS}"
  attempt=$(( attempt + 1 ))
done

# ---- 2. 放置 remote-deploy.sh ----
# 部署脚本唯一权威在本仓；每次部署都覆盖目标机上的副本，产品仓里不再各放一份。
REMOTE_DEPLOY_PATH="${LZ_ROOT}/lib/remote-deploy.sh"
remote "mkdir -p ${LZ_ROOT}/lib"
sshpass -e scp "${SCP_OPTS[@]}" "${LZ_REMOTE_DEPLOY_SCRIPT}" "${SSH_USER}@${SSH_HOST}:${REMOTE_DEPLOY_PATH}"

# ---- 3. 目标机就地构建并部署 ----
remote_env="$(printf 'LZ_ROOT=%q LZ_ETC=%q LZ_REMOTE_DEPLOY=%q LZ_GITHUB_OWNER=%q LZ_GITHUB_REPO=%q LZ_MODULE_PREFIX=%q LZ_SOURCE_REF=%q LZ_END=%q LZ_PACKAGE_MANAGER=%q LZ_FRONTEND_SCRIPT=%q APP_NAME=%q APP_DIR=%q SERVICE_NAME=%q APP_PORT=%q APP_BIND_ADDRESS=%q APP_PROFILE=%q HEALTH_PATH=%q HEALTH_SCHEME=%q HEALTH_TIMEOUT_SECONDS=%q RESTART_CMD=%q' \
  "${LZ_ROOT}" "${LZ_ETC}" "${REMOTE_DEPLOY_PATH}" "${LZ_GITHUB_OWNER}" "${LZ_GITHUB_REPO}" "${LZ_MODULE_PREFIX}" \
  "${LZ_SOURCE_REF}" "${LZ_END}" "${LZ_PACKAGE_MANAGER:-npm}" "${LZ_FRONTEND_SCRIPT:-build:deploy}" \
  "${APP_NAME}" "${APP_DIR}" "${SERVICE_NAME}" "${APP_PORT}" "${APP_BIND_ADDRESS}" "${APP_PROFILE}" \
  "${HEALTH_PATH}" "${HEALTH_SCHEME}" "${HEALTH_TIMEOUT_SECONDS}" "${RESTART_CMD}")"
# 按端点旋钮只在主机清单给了值时才传，留空交给 remote-build.sh 的缺省值。
append_opt() {
  if [[ -n "$2" ]]; then
    remote_env+=" $(printf '%s=%q' "$1" "$2")"
  fi
}
append_opt LZ_SRC_ROOT "$(lookup SRC_ROOT '')"
append_opt LZ_BUILD_TIMEOUT_SECONDS "$(lookup BUILD_TIMEOUT_SECONDS '')"
append_opt LZ_BUILD_SKIP_TESTS "$(lookup BUILD_SKIP_TESTS '')"
append_opt LZ_MIN_FREE_MB "$(lookup MIN_FREE_MB '')"
append_opt LZ_MAVEN_OPTS "$(lookup MAVEN_OPTS '')"
append_opt LZ_NODE_OPTIONS "$(lookup NODE_OPTIONS '')"
append_opt LZ_MAVEN_MIRROR_URL "$(lookup MAVEN_MIRROR_URL '')"
append_opt LZ_KEEP_RELEASES "$(lookup KEEP_RELEASES '')"

echo "[wrapper] ${LZ_GITHUB_REPO}@${LZ_SOURCE_REF} 将在 ${SSH_HOST} 上就地构建并部署"
# GIT_TOKEN 随 stdin 里的脚本文本进入远端 bash，不进 ssh 命令串（命令串会成为目标机上 ps 可见的 argv）。
# 刻意不重试：这次会话覆盖「构建 + 替换重启」，自动重来等于自动重新部署。
rc=0
{
  printf 'set +x\n'
  printf 'GIT_TOKEN=%q\n' "${GIT_TOKEN}"
  printf 'export GIT_TOKEN\n'
  cat "${LZ_REMOTE_BUILD_SCRIPT}"
} | remote "${remote_env} bash -s" || rc=$?

if (( rc == 0 )); then
  echo "[wrapper] ${APP_NAME} 部署完成"
  exit 0
fi
if (( rc == 255 )); then
  echo "[wrapper] ERROR: SSH 会话中断（255）。这是网络问题；构建若已开始也会随连接断开而终止。" >&2
else
  echo "[wrapper] ERROR: 目标机上构建或部署失败（退出码 ${rc}），原因见上方 [remote-build] / [remote-deploy] 日志。" >&2
fi
echo '[wrapper] 不自动重跑。定位原因后人工重新点这个 Job。' >&2
exit "${rc}"
