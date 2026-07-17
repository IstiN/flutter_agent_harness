import 'dart:async';
import 'dart:io';

import 'package:dart_git/dart_git.dart';
import 'package:flutter_agent_example/git_smart_http.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
  });
}
