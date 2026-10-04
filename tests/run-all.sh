#!/usr/bin/env bash
# 本仓全部检查：脚本语法 + 构建计划 + 主机清单解析 + 回环隔离 + 清库 / 建库 + Job 清单。不连任何主机。
# 用法：bash tests/run-all.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${PYTHON:-$(command -v python3 || command -v python)}"

for f in "${ROOT}"/resources/com/longzhu/jenkins/*.sh "${ROOT}"/jenkins/install/*.sh "${ROOT}"/deploy/tls/*.sh "${ROOT}"/tests/*.sh; do
  bash -n "${f}"
  head -1 "${f}" | grep -qx '#!/usr/bin/env bash' || { echo "缺少 bash shebang：${f}（Jenkins 的 sh 步骤默认用 dash）" >&2; exit 1; }
done
echo 'PASS: 脚本语法与 shebang'

"${PYTHON}" -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' \
  "${ROOT}/resources/com/longzhu/jenkins/products.json"
echo 'PASS: products.json'

bash "${ROOT}/tests/test-remote-build-plan.sh"
bash "${ROOT}/tests/test-wrapper-plan.sh"
bash "${ROOT}/tests/test-loopback-binding.sh"
bash "${ROOT}/tests/test-init-database.sh"
bash "${ROOT}/tests/test-clean-database.sh"
"${PYTHON}" "${ROOT}/tests/test_jobs.py"
echo 'ALL PASS'
