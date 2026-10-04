# 龙珠车服发布说明

通用流程见仓库根 README；这里只写龙珠车服自己的部分。

## 应用形态

- 两端：用户端 `user`、管理端 `admin`，都是 Spring Boot fat jar，前端构建产物打进 jar。
- 代码仓 `liuliuzo/longzhu`（私有），发布分支 `develop`（dev 与 prod 都发 develop，只换 `application-<profile>.properties`）。
- 模块前缀 `longzhu`（`longzhu-user/longzhu-user`、`longzhu-admin/longzhu-admin-react` 等），接口前缀 `/longzhu`，健康检查 `/longzhu/health/readiness`，库名 `longzhu`。
- 数据源、JWT 等中间件参数按产品线口径写在应用仓 `application-dev.properties`，目标机不需要额外的 env 文件。

## 目标机布局（dev）

两端同在一台机上，主机地址在 Jenkins 凭据 `longzhu-dev-hosts` 里。

| 项 | 用户端 | 管理端 |
| --- | --- | --- |
| 域名 | `dev.user.bgssai-insurance.com` | `dev.admin.bgssai-insurance.com` |
| systemd 服务 | `longzhu-user` | `longzhu-admin` |
| 部署目录 | `/opt/longzhu/longzhu-user` | `/opt/longzhu/longzhu-admin` |
| 监听 | `8081`（启动参数 `--server.port`） | `8080` |

- 产品线约定应用端口一律 8080；同机跑两端时用启动参数把用户端错开到 8081，不写进 properties。端口来自主机清单 `LONGZHU_<端>_PORT`，部署脚本写进 systemd 单元的 `--server.port`。
- 公网只需开 80（证书就绪后加 443），由 Nginx 按域名转发到本机两个端口，配置见 `deploy/nginx/longzhu-dev.conf`。
- 源码缓存 `/opt/longzhu/src/longzhu`，两端共用，构建时加锁排队。
- 应用日志 `/opt/longzhu/log`（应用 properties 的 `logging.applog.path`）。
- 机器只有 2 GB 内存：装机时加了 4 GB 交换分区；主机清单给两端设了 `MAVEN_OPTS=-Xmx768m`、`NODE_OPTIONS=--max-old-space-size=1024`。

## 域名与解析

- 解析区域 `bgssai-insurance.com` 在华为云 DNS（bgssai 云账号），已加两条 A 记录 `dev.user` / `dev.admin` 指向目标机公网地址。
- 域名 2026-10-04 刚注册，注册局状态为 `serverHold`（等实名认证）。解除前公网解析不到，Nginx 按域名转发也就访问不到；可以先在本机用 `curl -H 'Host: dev.admin.bgssai-insurance.com' http://<目标机>/` 验证。
- HTTPS：目标机用 certbot（nginx 插件，HTTP-01）签 Let's Encrypt 证书，不需要云账号密钥；签好后 certbot 自动给 Nginx 加 443 并把 80 跳 443，续期由 `certbot.timer` 负责。
- 自动签发：`deploy/tls/issue-certificate.sh` 装在 `/opt/longzhu/lib/`，由 `longzhu-cert-issue.timer` 每 30 分钟检查一次。两个域名都解析到本机之前它只做只读预检、不调用 certbot；生效后签发并停用该 timer。手动立即执行：`systemctl start longzhu-cert-issue.service`，看结果：`journalctl -u longzhu-cert-issue.service`。
- 公网安全组需放行 80 与 443（HTTP-01 验证走 80）。

## 数据库

- MySQL 8，开发库 `longzhu`，地址在主机清单 `LONGZHU_DB_HOST`。SQL 在应用仓 `sql/`：`DDL.sql`（建库建表）、`DML.sql`（共享种子）、`dev/DML.sql`（开发种子）。
- 开发环境全量发布：clean database → init database → deploy。演示账号见应用仓 `sql/DML.sql` 头部注释。
- Jenkins 凭据 `longzhu-dev-mysql` 需要对 `longzhu` 库的全部权限（含 DROP / CREATE DATABASE）。

## 当前 dev（2026-10-04）

- 暂无 prod。开通方法见 `jenkins/credentials/longzhu-hosts.prod.env.example` 顶部。
