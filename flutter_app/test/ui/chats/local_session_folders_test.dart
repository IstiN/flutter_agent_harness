// Copyright (c) 2026, the Flutter Agent Harness authors.

import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/local_session_folders.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The gradient is the folder's identity: the same cwd must always paint
  // the same two-stop HSL ramp, regardless of list order or display name.
  group('folder avatar gradient determinism', () {
    const cwd = '/Users/dev/projects/flutter_agent';

    test('same cwd → same start/end colors', () {
      final a = folderAvatarGradient(cwd);
      final b = folderAvatarGradient(cwd);
      expect(a.$1, b.$1);
      expect(a.$2, b.$2);
    });

    test('hue derives from the cwd path string', () {
      final hue = folderAvatarHue(cwd);
      expect(hue, cwd.hashCode.abs() % 360);
      final (start, end) = folderAvatarGradient(cwd);
      expect(start, HSLColor.fromAHSL(1, hue.toDouble(), 0.45, 0.42).toColor());
      expect(
        end,
        HSLColor.fromAHSL(1, ((hue + 32) % 360).toDouble(), 0.5, 0.3).toColor(),
      );
    });

    test('different cwds can diverge (sanity)', () {
      // Not a strict inequality proof, but the two project folders from the
      // golden fixtures must not collapse onto one ramp.
      final fa = folderAvatarGradient('/work/fa');
      final website = folderAvatarGradient('/work/website');
      expect(fa == website, isFalse);
    });
  });

  group('folder avatar letter', () {
    test('uppercase first rune of the trimmed basename', () {
      expect(folderAvatarLetter('flutter_agent'), 'F');
      expect(folderAvatarLetter('  fa  '), 'F');
      expect(folderAvatarLetter('мессенджер'), 'М');
    });

    test('empty falls back to "?"', () {
      expect(folderAvatarLetter(''), '?');
      expect(folderAvatarLetter('   '), '?');
    });
  });

  group('groupLocalSessionFolders', () {
    ChatListEntry entry(
      String id, {
      String? cwd,
      String? title,
      DateTime? activity,
      bool subagent = false,
      bool streaming = false,
      int unread = 0,
    }) => ChatListEntry(
      id: ChatEntryId.local(id),
      kind: ChatListEntryKind.localAgent,
      title: title ?? id,
      createdAt: DateTime.utc(2026, 1, 1),
      lastActivity: activity ?? DateTime.utc(2026, 1, 2),
      folderName: cwd == null ? null : cwd.split('/').last,
      folderPath: cwd,
      unreadCount: unread,
      isStreaming: streaming,
      isSubagent: subagent,
    );

    test('groups by cwd, sorts folders by most-recent session', () {
      final folders = groupLocalSessionFolders([
        entry('a', cwd: '/work/fa', activity: DateTime.utc(2026, 1, 2)),
        entry('b', cwd: '/work/website', activity: DateTime.utc(2026, 1, 5)),
        entry('c', cwd: '/work/fa', activity: DateTime.utc(2026, 1, 3)),
      ], personalName: 'Personal');

      // Sorted by each folder's most-recent session (website: Jan 5 > fa: Jan 3).
      expect(folders.map((f) => f.id), ['/work/website', '/work/fa']);
      expect(folders.last.name, 'fa');
      expect(folders.last.sessions.map((s) => s.id.value), ['c', 'a']);
      expect(folders.last.latestActivity, DateTime.utc(2026, 1, 3));
    });

    test('folder-less sessions land in one Personal group', () {
      final folders = groupLocalSessionFolders([
        entry('a'),
        entry('b', cwd: '/work/fa'),
        entry('c'),
      ], personalName: 'Personal');

      expect(folders.length, 2);
      final personal = folders.firstWhere((f) => f.id.isEmpty);
      expect(personal.name, 'Personal');
      expect(personal.personal, isTrue);
      expect(personal.sessions.map((s) => s.id.value), ['a', 'c']);
    });

    test('subagent rows never become folder sessions', () {
      final folders = groupLocalSessionFolders([
        entry('main', cwd: '/work/fa'),
        entry('child', cwd: '/work/fa', subagent: true),
      ], personalName: 'Personal');
      expect(folders.single.sessions.map((s) => s.id.value), ['main']);
    });

    test('running badge counts streaming rows per folder', () {
      final folders = groupLocalSessionFolders([
        entry('a', cwd: '/work/fa', streaming: true),
        entry('b', cwd: '/work/fa'),
        entry('c', cwd: '/work/web', streaming: true, unread: 2),
      ], personalName: 'Personal');
      expect(folders.first.folder, '/work/fa');
      expect(folders.first.runningCount, 1);
      expect(folders.last.runningCount, 1);
    });
  });
}
