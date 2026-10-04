// 清库：DROP DATABASE IF EXISTS <库名>。不读 SQL、不克隆产品仓、不动应用。
//
// 开发环境全量发布的第一步：clean database → init database → deploy。只允许 dev。
//
// 在 Jenkins agent 上执行（需要 mysql 客户端）。库名取主机清单的 <PRODUCT>_DB_NAME。
//
// 入参（Map）：
//   product      必填。产品短名（products.json 里 database=true）
//   environment  必填。只能是 dev
//
// 依赖的 Jenkins 凭据：
//   longzhu-<env>-mysql  Username with password。有删库权限的数据库账号
//   longzhu-<env>-hosts  Secret file。读取 <PRODUCT>_DB_HOST / <PRODUCT>_DB_PORT / <PRODUCT>_DB_NAME

def call(Map cfg = [:]) {
  String product = (cfg.product ?: '').toString().trim()
  String environment = (cfg.environment ?: '').toString().trim()

  Map p = longzhuProduct(product)
  if (!p.database) {
    error "longzhuCleanDatabase: ${product} 没有数据库"
  }
  if (!(environment in p.environments)) {
    error "longzhuCleanDatabase: ${product} 没有开通 ${environment} 环境"
  }
  if (environment != 'dev') {
    error "longzhuCleanDatabase: 只允许清理开发库（当前 ${environment}）"
  }

  withCredentials([
    usernamePassword(credentialsId: "longzhu-${environment}-mysql", usernameVariable: 'MYSQL_USER', passwordVariable: 'MYSQL_PASSWORD'),
    file(credentialsId: "longzhu-${environment}-hosts", variable: 'LZ_HOSTS_FILE'),
  ]) {
    withEnv([
      "LZ_ENV=${environment}",
      "LZ_HOSTS_KEY=${product.toUpperCase().replace('-', '_')}",
    ]) {
      sh(label: "clean database ${product} (${environment})", script: libraryResource('com/longzhu/jenkins/clean-database.sh'))
    }
  }
}
