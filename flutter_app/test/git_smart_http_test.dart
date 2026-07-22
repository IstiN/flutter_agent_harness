import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_git/dart_git.dart';
import 'package:flutter/foundation.dart';
import 'package:fa/git_smart_http.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Requires dart:io (HttpServer, dart_git on the host FS): host-only test.
  if (kIsWeb) return;

  group('GitSmartHttp', () {
    late HttpServer server;
    late int port;

    setUpAll(() async {
      final advertisement = File(
        'test/fixtures/upload_pack_advertisement.bin',
      ).readAsBytesSync();
      final packResponse = File(
        'test/fixtures/upload_pack_response.bin',
      ).readAsBytesSync();

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      port = server.port;
      unawaited(
        server.forEach((request) async {
          if (request.uri.path.endsWith('/info/refs')) {
            expect(
              request.uri.queryParameters['service'],
              'git-upload-pack',
              reason: 'client must ask for the upload-pack service',
            );
            request.response
              ..headers.contentType = ContentType(
                'application',
                'x-git-upload-pack-advertisement',
              )
              ..add(advertisement);
          } else if (request.uri.path.endsWith('/git-upload-pack')) {
            final body = await request.fold<List<int>>(
              <int>[],
              (acc, chunk) => acc..addAll(chunk),
            );
            final bodyText = String.fromCharCodes(body);
            expect(
              bodyText,
              contains('want b3c1526fe274e47d3270da3412314fa25b86c779'),
              reason: 'client must request the advertised HEAD hash',
            );
            expect(bodyText, contains('side-band-64k'));
            expect(bodyText, contains('done'));
            request.response
              ..headers.contentType = ContentType(
                'application',
                'x-git-upload-pack-result',
              )
              ..add(packResponse);
          } else {
            request.response.statusCode = HttpStatus.notFound;
          }
          await request.response.close();
        }),
      );
    });

    tearDownAll(() async {
      await server.close(force: true);
    });

    test('clones a repository over smart HTTP from fixture bytes', () async {
      final tmp = Directory.systemTemp.createTempSync('fah_git_smart_test');
      addTearDown(() => tmp.delete(recursive: true));

      final branch = await GitSmartHttp().cloneInto(
        url: 'http://127.0.0.1:$port/repo.git',
        hostDir: tmp.path,
      );

      expect(branch, 'main', reason: 'HEAD symref points at refs/heads/main');
      expect(Directory('${tmp.path}/.git').existsSync(), isTrue);

      // The checkout materialized the working tree from the pack.
      final entries = tmp.listSync().where((e) => !e.path.endsWith('.git'));
      expect(entries, isNotEmpty, reason: 'checkout must write files');

      // The full object graph is present: HEAD commit resolves and the log
      // walks the parent chain.
      final repo = GitRepository.load(tmp.path);
      final head = repo.headCommit();
      expect(head.message.trim(), isNotEmpty);
      var count = 0;
      var commit = head;
      while (true) {
        count++;
        if (commit.parents.isEmpty) break;
        commit = repo.objStorage.readCommit(commit.parents.first);
      }
      expect(count, greaterThanOrEqualTo(1));
      expect(repo.currentBranch(), 'main');
      expect(repo.branches(), contains('main'));

      final origin = repo.config.remote('origin');
      expect(origin?.url, contains('127.0.0.1:$port'));
      repo.close();
    });

    test('fails cleanly on a non-git HTTP endpoint', () async {
      final tmp = Directory.systemTemp.createTempSync('fah_git_smart_test');
      addTearDown(() => tmp.delete(recursive: true));

      final plain = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => plain.close(force: true));
      unawaited(
        plain.forEach((request) async {
          request.response.write('not a git server');
          await request.response.close();
        }),
      );

      expect(
        () => GitSmartHttp().cloneInto(
          url: 'http://127.0.0.1:${plain.port}/x',
          hostDir: tmp.path,
        ),
        throwsA(anything),
      );
    });

    test('pushes a commit over git-receive-pack with token auth', () async {
      final advertisement = File(
        'test/fixtures/upload_pack_advertisement.bin',
      ).readAsBytesSync();
      final packResponse = File(
        'test/fixtures/upload_pack_response.bin',
      ).readAsBytesSync();
      // The fixture's HEAD commit hash (from the advertisement).
      const fixtureHead = 'b3c1526fe274e47d3270da3412314fa25b86c779';

      String? capturedAuth;
      String? capturedCommand;
      var capturedPackValid = false;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      unawaited(
        server.forEach((request) async {
          final path = request.uri.path;
          if (path.endsWith('/info/refs')) {
            final service = request.uri.queryParameters['service'];
            request.response.headers.contentType = ContentType(
              'application',
              'x-$service-advertisement',
            );
            if (service == 'git-receive-pack') {
              capturedAuth = request.headers.value('authorization');
              // Advertise the fixture's current main.
              final line = '$fixtureHead refs/heads/main';
              final caps = 'report-status side-band-64k agent=mock';
              final pkt =
                  '${(line.length + 5 + caps.length + 4).toRadixString(16).padLeft(4, '0')}'
                  '$line\x00$caps\n';
              request.response
                ..write(pkt)
                ..write('0000');
            } else {
              request.response.add(advertisement);
            }
          } else if (path.endsWith('/git-upload-pack')) {
            request.response
              ..headers.contentType = ContentType(
                'application',
                'x-git-upload-pack-result',
              )
              ..add(packResponse);
          } else if (path.endsWith('/git-receive-pack')) {
            final body = await request.fold<List<int>>(
              <int>[],
              (acc, chunk) => acc..addAll(chunk),
            );
            // First pkt-line: "<old> <new> refs/heads/main\0capabilities".
            final hexLen = String.fromCharCodes(body.sublist(0, 4));
            final len = int.parse(hexLen, radix: 16);
            capturedCommand = utf8.decode(body.sublist(4, len));
            // The pack starts right after the flush pkt.
            final flushIdx = len;
            expect(
              String.fromCharCodes(body.sublist(flushIdx, flushIdx + 4)),
              '0000',
              reason: 'a flush pkt must separate commands from the pack',
            );
            final pack = body.sublist(flushIdx + 4);
            capturedPackValid =
                pack.length > 32 &&
                String.fromCharCodes(pack.sublist(0, 4)) == 'PACK';
            // report-status in side-band-64k framing.
            const unpack = 'unpack ok\n';
            const ok = 'ok refs/heads/main\n';
            request.response
              ..headers.contentType = ContentType(
                'application',
                'x-git-receive-pack-result',
              )
              ..write(
                '${(unpack.length + 5).toRadixString(16).padLeft(4, '0')}'
                '\x01$unpack'
                '${(ok.length + 5).toRadixString(16).padLeft(4, '0')}'
                '\x01$ok'
                '0000',
              );
          } else {
            request.response.statusCode = HttpStatus.notFound;
          }
          await request.response.close();
        }),
      );

      // Clone the fixture, then create a new commit on top of main.
      final tmp = Directory.systemTemp.createTempSync('fah_git_push_test');
      addTearDown(() => tmp.delete(recursive: true));
      await GitSmartHttp().cloneInto(
        url: 'http://127.0.0.1:${server.port}/repo.git',
        hostDir: tmp.path,
      );

      final repo = GitRepository.load(tmp.path);
      File('${tmp.path}/pushed.txt').writeAsStringSync('pushed content\n');
      repo.add('${tmp.path}/pushed.txt');
      final author = GitAuthor(name: 'fah', email: 'fah@example.com');
      final commit = repo.commit(
        message: 'push test commit',
        author: author,
        committer: author,
      );

      final report = await GitSmartHttp().pushInto(
        url: 'http://127.0.0.1:${server.port}/repo.git',
        hostDir: tmp.path,
        branch: 'main',
        token: 'secret-token',
      );

      expect(report, contains('unpack ok'));
      expect(report, contains('ok refs/heads/main'));
      expect(
        capturedAuth,
        isNotNull,
        reason: 'receive-pack must receive the Authorization header',
      );
      expect(
        capturedAuth,
        'Basic ${base64Encode(utf8.encode('x-access-token:secret-token'))}',
      );
      expect(capturedCommand, isNotNull);
      expect(
        capturedCommand,
        startsWith('$fixtureHead ${commit.hash} refs/heads/main'),
      );
      expect(capturedPackValid, isTrue, reason: 'push must send a packfile');
      repo.close();
    });
  });
}
