// Global setup — mirrors the dart suite's _requireBuiltAgent convention:
// the embedded agent (browser_ext/sw/agent.js) is a dart2js build artifact.
// Present: nothing to do. Absent + dart on PATH: build it. Absent + no
// dart: fail LOUDLY with the fix — never a silent green run.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const e2eDir = path.dirname(fileURLToPath(import.meta.url));
export const repoRoot = path.resolve(e2eDir, '..', '..');

export default function globalSetup(): void {
  const agentJs = path.join(repoRoot, 'browser_ext/sw/agent.js');
  if (fs.existsSync(agentJs)) return;

  const dart = spawnSync('dart', ['--version'], { stdio: 'ignore' });
  if (dart.error || dart.status !== 0) {
    throw new Error(
      'browser_ext/sw/agent.js not built and no dart SDK on PATH — run '
        + 'scripts/build_browser_ext.sh first (the embedded agent is a '
        + 'dart2js build artifact).',
    );
  }

  const res = spawnSync(
    'bash',
    [path.join(repoRoot, 'scripts/build_browser_ext.sh')],
    { cwd: repoRoot, stdio: 'inherit' },
  );
  if (res.status !== 0 || !fs.existsSync(agentJs)) {
    throw new Error(
      'scripts/build_browser_ext.sh failed to produce browser_ext/sw/agent.js',
    );
  }
}
