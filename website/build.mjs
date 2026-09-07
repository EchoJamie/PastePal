import { cpSync, existsSync, lstatSync, mkdirSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.dirname(fileURLToPath(import.meta.url));
const output = path.join(root, 'dist');
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
console.log('站点已输出到 website/dist/');
