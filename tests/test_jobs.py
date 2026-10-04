#!/usr/bin/env python3
"""jenkins/seed/jobs.py：Job 清单完全由 products.json 推出，且与流水线约定一致。"""
import importlib.util
import os
import re
import sys
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location('jobs', os.path.join(ROOT, 'jenkins', 'seed', 'jobs.py'))
jobs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(jobs)


def main():
    registry = jobs.load_registry()
    built = jobs.build_jobs(registry)
    names = [n for n, _, _ in built]

    # 只开通 dev：全量发布三步 clean database → init database → deploy。
    assert names == ['dev-longzhu-clean-database', 'dev-longzhu-init-database', 'dev-longzhu-deploy'], names

    for name, display, xml in built:
        root = ET.fromstring(xml.split('\n', 1)[1])
        env, rest = name.split('-', 1)
        assert env in ('dev', 'prod')
        # 内部名必须能被 vars/longzhuResolveJob.groovy 解析：<env>-<product>-<operation>
        m = re.fullmatch(r'(dev|prod)-(.+)-(deploy|clean-database|init-database)', name)
        assert m, name
        url = root.find('.//hudson.plugins.git.UserRemoteConfig/url').text
        assert url == 'https://github.com/liuliuzo/longzhu-workflows.git', url
        assert root.find('.//hudson.plugins.git.UserRemoteConfig/credentialsId').text == 'longzhu-github'
        assert root.find('.//branches/hudson.plugins.git.BranchSpec/name').text == 'develop'
        script = root.find('.//scriptPath').text
        assert os.path.isfile(os.path.join(ROOT, script)), script
        assert display.startswith('longzhu ') and display.endswith('(%s)' % env), display
        params = [p.find('name').text for p in root.iter('hudson.model.ChoiceParameterDefinition')]
        assert params == (['target'] if m.group(3) == 'deploy' else []), (name, params)

    # 每个 Jenkinsfile 都加载同名共享库。
    for script in ('Jenkinsfile.deploy', 'Jenkinsfile.cleandb', 'Jenkinsfile.initdb'):
        with open(os.path.join(ROOT, 'jenkins', script), encoding='utf-8') as fh:
            assert "@Library('longzhu') _" in fh.read(), script

    # 文件夹自带共享库：名字与 Jenkinsfile 的 @Library 一致，指向本仓 develop，用文件夹里的 GitHub 凭据。
    assert registry['jenkinsFolder'] == 'longzhu'
    folder = ET.fromstring(jobs.folder_xml(registry).split('\n', 1)[1])
    assert folder.findtext('displayName') == 'longzhu · 龙珠车服'
    lib = folder.find('.//org.jenkinsci.plugins.workflow.libs.LibraryConfiguration')
    assert lib.findtext('name') == 'longzhu'
    assert lib.findtext('defaultVersion') == 'develop'
    assert lib.findtext('.//remote') == 'https://github.com/liuliuzo/longzhu-workflows.git'
    assert lib.findtext('.//credentialsId') == 'longzhu-github'
    displays = [d for _, d, _ in built]
    assert displays == ['longzhu clean database(dev)', 'longzhu init database(dev)', 'longzhu deploy(dev)'], displays
    print('PASS: Job 清单 %d 个：%s' % (len(names), ', '.join(names)))


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    main()
