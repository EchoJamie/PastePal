import { cpSync, existsSync, lstatSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.dirname(fileURLToPath(import.meta.url));
const output = path.join(root, 'dist');
const owner = process.env.VERCEL_GIT_REPO_OWNER;
const slug = process.env.VERCEL_GIT_REPO_SLUG;
if (Boolean(owner) !== Boolean(slug)) throw new Error('Vercel 仓库所属账号与仓库名必须同时提供');
if (owner && (!/^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/.test(owner)
  || !/^[A-Za-z0-9_.-]+$/.test(slug) || ['.', '..'].includes(slug))) {
  throw new Error('Vercel GitHub 仓库信息无效');
}
const repository = owner ? `${owner}/${slug}` : 'EchoJamie/PastePal';
const releasesURL = `https://github.com/${repository}/releases`;
const html = readFileSync(path.join(root, 'index.html'), 'utf8')
  .replaceAll('https://github.com/EchoJamie/PastePal/releases', releasesURL);
const entries = ['index.html', 'styles.css', 'script.js', 'assets'];
for (const entry of entries) {
  if (!existsSync(path.join(root, entry))) throw new Error(`缺少站点资源：${entry}`);
}
if (existsSync(output) && lstatSync(output).isSymbolicLink()) {
  throw new Error('拒绝覆盖指向其他位置的 dist');
}
rmSync(output, { recursive: true, force: true });
mkdirSync(output);
for (const entry of entries) cpSync(path.join(root, entry), path.join(output, entry), { recursive: true });
writeFileSync(path.join(output, 'index.html'), html);
console.log('站点已输出到 website/dist/');
console.log(`下载入口（${owner ? 'Vercel Git 变量' : '本地默认仓库'}）：${releasesURL}`);
