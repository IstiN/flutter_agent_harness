// Issue #228 — sessions disappear in the Chrome extension. Pure-Dart pins
// for the four loss vectors in the web persistence layer, over FakeChrome's
// quota-enforcing storage:
//
//   vector 1 (eviction):  deleting one session must remove ONLY its record;
//                         a save must never drop live session keys.
//   vector 2 (version wipe): a v1 envelope migrates; an unreadable/newer
//                         envelope is backed up under faFs.bak BEFORE any
//                         save can overwrite it, and session records
//                         (version-independent keys) still restore.
//   vector 3 (torn/unload): session writes persist EAGERLY — a SW restart
//                         inside the old 800 ms debounce window must not
//                         lose the tail of a conversation.
//   vector 4 (one-key quota): sessions live as per-file records outside
//                         the monolith envelope, so one oversized session
//                         fails alone; unrelated saves keep working and
//                         previously-saved sessions stay byte-identical.
import 'dart:convert';

import 'package:test/test.dart';

import '../src/chrome_api.dart' show StorageApi;
import '../src/chrome_storage_env.dart';
import '../src/fake_chrome.dart';

/// Drains the microtask queue plus a few macrotask turns so fire-and-forget
/// persists (eager session saves, no fake timers involved) can settle
/// WITHOUT calling flush — flush would mask the loss vector being pinned.
Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

String v1Envelope({
  Map<String, String> files = const {},
  List<String> dirs = const [],
}) => jsonEncode({
  'version': 1,
  'dirs': dirs,
  'files': [
    for (final e in files.entries)
      {'path': e.key, 'data': base64Encode(utf8.encode(e.value))},
  ],
});

String b64(String text) => base64Encode(utf8.encode(text));

Map<String, dynamic> envelopeOf(Map<String, Object?> stored) =>
    jsonDecode(stored[ChromeStorageEnv.storageKey]! as String)
        as Map<String, dynamic>;

List<String> envelopeFilePaths(Map<String, Object?> stored) => [
  for (final f in envelopeOf(stored)['files'] as List)
    (f as Map)['path'] as String,
];

