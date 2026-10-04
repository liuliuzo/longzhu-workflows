#!/usr/bin/env python3
"""按产品清单生成并创建 Jenkins Job。

Job 清单完全由 resources/com/longzhu/jenkins/products.json 推出，不另外维护第二份：
每个产品 × 每个开通的环境 → deploy，有数据库的再加 clean-database 与 init-database。
开发环境全量发布顺序：clean database → init database → deploy。

用法（在任何能访问 Jenkins 的机器上，只需 python3）：
    python3 jenkins/seed/jobs.py generate --output /tmp/longzhu-jobs    # 只生成 config.xml 看看
    JENKINS_URL=http://127.0.0.1:8080 JENKINS_USER=admin JENKINS_TOKEN=... \\
        python3 jenkins/seed/jobs.py plan                                  # 对比线上，只读
    JENKINS_URL=... JENKINS_USER=... JENKINS_TOKEN=... \\
        python3 jenkins/seed/jobs.py create-missing                        # 只新建缺的

安全口径：只新建缺失的文件夹与 Job，**从不修改、删除或触发构建**。
已存在的 Job 要改配置，请在界面里改或先人工删除再 create-missing。
口令只从环境变量读（JENKINS_TOKEN 建议用 API Token），不进命令行参数。
"""
import argparse
import base64
import http.cookiejar
import json
import os
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REGISTRY = os.path.join(ROOT, 'resources', 'com', 'longzhu', 'jenkins', 'products.json')
GITHUB_CREDENTIALS_ID = 'longzhu-github'
TARGETS = ['both', 'user', 'admin']
OPERATIONS = {
    # 操作: (Jenkinsfile 路径, 显示名动词, 是否带 target 参数)
    'clean-database': ('jenkins/Jenkinsfile.cleandb', 'clean database', False),
    'init-database': ('jenkins/Jenkinsfile.initdb', 'init database', False),
    'deploy': ('jenkins/Jenkinsfile.deploy', 'deploy', True),
}


def load_registry():
    with open(REGISTRY, encoding='utf-8') as fh:
        return json.load(fh)


def choice_param(name, desc, choices):
    items = ''.join('<string>%s</string>' % escape(c) for c in choices)
    return ('<hudson.model.ChoiceParameterDefinition><name>%s</name><description>%s</description>'
            '<choices class="java.util.Arrays$ArrayList"><a class="string-array">%s</a></choices>'
            '</hudson.model.ChoiceParameterDefinition>') % (escape(name), escape(desc), items)


def job_xml(registry, display, desc, script_path, params):
    # Jenkinsfile 一律取自本仓 develop；lightweight=true 只读流水线文件，不克隆整仓。
    if params:
        props = ('<properties><hudson.model.ParametersDefinitionProperty><parameterDefinitions>%s'
                 '</parameterDefinitions></hudson.model.ParametersDefinitionProperty></properties>') % params
    else:
        props = '<properties/>'
    url = 'https://github.com/%s/%s.git' % (registry['githubOwner'], registry['workflowsRepo'])
    return ("<?xml version='1.1' encoding='UTF-8'?>\n"
            '<flow-definition plugin="workflow-job"><description>%s</description>'
            '<displayName>%s</displayName><keepDependencies>false</keepDependencies>%s'
            '<definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">'
            '<scm class="hudson.plugins.git.GitSCM" plugin="git"><configVersion>2</configVersion>'
            '<userRemoteConfigs><hudson.plugins.git.UserRemoteConfig>'
            '<url>%s</url><credentialsId>%s</credentialsId>'
            '</hudson.plugins.git.UserRemoteConfig></userRemoteConfigs>'
            '<branches><hudson.plugins.git.BranchSpec><name>develop</name></hudson.plugins.git.BranchSpec></branches>'
            '<doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>'
            '<submoduleCfg class="empty-list"/><extensions/></scm>'
            '<scriptPath>%s</scriptPath><lightweight>true</lightweight></definition>'
            '<triggers/><disabled>false</disabled></flow-definition>\n'
            ) % (escape(desc), escape(display), props, escape(url), GITHUB_CREDENTIALS_ID, escape(script_path))


FOLDER_DISPLAY_NAME = 'longzhu · 龙珠车服'


