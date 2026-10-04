#!/usr/bin/env python3
"""从本机触发 longzhu 文件夹里的 Job，并等到出结果。

用法（只需 python3；Windows 的 Git Bash / PowerShell 也行）：
    python3 jenkins/trigger.py status                               # 只读：各 Job 与最近一次构建
    python3 jenkins/trigger.py run dev-longzhu-deploy                # 真实发布两端，等结果
    python3 jenkins/trigger.py run dev-longzhu-deploy --target user  # 只发用户端
    python3 jenkins/trigger.py run dev-longzhu-deploy --log full     # 打印完整构建日志

Jenkins 地址与账号：环境变量 JENKINS_URL / JENKINS_USER / JENKINS_TOKEN（口令或 API Token 都行），
没设的从 ~/.config/longzhu/jenkins.env 读（本仓是公开仓，口令不入仓）；
放在别处用 LONGZHU_JENKINS_ENV 指定路径。

run 一调用就是真实执行，没有演练模式；Job 正在跑或在排队时拒绝再触发。
失败不自动重跑：构建失败线上没动，健康检查失败已自动回滚，看清日志再人工重跑。
退出码：0 成功；1 构建失败或被取消；2 用法、配置或网络问题（没有触发任何东西，或触发后失联）。
"""
import argparse
import importlib.util
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location('jobs', os.path.join(ROOT, 'jenkins', 'seed', 'jobs.py'))
jobs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(jobs)

ENV_KEYS = ('JENKINS_URL', 'JENKINS_USER', 'JENKINS_TOKEN')
DEFAULT_ENV_FILE = os.path.join(os.path.expanduser('~'), '.config', 'longzhu', 'jenkins.env')
# --log key 时只打印这些行：发布脚本自己的日志、阶段切换、错误与结论。
# progressiveText 里夹着 Jenkins 给界面用的隐藏注记（ESC[8mha:////…ESC[0m），打印前去掉。
CONSOLE_NOTE = re.compile(r'\x1b\[8mha:.*?\x1b\[0m')
KEY_LINE = re.compile(r'\[(wrapper|preflight|remote-build|remote-deploy|init-db|stop)\]'
                      r'|\[Pipeline\] \{ \(|ERROR|Finished: |部署成功|部署失败')
POLL_SECONDS = 3
QUEUE_TIMEOUT_SECONDS = 15 * 60
FAILURE_TAIL_LINES = 120


class Abort(Exception):
    """用法、配置或状态不对，脚本主动停下（退出码 2）。"""


def load_env_file():
    """把 jenkins.env 里的 KEY=VALUE 补进环境变量；已设的环境变量优先，不 eval 任何内容。"""
    path = os.environ.get('LONGZHU_JENKINS_ENV') or DEFAULT_ENV_FILE
    if not os.path.isfile(path):
        return path, False
    with open(path, encoding='utf-8-sig') as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            key, value = (s.strip() for s in line.split('=', 1))
            if len(value) >= 2 and value[0] == value[-1] and value[0] in '"\'':
                value = value[1:-1]
            if key in ENV_KEYS and value and not os.environ.get(key):
                os.environ[key] = value
    return path, True


def connect():
    path, found = load_env_file()
    missing = [k for k in ENV_KEYS if not os.environ.get(k)]
    if missing:
        hint = '已读 %s' % path if found else '也没找到 %s' % path
        raise Abort('缺少 %s：设环境变量，或补齐 ~/.config/longzhu/jenkins.env（%s）'
                         % (' / '.join(missing), hint))
    return jobs.Jenkins()


def get_json(jenkins, path):
    with jenkins.request('GET', path) as resp:
        return json.load(resp)


def job_path(folder, name):
    return '/job/%s/job/%s' % (urllib.parse.quote(folder), urllib.parse.quote(name))


