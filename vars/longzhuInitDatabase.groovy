// 空库初始化：按产品仓 sql/ 依次执行 DDL.sql → DML.sql → <env>/DML.sql。
//
// 只接受空库：目标库里已经有表就拒绝，绝不 DROP、绝不覆盖现有数据。
// 需要「推倒重建」时按 README 的全量口径人工处理：先备份，再清库，然后重跑本 Job。
//
// 在 Jenkins agent 上执行（需要 mysql 客户端），SQL 取自产品仓 develop 的浅克隆。
//
// 入参（Map）：
//   product      必填。产品短名（products.json 里 database=true）
//   environment  必填。dev / prod
//   sourceRef    可选。取 SQL 的分支，默认 develop
//
// 依赖的 Jenkins 凭据：
//   longzhu-<env>-mysql  Username with password。有建库建表权限的数据库账号
//   longzhu-<env>-hosts  Secret file。读取 <PRODUCT>_DB_HOST / <PRODUCT>_DB_PORT / <PRODUCT>_DB_NAME
//   longzhu-github       拉产品仓

def call(Map cfg = [:]) {
  String product = (cfg.product ?: '').toString().trim()
  String environment = (cfg.environment ?: '').toString().trim()
  String sourceRef = (cfg.sourceRef ?: 'develop').toString().trim()

  Map p = longzhuProduct(product)
  if (!p.database) {
    error "longzhuInitDatabase: ${product} 没有数据库"
  }
  if (!(environment in p.environments)) {
    error "longzhuInitDatabase: ${product} 没有开通 ${environment} 环境"
  }

  String srcDir = ".longzhu/src-${product}"
  dir(srcDir) {
    deleteDir()
    checkout([
      $class: 'GitSCM',
      branches: [[name: "*/${sourceRef}"]],
      userRemoteConfigs: [[url: "https://github.com/${p.githubOwner}/${p.githubRepo}.git", credentialsId: 'longzhu-github']],
      extensions: [[$class: 'CloneOption', shallow: true, depth: 1, noTags: true]],
    ])
  }

  withCredentials([
    usernamePassword(credentialsId: "longzhu-${environment}-mysql", usernameVariable: 'MYSQL_USER', passwordVariable: 'MYSQL_PASSWORD'),
    file(credentialsId: "longzhu-${environment}-hosts", variable: 'LZ_HOSTS_FILE'),
  ]) {
    withEnv([
      "LZ_ENV=${environment}",
      "LZ_HOSTS_KEY=${product.toUpperCase().replace('-', '_')}",
      "LZ_SQL_ROOT=${srcDir}/sql",
    ]) {
      sh(label: "init database ${product} (${environment})", script: libraryResource('com/longzhu/jenkins/init-database.sh'))
    }
  }
}
