// 从 Job 内部名推出「哪个环境、哪个产品」，并核对产品清单是否允许。
//
// Job 内部名约定：<env>-<product>-<operation>，例如
//   dev-longzhu-clean-database / dev-longzhu-init-database / dev-longzhu-deploy
// 界面显示名（longzhu deploy(dev)）只给人看，不参与判断。
//
// 为什么不做成下拉框：环境、产品、操作都写进 Job 名后，想部署另一个环境就必须换一个 Job，
// 不存在「同一个 Job 点错一个选项把生产当开发发」的失误；环境也出现在面包屑、构建历史里，一眼可见。
//
// 入参（Map）：
//   operation  必填。deploy / clean-database / init-database，必须与 Job 名结尾一致
//
// 返回：[environment: 'dev'|'prod', product: '<短名>']

def call(Map cfg = [:]) {
  String operation = (cfg.operation ?: '').toString().trim()
  if (!(operation in ['deploy', 'clean-database', 'init-database'])) {
    error "longzhuResolveJob: operation 必须是 deploy / clean-database / init-database（当前 '${operation}'）"
  }

  String jobName = (env.JOB_NAME ?: '').toString()
  List<String> segments = jobName.tokenize('/')
  String leaf = segments ? segments.last() : ''

  String environment = ''
  if (leaf.startsWith('dev-')) {
    environment = 'dev'
  } else if (leaf.startsWith('prod-')) {
    environment = 'prod'
  }
  String suffix = "-${operation}"
  if (!environment || !leaf.endsWith(suffix) || leaf.length() <= environment.length() + 1 + suffix.length()) {
    error """
无法从 Job 名推出环境与产品：${jobName}

Job 内部名必须是 <dev|prod>-<产品>-${operation}，例如 dev-longzhu-${operation}。
界面显示名不参与判断。Job 请用 jenkins/seed/jobs.py 生成，不要手工建。
""".trim()
  }
  String product = leaf.substring(environment.length() + 1, leaf.length() - suffix.length())

  Map p = longzhuProduct(product)
  if (!(environment in p.environments)) {
    error "产品 ${product} 在产品清单里没有开通 ${environment} 环境（已开通：${p.environments.join(', ')}）。先在 products.json 与主机清单里补齐，再用 jobs.py 建 Job。"
  }
  if (operation in ['clean-database', 'init-database'] && !p.database) {
    error "产品 ${product} 在产品清单里标记为没有数据库，不能清库或初始化数据库。"
  }

  echo "[job] 环境=${environment} 产品=${product} 操作=${operation}（由 Job 名 ${jobName} 推出）"
  return [environment: environment, product: product]
}