def fmt_build(b):
    if not b:
        return '还没有构建'
    if b.get('building'):
        state = '运行中'
    else:
        state = '%s，%ds' % (b.get('result'), (b.get('duration') or 0) // 1000)
    ts = time.strftime('%Y-%m-%d %H:%M:%S', time.localtime((b.get('timestamp') or 0) / 1000))
    return '#%s %s（%s 开始）' % (b.get('number'), state, ts)


def cmd_status(jenkins, folder, built):
    for name, display, _ in built:
        try:
            info = get_json(jenkins, job_path(folder, name) + '/api/json?tree=inQueue,'
                            'lastBuild[number,result,building,duration,timestamp]')
        except urllib.error.HTTPError as err:
            if err.code != 404:
                raise
            print('%-28s 不存在（跑 jenkins/seed/jobs.py create-missing 建）' % name)
            continue
        queued = '，有一项在排队' if info.get('inQueue') else ''
        print('%-28s %s%s' % (name, fmt_build(info.get('lastBuild')), queued))
    return 0


def wait_for_build_number(jenkins, queue_path):
    deadline = time.time() + QUEUE_TIMEOUT_SECONDS
    last_why = None
    while time.time() < deadline:
        item = get_json(jenkins, queue_path + 'api/json')
        if item.get('cancelled'):
            return None
        executable = item.get('executable')
        if executable and executable.get('number'):
            return executable['number']
        why = item.get('why')
        if why and why != last_why:
            print('排队中：%s' % why)
            last_why = why
        time.sleep(POLL_SECONDS)
    raise Abort('排队超过 %d 分钟还没开始，脚本先退出；队列项 %s 仍在 Jenkins 里'
                     % (QUEUE_TIMEOUT_SECONDS // 60, queue_path))


def follow_log(jenkins, build_path, full):
    """按 progressiveText 增量读构建日志直到结束；按字节偏移续读，按整行解码。"""
    offset = 0
    pending = b''
    while True:
        with jenkins.request('GET', build_path + '/logText/progressiveText?start=%d' % offset) as resp:
            chunk = resp.read()
            offset = int(resp.headers.get('X-Text-Size') or offset + len(chunk))
            more = resp.headers.get('X-More-Data') == 'true'
        pending += chunk
        *lines, pending = pending.split(b'\n')
        if not more and pending:
            lines.append(pending)
            pending = b''
        for raw in lines:
            line = CONSOLE_NOTE.sub('', raw.decode('utf-8', errors='replace').rstrip('\r'))
            if full or KEY_LINE.search(line):
                print(line, flush=True)
        if not more:
            return
        time.sleep(POLL_SECONDS)


def cmd_run(jenkins, folder, built, name, target, log_mode):
    names = [n for n, _, _ in built]
    if name not in names:
        raise Abort('不认识的 Job：%s（清单里有 %s）' % (name, ' / '.join(names)))
    base = job_path(folder, name)
    info = get_json(jenkins, base + '/api/json?tree=url,inQueue,lastBuild[number,building],'
                    'property[parameterDefinitions[name,choices]]')
    choices = None
    for prop in info.get('property') or []:
        for p in prop.get('parameterDefinitions') or []:
            if p.get('name') == 'target':
                choices = p.get('choices') or []
    if choices is None and target:
        raise Abort('%s 没有 target 参数，不要传 --target' % name)
    if choices is not None:
        target = target or 'both'
        if target not in choices:
            raise Abort('%s 的 target 只能是 %s' % (name, ' / '.join(choices)))
    last = info.get('lastBuild') or {}
    if info.get('inQueue') or last.get('building'):
        raise Abort('%s 已有构建在跑或在排队（#%s），没有再触发；跑完再来' % (name, last.get('number')))

    if choices is not None:
        trigger = base + '/buildWithParameters?' + urllib.parse.urlencode({'target': target})
    else:
        trigger = base + '/build'
    print('触发 %s%s' % (name, ' target=%s' % target if target else ''))
    with jenkins.request('POST', trigger, b'') as resp:
        location = resp.headers.get('Location')
    if not location:
        raise Abort('Jenkins 接受了触发但没返回队列地址，去界面看 %s' % info.get('url'))
    number = wait_for_build_number(jenkins, urllib.parse.urlparse(location).path)
    if number is None:
        print('队列项被取消，没有开始构建')
        return 1

    build_path = '%s/%d' % (base, number)
    print('构建 #%d：%s%d/' % (number, info.get('url'), number), flush=True)
    follow_log(jenkins, build_path, log_mode == 'full')

    result = None
    for _ in range(20):  # 日志结束到 result 落库之间可能差一两秒
        build = get_json(jenkins, build_path + '/api/json?tree=result,duration')
        result = build.get('result')
        if result:
            break
        time.sleep(1)
    if result != 'SUCCESS' and log_mode == 'key':
        with jenkins.request('GET', build_path + '/consoleText') as resp:
            tail = resp.read().decode('utf-8', errors='replace').splitlines()[-FAILURE_TAIL_LINES:]
        print('---- 构建日志最后 %d 行 ----' % len(tail))
        print('\n'.join(tail))
    print('结果：%s，用时 %ds，%s%d/' % (result, (build.get('duration') or 0) // 1000, info.get('url'), number))
    return 0 if result == 'SUCCESS' else 1


def main():
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8', line_buffering=True)  # 输出被管道接走时也逐行出
    parser = argparse.ArgumentParser(description='从本机触发 longzhu 文件夹里的 Jenkins Job 并等结果')
    sub = parser.add_subparsers(dest='cmd', required=True)
    sub.add_parser('status', help='只读：各 Job 最近一次构建')
    run = sub.add_parser('run', help='真实触发一个 Job 并等结果')
    run.add_argument('job', help='Job 内部名，如 dev-longzhu-deploy')
    run.add_argument('--target', help='deploy / stop 的目标：both（缺省）/ user / admin')
    run.add_argument('--log', choices=['key', 'full'], default='key', help='key=只打关键行（缺省），full=完整日志')
    args = parser.parse_args()

    registry = jobs.load_registry()
    folder = registry['jenkinsFolder']
    built = jobs.build_jobs(registry)
    try:
        jenkins = connect()
        if args.cmd == 'status':
            return cmd_status(jenkins, folder, built)
        return cmd_run(jenkins, folder, built, args.job, args.target, args.log)
    except Abort as err:
        print(err, file=sys.stderr)
    except urllib.error.HTTPError as err:
        hint = '（账号或口令不对，或没有该 Job 的权限）' if err.code in (401, 403) else ''
        print('Jenkins 返回 HTTP %d：%s%s' % (err.code, err.url, hint), file=sys.stderr)
    except urllib.error.URLError as err:
        print('连不上 Jenkins %s：%s' % (os.environ.get('JENKINS_URL'), err.reason), file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main())