def folder_xml(registry):
    # Jenkins 是共用实例：全局的凭据与共享库属于 bgssai，龙珠车服的全部挂在本文件夹上，
    # 两边互不可见。文件夹自带共享库 longzhu（按沙箱运行，签名批准见 README）；凭据含口令，
    # 不写进这里，建好文件夹后在文件夹的 Credentials 里添加。
    desc = ('龙珠车服发布控制台。本文件夹自带凭据与共享库（longzhu），不使用 Jenkins 全局的凭据与共享库，'
            '这里的也只给本文件夹的 Job 用。'
            'Job 由 %s/%s 的 jenkins/seed/jobs.py 按产品清单生成，全部仅手动触发，点开即可执行。'
            '部署失败不自动重跑。') % (registry['githubOwner'], registry['workflowsRepo'])
    library = ('<org.jenkinsci.plugins.workflow.libs.FolderLibraries plugin="pipeline-groovy-lib"><libraries>'
               '<org.jenkinsci.plugins.workflow.libs.LibraryConfiguration><name>%s</name>'
               '<retriever class="org.jenkinsci.plugins.workflow.libs.SCMSourceRetriever"><clone>false</clone>'
               '<scm class="jenkins.plugins.git.GitSCMSource" plugin="git"><remote>https://github.com/%s/%s.git</remote>'
               '<credentialsId>%s</credentialsId><traits/></scm></retriever>'
               '<defaultVersion>develop</defaultVersion><implicit>false</implicit>'
               '<allowVersionOverride>true</allowVersionOverride><includeInChangesets>true</includeInChangesets>'
               '</org.jenkinsci.plugins.workflow.libs.LibraryConfiguration></libraries>'
               '</org.jenkinsci.plugins.workflow.libs.FolderLibraries>') % (
                   escape(registry['jenkinsFolder']), registry['githubOwner'], registry['workflowsRepo'],
                   GITHUB_CREDENTIALS_ID)
    return ("<?xml version='1.1' encoding='UTF-8'?>\n"
            '<com.cloudbees.hudson.plugins.folder.Folder plugin="cloudbees-folder">'
            '<description>%s</description><displayName>%s</displayName><properties>%s</properties>'
            '<folderViews class="com.cloudbees.hudson.plugins.folder.views.DefaultFolderViewHolder">'
            '<views><hudson.model.AllView>'
            '<owner class="com.cloudbees.hudson.plugins.folder.Folder" reference="../../../.."/>'
            '<name>All</name><filterExecutors>false</filterExecutors><filterQueue>false</filterQueue>'
            '<properties class="hudson.model.View$PropertyList"/></hudson.model.AllView></views>'
            '<tabBar class="hudson.views.DefaultViewsTabBar"/></folderViews><healthMetrics/>'
            '<icon class="com.cloudbees.hudson.plugins.folder.icons.StockFolderIcon"/>'
            '</com.cloudbees.hudson.plugins.folder.Folder>\n') % (escape(desc), escape(FOLDER_DISPLAY_NAME), library)


def env_label(e):
    return '开发环境（dev）' if e == 'dev' else '生产环境（prod）'


def build_jobs(registry):
    """返回 [(内部名, 显示名, config.xml)]，内部名 <env>-<product>-<operation>。"""
    jobs = []
    for product, p in sorted(registry['products'].items()):
        repo = p['githubRepo']
        for e in p['environments']:
            if e not in ('dev', 'prod'):
                raise ValueError('%s 的环境只能是 dev / prod：%s' % (product, e))
            for op, (script, verb, with_target) in OPERATIONS.items():
                if op in ('clean-database', 'init-database') and not p.get('database'):
                    continue
                if op == 'clean-database' and e != 'dev':
                    continue
                name = '%s-%s-%s' % (e, product, op)
                display = '%s %s(%s)' % (repo, verb, e)
                if op == 'deploy':
                    desc = '构建并部署 %s 到%s：目标机拉 develop、就地构建、替换重启、健康检查，失败自动回滚。仅手动触发。' % (repo, env_label(e))
                    params = choice_param('target', '部署目标（both=两端 / user=仅用户端 / admin=仅管理端），不改就是 both', TARGETS)
                elif op == 'clean-database':
                    desc = '删除%s的库（DROP DATABASE，不建表、不灌数据、不动应用）。全量发布第一步，之后跑 init database。' % env_label(e)
                    params = ''
                else:
                    desc = '用 %s 仓 develop 的 sql/ 初始化%s的空库（库里已有表就拒绝，绝不 DROP）。先跑 clean database。只动数据库，不部署应用。' % (repo, env_label(e))
                    params = ''
                assert with_target == bool(params)
                jobs.append((name, display, job_xml(registry, display, desc, script, params)))
    names = [j[0] for j in jobs]
    displays = [j[1] for j in jobs]
    if len(set(names)) != len(names) or len(set(displays)) != len(displays):
        raise ValueError('Job 名或显示名重复')
    for _, _, xml in jobs:
        ET.fromstring(xml.split('\n', 1)[1])
    return jobs


