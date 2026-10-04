// 读取产品清单 resources/com/longzhu/jenkins/products.json，返回一个产品的完整配置。
//
// 清单是唯一权威：Job 生成器 jenkins/seed/jobs.py 读的也是同一个文件，
// 所以「有哪些产品、各在哪些环境、怎么构建」只需要改一处。
//
// 用法：
//   Map p = longzhuProduct('longzhu')
//   p.githubOwner / p.githubRepo / p.modulePrefix / p.ends / p.environments / p.database
//   p.packageManager / p.frontendScript / p.appPort / p.healthScheme / p.healthPath
//   p.product（产品短名本身）

import groovy.json.JsonSlurperClassic

def call(String product) {
  String name = (product ?: '').toString().trim()
  if (!name) {
    error 'longzhuProduct: 缺少产品短名'
  }
  Map registry = (Map) parseRegistry(libraryResource('com/longzhu/jenkins/products.json'))
  Map products = (Map) registry.products
  if (!products.containsKey(name)) {
    error "longzhuProduct: 产品清单里没有 '${name}'（现有：${products.keySet().join(', ')}）"
  }
  // 共享库挂在 Jenkins 的 longzhu 文件夹上，按沙箱运行：用 Map 相加复制，不调构造函数。
  Map p = [:] + (Map) products[name]
  p.product = name
  p.githubOwner = registry.githubOwner
  return p
}

// 沙箱里需要管理员预先批准两条签名（README「首次接入」第 2 步）：
//   new groovy.json.JsonSlurperClassic
//   method groovy.json.JsonSlurperClassic parseText java.lang.String
@NonCPS
def parseRegistry(String text) {
  return new JsonSlurperClassic().parseText(text)
}
