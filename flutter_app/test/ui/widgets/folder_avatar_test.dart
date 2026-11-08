@TestOn('vm')
/// Unit tests for the deterministic folder avatar + the well-known icon
/// resolver: the gradient picks a FIXED palette slot (no hue clustering),
/// the letter is the first rune in white, and a folder icon file at one of
/// the short candidate paths wins over the letter — resolved through the
/// MOUNT namespace (host→mount rebase seam), cached, never a deep scan,
/// and never a raw host IO probe for folders outside the active mount.
library;

import 'dart:typed_data';

import 'package:fa/services/project_mount_env.dart';
import 'package:fa/ui/chats/local_session_folders.dart';
import 'package:fa/ui/widgets/folder_avatar.dart';
import 'package:flutter/painting.dart' show Color, HSLColor;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reads a color's HSL parts through Flutter's own conversion (the
/// algorithm's own math).
HSLColor hslOf(Color color) => HSLColor.fromColor(color);

void main() {
  group('avatar algorithm', () {
    test('the hue is a fixed palette slot indexed by the id hash', () {
      for (final id in [
        '/work/flutter_agent',
        '/work/mono',
        '',
        'π',
        '/tmp/x',
      ]) {
        expect(
          folderAvatarHue(id),
          folderAvatarHues[id.hashCode.abs() % folderAvatarHues.length],
          reason: '$id must pick a palette slot, not a raw % 360 hue',
        );
      }
    });

    test('same id → same slot + same gradient stops (determinism)', () {
      final (aStart, aEnd) = folderAvatarGradient('/work/flutter_agent');
      final (bStart, bEnd) = folderAvatarGradient('/work/flutter_agent');
      expect(aStart, bStart);
      expect(aEnd, bEnd);
      // The two-stop ramp: hue → hue+30, S .72→.66, L .58→.42.
      final start = hslOf(aStart);
      final end = hslOf(aEnd);
      expect(
        (end.hue - start.hue + 360) % 360,
        closeTo(30, 0.5),
      );
      expect(start.saturation, closeTo(0.72, 0.01));
      expect(start.lightness, closeTo(0.58, 0.01));
      expect(end.saturation, closeTo(0.66, 0.01));
      expect(end.lightness, closeTo(0.42, 0.01));
    });

    test('distinct ids spread the palette (no clustering into one slot)', () {
      final slots = <int>{
        for (var i = 0; i < 200; i++)
          folderAvatarHues['/work/folder-$i'.hashCode.abs() % 10],
      };
      // The hash spreads ids over the whole palette — 8+ of the 10 slots
      // see traffic across 200 synthetic cwds.
      expect(slots.length, greaterThanOrEqualTo(8));
    });

    test('every rendered stop is vivid (audited S/L floor)', () {
      for (final hue in folderAvatarHues) {
        final start = HSLColor.fromAHSL(1, hue.toDouble(), 0.72, 0.58);
        expect(start.saturation, greaterThan(0.6));
        expect(start.lightness, inInclusiveRange(0.5, 0.65));
      }
    });

    test('letter: uppercase first rune; empty → "?"', () {
      expect(folderAvatarLetter('flutter_agent'), 'F');
      expect(folderAvatarLetter(' mono '), 'M');
      expect(folderAvatarLetter('épsilon'), 'É');
      expect(folderAvatarLetter('  '), '?');
      expect(folderAvatarLetter(''), '?');
    });
  });

  group('FolderIconResolver', () {
    test('a mounted folder with icon.png in the mount → image, cached', () async {
      // The production shape: a ProjectMountEnv over the sandbox with the
      // user folder mounted at /project; the folder id is the HOST root.
      final env = ProjectMountEnv(MemoryExecutionEnv());
      env.mountedRoot = '/Users/me/proj';
      const bytes = <int>[1, 2, 3, 4];
      // Written through the mount segment — the only visible namespace.
      await env.writeFile('/project/icon.png', String.fromCharCodes(bytes));

      final resolver = FolderIconResolver(env);
      final first = await resolver.resolve('/Users/me/proj');
      expect(first, isNotNull, reason: 'the host root rebase probes /project');
      expect(first!.bytes, Uint8List.fromList(bytes));

      // The cache hands back the same resolved image, not a second probe.
      final cached = await resolver.resolve('/Users/me/proj');
      expect(identical(cached, first), isTrue);
    });

    test('the injected hostToMountPath seam drives the probing', () async {
      final env = MemoryExecutionEnv();
      const bytes = <int>[9, 8, 7];
      await env.writeFile('/project/assets/icon.png', String.fromCharCodes(
        bytes,
      ));
      final resolver = FolderIconResolver(
        env,
        hostToMountPath: (folderId) =>
            folderId == '/work/mono' ? '/project' : null,
      );
      final image = await resolver.resolve('/work/mono');
      expect(image, isNotNull);
      expect(image!.bytes, Uint8List.fromList(bytes));
    });

    test('a folder outside the active mount keeps the letter — no host '
        'IO even when the file exists in the sandbox', () async {
      final env = ProjectMountEnv(MemoryExecutionEnv());
      env.mountedRoot = '/Users/me/proj';
      // Files that RAW host IO would find must never be probed.
      await env.writeFile('/elsewhere/icon.png', 'x');
      await env.writeFile('/Users/me/other/icon.png', 'x');
      final resolver = FolderIconResolver(env);
      expect(await resolver.resolve('/elsewhere'), isNull);
      expect(await resolver.resolve('/Users/me/other'), isNull);
    });

    test('an env without a mount resolves every folder to null', () async {
      final env = ProjectMountEnv(MemoryExecutionEnv());
      final resolver = FolderIconResolver(env);
      expect(await resolver.resolve('/Users/me/proj'), isNull);
      expect(await resolver.resolve('/tmp'), isNull);
    });

    test('the default seam rebase: root → /project, subdir → /project/…', () {
      final env = ProjectMountEnv(MemoryExecutionEnv());
      env.mountedRoot = '/Users/me/proj';
      expect(defaultHostToMountPath(env, '/Users/me/proj'), '/project');
      expect(
        defaultHostToMountPath(env, '/Users/me/proj/sub/deep'),
        '/project/sub/deep',
      );
      expect(defaultHostToMountPath(env, '/Users/me/other'), isNull);
      expect(defaultHostToMountPath(env, '/Users/me/proj-suffix'), isNull);
    });

    test('a decorated env unwraps to the mount (SessionCwd walk parity)', () {
      final env = ProjectMountEnv(MemoryExecutionEnv());
      env.mountedRoot = '/Users/me/proj';
      final decorated = SecretsExecutionEnv(env, const {});
      expect(defaultHostToMountPath(decorated, '/Users/me/proj'), '/project');
    });

    test('at most one probe pass per folder (candidate list is short)', () {
      expect(FolderIconResolver.candidatePaths.length, lessThanOrEqualTo(6));
    });
  });
}
