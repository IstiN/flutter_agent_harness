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
import 'package:dart_git/utils/file_mode.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:http/http.dart' as http;

/// Wire transport for the git smart protocol: ref advertisements and RPC
/// bodies (upload-pack / receive-pack).
abstract class GitTransport {
  /// Fetches the ref advertisement for [service].
  Future<Uint8List> advertise(String service);

  /// Runs an RPC call against [service] with [body] and returns the response.
  Future<Uint8List> rpc(String service, Uint8List body);
}

/// Smart-HTTP transport (protocol v0 over plain HTTP(S), optional token auth).
final class HttpGitTransport implements GitTransport {
  /// Creates a transport for [url] using [client], optionally with [token]
  /// for Basic auth (GitHub PAT).
  HttpGitTransport({required this.url, required this.client, this.token});

  /// Repository base URL, e.g. `https://github.com/owner/repo.git`.
  final String url;

  /// Optional token for HTTP Basic auth.
  final String? token;

  /// HTTP client used for requests.
  final http.Client client;

  static const _userAgent = 'fah/1.0';

  @override
  Future<Uint8List> advertise(String service) async {
    final uri = Uri.parse('$url/info/refs?service=$service');
    final response = await client.get(
      uri,
      headers: {
        'Accept': 'application/x-$service-advertisement',
        'User-Agent': _userAgent,
        ...?_authHeaders(),
      },
    );
    if (response.statusCode != 200) {
      throw StateError('info/refs failed: HTTP ${response.statusCode}');
    }
    return response.bodyBytes;
  }

  @override
  Future<Uint8List> rpc(String service, Uint8List body) async {
    final response = await client.post(
      Uri.parse('$url/$service'),
      headers: {
        'Content-Type': 'application/x-$service-request',
        'Accept': 'application/x-$service-result',
        'User-Agent': _userAgent,
        ...?_authHeaders(),
      },
      body: body,
    );
    if (response.statusCode != 200) {
      throw StateError('$service failed: HTTP ${response.statusCode}');
    }
    return response.bodyBytes;
  }

  /// Builds auth headers for GitHub-style token auth. The token may come
  /// from [token] or from the URL userinfo (`https://user:token@host/...`).
  Map<String, String>? _authHeaders() {
    var effective = token;
    if (effective == null) {
      final uri = Uri.parse(url);
      if (uri.userInfo.isNotEmpty) {
        effective = uri.userInfo.split(':').last;
      }
    }
    if (effective == null || effective.isEmpty) return null;
    final basic = base64Encode(utf8.encode('x-access-token:$effective'));
    return {'Authorization': 'Basic $basic'};
  }
}

/// SSH transport (`git@host:owner/repo.git`) via package:dartssh2 — no system
/// ssh binary needed, works on iOS/Android.
final class SshGitTransport implements GitTransport {
  /// Creates a transport for the repository at [repoPath] on [host].
  SshGitTransport({
    required this.host,
    required this.username,
    required this.repoPath,
    required this.privateKeyPem,
    this.port = 22,
  });

  /// SSH host, e.g. `github.com`.
  final String host;

  /// SSH username, e.g. `git`.
  final String username;

  /// Repository path on the host, e.g. `/owner/repo.git`.
  final String repoPath;

  /// PEM-encoded private key (OpenSSH format).
  final String privateKeyPem;

  /// SSH port (defaults to 22).
  final int port;

  @override
  Future<Uint8List> advertise(String service) => _exec(service, null);

  @override
  Future<Uint8List> rpc(String service, Uint8List body) => _exec(service, body);

  Future<Uint8List> _exec(String service, Uint8List? body) async {
    final socket = await SSHSocket.connect(host, port);
    final client = SSHClient(
      socket,
      username: username,
      identities: SSHKeyPair.fromPem(privateKeyPem),
      // The sandbox has no known_hosts store; host key pinning is the
      // caller's responsibility (same trade-off as GIT_SSH_COMMAND wrappers).
      disableHostkeyVerification: true,
    );
    try {
      final session = await client.execute("$service '$repoPath'");
      if (body != null) {
        session.stdin.add(body);
      }
      await session.stdin.close();

      final out = BytesBuilder(copy: false);
      final err = BytesBuilder(copy: false);
      await Future.wait<void>([
        session.stdout.forEach(out.add),
        session.stderr.forEach(err.add),
      ]);
      final stderrText = utf8.decode(err.takeBytes(), allowMalformed: true);
      final stdout = out.takeBytes();
      if (stdout.isEmpty && stderrText.trim().isNotEmpty) {
        throw StateError('ssh $service failed: ${stderrText.trim()}');
      }
      return stdout;
    } finally {
      client.close();
    }
  }
}

