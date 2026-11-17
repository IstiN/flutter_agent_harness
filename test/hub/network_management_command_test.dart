// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:fa_hub_client/fa_hub_client.dart' as hub;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../../bin/fah_hub_plugin.dart';

final class _IO implements PluginIO {
  final lines = <String>[];

  @override
  void write(String text) => lines.add(text);

  @override
  void writeln(String text) => lines.add(text);

  String get text => lines.join('\n');
}

void main() {
  late Directory home;
  late HubPluginHost host;
  late PluginContext context;
  late _IO io;
  late List<List<String>> managementCalls;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('network-management-test');
    final environment = <String, String>{'DAP_KEY_PASSPHRASE': 'pass'};
    io = _IO();
    managementCalls = [];
    host = HubPluginHost(
      hub.HubPlugin(environment: environment, home: home.path),
      environment: environment,
      home: home.path,
      networkCommandRunner: (args, context) async {
        managementCalls.add(args);
        context.io.writeln('management: ${args.join(' ')}');
        return 0;
      },
    );
    context = PluginContext(
      env: MemoryExecutionEnv(cwd: home.path),
      io: io,
      askLine: (question, {secret = false}) async => 'answer',
    );
    host.register(context);
  });

  tearDown(() async {
    await host.dispose();
    if (await home.exists()) await home.delete(recursive: true);
  });

  test(
    'login/enroll/rename/status/devices dispatch to management runner',
    () async {
      final network = context.slashCommands['/network']!;
      for (final args in const [
        ['login'],
        ['enroll'],
        ['rename', 'Studio'],
        ['status'],
        ['devices'],
      ]) {
        await network(args);
      }

      expect(managementCalls, [
        ['login'],
        ['enroll'],
        ['rename', 'Studio'],
        ['status'],
        ['devices'],
      ]);
    },
  );

  test(
    'legacy join stays direct and the dap alias reaches the same wizard',
    () async {
      final network = context.slashCommands['/network']!;
      await network(['join', 'not an invite']);
      await network(['dap', 'join', 'still not an invite']);

      expect(managementCalls, isEmpty);
      expect(io.text, contains('invalid invite'));
      expect(io.text, isNot(contains('management: join')));
      expect(io.text, isNot(contains('management: dap')));
    },
  );

  test(
    'real TUI composition logs in, enrolls, renames and lists the device',
    () async {
      await host.dispose();
      final requests =
          <({String method, String path, String? bearer, Map body})>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final body = request.method == 'GET'
            ? <String, Object?>{}
            : (jsonDecode(await utf8.decoder.bind(request).join()) as Map)
                  .cast<String, Object?>();
        requests.add((
          method: request.method,
          path: request.uri.path,
          bearer: request.headers.value(HttpHeaders.authorizationHeader),
          body: body,
        ));
        request.response.headers.contentType = ContentType.json;
        switch ((request.method, request.uri.path)) {
          case ('POST', '/api/devices/enroll'):
            request.response.write(
              jsonEncode({
                'deviceId': 'dev-tui',
                'deviceToken': 'device-secret',
                'personalNetwork': {'id': 'net-personal'},
              }),
            );
          case ('PATCH', '/api/devices/dev-tui/name'):
            request.response.write(
              jsonEncode({'deviceId': 'dev-tui', 'friendlyName': body['name']}),
            );
          case ('GET', '/api/devices'):
            request.response.write(
              jsonEncode({
                'devices': [
                  {
                    'deviceId': 'dev-tui',
                    'name': 'integration-host',
                    'friendlyName': 'Studio',
                  },
                ],
              }),
            );
          default:
            request.response.statusCode = HttpStatus.notFound;
            request.response.write('{"error":"not found"}');
        }
        await request.response.close();
      });

      final base = 'http://${server.address.address}:${server.port}';
      final environment = <String, String>{
        'DAP_KEY_PASSPHRASE': 'pass',
        'FA_NETWORK_BASE_URL': base,
        'FA_NETWORK_AUTH_URL': base,
        'FA_NETWORK_DEVICE_NAME': 'integration-host',
      };
      io = _IO();
      host = HubPluginHost(
        hub.HubPlugin(environment: environment, home: home.path),
        environment: environment,
        home: home.path,
      );
      final answers = <String>['jwt-token', ''];
      final prompts = <(String, bool)>[];
      context = PluginContext(
        env: MemoryExecutionEnv(cwd: home.path),
        io: io,
        askLine: (question, {secret = false}) async {
          prompts.add((question, secret));
          return answers.removeAt(0);
        },
      );
      host.register(context);
      final network = context.slashCommands['/network']!;

      await network(['login', '--jwt']);
      await network(['enroll']);
      await network(['rename', 'Studio']);
      await network(['status']);
      await network(['devices']);

      expect(prompts.map((prompt) => prompt.$2), [true, false]);
      expect(prompts[1].$1, contains('integration-host'));
      expect(
        requests
            .singleWhere((request) => request.path == '/api/devices/enroll')
            .body,
        containsPair('name', 'integration-host'),
      );
      expect(
        requests
            .where((request) => request.path != '/api/devices')
            .every((request) => request.bearer == 'Bearer jwt-token'),
        isTrue,
      );
      expect(io.text, contains('enrolled: dev-tui'));
      expect(io.text, contains('Devices'));
      expect(io.text, contains('renamed dev-tui: Studio'));
      expect(io.text, contains('dev-tui'));
      expect(io.text, contains('Studio'));
      expect(io.text, isNot(contains('jwt-token')));
      expect(io.text, isNot(contains('device-secret')));
    },
  );

  test('network help disambiguates management and DAP commands', () async {
    await context.slashCommands['/network']!(['help']);

    expect(managementCalls, isEmpty);
    expect(io.text, contains('/network login'));
    expect(io.text, contains('/network enroll'));
    expect(io.text, contains('/network dap join'));
    expect(io.text, contains('/network join'));
  });
}
