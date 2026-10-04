# longzhu-workflows

龙珠车服（[longzhu](https://github.com/liuliuzo/longzhu)）的发布工具：Jenkins 共享库 + 流水线 + 目标机脚本。

开发环境全量发布就是在 Jenkins 文件夹 `longzhu` 里依次点三个 Job：

```
longzhu clean database(dev)  →  longzhu init database(dev)  →  longzhu deploy(dev)
   删库（DROP DATABASE）            空库按 sql/ 建表灌种子           两端构建、替换、重启、健康检查
```

deploy 这一步的链路：

```
Jenkins ──SSH──▶ 目标机：拉 longzhu 的 develop → 构建前端 → 构建后端（跑单元测试）
                        → 原子替换 jar → systemd 重启 → 健康检查 ──失败──▶ 自动回滚到上一版
```

Jenkins 这边不构建、不传 jar，只走一条 SSH 控制通道；构建失败时线上服务一个字节都不动。

## Jenkins 里有什么

Jenkins 与 bgssai、博锐康共用，按文件夹隔开。龙珠车服的凭据和共享库只挂在文件夹 `longzhu`（显示「longzhu · 龙珠车服」）上，Jenkins 全局里不放任何 `longzhu-*` 的东西。

文件夹 `longzhu` 里的 Job 全部由 `jenkins/seed/jobs.py` 按产品清单生成，全部只能手动触发，点开即可执行：

| Job（界面显示名） | 内部名 | 做什么 |
| --- | --- | --- |
| longzhu clean database(dev) | `dev-longzhu-clean-database` | 删除开发库（`DROP DATABASE`）。不建表、不动应用。只允许 dev |
| longzhu init database(dev) | `dev-longzhu-init-database` | 空库初始化：`sql/DDL.sql` → `sql/DML.sql` → `sql/dev/DML.sql`。库里已有表就拒绝，绝不 DROP |
| longzhu deploy(dev) | `dev-longzhu-deploy` | 发版。`target` 不改就是两端，先用户端、后管理端 |

环境、产品、操作都写在 Job 内部名里（`<env>-<产品>-<操作>`），不做下拉框，免得点错环境。

## 日常使用

- **全量发布（开发环境）**：按顺序跑 clean database → init database → deploy。开发库会被清空重建，演示数据回到 `sql/` 里的种子。
- **只发代码、不动库**：只跑 deploy。
- **看结果**：Console Output 里 `[clean-db]` / `[init-db]` 是数据库，`[remote-build]` 是构建，`[remote-deploy]` 是替换与健康检查；失败时自动打印 systemd 状态和最后 80 行应用日志。
- **失败了**：构建失败 → 线上没动；健康检查失败 → 已自动回滚到上一版。都**不会**自动重跑，看清原因后人工再点。
- **手动回退到更早的版本**：目标机 `/opt/longzhu/longzhu-<端>/releases/` 里保留最近 5 个 `app-<提交号>.jar`，拷成 `app.jar` 后 `systemctl restart longzhu-<端>`。

### 不开浏览器，从本机命令行发版

`jenkins/trigger.py` 走 Jenkins REST API 触发 Job 并等到出结果（只需 python3，Windows 的 Git Bash / PowerShell 也行）。
本仓是公开仓，账号不入仓：设环境变量 `JENKINS_URL` / `JENKINS_USER` / `JENKINS_TOKEN`，或写进本机 `~/.config/longzhu/jenkins.env`（同名 `KEY=VALUE`）。

```bash
python3 jenkins/trigger.py status                                   # 只读：各 Job 最近一次构建
python3 jenkins/trigger.py run dev-longzhu-clean-database           # 真实执行，等结果
python3 jenkins/trigger.py run dev-longzhu-init-database
python3 jenkins/trigger.py run dev-longzhu-deploy                   # 两端；--target user 只发一端
```

`run` 一调用就是真实执行，没有演练模式；Job 正在跑或排队时拒绝再触发。退出码 0 成功、1 构建失败、2 配置或网络问题。

## 目录

| 路径 | 内容 |
| --- | --- |
| `resources/com/longzhu/jenkins/products.json` | **产品清单唯一权威**：仓名、模块前缀、开通的环境、端口、健康检查路径 |
| `vars/` | 共享库步骤：`longzhuResolveJob`（从 Job 名推环境/产品）、`longzhuDeploy`、`longzhuCleanDatabase`、`longzhuInitDatabase`、`longzhuProduct` |
| `resources/com/longzhu/jenkins/*.sh` | `deploy-wrapper.sh`（Jenkins 侧）、`remote-build.sh` / `remote-deploy.sh`（目标机侧）、`clean-database.sh`、`init-database.sh` |
| `jenkins/Jenkinsfile.*` | 三条流水线：`cleandb` / `initdb` / `deploy` |
| `jenkins/seed/jobs.py` | 按产品清单生成 / 创建文件夹与 Job（只建缺的，从不改、删、触发） |
| `jenkins/trigger.py` | 从本机触发 Job 并等结果（`status` 只读、`run` 真实执行） |
| `jenkins/credentials/*.env.example` | 主机清单模板（填好后上传成 Jenkins 凭据，实值不入仓） |
| `jenkins/install/` | 目标机一次性装机脚本、Jenkins 插件清单 |
| `deploy/nginx/` | Nginx 按域名转发配置 |
| `deploy/tls/` | 目标机签 HTTPS 证书：`issue-certificate.sh`（certbot，域名生效前只预检）与重试用的 systemd timer |
| `docs/longzhu.md` | 龙珠车服专属说明：目标机布局、域名与解析、数据库 |
| `tests/` | 本地检查，`bash tests/run-all.sh`，不连任何主机 |

## 首次接入（新 Jenkins 或新机器）

**1. Jenkins 插件与命令**：按 `jenkins/install/plugins.txt` 装插件；agent 上要有 `git`、`sshpass`、`ssh/scp`、`python3`、`mysql` 客户端。

**2. 建文件夹与 Job**（文件夹自带共享库 `longzhu`，指向本仓 develop，不用再去全局配置）：

```bash
JENKINS_URL=http://<jenkins>:8080 JENKINS_USER=<用户> JENKINS_TOKEN=<API Token> python3 jenkins/seed/jobs.py plan
JENKINS_URL=... JENKINS_USER=... JENKINS_TOKEN=... python3 jenkins/seed/jobs.py create-missing
```

文件夹级共享库按 Jenkins 的沙箱运行，读产品清单要用到 JSON 解析，需管理员批准两条签名一次（Manage Jenkins → In-process Script Approval）。同一台 Jenkins 上博锐康已批准过，不用重复：

```groovy
def sa = org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval.get()
sa.approveSignature('new groovy.json.JsonSlurperClassic')
sa.approveSignature('method groovy.json.JsonSlurperClassic parseText java.lang.String')
```

**3. 凭据**：加在**文件夹 `longzhu` 的** Credentials 里（文件夹页 → Credentials → Folder → Global credentials），不要加到 Jenkins 全局：

| 凭据 ID | 类型 | 内容 |
| --- | --- | --- |
| `longzhu-github` | Username with password | GitHub 用户名 + PAT。对 `longzhu`（私有）与本仓 Contents: Read |
| `longzhu-dev-ssh` | Username with password | 目标机 SSH 账号，需 root（要写 systemd 单元） |
| `longzhu-dev-hosts` | Secret file | 主机清单，照 `jenkins/credentials/longzhu-hosts.dev.env.example` 填，LF 行尾 |
| `longzhu-dev-mysql` | Username with password | 有建库、删库、建表权限的数据库账号，clean / init database 用 |

PAT 经 SSH 会话的 stdin 交给目标机的 git，不进命令行、不写进目标机磁盘。

**4. 目标机装机**（每台一次，root，可重复跑）：把 `jenkins/install/provision-build-host.sh` 拷上去执行。装 JDK 21、Node 20、Maven、git、ss，建 `/opt/longzhu` 与 `/etc/longzhu`。内存小于 4 GB 的机器加 `CREATE_SWAP_GB=4`。

**5. Nginx、域名与证书**：装 `nginx certbot python3-certbot-nginx`，放 `deploy/nginx/longzhu-dev.conf`，`nginx -t` 后 reload；`deploy/tls/` 的脚本与 timer 装好后会在域名生效时自动签证书。详见 `docs/longzhu.md`。

**6. 首发**：依次跑 clean database → init database → deploy，确认两端 `[remote-deploy] health ok`，再从公网打开两个域名登录一次。

## 数据库口径（全量）

SQL 只有应用仓里全量的 `sql/DDL.sql`、`sql/DML.sql`、`sql/<env>/DML.sql`，不写增量迁移。开发环境发版时直接全量重建：clean database → init database → deploy。

- clean database 只允许 dev，拒绝系统库；库名取主机清单 `LONGZHU_DB_NAME`。
- init database 只接受空库；SQL 里写的 `CREATE DATABASE` / `USE` 必须就是 `LONGZHU_DB_NAME`，写到别的库直接拒绝。
- 生产库（将来开通时）不经 Jenkins 删除：先备份，再人工清库，然后跑 init database。

## 加一个产品 / 开通 prod

1. 改 `resources/com/longzhu/jenkins/products.json`（加产品，或给 `environments` 加 `"prod"`）；
2. 主机清单与凭据补上对应的键（凭据一律加在 `longzhu` 文件夹里）；
3. 合并到 develop 后跑 `jobs.py create-missing`。prod 不生成 clean database。

流水线、脚本都不用改。产品仓目录需满足：`<模块前缀>-<端>/<模块前缀>-<端>`（Maven 模块）与 `<模块前缀>-<端>/<模块前缀>-<端>-react`（前端，`build:deploy` 把产物同步进后端 `static/`）。

## 本地检查

```bash
bash tests/run-all.sh
```

脚本语法、构建计划、主机清单解析、回环地址隔离、清库 / 建库、Job 清单。不连任何主机、不需要 Jenkins。

## 来历

2026-10-04 以 boruikang-workflows（其本身从 bgssai-workflows 抽出）为底，改为龙珠车服专用。
保留：目标机就地构建、端口归属预检、原子替换、systemd 托管、健康检查与自动回滚。
新增：clean database（只限 dev），开发环境全量发布三步。去掉：stop、仓内明文口令（本仓公开）。
目标机目录 `/opt/longzhu`、`/etc/longzhu`，与 bgssai、博锐康同机也互不干扰。
