// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dart_git/dart_git.dart';
import 'package:dart_git/plumbing/git_hash.dart';
import 'package:dart_git/plumbing/objects/object.dart';
import 'package:dart_git/plumbing/pack_file_delta.dart';
import 'package:dart_git/plumbing/reference.dart';
import 'package:http/http.dart' as http;

/// A minimal smart-HTTP (protocol v0) `git-upload-pack` client.
///
/// Clones any public HTTP(S) git remote without a system git binary:
///   1. `GET {url}/info/refs?service=git-upload-pack` (ref advertisement)
///   2. `POST {url}/git-upload-pack` with the wanted refs
///   3. Demuxes the side-band-64k response into a packfile
///   4. Imports every object (incl. ofs/ref deltas) as loose objects via
///      `dart_git` and checks out the default branch
///
/// Limitations: no authentication, no shallow clones, no protocol v2, no
/// resume. Good enough for `git clone` of public repositories on mobile/web.
final class GitSmartHttp {
  /// Creates a client using [client] for all requests.
  GitSmartHttp({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _userAgent = 'fah/1.0 (dart_git smart-http)';

  /// Clones [url] into [hostDir] and checks out the default branch.
  ///
  /// Returns the name of the checked-out branch.
  Future<String> cloneInto({
    required String url,
    required String hostDir,
  }) async {
    final advertisement = await _fetchRefs(url);
    if (advertisement.refs.isEmpty) {
      throw StateError('remote advertised no refs');
    }

    final branch = _pickDefaultBranch(advertisement);
    final branchRef = 'refs/heads/$branch';
    final wantHash = advertisement.refs[branchRef];
    if (wantHash == null) {
      throw StateError('remote has no ref $branchRef');
    }

    final packBytes = await _fetchPack(url, [wantHash]);

    GitRepository.init(hostDir);
    final repo = GitRepository.load(hostDir);

    final importer = _PackImporter();
    importer.import(packBytes, repo);

    // Write every advertised branch/tag ref, plus the origin/* tracking
    // refs so `git branch -r` and `git checkout origin/<branch>` work.
    for (final entry in advertisement.refs.entries) {
      if (!entry.key.startsWith('refs/')) continue;
      repo.refStorage.saveRef(
        HashReference(ReferenceName(entry.key), GitHash(entry.value)),
      );
      if (entry.key.startsWith('refs/heads/')) {
        final branch = entry.key.substring('refs/heads/'.length);
        repo.refStorage.saveRef(
          HashReference(
            ReferenceName.remote('origin', branch),
            GitHash(entry.value),
          ),
        );
      }
    }
    // Point HEAD at the default branch.
    repo.refStorage.saveRef(
      SymbolicReference(ReferenceName.HEAD(), ReferenceName.branch(branch)),
    );
    repo.addRemote('origin', url);

    // Materialize the working tree + index from HEAD. checkoutBranch would
    // diff HEAD against the same commit and write nothing, so do a full
    // tree checkout instead.
    repo.checkout(repo.workTree);
    repo.close();
    return branch;
  }

  /// Fetches all advertised branches of [url] into the repository at
  /// [hostDir], updating `refs/remotes/<remoteName>/*`.
  ///
  /// Returns the list of branch names whose remote ref moved.
  Future<List<String>> fetchInto({
    required String url,
    required String hostDir,
    required String remoteName,
  }) async {
    final advertisement = await _fetchRefs(url);
    final branchRefs = advertisement.refs.entries
        .where((e) => e.key.startsWith('refs/heads/'))
        .toList();
    if (branchRefs.isEmpty) {
      throw StateError('remote advertised no branches');
    }

    final repo = GitRepository.load(hostDir);

    // Only request commits we do not already have; writeObject skips
    // existing loose objects anyway, but this keeps the pack small when the
    // local repo is almost up to date.
    final missing = <String>[
      for (final entry in branchRefs)
        if (!_hasObject(repo, entry.value)) entry.value,
    ];
    if (missing.isNotEmpty) {
      final packBytes = await _fetchPack(url, missing);
      _PackImporter().import(packBytes, repo);
    }

    final moved = <String>[];
    for (final entry in branchRefs) {
      final branch = entry.key.substring('refs/heads/'.length);
      final refName = ReferenceName.remote(remoteName, branch);
      final existing = repo.resolveReferenceName(refName);
      if (existing == null || existing.hash.toString() != entry.value) {
        moved.add(branch);
      }
      repo.refStorage.saveRef(HashReference(refName, GitHash(entry.value)));
    }
    repo.close();
    return moved;
  }

  bool _hasObject(GitRepository repo, String hash) {
    try {
      repo.objStorage.read(GitHash(hash));
      return true;
    } on Object {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Protocol: ref advertisement
  // ---------------------------------------------------------------------------

  Future<_RefAdvertisement> _fetchRefs(String url) async {
    final uri = Uri.parse('$url/info/refs?service=git-upload-pack');
    final response = await _client.get(
      uri,
      headers: const {
        'Accept': 'application/x-git-upload-pack-advertisement',
        'User-Agent': _userAgent,
      },
    );
    if (response.statusCode != 200) {
      throw StateError('info/refs failed: HTTP ${response.statusCode}');
    }
    return _parseRefAdvertisement(response.bodyBytes);
  }

  String _pickDefaultBranch(_RefAdvertisement advertisement) {
    final symref = advertisement.headSymref;
    if (symref != null && symref.startsWith('refs/heads/')) {
      return symref.substring('refs/heads/'.length);
    }
    if (advertisement.refs.containsKey('refs/heads/main')) return 'main';
    if (advertisement.refs.containsKey('refs/heads/master')) return 'master';
    final branches = advertisement.refs.keys
        .where((k) => k.startsWith('refs/heads/'))
        .toList();
    if (branches.isEmpty) {
      throw StateError('remote advertised no branches');
    }
    branches.sort();
    return branches.first.substring('refs/heads/'.length);
  }

  // ---------------------------------------------------------------------------
  // Protocol: upload-pack request/response
  // ---------------------------------------------------------------------------

  Future<Uint8List> _fetchPack(String url, List<String> wantHashes) async {
    const capabilities =
        'multi_ack_detailed no-progress side-band-64k thin-pack ofs-delta '
        'agent=$_userAgent';
    final body = BytesBuilder(copy: false);
    for (var i = 0; i < wantHashes.length; i++) {
      final suffix = i == 0 ? ' $capabilities' : '';
      body.add(_pktLine(utf8.encode('want ${wantHashes[i]}$suffix\n')));
    }
    body
      ..add(_pktFlush())
      ..add(_pktLine(utf8.encode('done\n')));

    final response = await _client.post(
      Uri.parse('$url/git-upload-pack'),
      headers: const {
        'Content-Type': 'application/x-git-upload-pack-request',
        'Accept': 'application/x-git-upload-pack-result',
        'User-Agent': _userAgent,
      },
      body: body.takeBytes(),
    );
    if (response.statusCode != 200) {
      throw StateError('git-upload-pack failed: HTTP ${response.statusCode}');
    }
    return _demuxSideband(response.bodyBytes);
  }

  /// Extracts the packfile bytes from an upload-pack response, handling both
  /// side-band-64k multiplexed streams and plain responses.
  Uint8List _demuxSideband(Uint8List bytes) {
    // Fast path: the whole body is (or contains) a raw packfile.
    final packStart = _indexOfPack(bytes);
    if (packStart == 0) return bytes;

    final packData = BytesBuilder(copy: false);
    final reader = _PktReader(bytes);
    String? error;
    while (reader.hasNext) {
      final payload = reader.next();
      if (payload == null) break; // flush pkt
      if (payload.isEmpty) continue;
      // NAK/ACK lines are plain text before the pack.
      if (_startsWithAscii(payload, 'NAK') ||
          _startsWithAscii(payload, 'ACK')) {
        continue;
      }
      final channel = payload[0];
      switch (channel) {
        case 1:
          packData.add(payload.sublist(1));
        case 2:
        // Progress messages: ignored (no-progress requested anyway).
        case 3:
          error = utf8.decode(payload.sublist(1), allowMalformed: true).trim();
        default:
          // Not a side-band stream after all: fall back to scanning.
          final start = _indexOfPack(bytes);
          if (start == -1) {
            throw StateError('upload-pack response contains no packfile');
          }
          return bytes.sublist(start);
      }
    }
    if (error != null) {
      throw StateError('remote error: $error');
    }
    final result = packData.takeBytes();
    if (result.length < 12 || _indexOfPack(result) != 0) {
      throw StateError('upload-pack response contains no packfile');
    }
    return result;
  }

  int _indexOfPack(Uint8List bytes) {
    for (var i = 0; i + 4 <= bytes.length; i++) {
      if (bytes[i] == 0x50 && // P
          bytes[i + 1] == 0x41 && // A
          bytes[i + 2] == 0x43 && // C
          bytes[i + 3] == 0x4b) {
        // K
        return i;
      }
    }
    return -1;
  }

  bool _startsWithAscii(Uint8List bytes, String prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix.codeUnitAt(i)) return false;
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // pkt-line helpers
  // ---------------------------------------------------------------------------

  Uint8List _pktLine(List<int> payload) {
    final length = payload.length + 4;
    final hex = length.toRadixString(16).padLeft(4, '0');
    return Uint8List.fromList([...ascii.encode(hex), ...payload]);
  }

  Uint8List _pktFlush() => Uint8List.fromList(ascii.encode('0000'));

  /// Parses a ref advertisement body into a map of refs and the HEAD symref.
  _RefAdvertisement _parseRefAdvertisement(Uint8List bytes) {
    final refs = <String, String>{};
    String? headSymref;
    final reader = _PktReader(bytes);
    var isFirstRef = true;
    while (reader.hasNext) {
      final payload = reader.next();
      if (payload == null) continue; // flush pkt: keep reading
      var line = utf8.decode(payload, allowMalformed: true);
      if (line.endsWith('\n')) line = line.substring(0, line.length - 1);
      if (line.startsWith('#')) continue; // "# service=..." banner
      if (line.isEmpty) continue;

      if (isFirstRef) {
        final nul = line.indexOf('\x00');
        if (nul != -1) {
          final capabilities = line.substring(nul + 1).split(' ');
          for (final cap in capabilities) {
            if (cap.startsWith('symref=HEAD:')) {
              headSymref = cap.substring('symref=HEAD:'.length);
            }
          }
          line = line.substring(0, nul);
        }
        isFirstRef = false;
      }

      final space = line.indexOf(' ');
      if (space <= 0) continue;
      final hash = line.substring(0, space);
      final name = line.substring(space + 1);
      if (hash.length == 40) refs[name] = hash;
    }
    return _RefAdvertisement(refs: refs, headSymref: headSymref);
  }
}

final class _RefAdvertisement {
  _RefAdvertisement({required this.refs, this.headSymref});

  final Map<String, String> refs;
  final String? headSymref;
}

/// Sequential pkt-line reader over a byte buffer.
final class _PktReader {
  _PktReader(this._bytes);

  final Uint8List _bytes;
  int _pos = 0;

  bool get hasNext => _pos + 4 <= _bytes.length;

  /// Returns the next payload, `null` for a flush pkt (0000).
  Uint8List? next() {
    if (!hasNext) throw StateError('pkt-line: unexpected end of stream');
    final hex = ascii.decode(_bytes.sublist(_pos, _pos + 4));
    final length = int.parse(hex, radix: 16);
    _pos += 4;
    if (length == 0) return null;
    if (length < 4 || _pos + length - 4 > _bytes.length) {
      throw StateError('pkt-line: invalid length $length');
    }
    final payload = _bytes.sublist(_pos, _pos + length - 4);
    _pos += length - 4;
    return payload;
  }
}

/// Imports packfile objects into a [GitRepository] as loose objects.
final class _PackImporter {
  final _resolvedByOffset = <int, ({int type, Uint8List data})>{};
  final _resolvedByHash = <String, ({int type, Uint8List data})>{};
  final _rawByOffset = <int, _RawPackObject>{};
  final _raws = <_RawPackObject>[];

  static const _typeNames = {1: 'commit', 2: 'tree', 3: 'blob', 4: 'tag'};

  /// Parses [packBytes] and writes every object into [repo]'s object storage.
  void import(Uint8List packBytes, GitRepository repo) {
    _parseAll(packBytes);

    final pending = List<_RawPackObject>.from(_raws);
    var progressed = true;
    while (pending.isNotEmpty && progressed) {
      progressed = false;
      for (var i = pending.length - 1; i >= 0; i--) {
        final resolved = _tryResolve(pending[i]);
        if (resolved != null) {
          pending.removeAt(i);
          progressed = true;
        }
      }
    }
    if (pending.isNotEmpty) {
      throw StateError(
        'pack: ${pending.length} objects have unresolvable delta bases',
      );
    }

    for (final raw in _raws) {
      final obj = _resolvedByOffset[raw.offset]!;
      final hash = _hashObject(obj.type, obj.data);
      final gitObject = createObject(obj.type, obj.data, hash);
      repo.objStorage.writeObject(gitObject);
    }
  }

  void _parseAll(Uint8List packBytes) {
    if (packBytes.length < 12 ||
        ascii.decode(packBytes.sublist(0, 4)) != 'PACK') {
      throw StateError('pack: invalid header');
    }
    final header = ByteData.sublistView(packBytes, 0, 12);
    if (header.getUint32(4) != 2) {
      throw StateError('pack: unsupported version ${header.getUint32(4)}');
    }
    final count = header.getUint32(8);
    var pos = 12;

    for (var i = 0; i < count; i++) {
      final objOffset = pos;
      final objectHeader = _readObjectHeader(packBytes, pos);
      pos = objectHeader.dataStart;

      final inflated = _inflate(packBytes, pos, objectHeader.size);
      pos += inflated.consumed;

      final raw = _RawPackObject(
        offset: objOffset,
        type: objectHeader.type,
        data: inflated.data,
        baseOffset: objectHeader.baseOffset,
        baseHash: objectHeader.baseHash,
      );
      _raws.add(raw);
      _rawByOffset[objOffset] = raw;
    }
  }

  _PackObjectHeader _readObjectHeader(Uint8List packBytes, int pos) {
    final objOffset = pos;

    // Type + size varint.
    var byte = packBytes[pos++];
    final type = (byte >> 4) & 0x07;
    if (type == 0 || type == 5) {
      throw StateError('pack: invalid object type byte at $objOffset');
    }
    var size = byte & 0x0f;
    var shift = 4;
    while (byte & 0x80 != 0) {
      byte = packBytes[pos++];
      size |= (byte & 0x7f) << shift;
      shift += 7;
    }

    int? baseOffset;
    String? baseHash;
    if (type == 6) {
      // OFS_DELTA: negative offset varint.
      var c = packBytes[pos++];
      var n = c & 0x7f;
      while (c & 0x80 != 0) {
        c = packBytes[pos++];
        n = ((n + 1) << 7) | (c & 0x7f);
      }
      baseOffset = objOffset - n;
    } else if (type == 7) {
      // REF_DELTA: 20-byte base sha1.
      baseHash = _hex(packBytes.sublist(pos, pos + 20));
      pos += 20;
    }

    return _PackObjectHeader(
      type: type,
      size: size,
      dataStart: pos,
      baseOffset: baseOffset,
      baseHash: baseHash,
    );
  }

  ({int type, Uint8List data})? _tryResolve(_RawPackObject raw) {
    final cached = _resolvedByOffset[raw.offset];
    if (cached != null) return cached;

    ({int type, Uint8List data})? resolved;
    if (raw.type >= 1 && raw.type <= 4) {
      resolved = (type: raw.type, data: raw.data);
    } else if (raw.type == 6) {
      final baseRaw = _rawByOffset[raw.baseOffset];
      if (baseRaw == null) return null;
      final base = _tryResolve(baseRaw);
      if (base == null) return null;
      resolved = (type: base.type, data: patchDelta(base.data, raw.data));
    } else if (raw.type == 7) {
      final base = _resolvedByHash[raw.baseHash];
      if (base == null) return null;
      resolved = (type: base.type, data: patchDelta(base.data, raw.data));
    } else {
      throw StateError('pack: unsupported object type ${raw.type}');
    }

    _resolvedByOffset[raw.offset] = resolved;
    _resolvedByHash[_hashObject(resolved.type, resolved.data).toString()] =
        resolved;
    return resolved;
  }

  GitHash _hashObject(int type, Uint8List data) {
    final name = _typeNames[type];
    if (name == null) throw StateError('pack: unsupported object type $type');
    final envelope = BytesBuilder(copy: false)
      ..add(ascii.encode('$name ${data.length}'))
      ..addByte(0)
      ..add(data);
    return GitHash.compute(envelope.takeBytes());
  }

  /// Inflates exactly [size] bytes of zlib data starting at [start] and
  /// reports how many input bytes the compressed stream occupied, including
  /// the 2-byte zlib header and the 4-byte adler32 trailer.
  ///
  /// Uses the pure-Dart [Inflate] from package:archive, whose [InputStream]
  /// reports the exact end of the deflate stream — dart:io's zlib decoder
  /// cannot report how many input bytes were consumed.
  ({Uint8List data, int consumed}) _inflate(
    Uint8List buf,
    int start,
    int size,
  ) {
    final input = InputMemoryStream(buf, offset: start + 2);
    final inflate = Inflate.stream(input, uncompressedSize: size);
    final out = Uint8List.fromList(inflate.getBytes());
    if (out.length < size) {
      throw StateError('pack: failed to inflate object at offset $start');
    }
    final data = out.length == size
        ? out
        : Uint8List.fromList(out.sublist(0, size));
    return (data: data, consumed: 2 + input.position + 4);
  }

  String _hex(Uint8List bytes) {
    final buffer = StringBuffer();
    for (final b in bytes) {
      buffer.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}

final class _PackObjectHeader {
  _PackObjectHeader({
    required this.type,
    required this.size,
    required this.dataStart,
    this.baseOffset,
    this.baseHash,
  });

  final int type;
  final int size;
  final int dataStart;
  final int? baseOffset;
  final String? baseHash;
}

final class _RawPackObject {
  _RawPackObject({
    required this.offset,
    required this.type,
    required this.data,
    this.baseOffset,
    this.baseHash,
  });

  final int offset;
  final int type;
  final Uint8List data;
  final int? baseOffset;
  final String? baseHash;
}
