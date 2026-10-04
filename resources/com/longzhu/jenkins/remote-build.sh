#!/usr/bin/env bash
# 运行位置：目标服务器。由 Jenkins 侧 deploy-wrapper.sh 经 `ssh ... bash -s` 从标准输入喂进来执行，不落盘。
#
# 职责：把产品仓同步到指定分支最新提交 → 就地构建本端 fat jar → 落成 ${APP_DIR}/app.jar.incoming
#       → 交给 remote-deploy.sh 完成原子替换、重启、健康检查与失败回滚。
#
# 边界：
#   - 只检测不安装：git / JDK 21 / Maven / Node / npm 由 jenkins/install/provision-build-host.sh
#     一次性装好，部署过程不跑 apt-get / yum。
#   - 构建失败时，正在跑的 app.jar 与服务一个字节都不动。
#
# 必需环境变量（deploy-wrapper.sh 以 KEY=%q 前缀注入）：
#   LZ_GITHUB_OWNER LZ_GITHUB_REPO LZ_SOURCE_REF LZ_MODULE_PREFIX LZ_END
#   APP_NAME APP_DIR SERVICE_NAME APP_PORT APP_PROFILE
#   LZ_REMOTE_DEPLOY   remote-deploy.sh 在本机的路径（wrapper 已先放好）
# 可选：
#   LZ_ROOT            目标机根目录，默认 /opt/longzhu
#   LZ_SRC_ROOT        源码根目录，默认 ${LZ_ROOT}/src
#   LZ_PACKAGE_MANAGER npm（默认）或 pnpm
#   LZ_FRONTEND_SCRIPT 前端构建脚本名，默认 build:deploy（产物由脚本自己同步进后端 static/）
#   LZ_BUILD_TIMEOUT_SECONDS  前端 + 后端共用的构建墙钟预算，默认 2700
#   LZ_BUILD_SKIP_TESTS       1 则 mvn 加 -DskipTests；默认 0，即构建时跑单元测试，测试不过不上线
#   LZ_MIN_FREE_MB            构建前要求的最小可用磁盘，默认 5120；0 关闭检查
#   LZ_MAVEN_OPTS / LZ_NODE_OPTIONS   追加到 MAVEN_OPTS / NODE_OPTIONS（小内存机用）
#   LZ_MAVEN_MIRROR_URL       Maven 镜像，默认华为云；填 none 则不用镜像
#   LZ_KEEP_RELEASES          releases/ 保留的历史版本数，透传给 remote-deploy.sh
#   LZ_GIT_FETCH_ATTEMPTS     git fetch 尝试次数，默认 5；0 = 不走 git，直接用 GitHub API + codeload tarball
#                             （境内机连 github.com 的 git 通道常年超时、API 与 codeload 却很快时用）
#   APP_BIND_ADDRESS HEALTH_PATH HEALTH_SCHEME HEALTH_TIMEOUT_SECONDS RESTART_CMD  透传给 remote-deploy.sh
#   GIT_TOKEN           GitHub PAT。随 stdin 进来，只经 git credential helper 交给本次进程，
#                       不进 argv、不写进 .git/config
#   LZ_REMOTE_BUILD_PRINT_PLAN  非空则只打印构建计划后退出，不碰网络、磁盘与服务（tests/ 用）
set -euo pipefail
set +x

: "${LZ_GITHUB_OWNER:?LZ_GITHUB_OWNER is required}"
: "${LZ_GITHUB_REPO:?LZ_GITHUB_REPO is required}"
: "${LZ_SOURCE_REF:?LZ_SOURCE_REF is required}"
: "${LZ_MODULE_PREFIX:?LZ_MODULE_PREFIX is required}"
: "${LZ_END:?LZ_END is required}"
: "${APP_NAME:?APP_NAME is required}"
: "${APP_DIR:?APP_DIR is required}"
: "${SERVICE_NAME:?SERVICE_NAME is required}"
: "${APP_PORT:?APP_PORT is required}"
: "${APP_PROFILE:?APP_PROFILE is required}"

