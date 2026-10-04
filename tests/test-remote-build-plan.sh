#!/usr/bin/env bash
# remote-build.sh 的构建计划：只解析参数、打印计划，不碰网络、磁盘与服务。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/resources/com/longzhu/jenkins/remote-build.sh"

plan() {
  env -i PATH="${PATH}" LZ_REMOTE_BUILD_PRINT_PLAN=1 \
    LZ_GITHUB_OWNER=liuliuzo LZ_GITHUB_REPO=longzhu LZ_SOURCE_REF=develop \
    LZ_MODULE_PREFIX=longzhu APP_PROFILE=dev APP_PORT=8080 \
    APP_NAME="longzhu-$1" APP_DIR="/opt/longzhu/longzhu-$1" SERVICE_NAME="longzhu-$1" \
    LZ_END="$1" "${@:2}" bash "${SCRIPT}"
}

out="$(plan user)"
grep -qx 'git_url=https://github.com/liuliuzo/longzhu.git ref=develop end=user' <<<"${out}"
grep -qx 'src_dir=/opt/longzhu/src/longzhu module=longzhu-user/longzhu-user react=longzhu-user/longzhu-user-react jar_glob=longzhu-user' <<<"${out}"
# 缺省跑测试：mvn 参数里不能有 -DskipTests。
grep -qx 'mvn_args=-pl longzhu-user/longzhu-user -am' <<<"${out}"
grep -q 'maven_mirror=https://mirrors.huaweicloud.com/repository/maven/' <<<"${out}"

out="$(plan admin LZ_BUILD_SKIP_TESTS=1 LZ_MAVEN_MIRROR_URL=none)"
grep -qx 'mvn_args=-pl longzhu-admin/longzhu-admin -am -DskipTests' <<<"${out}"
grep -q 'maven_mirror=none' <<<"${out}"

# 非法参数必须失败。
if plan user LZ_BUILD_SKIP_TESTS=yes >/dev/null 2>&1; then echo 'LZ_BUILD_SKIP_TESTS=yes 应当被拒绝' >&2; exit 1; fi
if plan other >/dev/null 2>&1; then echo 'LZ_END=other 应当被拒绝' >&2; exit 1; fi
if plan user LZ_PACKAGE_MANAGER=yarn >/dev/null 2>&1; then echo 'yarn 应当被拒绝' >&2; exit 1; fi

echo 'PASS: remote-build 构建计划'
