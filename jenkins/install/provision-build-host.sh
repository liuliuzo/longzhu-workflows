#!/usr/bin/env bash
# 在一台**应用目标机**（dev / prod）上装齐「目标机自建」所需的构建工具链。脚本幂等，可重复执行。
#
# 用法（在目标机上以 root 或 sudo 执行）：
#   sudo bash provision-build-host.sh
#   sudo CREATE_SWAP_GB=4 bash provision-build-host.sh   # 内存偏小的机器顺便建交换分区
#
# 为什么需要它：部署是「目标机 git 拉代码、就地构建、就地部署」（见 README），
# 所以目标机要有一套完整构建工具链，而不只是一个 JRE。
#
# 部署流水线**只检测不安装**：remote-build.sh 发现缺工具即失败并指向本脚本，绝不在部署过程里
# 跑 apt-get —— 与 remote-deploy.sh 对 JDK 的既有口径一致。目标机的软件包由人工一次性准备，
# 部署过程不改动它，这样「线上这台机器装了什么」始终是一次有记录的人工决定。
#
# 安装内容：
#   Temurin JDK 21   构建与运行（机器上已有 JDK 21 则复用）
#   Node.js 20       前端构建（npm 随 Node 提供）
#   pnpm 10          备用；products.json 里 packageManager=pnpm 的产品才需要
#   Maven            后端模块构建
#   git / curl       同步产品仓源码（curl 用于 git 不通时的 tarball 兜底）
#   iproute2 (ss)    部署前的端口归属检查
#   coreutils/util-linux  构建墙钟上限（timeout）与构建互斥锁（flock）
#
# 支持 Debian / Ubuntu（apt）与 CentOS 7 / 8（yum）。CentOS 7 的 glibc 2.17
# 跑不了 Node.js 官方 20.x 二进制，因此 yum 分支统一安装 nodejs/unofficial-builds 的 glibc-217
# 产物（CentOS 8 也能跑），并在落盘前校验项目发布的 SHA-256；版本固定为与控制器实测一致的 20.20.2。
#
# 纯中间件机（数据库 / Redis 等）不要跑本脚本。
#
# 机器建议：2 vCPU / 4 GB 内存 / 40 GB 磁盘起步。前端 vite build 与 mvn package 都吃内存，
# 2 GB 的机器几乎必然在构建中被 OOM killer 打断 —— 这类机器请用 CREATE_SWAP_GB 补交换分区，
# 并在主机清单为该端点设 <KEY>_MAVEN_OPTS 与 <KEY>_NODE_OPTIONS 收紧堆上限。
#
# 本脚本不配置任何凭据、不写入任何口令，也不部署任何应用。
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "[provision] 请以 root 或 sudo 执行本脚本" >&2
  exit 1
fi

if command -v apt-get >/dev/null 2>&1; then
  PACKAGE_FAMILY=apt
elif command -v yum >/dev/null 2>&1; then
  PACKAGE_FAMILY=yum
else
  echo "[provision] 本脚本只支持 Debian / Ubuntu（apt）与 CentOS 7 / 8（yum）。" >&2
  echo "[provision] 当前机器没有 apt-get 或 yum，请参照本脚本手工安装 JDK 21 / Node 20 / pnpm 10 / Maven / git。" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
KEYRINGS=/usr/share/keyrings
NODE_VERSION=20.20.2
MAVEN_VERSION=3.8.7
# CentOS 主版本：8 可用官方 Node linux-x64；7 必须走 glibc-217 非官方构建。
OS_MAJOR=""
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_MAJOR="${VERSION_ID%%.*}"
fi
if [[ "${PACKAGE_FAMILY}" == "apt" ]]; then
  install -d -m 0755 "${KEYRINGS}"
fi