void main() {
  late FakeChrome chrome;
  late StorageApi storage;

  setUp(() {
    chrome = FakeChrome();
    storage = chrome.storage;
  });

  group('version safety (vector 2 — never wipe on version mismatch)', () {
    test('a v1 envelope migrates: sessions and files restore, then persist '
        'as v2 with sessions OUTSIDE the envelope', () async {
      await storage.set({
        ChromeStorageEnv.storageKey: v1Envelope(
          dirs: ['/notes'],
          files: {
            '/session.jsonl': '{"v":1}\n{"role":"user"}\n',
            '/notes/a.txt': 'alpha',
          },
        ),
      });

      final env = await ChromeStorageEnv.restore(storage: storage);
      expect(
        (await env.readTextFile('/session.jsonl')).valueOrNull,
        '{"v":1}\n{"role":"user"}\n',
      );
      expect((await env.readTextFile('/notes/a.txt')).valueOrNull, 'alpha');

      await env.writeFile('/b.txt', 'beta');
      await env.flush();

      final stored = await storage.get();
      final envelope = envelopeOf(stored);
      expect(envelope['version'], ChromeStorageEnv.snapshotVersion);
      // The session migrated out of the envelope into its own record.
      expect(envelopeFilePaths(stored), isNot(contains('/session.jsonl')));
      expect(envelopeFilePaths(stored), containsAll(['/notes/a.txt', '/b.txt']));
      expect(
        stored['${ChromeStorageEnv.sessionKeyPrefix}/session.jsonl'],
        b64('{"v":1}\n{"role":"user"}\n'),
      );
    });

    test('a NEWER-version envelope is backed up, never wiped; session '
        'records still restore', () async {
      final futureEnvelope = jsonEncode({
        'version': ChromeStorageEnv.snapshotVersion + 1,
        'dirs': <String>[],
        'files': <Object>[],
        'futureField': 'must-not-be-destroyed',
      });
      await storage.set({
        ChromeStorageEnv.storageKey: futureEnvelope,
        '${ChromeStorageEnv.sessionKeyPrefix}/session.jsonl': b64('HISTORY'),
      });

      final env = await ChromeStorageEnv.restore(storage: storage);
      // Version-independent session records survive the envelope bump.
      expect((await env.readTextFile('/session.jsonl')).valueOrNull, 'HISTORY');
      // The unreadable envelope is preserved under the backup key.
      final stored = await storage.get();
      expect(stored[ChromeStorageEnv.backupKey], futureEnvelope);

      // A subsequent save may replace the envelope — but the backup stays.
      await env.writeFile('/x.txt', 'x');
      await env.flush();
      final after = await storage.get();
      expect(after[ChromeStorageEnv.backupKey], futureEnvelope);
      expect(envelopeOf(after)['version'], ChromeStorageEnv.snapshotVersion);
    });

    test('a corrupt envelope is backed up and boot still restores session '
        'records', () async {
      await storage.set({
        ChromeStorageEnv.storageKey: '{not json at all',
        '${ChromeStorageEnv.sessionKeyPrefix}/session-abc.jsonl': b64('OLD'),
      });

      final env = await ChromeStorageEnv.restore(storage: storage);
      expect(
        (await env.readTextFile('/session-abc.jsonl')).valueOrNull,
        'OLD',
      );
      final stored = await storage.get();
      expect(stored[ChromeStorageEnv.backupKey], '{not json at all');
    });
  });

  group('eager session persist (vector 3 — unload inside the debounce '
      'window)', () {
    test('a session write survives a SW restart WITHOUT a flush', () async {
      final env = await ChromeStorageEnv.restore(storage: storage);
      await env.writeFile('/session.jsonl', '{"turn":1}\n');
      // NO flush: the service worker is reaped here. The 800 ms debounce
      // never fires — on the old code nothing reached storage.
      await settle();

      final reincarnated = await ChromeStorageEnv.restore(storage: storage);
      expect(
        (await reincarnated.readTextFile('/session.jsonl')).valueOrNull,
        '{"turn":1}\n',
      );
      env.dispose();
    });

    test('rapid session appends each reach storage without a flush', () async {
      final env = await ChromeStorageEnv.restore(storage: storage);
      await env.appendFile('/session.jsonl', 'a\n');
      await env.appendFile('/session.jsonl', 'b\n');
      await env.appendFile('/session.jsonl', 'c\n');
      await settle();

      final reincarnated = await ChromeStorageEnv.restore(storage: storage);
      expect(
        (await reincarnated.readTextFile('/session.jsonl')).valueOrNull,
        'a\nb\nc\n',
      );
      env.dispose();
    });

    test('non-session files keep the debounce (documented tradeoff)',
        () async {
      final env = await ChromeStorageEnv.restore(storage: storage);
      await env.writeFile('/scratch.txt', 'temp');
      await settle();
      expect(await storage.get(), isNot(contains(ChromeStorageEnv.storageKey)));
      await env.flush();
      expect(await storage.get(), contains(ChromeStorageEnv.storageKey));
      env.dispose();
    });
  });

  group('per-session storage records (vector 1 eviction / vector 4 '
      'monolith)', () {
    test('sessions live outside the monolith envelope', () async {
      final env = await ChromeStorageEnv.restore(storage: storage);
      await env.writeFile('/session.jsonl', 'S' * 2000);
      await env.writeFile('/app/data.txt', 'app-bytes');
      await env.flush();

      final stored = await storage.get();
      expect(
        stored.keys,
        containsAll([
          ChromeStorageEnv.storageKey,
          '${ChromeStorageEnv.sessionKeyPrefix}/session.jsonl',
        ]),
      );
      // The envelope carries neither the session path nor its bytes.
      expect(envelopeFilePaths(stored), ['/app/data.txt']);
      expect(
        stored[ChromeStorageEnv.storageKey]! as String,
        isNot(contains(b64('S' * 2000))),
      );
      env.dispose();
    });

    test('appending to one session rewrites ONLY that record', () async {
      final env = await ChromeStorageEnv.restore(storage: storage);
      await env.writeFile('/session-aaa.jsonl', 'one\n');
      await env.writeFile('/session-bbb.jsonl', 'two\n');
      await env.writeFile('/note.txt', 'n');
      await env.flush();

      final changedKeys = <String>{};
      final sub = storage.onChanged.listen((c) => changedKeys.add(c.key));
      await env.appendFile('/session-aaa.jsonl', 'more\n');
      await settle();
      await sub.cancel();

      expect(changedKeys, {'${ChromeStorageEnv.sessionKeyPrefix}/session-aaa.jsonl'});
      env.dispose();
    });

    test('deleting a session removes only its record; live records are '
        'never evicted by a save', () async {
      final env = await ChromeStorageEnv.restore(storage: storage);
      await env.writeFile('/session-aaa.jsonl', 'one\n');
      await env.writeFile('/session-bbb.jsonl', 'two\n');
      await env.flush();
      expect(
        await storage.get(),
        contains('${ChromeStorageEnv.sessionKeyPrefix}/session-aaa.jsonl'),
      );

      await env.remove('/session-aaa.jsonl');
      await env.flush();

      final stored = await storage.get();
      expect(
        stored,
        isNot(contains('${ChromeStorageEnv.sessionKeyPrefix}/session-aaa.jsonl')),
      );
      expect(
        stored['${ChromeStorageEnv.sessionKeyPrefix}/session-bbb.jsonl'],
        b64('two\n'),
      );
      expect(stored, contains(ChromeStorageEnv.storageKey));
      env.dispose();
    });
  });

  group('quota isolation (vector 4 — one oversized session fails alone)',
      () {
    test('an over-quota session does not block unrelated saves and leaves '
        'previously-saved sessions byte-identical', () async {
      chrome = FakeChrome(quotaBytes: 4000);
      storage = chrome.storage;

      final env = await ChromeStorageEnv.restore(storage: storage);
      await env.writeFile('/session-aaa.jsonl', 'A' * 400);
      await env.flush();
      final savedA =
          (await storage.get(['${ChromeStorageEnv.sessionKeyPrefix}/session-aaa.jsonl']))[
              '${ChromeStorageEnv.sessionKeyPrefix}/session-aaa.jsonl'];
      expect(savedA, isNotNull);

      // The oversized session can never fit: its record write fails, the
      // env stays dirty (surfaced, retried), but nothing else breaks.
      await env.writeFile('/session-big.jsonl', 'B' * 100000);
      await env.flush();
      expect(env.hasPendingChanges, isTrue);

      // Unrelated saves keep working: the envelope no longer carries
      // session bytes, so it still fits.
      await env.writeFile('/note.txt', 'tiny');
      await env.flush();

      final stored = await storage.get();
      // Vector 1/4: the previously-saved session was never dropped or
      // rewritten by the failing saves.
      expect(
        stored['${ChromeStorageEnv.sessionKeyPrefix}/session-aaa.jsonl'],
        savedA,
      );
      expect(envelopeFilePaths(stored), contains('/note.txt'));
      // Session-local damage: only the oversized record is missing.
      expect(
        stored,
        isNot(contains('${ChromeStorageEnv.sessionKeyPrefix}/session-big.jsonl')),
      );

      // After a restart: everything that fit survived.
      final reincarnated = await ChromeStorageEnv.restore(storage: storage);
      expect(
        (await reincarnated.readTextFile('/session-aaa.jsonl')).valueOrNull,
        'A' * 400,
      );
      expect((await reincarnated.readTextFile('/note.txt')).valueOrNull, 'tiny');
      expect(
        (await reincarnated.exists('/session-big.jsonl')).valueOrNull,
        isFalse,
      );
      env.dispose();
    });
  });

  group('round-trip', () {
    test('the full tree (dirs, files, sessions) survives a restart',
        () async {
      final env = await ChromeStorageEnv.restore(storage: storage);
      await env.createDir('/deep/nested');
      await env.writeFile('/deep/nested/f.txt', 'leaf');
      await env.writeFile('/session.jsonl', 'live\n');
      await env.writeFile('/session-old.jsonl', 'archived\n');
      await env.flush();

      final reincarnated = await ChromeStorageEnv.restore(storage: storage);
      expect(
        (await reincarnated.readTextFile('/deep/nested/f.txt')).valueOrNull,
        'leaf',
      );
      expect(
        (await reincarnated.readTextFile('/session.jsonl')).valueOrNull,
        'live\n',
      );
      expect(
        (await reincarnated.readTextFile('/session-old.jsonl')).valueOrNull,
        'archived\n',
      );
      env.dispose();
    });

    test('storage unavailable (null) runs memory-only without crashing',
        () async {
      final env = await ChromeStorageEnv.restore();
      await env.writeFile('/session.jsonl', 'x');
      await env.flush();
      expect((await env.readTextFile('/session.jsonl')).valueOrNull, 'x');
      env.dispose();
    });
  });
}
