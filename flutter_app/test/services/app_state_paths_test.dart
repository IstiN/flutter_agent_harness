// gh-2185 AC1: the ONE runtime-state home is `<cwd>/.fah/state/` — never
// the repo root. This pins the seam every app store persists through:
// path shape, state-root precedence, and the one-release legacy fallback.
@TestOn('vm')
library;

import 'package:fa/services/app_state_paths.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('appStateFilePath', () {
    test('resolves under <cwd>/.fah/state/, never the cwd itself', () {
      final env = MemoryExecutionEnv(cwd: '/repo');
      expect(
        appStateFilePath(env, 'theme.json'),
        '/repo/.fah/state/theme.json',
      );
      expect(
        appStateFilePath(env, 'chat_read_cursors.json'),
        '/repo/.fah/state/chat_read_cursors.json',
      );
    });

    test('legacy path is the pre-gh-2185 root location', () {
      final env = MemoryExecutionEnv(cwd: '/repo');
      expect(legacyAppStateFilePath(env, 'theme.json'), '/repo/theme.json');
    });
  });

  group('readAppStateText', () {
    test('returns the state-root copy when present', () async {
      final env = MemoryExecutionEnv(cwd: '/repo');
      await env.writeFile('/repo/.fah/state/theme.json', 'fresh');
      await env.writeFile('/repo/theme.json', 'legacy');

      expect(await readAppStateText(env, 'theme.json'), 'fresh');
    });

    test('falls back to the legacy root copy for one release', () async {
      final env = MemoryExecutionEnv(cwd: '/repo');
      await env.writeFile('/repo/theme.json', 'legacy');

      expect(await readAppStateText(env, 'theme.json'), 'legacy');
    });

    test('null when neither location has the file', () async {
      final env = MemoryExecutionEnv(cwd: '/repo');
      expect(await readAppStateText(env, 'theme.json'), isNull);
    });
  });
}