# 若机器上已有可用的 JDK 21（含 javac），直接复用 —— 境内 CentOS 8 应用机常预装 Oracle JDK 21，
# 再从 GitHub 拉 Temurin tarball 会卡在跨境慢链路上数十分钟。版本主号一致即可构建。
find_existing_jdk21() {
  local candidate
  for candidate in \
    /opt/temurin-21 \
    /usr/lib/jvm/jdk-21* \
    /usr/lib/jvm/temurin-21* \
    /usr/lib/jvm/java-21* \
    /usr/java/jdk-21*; do
    [[ -d "${candidate}" ]] || continue
    if [[ -x "${candidate}/bin/java" && -x "${candidate}/bin/javac" ]] \
      && "${candidate}/bin/java" -version 2>&1 | grep -q 'version "21'; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

# install_apt_key <密钥 URL> <目标 .gpg 路径> <名称>
#
# 每次都重新下载并校验，不因目标文件已存在就跳过 —— 上一次跑到一半留下的空文件 / HTML 错误页
# 会让 apt 报 `NO_PUBKEY ... repository is not signed`，而该失败很容易被误读为网络或系统问题。
# 先落临时文件、校验是 PGP armored 公钥块、再 dearmor 到目标路径，保证目标文件要么正确要么不存在。
install_apt_key() {
  local url="$1" dest="$2" name="$3" tmp
  tmp="$(mktemp)"
  echo "[provision] (key) 下载 ${name}"
  if ! curl -fsSL --retry 3 --retry-delay 2 "${url}" -o "${tmp}"; then
    echo "[provision] ERROR: ${name} 密钥下载失败: ${url}" >&2
    rm -f "${tmp}"
    exit 1
  fi
  if [[ ! -s "${tmp}" ]] || ! grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "${tmp}"; then
    echo "[provision] ERROR: ${name} 密钥内容不是 PGP 公钥（可能被网关替换成了错误页）: ${url}" >&2
    rm -f "${tmp}"
    exit 1
  fi
  rm -f "${dest}"
  gpg --batch --yes --dearmor -o "${dest}" "${tmp}"
  chmod 644 "${dest}"
  rm -f "${tmp}"
}

maven_version_line() {
  # 不能用 `mvn -v | head -1`：Java 21 下 Maven/Jansi 在 head 提前关管道时会以 Broken pipe
  # 非零退出，让装机脚本在工具已经装好后误判失败。先完整收完输出，再只打印首行。
  local output
  output="$(mvn -v 2>&1)"
  printf '%s\n' "${output%%$'\n'*}"
}

echo "[provision] === 1/6 基础依赖 ==="
if [[ "${PACKAGE_FAMILY}" == "apt" ]]; then
  apt-get update -qq
  apt-get install -y -qq \
    ca-certificates curl gnupg apt-transport-https lsb-release \
    git rsync zip unzip fontconfig procps coreutils util-linux iproute2
else
  yum install -y \
    ca-certificates curl gnupg2 git rsync zip unzip fontconfig procps-ng \
    coreutils util-linux tar xz iproute
fi

echo "[provision] === 2/6 Temurin JDK 21 ==="
if existing_jdk="$(find_existing_jdk21)"; then
  echo "[provision] 复用本机已有 JDK 21: ${existing_jdk}"
  temurin_home="${existing_jdk}"
elif [[ "${PACKAGE_FAMILY}" == "apt" ]]; then
  install_apt_key https://packages.adoptium.net/artifactory/api/gpg/key/public \
    "${KEYRINGS}/adoptium.gpg" Adoptium
  echo "deb [signed-by=${KEYRINGS}/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(. /etc/os-release && echo "${VERSION_CODENAME}") main" \
    > /etc/apt/sources.list.d/adoptium.list
  apt-get update -qq
  apt-get install -y -qq temurin-21-jdk
  temurin_home="$(dirname "$(dirname "$(dpkg -L temurin-21-jdk | awk '/\/bin\/java$/ {print; exit}')")")"
else
  # CentOS 8 的 Adoptium yum 源已无 temurin-21-jdk。优先清华镜像，失败再回落 GitHub。
  temurin_ver_us="21.0.12_8"
  temurin_tag="jdk-21.0.12%2B8"
  temurin_archive="OpenJDK21U-jdk_x64_linux_hotspot_${temurin_ver_us}.tar.gz"
  temurin_tmp="$(mktemp -d)"
  temurin_ok=0
  for temurin_base_url in \
    "https://mirrors.tuna.tsinghua.edu.cn/Adoptium/21/jdk/x64/linux" \
    "https://github.com/adoptium/temurin21-binaries/releases/download/${temurin_tag}"
  do
    echo "[provision] 尝试下载 Temurin: ${temurin_base_url}/${temurin_archive}"
    if curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 20 --max-time 600 \
      "${temurin_base_url}/${temurin_archive}" -o "${temurin_tmp}/${temurin_archive}" \
      && curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 20 --max-time 60 \
        "${temurin_base_url}/${temurin_archive}.sha256.txt" -o "${temurin_tmp}/${temurin_archive}.sha256.txt"
    then
      temurin_ok=1
      break
    fi
    echo "[provision] 该源失败，换下一个" >&2
    rm -f "${temurin_tmp}/${temurin_archive}" "${temurin_tmp}/${temurin_archive}.sha256.txt"
  done
  if (( temurin_ok != 1 )); then
    echo "[provision] ERROR: Temurin 21 tarball 全部下载失败。可先在本机装好 JDK 21（含 javac）再重跑。" >&2
    rm -rf "${temurin_tmp}"
    exit 1
  fi
  temurin_sha256="$(awk '{print $1}' "${temurin_tmp}/${temurin_archive}.sha256.txt")"
  if [[ ! "${temurin_sha256}" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo "[provision] ERROR: Temurin SHA-256 内容无效" >&2
    rm -rf "${temurin_tmp}"
    exit 1
  fi
  printf '%s  %s\n' "${temurin_sha256}" "${temurin_tmp}/${temurin_archive}" | sha256sum -c -
  temurin_home="/opt/temurin-21"
  rm -rf "${temurin_home}.incoming"
  install -d -m 0755 "${temurin_home}.incoming"
  tar -xzf "${temurin_tmp}/${temurin_archive}" --strip-components=1 -C "${temurin_home}.incoming"
  rm -rf "${temurin_home}"
  mv "${temurin_home}.incoming" "${temurin_home}"
  rm -rf "${temurin_tmp}"
fi
# /usr/local/bin 在非交互 SSH 的 PATH 中优先于 /usr/bin，显式固定到本次选用的 JDK 21。
[[ -x "${temurin_home}/bin/java" && -x "${temurin_home}/bin/javac" ]] || {
  echo "[provision] ERROR: 无法定位 JDK 21 的 java / javac（home=${temurin_home}）" >&2
  exit 1
}
for tool in java javac jar; do
  ln -sfn "${temurin_home}/bin/${tool}" "/usr/local/bin/${tool}"
done
java -version
javac -version

echo "[provision] === 3/6 Node.js 20 + pnpm ==="
if [[ "${PACKAGE_FAMILY}" == "apt" ]]; then
  install_apt_key https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    "${KEYRINGS}/nodesource.gpg" NodeSource
  echo "deb [signed-by=${KEYRINGS}/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get update -qq
  apt-get install -y -qq nodejs
else
  # CentOS 8（glibc >= 2.28）用官方 linux-x64，优先 npmmirror；CentOS 7 只能用 glibc-217。
  node_tmp="$(mktemp -d)"
  if [[ "${OS_MAJOR}" == "7" ]]; then
    node_dist="node-v${NODE_VERSION}-linux-x64-glibc-217"
    node_archive="${node_dist}.tar.xz"
    node_urls=(
      "https://unofficial-builds.nodejs.org/download/release/v${NODE_VERSION}/${node_archive}"
    )
    node_sum_urls=(
      "https://unofficial-builds.nodejs.org/download/release/v${NODE_VERSION}/SHASUMS256.txt"
    )
  else
    node_dist="node-v${NODE_VERSION}-linux-x64"
    node_archive="${node_dist}.tar.xz"
    node_urls=(
      "https://npmmirror.com/mirrors/node/v${NODE_VERSION}/${node_archive}"
      "https://nodejs.org/dist/v${NODE_VERSION}/${node_archive}"
    )
    node_sum_urls=(
      "https://npmmirror.com/mirrors/node/v${NODE_VERSION}/SHASUMS256.txt"
      "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"
    )
  fi
  node_ok=0
  for i in "${!node_urls[@]}"; do
    echo "[provision] 尝试下载 Node: ${node_urls[$i]}"
    if curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 20 --max-time 600 \
      "${node_urls[$i]}" -o "${node_tmp}/${node_archive}" \
      && curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 20 --max-time 60 \
        "${node_sum_urls[$i]}" -o "${node_tmp}/SHASUMS256.txt"
    then
      node_ok=1
      break
    fi
    echo "[provision] 该源失败，换下一个" >&2
    rm -f "${node_tmp}/${node_archive}" "${node_tmp}/SHASUMS256.txt"
  done
  if (( node_ok != 1 )); then
    echo "[provision] ERROR: Node.js ${NODE_VERSION} 全部下载失败" >&2
    rm -rf "${node_tmp}"
    exit 1
  fi
  node_sha256="$(awk -v archive="${node_archive}" '$2 == archive {print $1}' "${node_tmp}/SHASUMS256.txt")"
  if [[ ! "${node_sha256}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "[provision] ERROR: Node.js 发布清单缺少 ${node_archive}" >&2
    rm -rf "${node_tmp}"
    exit 1
  fi
  printf '%s  %s\n' "${node_sha256}" "${node_tmp}/${node_archive}" | sha256sum -c -
  node_home="/opt/${node_dist}"
  rm -rf "${node_home}.incoming"
  install -d -m 0755 "${node_home}.incoming"
  tar -xJf "${node_tmp}/${node_archive}" --strip-components=1 -C "${node_home}.incoming"
  rm -rf "${node_home}"
  mv "${node_home}.incoming" "${node_home}"
  rm -rf "${node_tmp}"
  for tool in node npm npx corepack; do
    ln -sfn "${node_home}/bin/${tool}" "/usr/local/bin/${tool}"
  done
fi
node --version
npm --version
# corepack 随 Node 20 提供，用它装 pnpm 10。只有 packageManager=pnpm 的产品需要，装不上不阻断。
if [[ "${PACKAGE_FAMILY}" == "yum" ]]; then
  corepack enable --install-directory "${node_home}/bin"
fi
if corepack prepare pnpm@10 --activate; then
  if [[ "${PACKAGE_FAMILY}" == "yum" ]]; then
    for tool in pnpm pnpx; do
      ln -sfn "${node_home}/bin/${tool}" "/usr/local/bin/${tool}"
    done
  else
    corepack enable
  fi
  pnpm --version
else
  echo "[provision] WARNING: pnpm 未装上。只有 products.json 里 packageManager=pnpm 的产品需要它。" >&2
fi

echo "[provision] === 4/6 Maven ==="
if [[ "${PACKAGE_FAMILY}" == "apt" ]]; then
  apt-get install -y -qq maven
  maven_home=/usr/share/maven
else
  # CentOS 7/8 自带 Maven 过旧或缺失。装 Apache 官方 3.8.7 二进制。
  # 包本体优先华为云镜像（境内快）；校验和钉死官方发布值（镜像侧常没有 .sha512）。
  maven_dist="apache-maven-${MAVEN_VERSION}"
  maven_archive="${maven_dist}-bin.tar.gz"
  # apache-maven-3.8.7-bin.tar.gz 官方 SHA-512（Apache 发布页）
  maven_sha512='21c2be0a180a326353e8f6d12289f74bc7cd53080305f05358936f3a1b6dd4d91203f4cc799e81761cf5c53c5bbe9dcc13bdb27ec8f57ecf21b2f9ceec3c8d27'
  maven_tmp="$(mktemp -d)"
  maven_ok=0
  for maven_url in \
    "https://repo.huaweicloud.com/apache/maven/maven-3/${MAVEN_VERSION}/binaries/${maven_archive}" \
    "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/${maven_archive}"
  do
    echo "[provision] 尝试下载 Maven: ${maven_url}"
    if curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 20 --max-time 180 \
      "${maven_url}" -o "${maven_tmp}/${maven_archive}"
    then
      maven_ok=1
      break
    fi
    echo "[provision] 该源失败，换下一个" >&2
    rm -f "${maven_tmp}/${maven_archive}"
  done
  if (( maven_ok != 1 )); then
    echo "[provision] ERROR: Maven ${MAVEN_VERSION} 全部下载失败" >&2
    rm -rf "${maven_tmp}"
    exit 1
  fi
  printf '%s  %s\n' "${maven_sha512}" "${maven_tmp}/${maven_archive}" | sha512sum -c -
  maven_home="/opt/${maven_dist}"
  rm -rf "${maven_home}.incoming"
  install -d -m 0755 "${maven_home}.incoming"
  tar -xzf "${maven_tmp}/${maven_archive}" --strip-components=1 -C "${maven_home}.incoming"
  rm -rf "${maven_home}"
  mv "${maven_home}.incoming" "${maven_home}"
  rm -rf "${maven_tmp}"
fi
# 部分目标机的登录环境残留了旧 JDK 的 JAVA_HOME。用很薄的入口固定到本次安装的 Temurin；
# Jenkins 的非交互 SSH 与人工登录两种入口都因此得到同一套 JDK，不会在构建前报 JAVA_HOME 无效。
for tool in mvn mvnDebug; do
  # 旧版脚本在这里创建的是指向 Maven 本体的符号链接；直接重定向会沿链接覆盖本体并形成递归。
  rm -f "/usr/local/bin/${tool}"
  printf '#!/usr/bin/env bash\nexport JAVA_HOME=%q\nexec %q "$@"\n' \
    "${temurin_home}" "${maven_home}/bin/${tool}" > "/usr/local/bin/${tool}"
  chmod 755 "/usr/local/bin/${tool}"
done
maven_version_line

echo "[provision] === 5/6 目录 ==="
# remote-build.sh 的默认源码根与配置目录；Maven 镜像配置由 remote-build.sh 每次按主机清单写入。
install -d -m 0755 /opt/longzhu/src /opt/longzhu/conf /opt/longzhu/lib
install -d -m 0700 /etc/longzhu
echo "[provision] 源码根: /opt/longzhu/src；运行时口令文件目录: /etc/longzhu（0700）"
echo "[provision] === 6/6 内存与磁盘自检 ==="
mem_mb="$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)"
swap_mb="$(awk '/SwapTotal/ {print int($2 / 1024)}' /proc/meminfo)"
free_mb="$(df -Pm /opt/longzhu 2>/dev/null | awk 'NR==2 {print $4}')"
echo "[provision] 内存 ${mem_mb} MB / 交换 ${swap_mb} MB / /opt/longzhu 可用 ${free_mb:-未知} MB"

CREATE_SWAP_GB="${CREATE_SWAP_GB:-0}"
if ! [[ "${CREATE_SWAP_GB}" =~ ^[0-9]+$ ]]; then
  echo "[provision] ERROR: CREATE_SWAP_GB 必须是非负整数（当前 ${CREATE_SWAP_GB}）" >&2
  exit 1
fi
if (( CREATE_SWAP_GB > 0 )); then
  # 只在完全没有交换分区时建：已有交换还去建第二个文件，收益有限而副作用（磁盘被吃掉）确定。
  if (( swap_mb > 0 )); then
    echo "[provision] 已有 ${swap_mb} MB 交换空间，跳过创建"
  elif [[ -e /swapfile ]]; then
    echo "[provision] /swapfile 已存在但未启用，跳过创建（如需启用: swapon /swapfile）"
  else
    echo "[provision] 创建 ${CREATE_SWAP_GB} GB 交换文件 /swapfile"
    fallocate -l "${CREATE_SWAP_GB}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$(( CREATE_SWAP_GB * 1024 ))
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    if ! grep -q '^/swapfile ' /etc/fstab; then
      echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    echo "[provision] 交换文件已启用并写入 /etc/fstab（重启后仍在）"
  fi
fi

if (( mem_mb < 3500 )) && (( swap_mb == 0 )) && (( CREATE_SWAP_GB == 0 )); then
  echo "[provision] WARNING: 本机内存 ${mem_mb} MB 且无交换空间，前端 vite build 与 mvn package 很可能被 OOM killer 打断。" >&2
  echo "[provision] 建议重跑本脚本并带上 CREATE_SWAP_GB=4，或在主机清单为该端点设" >&2
  echo "[provision]   <KEY>_MAVEN_OPTS=-Xmx1g" >&2
  echo "[provision]   <KEY>_NODE_OPTIONS=--max-old-space-size=1024" >&2
fi

echo
echo "[provision] 完成。本机工具链："
echo "  java  : $(java -version 2>&1 | head -1)"
echo "  node  : $(node --version)"
echo "  pnpm  : $(pnpm --version 2>/dev/null || echo '未安装')"
echo "  maven : $(maven_version_line)"
echo "  git   : $(git --version)"
echo
echo "[provision] 下一步：把运行时口令写进 /etc/longzhu/longzhu-<产品>-<端>.env（0600），再在 Jenkins 上跑 longzhu/<env>-<产品>-deploy。"