LZ_ROOT="${LZ_ROOT:-/opt/longzhu}"
LZ_SRC_ROOT="${LZ_SRC_ROOT:-${LZ_ROOT}/src}"
LZ_PACKAGE_MANAGER="${LZ_PACKAGE_MANAGER:-npm}"
LZ_FRONTEND_SCRIPT="${LZ_FRONTEND_SCRIPT:-build:deploy}"
LZ_BUILD_TIMEOUT_SECONDS="${LZ_BUILD_TIMEOUT_SECONDS:-2700}"
LZ_BUILD_SKIP_TESTS="${LZ_BUILD_SKIP_TESTS:-0}"
LZ_MIN_FREE_MB="${LZ_MIN_FREE_MB:-5120}"
LZ_MAVEN_MIRROR_URL="${LZ_MAVEN_MIRROR_URL:-https://mirrors.huaweicloud.com/repository/maven/}"
LZ_GIT_FETCH_ATTEMPTS="${LZ_GIT_FETCH_ATTEMPTS:-5}"

log() { printf '[remote-build][%s] %s\n' "${APP_NAME}" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ "${LZ_END}" == "user" || "${LZ_END}" == "admin" ]] || die "LZ_END 必须是 user 或 admin（当前 '${LZ_END}'）"
[[ "${LZ_PACKAGE_MANAGER}" == "npm" || "${LZ_PACKAGE_MANAGER}" == "pnpm" ]] \
  || die "LZ_PACKAGE_MANAGER 必须是 npm 或 pnpm（当前 '${LZ_PACKAGE_MANAGER}'）"
[[ "${LZ_BUILD_SKIP_TESTS}" == "0" || "${LZ_BUILD_SKIP_TESTS}" == "1" ]] \
  || die "LZ_BUILD_SKIP_TESTS 必须是 0 或 1（当前 '${LZ_BUILD_SKIP_TESTS}'）"
for numeric_var in LZ_BUILD_TIMEOUT_SECONDS LZ_MIN_FREE_MB LZ_GIT_FETCH_ATTEMPTS; do
  [[ "${!numeric_var}" =~ ^[0-9]+$ ]] || die "${numeric_var} 必须是非负整数（当前 '${!numeric_var}'）"
done
(( LZ_BUILD_TIMEOUT_SECONDS > 0 )) || die 'LZ_BUILD_TIMEOUT_SECONDS 必须为正整数'

SRC_DIR="${LZ_SRC_ROOT}/${LZ_GITHUB_REPO}"
LOCK_FILE="${LZ_SRC_ROOT}/.${LZ_GITHUB_REPO}.build.lock"
GIT_URL="https://github.com/${LZ_GITHUB_OWNER}/${LZ_GITHUB_REPO}.git"
# 仓内目录约定：<prefix>-<end>/<prefix>-<end>（后端 Maven 模块）与 <prefix>-<end>/<prefix>-<end>-react（前端）。
MODULE_REL="${LZ_MODULE_PREFIX}-${LZ_END}/${LZ_MODULE_PREFIX}-${LZ_END}"
REACT_REL="${LZ_MODULE_PREFIX}-${LZ_END}/${LZ_MODULE_PREFIX}-${LZ_END}-react"
JAR_GLOB="${LZ_MODULE_PREFIX}-${LZ_END}"
# 只构建本端；-am 把聚合父 pom 与公共模块一起带进反应堆。
MVN_ARGS=(-pl "${MODULE_REL}" -am)
if [[ "${LZ_BUILD_SKIP_TESTS}" == "1" ]]; then
  MVN_ARGS+=(-DskipTests)
fi

if [[ -n "${LZ_REMOTE_BUILD_PRINT_PLAN:-}" ]]; then
  printf 'git_url=%s ref=%s end=%s\n' "${GIT_URL}" "${LZ_SOURCE_REF}" "${LZ_END}"
  printf 'src_dir=%s module=%s react=%s jar_glob=%s\n' "${SRC_DIR}" "${MODULE_REL}" "${REACT_REL}" "${JAR_GLOB}"
  printf 'mvn_args=%s\n' "${MVN_ARGS[*]}"
  printf 'package_manager=%s frontend_script=%s\n' "${LZ_PACKAGE_MANAGER}" "${LZ_FRONTEND_SCRIPT}"
  printf 'build_timeout=%ss min_free_mb=%s maven_mirror=%s\n' "${LZ_BUILD_TIMEOUT_SECONDS}" "${LZ_MIN_FREE_MB}" "${LZ_MAVEN_MIRROR_URL}"
  printf 'git_fetch_attempts=%s\n' "${LZ_GIT_FETCH_ATTEMPTS}"
  printf 'app_dir=%s service=%s remote_deploy=%s\n' "${APP_DIR}" "${SERVICE_NAME}" "${LZ_REMOTE_DEPLOY:-<unset>}"
  exit 0