/// A minimal smart protocol v0 git client (`git-upload-pack` /
/// `git-receive-pack`).
///
/// Clones, fetches, and pushes to any public HTTP(S) or SSH git remote
/// without a system git binary:
///   1. ref advertisement (pkt-line, `symref=HEAD` for the default branch)
///   2. want/done negotiation, side-band-64k demuxing into a packfile
///   3. imports every object (incl. ofs/ref deltas) as loose objects via
///      `dart_git` and checks out the default branch
///   4. pushes by building a full-object packfile and sending receive-pack
///      commands, verifying `report-status`
///
/// Limitations: no shallow clones, no protocol v2, no resume, no delta
/// compression on push. Good enough for everyday clone/fetch/push of public
/// repositories on mobile/web.
final class GitSmartHttp {
  /// Creates a client. When [transport] is null a smart-HTTP transport is
  /// used per call; pass an [SshGitTransport] for `git@host:` URLs.
  GitSmartHttp({http.Client? client, this.transport})
    : _client = client ?? http.Client();

  final http.Client _client;

  /// Optional transport override (e.g. [SshGitTransport]); when null a
  /// smart-HTTP transport is created per call.
  final GitTransport? transport;

  static const _userAgent = 'fah/1.0';

  GitTransport _transportFor(String url, String? token) {
    return transport ??
        HttpGitTransport(url: url, client: _client, token: token);
  }

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
  // Protocol: push (git-receive-pack)
  // ---------------------------------------------------------------------------

  /// Pushes the local [branch] of the repository at [hostDir] to [url].
  ///
  /// [token] is used for HTTP Basic auth (GitHub PAT). Returns the remote's
  /// report-status text (`unpack ok ...`) or throws on rejection.
  Future<String> pushInto({
    required String url,
    required String hostDir,
    required String branch,
    String? token,
  }) async {
    final repo = GitRepository.load(hostDir);
    final localRef = repo.resolveReferenceName(ReferenceName.branch(branch));
    if (localRef == null) {
      throw StateError("error: src refspec $branch does not match any");
    }
    final localHash = localRef.hash;
    final remoteRefName = 'refs/heads/$branch';

    final advertisement = await _fetchRefs(
      url,
      service: 'git-receive-pack',
      token: token,
    );
    final remoteHash = advertisement.refs[remoteRefName];
    if (remoteHash == localHash.toString()) {
      return 'Everything up-to-date';
    }
    if (remoteHash != null &&
        !_isAncestor(repo, GitHash(remoteHash), localHash)) {
      throw StateError(
        'failed to push some refs (non-fast-forward; fetch first)',
      );
    }

    final objects = _collectObjects(
      repo,
      from: localHash,
      stopAt: remoteHash != null ? GitHash(remoteHash) : null,
    );
    final pack = _buildPack(objects);

    final oldHash = remoteHash ?? '0000000000000000000000000000000000000000';
    final body = BytesBuilder(copy: false)
      ..add(
        _pktLine(
          utf8.encode(
            '$oldHash $localHash $remoteRefName\x00'
            'report-status side-band-64k agent=$_userAgent\n',
          ),
        ),
      )
      ..add(_pktFlush())
      ..add(pack);

    final response = await _transportFor(
      url,
      token,
    ).rpc('git-receive-pack', body.takeBytes());
    return _parseReportStatus(response);
  }

