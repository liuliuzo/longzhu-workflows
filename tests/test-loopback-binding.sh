#!/usr/bin/env bash
# 两端同机、各占一个回环地址共用 8080 时：端口归属只看本端地址，通配监听视为冲突，
# ss 读取失败必须中止部署。只用假数据，不连主机、不停服务、不杀进程。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY="${ROOT}/resources/com/longzhu/jenkins/remote-deploy.sh"
WRAPPER="${ROOT}/resources/com/longzhu/jenkins/deploy-wrapper.sh"
extract() { awk -v name="$2" '$0 == name "() {" {p=1} p {print} p && /^}$/ {exit}' "$1"; }

APP_PORT=8080
ss() { [[ "${SS_FAIL:-0}" == 0 ]] || return 1; printf '%s\n' "${SOCKETS}"; }

check_listener_parser() {
  APP_BIND_ADDRESS=127.0.0.2
  SOCKETS='LISTEN 0 100 127.0.0.2:8080 0.0.0.0:* users:(("java",pid=111,fd=1))
LISTEN 0 100 127.0.0.3:8080 0.0.0.0:* users:(("java",pid=222,fd=1))'
  [[ "$(port_listener_pids)" == 111 ]]
  APP_BIND_ADDRESS=127.0.0.3
  [[ "$(port_listener_pids)" == 222 ]]
  APP_BIND_ADDRESS=127.0.0.4
  [[ -z "$(port_listener_pids)" ]]
  SOCKETS='LISTEN 0 100 [::ffff:127.0.0.2]:8080 *:* users:(("java",pid=111,fd=1))'
  APP_BIND_ADDRESS=127.0.0.2
  [[ "$(port_listener_pids)" == 111 ]]
  for wildcard in '0.0.0.0' '*' '[::]' '::' '[::ffff:0.0.0.0]' '::ffff:0.0.0.0'; do
    SOCKETS="LISTEN 0 100 ${wildcard}:8080 0.0.0.0:* users:((\"java\",pid=333,fd=1))"
    [[ "$(port_listener_pids)" == 333 ]]
  done
  SS_FAIL=1
  if port_listener_pids >/dev/null 2>&1; then echo 'ss 读取失败必须中止部署' >&2; exit 1; fi
  SS_FAIL=0
}

# remote-deploy.sh 与 deploy-wrapper.sh（预检段）各有一份解析，两份都要对。
eval "$(extract "${DEPLOY}" port_listener_pids)"
check_listener_parser
unset -f port_listener_pids
preflight="$(awk '/^REMOTE_PREFLIGHT_SCRIPT=/ {p=1; next} /^REMOTE_PREFLIGHT$/ {p=0} p' "${WRAPPER}")"
eval "$(extract <(printf '%s\n' "${preflight}") port_listener_pids)"
declare -F port_listener_pids >/dev/null || { echo '没从 deploy-wrapper.sh 的预检段取到 port_listener_pids' >&2; exit 1; }
check_listener_parser

# 健康探测打到本端回环地址。
eval "$(extract "${DEPLOY}" probe_once)"
HEALTH_HOST=127.0.0.3 HEALTH_PATH=/longzhu/health/readiness HEALTH_SCHEME=http
curl() { [[ "${*: -1}" == 'http://127.0.0.3:8080/longzhu/health/readiness' ]] || return 1; printf 200; }
probe_once

echo 'PASS: 回环地址隔离、通配冲突、ss 失败即中止、探测地址'
