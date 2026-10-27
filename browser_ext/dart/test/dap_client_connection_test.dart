@TestOn('chrome')
library;

import 'dart:async';

import 'package:test/test.dart';

import '../src/dap/dap_client.dart';
import '../src/dap/dap_frames.dart';
import '../src/dap/dap_integration.dart';

void main() {
  // Uri accepts the out-of-range port, but WebSocket rejects it synchronously
  // and Chrome echoes the complete credential-bearing URL in its SyntaxError.
  const url = 'ws://127.0.0.1:65536/ws';
  const secret = 'test-only-hub-password';
  const connectionFailure = 'Bad state: hub WebSocket connection failed';

  late String keyFile;

  setUpAll(() async {
    keyFile = await (await DapIdentity.generate()).toKeyFile();
  });

  DapConfig config() => DapConfig(
    url: url,
    name: 'connection-test',
    secret: secret,
    loadKeyFile: () async => keyFile,
    saveKeyFile: (_) async {},
  );

  test('synchronous socket construction failures hide credentials', () async {
    final identity = await DapIdentity.fromKeyFile(keyFile);
    final client = DapClient(
      identity: identity,
      url: url,
      name: 'connection-test',
      secret: secret,
      onMail: (_, _) {},
      onStatus: (_) {},
    );

    Object? error;
    try {
      client.start();
    } on Object catch (e) {
      error = e;
    }

    expect(error, isA<StateError>());
    expect(error.toString(), connectionFailure);
    expect(error.toString(), isNot(contains(client.wsUrl)));
    expect(error.toString(), isNot(contains(url)));
    expect(error.toString(), isNot(contains(secret)));
  });

  test('integration console and status hide constructor error text', () async {
    final integration = DapIntegration(
      config: config(),
      pushMail: (_, _) {},
      onStatusChanged: () {},
    );
    final logs = <String>[];

    await runZoned(
      integration.start,
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => logs.add(line),
      ),
    );

    final output = '${logs.join('\n')}\n${integration.snapshot()}';
    final credentialUrl = dapWsUrlWithToken(url, secret);
    expect(logs.last, '[fa] dap identity/start failed: $connectionFailure');
    expect(integration.snapshot(), containsPair('error', connectionFailure));
    expect(output, isNot(contains(credentialUrl)));
    expect(output, isNot(contains(url)));
    expect(output, isNot(contains(secret)));
  });

  test('integration retains nonsecret startup diagnostics', () async {
    const diagnostic = 'key storage unavailable';
    final integration = DapIntegration(
      config: DapConfig(
        url: 'ws://127.0.0.1:9/ws',
        name: 'connection-test',
        loadKeyFile: () async => throw StateError(diagnostic),
        saveKeyFile: (_) async {},
      ),
      pushMail: (_, _) {},
      onStatusChanged: () {},
    );
    final logs = <String>[];

    await runZoned(
      integration.start,
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => logs.add(line),
      ),
    );

    expect(logs.last, contains(diagnostic));
    expect(integration.snapshot(), containsPair('error', contains(diagnostic)));
  });
}
