// Bundles the webapp into dist/app/ and, with --package, zips it for Bridgething.
import { execFileSync } from 'node:child_process';
import { cpSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as esbuild from 'esbuild';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const out = join(root, 'dist', 'app');
const watch = process.argv.includes('--watch');
const pack = process.argv.includes('--package');
const { version } = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
cpSync(join(root, 'public'), out, { recursive: true });

const options = {
  entryPoints: [
    { in: join(root, 'src', 'main.ts'), out: 'app' },
    { in: join(root, 'src', 'ui', 'app.css'), out: 'app' },
  ],
  outdir: out,
  bundle: true,
  format: 'iife',
  // The Car Thing runs an older Chromium (the previous build relied on optional chaining, so 80+).
  target: 'chrome80',
  minify: !watch,
  sourcemap: watch ? 'inline' : false,
  legalComments: 'none',
  define: { __APP_VERSION__: JSON.stringify(version) },
  logLevel: 'info',
};

if (watch) {
  const context = await esbuild.context(options);
  await context.watch();
} else {
  await esbuild.build(options);
}

if (pack) {
  const zip = join(root, 'dist', 'TVThing-CarThing.zip');
  rmSync(zip, { force: true });
  execFileSync('zip', ['-qrX', zip, '.', '-x', '.*'], { cwd: out });
  console.log(`Packaged ${zip}`);
}
