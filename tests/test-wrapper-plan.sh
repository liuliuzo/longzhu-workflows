#!/usr/bin/env bash
# deploy-wrapper.sh 解析主机清单：只打印解析结果，不连目标机。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/resources/com/longzhu/jenkins/deploy-wrapper.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

run() {
  env -i PATH="${PATH}" LZ_WRAPPER_PRINT_PLAN=1 LZ_HOSTS_FILE="$1" LZ_HOSTS_KEY=LONGZHU_USER \
    APP_NAME=longzhu-user APP_PROFILE=dev \
    LZ_GITHUB_OWNER=liuliuzo LZ_GITHUB_REPO=longzhu LZ_MODULE_PREFIX=longzhu \
    LZ_SOURCE_REF=develop LZ_END=user LZ_DEFAULT_APP_PORT=8080 LZ_DEFAULT_HEALTH_PATH=/longzhu/health/readiness \
    bash "${SCRIPT}"
}

# 模板原样（HOST 留空）必须失败，并指出缺哪个键。
if out="$(run "${ROOT}/jenkins/credentials/longzhu-hosts.dev.env.example" 2>&1)"; then
  echo '模板未填 HOST 时应当失败' >&2; exit 1
fi
grep -q 'LONGZHU_USER_HOST' <<<"${out}"

# 填好 HOST，且故意用 CRLF 行尾：应能解析，并给出 CRLF 告警。
sed 's/^LONGZHU_USER_HOST=$/LONGZHU_USER_HOST=10.0.0.8/' "${ROOT}/jenkins/credentials/longzhu-hosts.dev.env.example" \
  | sed 's/$/\r/' > "${TMP}/hosts.env"
out="$(run "${TMP}/hosts.env" 2>&1)"
grep -q 'CRLF' <<<"${out}"
grep -q -- '-> <ssh-user>@10.0.0.8:22' <<<"${out}"
grep -q 'app_dir=/opt/longzhu/longzhu-user service=longzhu-user profile=dev' <<<"${out}"
grep -q 'health=http://127.0.0.1:8081/longzhu/health/readiness' <<<"${out}"

# 回环地址越界必须失败。
{ sed 's/^LONGZHU_USER_HOST=$/LONGZHU_USER_HOST=10.0.0.8/' "${ROOT}/jenkins/credentials/longzhu-hosts.dev.env.example"
  echo 'LONGZHU_USER_BIND_ADDRESS=10.0.0.8'; } > "${TMP}/bad.env"
if run "${TMP}/bad.env" >/dev/null 2>&1; then echo 'BIND_ADDRESS=10.0.0.8 应当被拒绝' >&2; exit 1; fi

echo 'PASS: deploy-wrapper 主机清单解析'