  /// Walks the object graph from [from] to (but excluding) [stopAt] and
  /// returns every commit, tree, and blob that must be sent to the remote.
  List<({int type, Uint8List data})> _collectObjects(
    GitRepository repo, {
    required GitHash from,
    GitHash? stopAt,
  }) {
    const typeByName = {'commit': 1, 'tree': 2, 'blob': 3, 'tag': 4};
    final seen = <String>{};
    final result = <({int type, Uint8List data})>[];

    void addObject(GitHash hash) {
      if (!seen.add(hash.toString())) return;
      final obj = repo.objStorage.read(hash);
      if (obj == null) throw StateError('missing object $hash');
      result.add((
        type: typeByName[obj.formatStr()]!,
        data: obj.serializeData(),
      ));
    }

    void walkTree(GitHash treeHash) {
      addObject(treeHash);
      final tree = repo.objStorage.readTree(treeHash);
      for (final entry in tree.entries) {
        if (entry.mode == GitFileMode.Dir) {
          walkTree(entry.hash);
        } else {
          addObject(entry.hash);
        }
      }
    }

    final queue = <GitHash>[from];
    while (queue.isNotEmpty) {
      final hash = queue.removeAt(0);
      if (stopAt != null && hash == stopAt) continue;
      if (seen.contains(hash.toString())) continue;
      final commit = repo.objStorage.readCommit(hash);
      addObject(hash);
      walkTree(commit.treeHash);
      queue.addAll(commit.parents);
    }
    return result;
  }

  bool _isAncestor(GitRepository repo, GitHash ancestor, GitHash child) {
    final queue = <GitHash>[child];
    final seen = <String>{};
    while (queue.isNotEmpty) {
      final hash = queue.removeAt(0);
      if (hash == ancestor) return true;
      if (!seen.add(hash.toString())) continue;
      final commit = repo.objStorage.readCommit(hash);
      queue.addAll(commit.parents);
    }
    return false;
  }

  /// Serializes objects into a packfile (no deltas: every object is stored
  /// in full, zlib-deflated).
  Uint8List _buildPack(List<({int type, Uint8List data})> objects) {
    final out = BytesBuilder(copy: false)..add(ascii.encode('PACK'));
    final meta = ByteData(8)
      ..setUint32(0, 2)
      ..setUint32(4, objects.length);
    out.add(meta.buffer.asUint8List());

    for (final obj in objects) {
      // Type + size varint (4 bits in the first byte, then 7 per byte).
      var size = obj.data.length;
      final first = (obj.type << 4) | (size & 0x0f);
      size >>= 4;
      final headerBytes = <int>[];
      if (size == 0) {
        headerBytes.add(first);
      } else {
        headerBytes.add(first | 0x80);
        while (size > 0x7f) {
          headerBytes.add((size & 0x7f) | 0x80);
          size >>= 7;
        }
        headerBytes.add(size);
      }
      out.add(headerBytes);
      out.add(ZLibEncoder().encode(obj.data));
    }

    out.add(GitHash.compute(out.toBytes()).bytes);
    return out.takeBytes();
  }

  /// Parses a receive-pack report-status response, tolerating both
  /// side-band-64k framing (HTTP) and plain pkt-line text (SSH).
  String _parseReportStatus(Uint8List bytes) {
    final reader = _PktReader(bytes);
    final status = StringBuffer();
    String? error;
    while (reader.hasNext) {
      final payload = reader.next();
      // Flush pkts separate the (SSH) ref advertisement from the actual
      // report-status: skip them and keep reading.
      if (payload == null) continue;
      if (payload.isEmpty) continue;
      String text;
      final channel = payload[0];
      if (channel >= 1 && channel <= 3) {
        text = utf8.decode(payload.sublist(1), allowMalformed: true);
      } else {
        // Plain (non-side-band) report-status lines.
        text = utf8.decode(payload, allowMalformed: true);
      }
      if (channel == 3) {
        error = text.trim();
      } else {
        status.write(text);
      }
    }
    if (error != null) {
      throw StateError('remote error: $error');
    }
    final report = status.toString();
    if (!report.contains('unpack ok')) {
      throw StateError(
        'push rejected: ${report.trim().isEmpty ? 'no report-status' : report.trim()}',
      );
    }
    for (final line in report.split('\n')) {
      if (line.startsWith('ng ')) {
        throw StateError('push rejected: $line');
      }
    }
    return report.trim();
  }

  // ---------------------------------------------------------------------------
  // Protocol: ref advertisement
  // ---------------------------------------------------------------------------

  Future<_RefAdvertisement> _fetchRefs(
    String url, {
    String service = 'git-upload-pack',
    String? token,
  }) async {
    final body = await _transportFor(url, token).advertise(service);
    return _parseRefAdvertisement(body);
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

  Future<Uint8List> _fetchPack(
    String url,
    List<String> wantHashes, {
    String? token,
  }) async {
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

    final response = await _transportFor(
      url,
      token,
    ).rpc('git-upload-pack', body.takeBytes());
    return _demuxSideband(response);
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