def cmd_generate(registry, out):
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, '_folder.xml'), 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(folder_xml(registry))
    jobs = build_jobs(registry)
    for name, display, xml in jobs:
        with open(os.path.join(out, name + '.xml'), 'w', encoding='utf-8', newline='\n') as fh:
            fh.write(xml)
    print('生成文件夹 %s 与 %d 个 Job 到 %s：' % (registry['jenkinsFolder'], len(jobs), out))
    for name, display, _ in jobs:
        print('  %-40s (%s)' % (display, name))
    return 0


class Jenkins:
    def __init__(self):
        self.url = os.environ.get('JENKINS_URL', '').rstrip('/')
        user = os.environ.get('JENKINS_USER', '')
        token = os.environ.get('JENKINS_TOKEN', '')
        if not (self.url and user and token):
            raise SystemExit('需要环境变量 JENKINS_URL / JENKINS_USER / JENKINS_TOKEN')
        self.auth = 'Basic ' + base64.b64encode(('%s:%s' % (user, token)).encode()).decode()
        # crumb 与会话绑定：取 crumb 与后续 POST 必须用同一个 cookie 会话。
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        self.crumb = None

    def request(self, method, path, data=None, content_type=None):
        req = urllib.request.Request(self.url + path, data=data, method=method)
        req.add_header('Authorization', self.auth)
        if content_type:
            req.add_header('Content-Type', content_type)
        if method == 'POST':
            if self.crumb is None:
                self.crumb = self._crumb()
            if self.crumb:
                req.add_header(self.crumb[0], self.crumb[1])
        return self.opener.open(req, timeout=30)

    def _crumb(self):
        try:
            with self.request('GET', '/crumbIssuer/api/json') as resp:
                body = json.load(resp)
                return body['crumbRequestField'], body['crumb']
        except urllib.error.HTTPError as err:
            if err.code == 404:
                return ()
            raise

    def existing_jobs(self, folder):
        try:
            with self.request('GET', '/job/%s/api/json?tree=jobs[name]' % urllib.parse.quote(folder)) as resp:
                return {j['name'] for j in json.load(resp).get('jobs', [])}
        except urllib.error.HTTPError as err:
            if err.code == 404:
                return None
            raise

    def create(self, parent, name, xml):
        path = (parent + '/createItem?name=' + urllib.parse.quote(name))
        with self.request('POST', path, xml.encode('utf-8'), 'application/xml; charset=utf-8') as resp:
            return resp.status


def cmd_plan_or_create(registry, create):
    jenkins = Jenkins()
    folder = registry['jenkinsFolder']
    jobs = build_jobs(registry)
    existing = jenkins.existing_jobs(folder)
    wanted = {name for name, _, _ in jobs}
    if existing is None:
        print('文件夹 %s 不存在' % folder)
        missing_folder = True
        existing = set()
    else:
        missing_folder = False
    missing = [j for j in jobs if j[0] not in existing]
    extra = sorted(existing - wanted)
    print('清单 %d 个，已存在 %d 个，缺 %d 个，清单外 %d 个' % (len(jobs), len(wanted & existing), len(missing), len(extra)))
    for name, display, _ in missing:
        print('  缺少: %s (%s)' % (display, name))
    for name in extra:
        print('  清单外（不会动它）: %s' % name)
    if not create:
        return 0
    if missing_folder:
        jenkins.create('', folder, folder_xml(registry))
        print('已建文件夹 %s（自带共享库 longzhu）。凭据请加在这个文件夹的 Credentials 里，不要加到全局。' % folder)
    created = 0
    for name, display, xml in missing:
        jenkins.create('/job/%s' % urllib.parse.quote(folder), name, xml)
        created += 1
        print('已建: %s (%s)' % (display, name))
    print('created=%d' % created)
    return 0


def main():
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description='按产品清单生成 / 创建 Jenkins Job')
    sub = parser.add_subparsers(dest='cmd', required=True)
    gen = sub.add_parser('generate', help='只生成 config.xml')
    gen.add_argument('--output', default=os.path.join(tempfile.gettempdir(), 'longzhu-jobs'))
    sub.add_parser('plan', help='对比线上 Jenkins（只读）')
    sub.add_parser('create-missing', help='只新建缺失的文件夹与 Job')
    args = parser.parse_args()
    registry = load_registry()
    if args.cmd == 'generate':
        return cmd_generate(registry, args.output)
    return cmd_plan_or_create(registry, args.cmd == 'create-missing')


if __name__ == '__main__':
    sys.exit(main())
