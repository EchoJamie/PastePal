#!/usr/bin/env python3
"""校验当前文档的本地链接，不依赖个人路径或 Git 历史。"""
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit

root = Path(__file__).resolve().parent.parent
files = [root/'README.md', *sorted(root.joinpath('docs').rglob('*.md')), root/'website/README.md']
errors = []
links = 0
for file in files:
    content = re.sub(r'```.*?```', '', file.read_text(), flags=re.DOTALL)
    for target in re.findall(r'\]\(([^)]+)\)', content):
        target = target.strip()
        target = target[1:target.index('>')] if target.startswith('<') else target.split()[0]
        url = urlsplit(target)
        if url.scheme or url.netloc or not url.path:
            continue
        if not (file.parent/unquote(url.path)).exists():
            errors.append(f'{file.relative_to(root)}: {target}')
        links += 1
if errors:
    raise SystemExit('文档链接失效：\n' + '\n'.join(errors))
print(f'已检查 {len(files)} 份 Markdown、{links} 个本地链接，全部有效。')
