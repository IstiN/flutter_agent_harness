@Tags(['io'])
library;

import 'package:flutter_agent_harness/src/cli/openrouter_oauth_server.dart';
import 'package:test/test.dart';

void main() {
  group('isHeadlessOrRemoteSession', () {
    test('an interactive local session is not headless', () {
      expect(
        isHeadlessOrRemoteSession(
          environment: const {'DISPLAY': ':0'},
          stdoutHasTerminal: true,
          isLinux: true,
        ),
        isFalse,
      );
    });

    test('a Linux session without any display is headless', () {
      expect(
        isHeadlessOrRemoteSession(
          environment: const {},
          stdoutHasTerminal: true,
          isLinux: true,
        ),
        isTrue,
      );
    });

    test('WAYLAND_DISPLAY counts as a display', () {
      expect(
        isHeadlessOrRemoteSession(
          environment: const {'WAYLAND_DISPLAY': 'wayland-0'},
          stdoutHasTerminal: true,
          isLinux: true,
        ),
        isFalse,
      );
    });

    test('an empty display value counts as absent', () {
      expect(
        isHeadlessOrRemoteSession(
          environment: const {'DISPLAY': ''},
          stdoutHasTerminal: true,
          isLinux: true,
        ),
        isTrue,
      );
    });

    test('SSH_TTY marks the session remote', () {
      expect(
        isHeadlessOrRemoteSession(
          environment: const {'DISPLAY': ':0', 'SSH_TTY': '/dev/pts/0'},
          stdoutHasTerminal: true,
          isLinux: true,
        ),
        isTrue,
      );
    });

    test('SSH_CONNECTION alone marks the session remote', () {
      expect(
        isHeadlessOrRemoteSession(
          environment: const {
            'DISPLAY': ':0',
            'SSH_CONNECTION': '10.0.0.1 5000 10.0.0.2 22',
          },
          stdoutHasTerminal: true,
          isLinux: true,
        ),
        isTrue,
      );
    });

    test('non-interactive stdout marks the session headless', () {
      expect(
        isHeadlessOrRemoteSession(
          environment: const {'DISPLAY': ':0'},
          stdoutHasTerminal: false,
          isLinux: true,
        ),
        isTrue,
      );
    });

    test('the display check is Linux-only (macOS/Windows need none)', () {
      expect(
        isHeadlessOrRemoteSession(
          environment: const {},
          stdoutHasTerminal: true,
          isLinux: false,
        ),
        isFalse,
      );
    });

    test('SSH markers apply on every platform', () {
      expect(
        isHeadlessOrRemoteSession(
          environment: const {'SSH_CONNECTION': '10.0.0.1 5000 10.0.0.2 22'},
          stdoutHasTerminal: true,
          isLinux: false,
        ),
        isTrue,
      );
    });
  });

  group('shouldLaunchBrowser (precedence: flag > env > auto-detect)', () {
    test('launches for an interactive local session', () {
      expect(
        shouldLaunchBrowser(
          environment: const {'DISPLAY': ':0'},
          stdoutHasTerminal: true,
          isLinux: true,
        ),
        isTrue,
      );
    });

    test('the --no-browser flag alone skips the launch', () {
      expect(
        shouldLaunchBrowser(
          noBrowserFlag: true,
          environment: const {'DISPLAY': ':0'},
          stdoutHasTerminal: true,
          isLinux: true,
        ),
        isFalse,
      );
    });

    test('a truthy FA_NO_BROWSER alone skips the launch', () {
      for (final value in const ['1', 'true', 'yes', 'on', 'TRUE', ' Yes ']) {
        expect(
          shouldLaunchBrowser(
            environment: {'FA_NO_BROWSER': value, 'DISPLAY': ':0'},
            stdoutHasTerminal: true,
            isLinux: true,
          ),
          isFalse,
          reason: 'FA_NO_BROWSER=$value must skip the launch',
        );
      }
    });

    test('non-truthy FA_NO_BROWSER values do not skip the launch', () {
      for (final value in const ['0', 'false', '', 'no', 'off']) {
        expect(
          shouldLaunchBrowser(
            environment: {'FA_NO_BROWSER': value, 'DISPLAY': ':0'},
            stdoutHasTerminal: true,
            isLinux: true,
          ),
          isTrue,
          reason: 'FA_NO_BROWSER=$value must not skip the launch',
        );
      }
    });

    test('the flag wins over a non-truthy env var', () {
      expect(
        shouldLaunchBrowser(
          noBrowserFlag: true,
          environment: const {'FA_NO_BROWSER': '0', 'DISPLAY': ':0'},
          stdoutHasTerminal: true,
          isLinux: true,
        ),
        isFalse,
      );
    });

    test('the flag wins over a truthy env var (both set: flag wins)', () {
      expect(
        shouldLaunchBrowser(
          noBrowserFlag: true,
          environment: const {'FA_NO_BROWSER': '1', 'DISPLAY': ':0'},
          stdoutHasTerminal: true,
          isLinux: true,
        ),
        isFalse,
      );
    });

    test('env beats auto-detect (env set on an interactive session: skip)',
        () {
      expect(
        shouldLaunchBrowser(
          environment: const {'FA_NO_BROWSER': 'yes', 'DISPLAY': ':0'},
          stdoutHasTerminal: true,
          isLinux: true,
        ),
        isFalse,
      );
    });

    test('auto-detect fires when flag and env are clear', () {
      for (final (label, env, terminal) in const [
        ('no display', <String, String>{}, true),
        ('ssh marker', {
          'DISPLAY': ':0',
          'SSH_TTY': '/dev/pts/0',
        }, true),
        ('piped stdout', {'DISPLAY': ':0'}, false),
      ]) {
        expect(
          shouldLaunchBrowser(
            environment: env,
            stdoutHasTerminal: terminal,
            isLinux: true,
          ),
          isFalse,
          reason: '$label must skip the launch',
        );
      }
    });
  });
}
