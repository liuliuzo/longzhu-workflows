// 部署一个产品的一端（user 或 admin）：目标机自己拉代码、就地构建、原子替换、重启、健康检查、失败回滚。
//
// Jenkins 这一侧不构建、不传 jar，只经一条 SSH 会话把构建脚本喂给目标机。
// 整条链路：
//   deploy-wrapper.sh（Jenkins）  读主机清单 → 只读端口预检 → 推 remote-deploy.sh → 喂 remote-build.sh
//   remote-build.sh（目标机）     拉源码 → 前端 + 后端构建 → 暂存 app.jar.incoming
//   remote-deploy.sh（目标机）    原子替换 → systemd 重启 → 健康检查 → 失败回滚上一版
//
// 入参（Map）：
//   product      必填。产品短名，见 products.json
//   end          必填。user / admin
//   environment  必填。dev / prod（取 longzhuResolveJob 的返回值）
//   sourceRef    可选。目标机检出的分支，默认 develop（dev 与 prod 都发 develop，只换 properties）
//
// 依赖的 Jenkins 凭据：
//   longzhu-<env>-ssh    Username with password。目标机 SSH 账号（需 root：要写 systemd 单元）
//   longzhu-<env>-hosts  Secret file。主机清单，模板见 jenkins/credentials/
//   longzhu-github       Username with password。GitHub 用户名 + PAT（产品仓 Contents: Read）
//                          PAT 经 SSH 会话的 stdin 交给目标机，不进命令行、不写进目标机 .git/config

def call(Map cfg = [:]) {
  String product = (cfg.product ?: '').toString().trim()
  String end = (cfg.end ?: '').toString().trim()
  String environment = (cfg.environment ?: '').toString().trim()
  String sourceRef = (cfg.sourceRef ?: 'develop').toString().trim()

  Map p = longzhuProduct(product)
  if (!(end in p.ends)) {
    error "longzhuDeploy: ${product} 没有 '${end}' 这一端（有：${p.ends.join(', ')}）"
  }
  if (!(environment in p.environments)) {
    error "longzhuDeploy: ${product} 没有开通 ${environment} 环境"
  }

  String appName = "${product}-${end}"
  String hostsKey = "${product}_${end}".toUpperCase().replace('-', '_')

  // 两个目标机脚本先落到工作区，再由 wrapper 送过去。按 appName 取名，避免两端并行时互相覆盖。
  String buildScript = ".longzhu/remote-build-${appName}.sh"
  String deployScript = ".longzhu/remote-deploy-${appName}.sh"
  writeFile(file: buildScript, text: libraryResource('com/longzhu/jenkins/remote-build.sh'))
  writeFile(file: deployScript, text: libraryResource('com/longzhu/jenkins/remote-deploy.sh'))

  echo "[deploy] ${appName} -> ${environment}，主机清单键 ${hostsKey}_*，源码 ${p.githubOwner}/${p.githubRepo}@${sourceRef}"

  withCredentials([
    usernamePassword(credentialsId: "longzhu-${environment}-ssh", usernameVariable: 'SSH_USER', passwordVariable: 'SSHPASS'),
    file(credentialsId: "longzhu-${environment}-hosts", variable: 'LZ_HOSTS_FILE'),
    usernamePassword(credentialsId: 'longzhu-github', usernameVariable: 'GIT_USER', passwordVariable: 'GIT_TOKEN'),
  ]) {
    withEnv([
      "LZ_HOSTS_KEY=${hostsKey}",
      "LZ_REMOTE_BUILD_SCRIPT=${buildScript}",
      "LZ_REMOTE_DEPLOY_SCRIPT=${deployScript}",
      "LZ_GITHUB_OWNER=${p.githubOwner}",
      "LZ_GITHUB_REPO=${p.githubRepo}",
      "LZ_MODULE_PREFIX=${p.modulePrefix}",
      "LZ_SOURCE_REF=${sourceRef}",
      "LZ_END=${end}",
      "LZ_PACKAGE_MANAGER=${p.packageManager ?: 'npm'}",
      "LZ_FRONTEND_SCRIPT=${p.frontendScript ?: 'build:deploy'}",
      "LZ_DEFAULT_APP_PORT=${p.appPort ?: '8080'}",
      "LZ_DEFAULT_HEALTH_SCHEME=${p.healthScheme ?: 'http'}",
      "LZ_DEFAULT_HEALTH_PATH=${p.healthPath ?: '/'}",
      "APP_NAME=${appName}",
      "APP_PROFILE=${environment}",
    ]) {
      sh(label: "build + deploy ${appName} (${environment})", script: libraryResource('com/longzhu/jenkins/deploy-wrapper.sh'))
    }
  }
}
