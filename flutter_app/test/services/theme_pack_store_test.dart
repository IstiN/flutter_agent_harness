// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fa/services/theme_pack_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Store-level tests (issue #169): the zip install pipeline (entry
/// screening, validate-before-write), the E1 colors-only update, and the
/// E2 deleted-wallpaper fallback. The validator itself is covered by
/// `theme_packs_test.dart`.
void main() {
  // 1×1 transparent PNG — a real decodable image header prefix so the
  // extension/size screens are the only things that can reject it.
  final tinyPng = Uint8List.fromList([
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0,
    0,
    0,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    1,
    8,
    6,
    0,
    0,
    0,
    0x1F,
    0x15,
  ]);

  Uint8List zip(Map<String, List<int>> entries) {
    final archive = Archive();
    entries.forEach(
      (name, bytes) => archive.add(ArchiveFile.bytes(name, bytes)),
    );
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  /// A minimal stored-entry zip whose second entry is a unix symlink
  /// (`mode` S_IFLNK, creator 3, target as the content) — what a
  /// hand-crafted hostile archive looks like (archive's own encoder
  /// always writes an MSDOS creator byte and can't produce one).
  Uint8List maliciousSymlinkZip(
    String regularName,
    String linkName,
    String target,
  ) {
    int crc32(List<int> bytes) {
      var crc = 0xFFFFFFFF;
      for (final b in bytes) {
        crc ^= b;
        for (var i = 0; i < 8; i++) {
          crc = (crc >> 1) ^ (0xEDB88320 & -(crc & 1));
        }
      }
      return crc ^ 0xFFFFFFFF;
    }

    void le16(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);
    void le32(BytesBuilder b, int v) =>
        b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

    final local = BytesBuilder();
    final central = BytesBuilder();
    void entry(String name, List<int> content, {required int mode}) {
      final nameBytes = utf8.encode(name);
      final crc = crc32(content);
      final offset = local.length;

      local.add([0x50, 0x4B, 0x03, 0x04]);
      le16(local, 20); // version needed
      le16(local, 0); // flags
      le16(local, 0); // stored
      le16(local, 0); // time
      le16(local, 0); // date
      le32(local, crc);
      le32(local, content.length);
      le32(local, content.length);
      le16(local, nameBytes.length);
      le16(local, 0); // extra len
      local.add(nameBytes);
      local.add(content);

      central.add([0x50, 0x4B, 0x01, 0x02]);
      le16(central, (3 << 8) | 20); // version made by: unix (3)
      le16(central, 20); // version needed
      le16(central, 0); // flags
      le16(central, 0); // stored
      le16(central, 0); // time
      le16(central, 0); // date
      le32(central, crc);
      le32(central, content.length);
      le32(central, content.length);
      le16(central, nameBytes.length);
      le16(central, 0); // extra
      le16(central, 0); // comment
      le16(central, 0); // disk number
      le16(central, 0); // internal attrs
      le32(central, mode << 16); // external attrs: unix mode
      le32(central, offset);
      central.add(nameBytes);
    }

    entry(
      regularName,
      utf8.encode('{"name":"X","version":"1.0.0"}'),
      mode: 0x81A4,
    ); // regular file, 0644
    entry(linkName, utf8.encode(target), mode: 0xA1FF); // S_IFLNK | 0777

    final cdOffset = local.length;
    final cdSize = central.length;
    final eocd = BytesBuilder()
      ..add([0x50, 0x4B, 0x05, 0x06])
      ..add(List.filled(4, 0)) // disks
      ..add([2, 0, 2, 0]); // entries on disk / total
    le32(eocd, cdSize);
    le32(eocd, cdOffset);
    eocd.add([0, 0]); // comment len
    return (BytesBuilder()
          ..add(local.toBytes())
          ..add(central.toBytes())
          ..add(eocd.toBytes()))
        .toBytes();
  }

  Uint8List packZip({
    required String themeJson,
    String? assetName,
    List<int>? assetBytes,
    Map<String, List<int>> extra = const {},
  }) => zip({
    'theme.json': utf8.encode(themeJson),
    ?assetName: assetBytes ?? tinyPng,
    ...extra,
  });

  String themeJson({
    required String version,
    bool withWallpaper = false,
    String accent = '#2E7D32',
  }) => jsonEncode({
    'name': 'Forest Walk',
    'version': version,
    'colors': {
      'dark': {'accent': accent},
    },
    if (withWallpaper) 'wallpaper': {'asset': 'bg.png', 'fit': 'cover'},
  });

  test('installFromZip writes a pack and it survives a reload', () async {
    final env = MemoryExecutionEnv();
    final store = await ThemePackStore.load(env);

    final result = await store.installFromZip(
      packZip(
        themeJson: themeJson(version: '1.0.0', withWallpaper: true),
        assetName: 'bg.png',
      ),
    );
    expect(result.spec, isNotNull, reason: result.reasons.join('\n'));
    expect(store.packs.single.id, 'forest-walk');
    expect(store.packs.single.spec.wallpaper!.asset, 'bg.png');
    expect(store.packs.single.wallpaperBytes, tinyPng);

    final reloaded = await ThemePackStore.load(env);
    expect(reloaded.byId('forest-walk')!.spec.version, '1.0.0');
    expect(reloaded.byId('forest-walk')!.wallpaperBytes, tinyPng);
  });

  test(
    'a shared top-level folder is stripped (what compress-folder makes)',
    () async {
      final env = MemoryExecutionEnv();
      final store = await ThemePackStore.load(env);

      final result = await store.installFromZip(
        zip({
          'forest-walk/theme.json': utf8.encode(themeJson(version: '1.0.0')),
        }),
      );
      expect(result.spec, isNotNull, reason: result.reasons.join('\n'));
      expect(store.packs.single.id, 'forest-walk');
    },
  );

  test(
    'traversal and symlink entries reject before anything is written',
    () async {
      final env = MemoryExecutionEnv();
      final store = await ThemePackStore.load(env);

      final traversal = await store.installFromZip(
        zip({'../evil-theme.json': utf8.encode(themeJson(version: '1.0.0'))}),
      );
      expect(traversal.spec, isNull);
      // A real attacker zip: archive's own encoder writes an MSDOS creator
      // byte, which its decoder then never treats as a symlink — so build
      // the hostile entry by hand (unix creator + S_IFLNK mode, target as
      // the file content, exactly what Info-ZIP writes).
      final symlink = await store.installFromZip(
        maliciousSymlinkZip('theme.json', 'link', '../../outside'),
      );
      expect(symlink.spec, isNull);
      expect(symlink.reasons.join('\n'), contains('symbolic links'));

      expect(store.packs, isEmpty, reason: 'nothing may be written on reject');
      expect((await env.listDir('themes')).valueOrNull ?? const [], isEmpty);
    },
  );

  test('a stray extra file in the zip rejects the install', () async {
    final env = MemoryExecutionEnv();
    final store = await ThemePackStore.load(env);

    final result = await store.installFromZip(
      packZip(
        themeJson: themeJson(version: '1.0.0'),
        extra: {
          'payload.js': [1, 2, 3],
        },
      ),
    );
    expect(result.spec, isNull);
    expect(result.reasons.join('\n'), contains('unexpected file in pack'));
    expect(store.packs, isEmpty);
  });

  test('not a zip and missing theme.json reject', () async {
    final store = await ThemePackStore.load(MemoryExecutionEnv());

    final notZip = await store.installFromZip(Uint8List.fromList([1, 2, 3]));
    expect(notZip.spec, isNull);
    // Garbage bytes decode leniently in archive 4.x (an empty archive)
    // — either rejection reason is a correct outcome.
    expect(
      notZip.reasons.join('\n'),
      anyOf(contains('not a readable .zip'), contains('theme.json missing')),
    );

    final noJson = await store.installFromZip(
      zip({
        'readme.txt': [1],
      }),
    );
    expect(noJson.spec, isNull);
    expect(noJson.reasons.single, contains('theme.json missing'));
  });

  test('E1: an update re-validates, wipes and re-writes; the id (the active '
      'choice) survives', () async {
    final env = MemoryExecutionEnv();
    final store = await ThemePackStore.load(env);

    await store.installFromZip(
      packZip(
        themeJson: themeJson(version: '1.0.0', withWallpaper: true),
        assetName: 'bg.png',
      ),
    );
    expect(store.byId('forest-walk')!.spec.wallpaper, isNotNull);

    // The colors-only update replaces the whole directory (pinned
    // decision: wipe + re-write; the active id, not the files, is what
    // survives — the user re-applies in place).
    final update = await store.installFromZip(
      packZip(themeJson: themeJson(version: '2.0.0')),
    );
    expect(update.spec, isNotNull, reason: update.reasons.join('\n'));
    expect(store.byId('forest-walk')!.spec.version, '2.0.0');
    expect(store.byId('forest-walk')!.spec.wallpaper, isNull);
    expect(
      (await env.readBinaryFile('themes/forest-walk/bg.png')).valueOrNull,
      isNull,
      reason: 'the old wallpaper must not linger on disk',
    );

    // A reload of the same id sees only v2 — no stale v1 state.
    final reloaded = await ThemePackStore.load(env);
    expect(reloaded.byId('forest-walk')!.spec.version, '2.0.0');
  });

  test('E2: a wallpaper deleted after install loads colors-only', () async {
    final env = MemoryExecutionEnv();
    var store = await ThemePackStore.load(env);
    await store.installFromZip(
      packZip(
        themeJson: themeJson(version: '1.0.0', withWallpaper: true),
        assetName: 'bg.png',
      ),
    );

    await env.remove('themes/forest-walk/bg.png');
    store = await ThemePackStore.load(env);
    final pack = store.byId('forest-walk');
    expect(pack, isNotNull, reason: 'the pack must stay usable, never crash');
    expect(pack!.spec.wallpaper, isNull, reason: 'no phantom asset promises');
    expect(pack.spec.dark!.accent, isNotNull, reason: 'colors still apply');
    expect(pack.wallpaperBytes, isNull);
  });

  test('uninstall removes the directory and notifies', () async {
    final env = MemoryExecutionEnv();
    final store = await ThemePackStore.load(env);
    await store.installFromZip(packZip(themeJson: themeJson(version: '1.0.0')));
    var notifications = 0;
    store.addListener(() => notifications++);

    expect(await store.uninstall('forest-walk'), isTrue);
    expect(notifications, 1);
    expect(store.packs, isEmpty);
    expect(await store.uninstall('forest-walk'), isFalse);

    final reloaded = await ThemePackStore.load(env);
    expect(reloaded.packs, isEmpty);
  });
}