fi

: "${LZ_REMOTE_DEPLOY:?LZ_REMOTE_DEPLOY is required}"
: "${GIT_TOKEN:?GIT_TOKEN is required（Jenkins 凭据 longzhu-github 未注入?）}"
[[ -f "${LZ_REMOTE_DEPLOY}" ]] || die "找不到 ${LZ_REMOTE_DEPLOY}"

# ---- 1. 工具链检测（只检测，不安装）----
MISSING_TOOLS=()
require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "缺少 $1（$2）"
    MISSING_TOOLS+=("$1")
  fi
}
require_tool git '同步产品仓源码'
require_tool java '运行构建出的 jar'
require_tool mvn '构建后端模块'
require_tool flock '构建互斥锁'
require_tool node '构建前端'
require_tool "${LZ_PACKAGE_MANAGER}" "前端用 ${LZ_PACKAGE_MANAGER} 构建"
if (( ${#MISSING_TOOLS[@]} > 0 )); then
  log '目标机需要 git + JDK 21 + Maven + Node 20 + npm。部署过程只检测、不安装。'
  log '一次性准备：把本仓 jenkins/install/provision-build-host.sh 拷到目标机，以 root 执行一次（可重复跑）。'
  die "缺少工具: ${MISSING_TOOLS[*]}"
fi
log "toolchain: $(git --version 2>/dev/null | head -1), java=$(java -version 2>&1 | head -1)"
log "toolchain: node=$(node --version 2>/dev/null), ${LZ_PACKAGE_MANAGER}=$("${LZ_PACKAGE_MANAGER}" --version 2>/dev/null || echo '解析失败')"

# ---- 2. 磁盘检查 ----
mkdir -p "${LZ_SRC_ROOT}"
if (( LZ_MIN_FREE_MB > 0 )); then
  free_mb="$(df -Pm "${LZ_SRC_ROOT}" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ "${free_mb}" =~ ^[0-9]+$ ]]; then
    if (( free_mb < LZ_MIN_FREE_MB )); then
      log "ERROR: ${LZ_SRC_ROOT} 所在分区只剩 ${free_mb} MB，低于要求的 ${LZ_MIN_FREE_MB} MB。"
      log "腾空间：清理 ~/.m2/repository、${APP_DIR}/releases，或删掉不用的 ${LZ_SRC_ROOT}/<仓名>。"
      log '远端未被改动：app.jar 未替换、服务未重启。'
      exit 1
    fi
    log "disk: ${LZ_SRC_ROOT} 可用 ${free_mb} MB（要求 ${LZ_MIN_FREE_MB} MB）"
  else
    log 'WARNING: 无法解析磁盘可用空间，跳过检查'
  fi
fi

# ---- 3. 构建互斥 ----
# 两端同机时 user / admin 共用一份源码树，拿不到锁就等对方结束，而不是互相拆台。
exec 9>"${LOCK_FILE}"
if ! flock -w "${LZ_BUILD_TIMEOUT_SECONDS}" 9; then
  log "ERROR: ${SRC_DIR} 在 ${LZ_BUILD_TIMEOUT_SECONDS}s 内一直被其它构建占用（锁 ${LOCK_FILE}）。远端未被改动。"
  exit 1
fi

# ---- 4. 同步源码 ----
# 令牌只经 credential helper 交给本次 git 进程；远端地址每次重置为不含凭据的形式。
export GIT_TOKEN
export GIT_TERMINAL_PROMPT=0
GIT_TOKEN_HELPER='!f() { printf "username=x-access-token\npassword=%s\n" "${GIT_TOKEN}"; }; f'
# 不用 git -C：CentOS 7 自带 git 1.8.3 不支持。
git_in() { local dir="$1"; shift; (cd "${dir}" && git "$@"); }
git_authed_in() {
  local dir="$1"; shift
  (cd "${dir}" && git -c "credential.helper=${GIT_TOKEN_HELPER}" -c http.version=HTTP/1.1 \
    -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 "$@")
}

if [[ ! -d "${SRC_DIR}/.git" ]]; then
  log "首次同步：初始化 ${SRC_DIR}"
  rm -rf "${SRC_DIR}"
  mkdir -p "${SRC_DIR}"
  git_in "${SRC_DIR}" init -q
  git_in "${SRC_DIR}" remote add origin "${GIT_URL}"
fi
git_in "${SRC_DIR}" remote set-url origin "${GIT_URL}"

log "同步 ${LZ_GITHUB_OWNER}/${LZ_GITHUB_REPO}@${LZ_SOURCE_REF} -> ${SRC_DIR}"
# 境内机访问 github.com 偶发超时 / 重置，多试几次并拉长退避；主机清单设 0 则直接走 tarball。
FETCH_MAX_ATTEMPTS="${LZ_GIT_FETCH_ATTEMPTS}"
fetch_ok=false
for (( attempt = 1; attempt <= FETCH_MAX_ATTEMPTS; attempt++ )); do
  if git_authed_in "${SRC_DIR}" fetch --depth 1 --no-tags --prune origin "${LZ_SOURCE_REF}" </dev/null; then
    fetch_ok=true
    break
  fi
  (( attempt == FETCH_MAX_ATTEMPTS )) && break
  backoff=$(( 5 * 2 ** (attempt - 1) ))
  (( backoff > 60 )) && backoff=60
  log "WARNING: 第 ${attempt}/${FETCH_MAX_ATTEMPTS} 次 fetch 失败，${backoff}s 后重试"
  sleep "${backoff}"
done

if [[ "${fetch_ok}" == "true" ]]; then
  # reset --hard + clean -xfd：工作树与「全新克隆」等价，不让上次构建的残留混进这次 jar。
  git_in "${SRC_DIR}" reset --hard -q FETCH_HEAD
  git_in "${SRC_DIR}" clean -xfdq
  BUILD_ID="$(git_in "${SRC_DIR}" rev-parse HEAD)"
  log "checked out ${LZ_SOURCE_REF} @ ${BUILD_ID}"
else
  # git 协议挂了但 REST / codeload 往往还通：走 tarball 兜底。令牌只走 Authorization 头。
  if (( FETCH_MAX_ATTEMPTS == 0 )); then
    log "主机清单设定不走 git（_GIT_FETCH_ATTEMPTS=0），直接用 GitHub API / codeload tarball"
  else
    log "WARNING: git fetch 连续 ${FETCH_MAX_ATTEMPTS} 次失败，改用 GitHub API / codeload tarball 兜底"
  fi
  command -v curl >/dev/null 2>&1 || die '本机没有 curl，无法走 tarball 兜底。远端未被改动。'
  API_JSON="$(curl -fsSL --connect-timeout 20 --max-time 120 \
      -H "Authorization: Bearer ${GIT_TOKEN}" -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/${LZ_GITHUB_OWNER}/${LZ_GITHUB_REPO}/commits/${LZ_SOURCE_REF}")" \
    || die '无法经 GitHub API 取到分支最新提交（网络或令牌问题）。远端未被改动。'
  API_SHA="$(printf '%s' "${API_JSON}" | grep -m1 -oE '"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]{40}"' | grep -oE '[0-9a-f]{40}' || true)"
  [[ -n "${API_SHA}" ]] || die '无法解析分支最新提交 SHA。远端未被改动。'
  TARBALL_TMP="$(mktemp -d "${LZ_SRC_ROOT}/.${LZ_GITHUB_REPO}.tarball.XXXXXX")"
  trap 'rm -rf "${TARBALL_TMP}"' EXIT
  curl -fsSL --connect-timeout 20 --max-time 600 -H "Authorization: Bearer ${GIT_TOKEN}" \
      -o "${TARBALL_TMP}/src.tgz" "https://codeload.github.com/${LZ_GITHUB_OWNER}/${LZ_GITHUB_REPO}/tar.gz/${API_SHA}" \
    || die 'codeload.github.com 下载失败。远端未被改动。'
  find "${SRC_DIR}" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
  tar -xzf "${TARBALL_TMP}/src.tgz" -C "${SRC_DIR}" --strip-components=1
  rm -rf "${TARBALL_TMP}"
  trap - EXIT
  BUILD_ID="${API_SHA}"
  log "checked out ${LZ_SOURCE_REF} @ ${BUILD_ID}（tarball 兜底）"
fi

# ---- 5. 构建 ----
export MAVEN_OPTS="-Daether.connector.connectTimeout=60000 -Daether.connector.requestTimeout=600000 -Dmaven.wagon.http.retryHandler.count=5 ${MAVEN_OPTS:-}${LZ_MAVEN_OPTS:+ ${LZ_MAVEN_OPTS}}"
export NODE_OPTIONS="${NODE_OPTIONS:-}${LZ_NODE_OPTIONS:+ ${LZ_NODE_OPTIONS}}"
# CentOS 8（glibc 2.28）跑不了新版 rollup 的原生绑定，回落 JS 实现。
export ROLLUP_SKIP_NODEJS_NATIVE="${ROLLUP_SKIP_NODEJS_NATIVE:-1}"

MVN_CMD=(mvn -B -ntp)
if [[ "${LZ_MAVEN_MIRROR_URL}" != "none" ]]; then
  # 境内机访问 Maven 中央仓偶发 DNS 失败，默认走镜像。镜像地址写进标记行，换地址会自动重写。
  MAVEN_SETTINGS="${LZ_ROOT}/conf/maven-settings.xml"
  MAVEN_MARKER="<!-- longzhu-maven-settings mirror=${LZ_MAVEN_MIRROR_URL} -->"
  mkdir -p "$(dirname "${MAVEN_SETTINGS}")"
  if [[ ! -f "${MAVEN_SETTINGS}" ]] || ! grep -Fq "${MAVEN_MARKER}" "${MAVEN_SETTINGS}"; then
    cat > "${MAVEN_SETTINGS}.incoming" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
${MAVEN_MARKER}
<settings xmlns="http://maven.apache.org/SETTINGS/1.2.0">
  <mirrors>
    <mirror>
      <id>longzhu-mirror</id>
      <url>${LZ_MAVEN_MIRROR_URL}</url>
      <mirrorOf>*</mirrorOf>
    </mirror>
  </mirrors>
</settings>
EOF
    mv "${MAVEN_SETTINGS}.incoming" "${MAVEN_SETTINGS}"
    log "已写入 Maven 镜像配置 ${MAVEN_SETTINGS}"
  fi
  MVN_CMD+=(-s "${MAVEN_SETTINGS}")
fi
MVN_CMD+=("${MVN_ARGS[@]}" package)

# 半截下载会把后续构建钉死在「本地已有损坏文件」上，开工前清掉标记文件。
purge_stale_m2() {
  local repo="${HOME}/.m2/repository"
  [[ -d "${repo}" ]] || return 0
  find "${repo}" \( -name '*.lastUpdated' -o -name '*.part' -o -name '*.jar.tmp' \) -type f -delete 2>/dev/null || true
}
purge_stale_m2

# 整次构建共用一份墙钟预算；timeout 会连同 mvn 分叉出的测试子进程一起收掉。构建失败不重试。
BUILD_DEADLINE=$(( SECONDS + LZ_BUILD_TIMEOUT_SECONDS ))
HAVE_TIMEOUT=true
command -v timeout >/dev/null 2>&1 || { HAVE_TIMEOUT=false; log 'WARNING: 本机无 timeout，本次构建不设墙钟上限'; }
run_step() {
  local what="$1" remaining rc=0
  shift
  if [[ "${HAVE_TIMEOUT}" == "true" ]]; then
    remaining=$(( BUILD_DEADLINE - SECONDS ))
    if (( remaining <= 0 )); then
      log "ERROR: 构建预算 ${LZ_BUILD_TIMEOUT_SECONDS}s 已用尽，${what} 未开始"
      return 124
    fi
    timeout --signal=TERM --kill-after=30s "${remaining}" "$@" </dev/null || rc=$?
  else
    "$@" </dev/null || rc=$?
  fi
  (( rc == 137 )) && rc=124
  (( rc != 0 )) && log "ERROR: ${what} 失败（退出码 ${rc}）"
  return "${rc}"
}

build_started="${SECONDS}"
build_rc=0
[[ -d "${SRC_DIR}/${REACT_REL}" ]] || die "前端工程目录不存在: ${SRC_DIR}/${REACT_REL}（products.json 的 modulePrefix 对吗?）"
cd "${SRC_DIR}/${REACT_REL}"
log "=== ${LZ_END} 前端 (${REACT_REL}) ==="
if [[ "${LZ_PACKAGE_MANAGER}" == "pnpm" ]]; then
  if [[ -f pnpm-lock.yaml ]]; then
    run_step '前端依赖安装 (pnpm install --frozen-lockfile)' pnpm install --frozen-lockfile || build_rc=$?
  else
    run_step '前端依赖安装 (pnpm install)' pnpm install || build_rc=$?
  fi
else
  if [[ -f package-lock.json ]]; then
    run_step '前端依赖安装 (npm ci)' npm ci || build_rc=$?
  else
    run_step '前端依赖安装 (npm install)' npm install || build_rc=$?
  fi
fi
if (( build_rc == 0 )); then
  run_step "前端构建 (${LZ_PACKAGE_MANAGER} run ${LZ_FRONTEND_SCRIPT})" "${LZ_PACKAGE_MANAGER}" run "${LZ_FRONTEND_SCRIPT}" || build_rc=$?
fi

if (( build_rc == 0 )); then
  cd "${SRC_DIR}"
  log "=== 后端 (${MVN_CMD[*]}) ==="
  run_step '后端构建 (mvn package)' "${MVN_CMD[@]}" || build_rc=$?
  # 只对「依赖下载被掐断留下半截缓存」重试一次；编译 / 测试失败不重来。
  if (( build_rc != 0 && build_rc != 124 )) && [[ -d "${HOME}/.m2/repository" ]] \
    && find "${HOME}/.m2/repository" \( -name '*.lastUpdated' -o -name '*.part' \) -type f 2>/dev/null | grep -q .; then
    log 'WARNING: 检测到半截 Maven 依赖，清理后重试一次'
    purge_stale_m2
    build_rc=0
    run_step '后端构建 (mvn package 重试)' "${MVN_CMD[@]}" || build_rc=$?
  fi
fi

build_elapsed=$(( SECONDS - build_started ))
if (( build_rc != 0 )); then
  log "构建失败（退出码 ${build_rc}，耗时 ${build_elapsed}s）"
  if (( build_rc == 124 )); then
    log "撞上了构建预算 ${LZ_BUILD_TIMEOUT_SECONDS}s。多半是内存不足：看 free -m 与 dmesg 有无 oom-kill；"
    log '内存紧张时在主机清单给该端点设 <KEY>_MAVEN_OPTS=-Xmx1g 与 <KEY>_NODE_OPTIONS=--max-old-space-size=1024。'
  fi
  log '远端未被改动：app.jar 未替换、服务未重启，仍在跑上一版本。'
  exit 1
fi
log "构建完成，耗时 ${build_elapsed}s"

# ---- 6. 落暂存 jar ----
TARGET_DIR="${SRC_DIR}/${MODULE_REL}/target"
jar_src="$(find "${TARGET_DIR}" -maxdepth 1 -type f -name "${JAR_GLOB}*.jar" ! -name '*.jar.original' 2>/dev/null | sort | head -1)"
[[ -n "${jar_src}" ]] || die "在 ${TARGET_DIR} 没找到 ${JAR_GLOB}*.jar（构建产物命名变了?）"
mkdir -p "${APP_DIR}"
cp -f "${jar_src}" "${APP_DIR}/app.jar.incoming"
log "staged ${APP_DIR}/app.jar.incoming ($(du -h "${APP_DIR}/app.jar.incoming" | cut -f1)) <- ${jar_src}"

# ---- 7. 交给部署脚本 ----
log "交给 remote-deploy.sh（build ${BUILD_ID}）"
cd "${APP_DIR}"
LZ_ROOT="${LZ_ROOT}" \
LZ_ETC="${LZ_ETC:-/etc/longzhu}" \
APP_NAME="${APP_NAME}" \
APP_DIR="${APP_DIR}" \
SERVICE_NAME="${SERVICE_NAME}" \
APP_PORT="${APP_PORT}" \
APP_BIND_ADDRESS="${APP_BIND_ADDRESS:-}" \
APP_PROFILE="${APP_PROFILE}" \
HEALTH_PATH="${HEALTH_PATH:-}" \
HEALTH_SCHEME="${HEALTH_SCHEME:-}" \
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-}" \
RESTART_CMD="${RESTART_CMD:-}" \
KEEP_RELEASES="${LZ_KEEP_RELEASES:-}" \
BUILD_ID="${BUILD_ID}" \
  bash "${LZ_REMOTE_DEPLOY}" </dev/null
