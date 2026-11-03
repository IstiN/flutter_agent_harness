@TestOn('vm')
/// Unit tests for the deterministic folder avatar + the well-known icon
/// resolver (yoloit tier-1/tier-2 port): the gradient derives from the
/// cwd string, the letter is the first rune, and a folder icon file at
/// one of the short candidate paths wins over the letter — resolved
/// through the session env, cached, never a deep scan.
library;

import 'dart:typed_data';

import 'package:fa/ui/chats/local_session_folders.dart';
import 'package:fa/ui/widgets/folder_avatar.dart';
import 'package:flutter/painting.dart' show Color, HSLColor;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reads a color's hue through Flutter's HSL conversion (the algorithm's
/// own math).
double hueOf(Color color) => HSLColor.fromColor(color).hue;

void main() {
  group('avatar algorithm', () {
    test('hue derives from the cwd path string', () {
      expect(
        folderAvatarHue('/work/flutter_agent'),
        '/work/flutter_agent'.hashCode.abs() % 360,
      );
    });

    test('same cwd → same gradient stops (determinism)', () {
      final (aStart, aEnd) = folderAvatarGradient('/work/flutter_agent');
      final (bStart, bEnd) = folderAvatarGradient('/work/flutter_agent');
      expect(aStart, bStart);
      expect(aEnd, bEnd);
      // The two-stop ramp: hue → hue+32, S .45→.5, L .42→.3.
      final startHue = hueOf(aStart);
      final endHue = hueOf(aEnd);
      expect((endHue - startHue + 360) % 360, closeTo(32, 0.5));
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
    test('a well-known icon file wins and is cached per folder', () async {
      final env = MemoryExecutionEnv();
      const bytes = <int>[1, 2, 3, 4];
      await env.writeFile('/work/mono/icon.png', String.fromCharCodes(bytes));
      final resolver = FolderIconResolver(env);

      final first = await resolver.resolve('/work/mono');
      expect(first, isNotNull);
      expect(first!.bytes, Uint8List.fromList(bytes));

      // The cache hands back the same resolved image, not a second probe.
      final cached = await resolver.resolve('/work/mono');
      expect(identical(cached, first), isTrue);
    });

    test('folders without an icon resolve to null (gradient letter)', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('/work/plain/README.md', 'no icon here');
      final resolver = FolderIconResolver(env);
      expect(await resolver.resolve('/work/plain'), isNull);
      // An unreadable root degrades to the fallback, never throws.
      expect(await resolver.resolve('/does/not/exist'), isNull);
    });

    test('at most one probe pass per folder (candidate list is short)', () {
      expect(FolderIconResolver.candidatePaths.length, lessThanOrEqualTo(6));
    });
  });
}
