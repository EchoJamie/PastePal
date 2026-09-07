#!/usr/bin/env python3
"""使锁定的快捷键依赖从标准 .app 资源目录加载本地化。"""
from pathlib import Path
import json
import subprocess

root = Path(__file__).resolve().parent.parent
checkout = root / '.build/checkouts/KeyboardShortcuts'
revision = '1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27'
lock = json.loads((root / 'Package.resolved').read_text())
assert lock['pins'][0]['state']['revision'] == revision, '依赖版本变化，请复核资源补丁'
actual = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
assert actual == revision, '检出的依赖提交与锁定版本不一致'
path = checkout / 'Sources/KeyboardShortcuts/Utilities.swift'
original = subprocess.check_output(['git', '-C', str(checkout), 'show', 'HEAD:Sources/KeyboardShortcuts/Utilities.swift'], text=True)
before = '\t\tNSLocalizedString(self, bundle: .module, comment: self)'
after = '''\t\tlet appResources = Bundle.main.resourceURL?.appendingPathComponent("KeyboardShortcuts_KeyboardShortcuts.bundle")
\t\tlet resources = appResources.flatMap { Bundle(url: $0) } ?? .module
\t\treturn NSLocalizedString(self, bundle: resources, comment: self)'''
assert original.count(before) == 1, '未找到预期资源调用'
patched = original.replace(before, after)
current = path.read_text()
assert current in (original, patched), '依赖存在其他修改，停止自动打包'
if current != patched:
    path.chmod(path.stat().st_mode | 0o200)
    path.write_text(patched)
