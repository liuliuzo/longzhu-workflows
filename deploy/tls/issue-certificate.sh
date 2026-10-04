#!/usr/bin/env bash
# 运行位置：目标机（root）。为 Nginx 上的龙珠车服域名签 Let's Encrypt 证书并开启 HTTPS。
#
# 用 certbot 的 nginx 插件走 HTTP-01 验证：不需要任何云账号密钥，签好后 certbot 自动改写
# Nginx 配置（加 443、80 跳 443），续期由 certbot 自带的 systemd timer 负责。
#
# 先做只读预检：每个域名都必须已在公网解析到本机，否则不调用 certbot（避免撞 Let's Encrypt
# 的失败验证频率限制），退出码 3。配合 longzhu-cert-issue.timer 使用时，域名生效前每次都
# 安静地退出；签发成功后自动停用该 timer。
#
# 用法：
#   bash issue-certificate.sh dev.user.bgssai-insurance.com dev.admin.bgssai-insurance.com
# 退出码：0 已签发（或证书已覆盖全部域名）；3 域名尚未解析到本机；其它为 certbot / 环境错误。
set -euo pipefail

TIMER=longzhu-cert-issue.timer
log() { printf '[cert] %s\n' "$*"; }

(( $# >= 1 )) || { echo "用法: $0 <域名>..." >&2; exit 2; }
command -v certbot >/dev/null 2>&1 || { log 'ERROR: 缺少 certbot（apt-get install -y certbot python3-certbot-nginx）'; exit 1; }
command -v nginx >/dev/null 2>&1 || { log 'ERROR: 缺少 nginx'; exit 1; }

public_ip="$(curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null || true)"
[[ -n "${public_ip}" ]] || { log 'ERROR: 取不到本机公网地址'; exit 1; }

# 证书名固定为第一个域名；已覆盖全部域名就不重复签。
cert_name="$1"
if certbot certificates --cert-name "${cert_name}" 2>/dev/null | grep -q 'Domains:'; then
  have="$(certbot certificates --cert-name "${cert_name}" 2>/dev/null | sed -n 's/^ *Domains: //p')"
  missing=0
  for d in "$@"; do [[ " ${have} " == *" ${d} "* ]] || missing=1; done
  if (( missing == 0 )); then
    log "证书 ${cert_name} 已覆盖全部域名，无需重签"
    systemctl disable --now "${TIMER}" >/dev/null 2>&1 || true
    exit 0
  fi
fi

for d in "$@"; do
  resolved="$(getent ahostsv4 "${d}" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
  if [[ "${resolved}" != "${public_ip}" ]]; then
    log "域名 ${d} 尚未解析到本机（解析结果 '${resolved:-无}'，本机 ${public_ip}），暂不签发"
    exit 3
  fi
done

domain_args=()
for d in "$@"; do domain_args+=(-d "${d}"); done
log "签发 $*"
certbot --nginx --non-interactive --agree-tos --register-unsafely-without-email \
  --cert-name "${cert_name}" --redirect "${domain_args[@]}"
nginx -t
systemctl reload nginx
systemctl disable --now "${TIMER}" >/dev/null 2>&1 || true
log "已签发并启用 HTTPS；续期由 certbot.timer 负责"
