@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter_agent_harness/src/a2a/a2a_client.dart';
import 'package:flutter_agent_harness/src/a2a/a2a_config.dart';
import 'package:flutter_agent_harness/src/a2a/a2a_mail_gateway.dart';
import 'package:flutter_agent_harness/src/a2a/a2a_manager.dart';
import 'package:flutter_agent_harness/src/messaging/agent_message.dart';
import 'package:flutter_agent_harness/src/messaging/messaging_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

/// Captures message/send bodies and answers with [sendState].
http.Client _mockBackend({
  String sendState = 'completed',
  String artifactText = 'delivered to goal_builder inbox',
  List<Map<String, dynamic>>? captured,
}) {
  return http_testing.MockClient((request) async {
    if (request.url.path.endsWith('/.well-known/agent.json')) {
      return http.Response(
        '{"name":"renderbox","description":"t","url":"https://rb.example.com"}',
        200,
      );
    }
    if (request.body.contains('"message/send"')) {
      captured?.add((jsonDecode(request.body) as Map)['params']['message']);
      final artifact = sendState == 'completed'
          ? ',"artifacts":[{"parts":[{"type":"text","text":"$artifactText"}]}]'
          : '';
      return http.Response(
        '{"jsonrpc":"2.0","id":1,"result":{"id":"task-1",'
        '"status":{"state":"$sendState"},"messages":['
        '{"role":"agent","parts":[{"type":"text","text":"$artifactText"}]}]'
        '$artifact}}',
        200,
      );
    }
    return http.Response('not found', 404);
  });
}

A2aManager _manager(http.Client backend) => A2aManager(
  A2aConfig(
    servers: {
      'renderbox': const A2aServerConfig(
        name: 'renderbox',
        url: 'https://rb.example.com',
      ),
    },
  ),
  clientFactory: (config) =>
      A2aClient(baseUrl: config.url, token: config.token, client: backend),
);

AgentMessage _mail({String to = 'goal_builder@renderbox'}) => AgentMessage(
  id: 'm1',
  fromId: 'sess1/main',
  toId: to,
  text: 'hello across machines',
  sentAt: '2026-09-08T10:00:00.000Z',
  hops: 2,
);

A2aMailEnvelope _envelope({String to = 'goal_builder'}) => A2aMailEnvelope(
  id: 'm1',
  from: 'other/main@renderbox',
  to: to,
  text: 'hi from renderbox',
  sentAt: '2026-09-08T10:00:00.000Z',
  hops: 2,
);

/// A minimal in-memory fabric for the accept() tests.
class _FakeFabric implements MessagingRepository {
  _FakeFabric(this.entries);
  final List<MailboxEntry> entries;
  final sent = <AgentMessage>[];

  @override
  Future<void> send(AgentMessage message) async => sent.add(message);

  @override
  Future<List<MailboxEntry>> directory() async => entries;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('A2aMailGateway.deliver (outbound)', () {
    test('sends the faMail envelope to the machine-matching server', () async {
      final captured = <Map<String, dynamic>>[];
      final gateway = A2aMailGateway(
        manager: _manager(_mockBackend(captured: captured)),
        machineName: 'workstation',
      );
      await gateway.deliver(_mail());
      expect(captured, hasLength(1));
      final envelope =
          captured.single['metadata']['faMail'] as Map<String, dynamic>;
      expect(envelope['to'], 'goal_builder');
      expect(envelope['from'], 'sess1/main@workstation');
      expect(envelope['id'], 'm1');
      expect(envelope['text'], 'hello across machines');
      expect(envelope['hops'], 2);
    });

    test('matches the machine name case-insensitively', () async {
      final captured = <Map<String, dynamic>>[];
      final gateway = A2aMailGateway(
        manager: _manager(_mockBackend(captured: captured)),
      );
      await gateway.deliver(_mail(to: 'goal_builder@RenderBox'));
      expect(captured, hasLength(1));
    });

    test('an empty machine name stamps the bare sender mailbox', () async {
      final captured = <Map<String, dynamic>>[];
      final gateway = A2aMailGateway(
        manager: _manager(_mockBackend(captured: captured)),
        machineName: '  ',
      );
      await gateway.deliver(_mail());
      final envelope =
          captured.single['metadata']['faMail'] as Map<String, dynamic>;
      expect(envelope['from'], 'sess1/main');
    });

    test('an unknown machine fails with the config hint', () async {
      final gateway = A2aMailGateway(manager: _manager(_mockBackend()));
      await expectLater(
        gateway.deliver(_mail(to: 'goal_builder@elsewhere')),
        throwsA(
          isA<StateError>().having(
            (e) => '$e',
            'message',
            contains('a2a.servers.elsewhere'),
          ),
        ),
      );
    });

    test('a malformed remote address fails', () async {
      final gateway = A2aMailGateway(manager: _manager(_mockBackend()));
      await expectLater(
        gateway.deliver(_mail(to: 'goal_builder@')),
        throwsA(isA<StateError>()),
      );
    });

    test('a failed remote task surfaces the remote error', () async {
      final gateway = A2aMailGateway(
        manager: _manager(_mockBackend(sendState: 'failed')),
      );
      await expectLater(
        gateway.deliver(_mail()),
        throwsA(
          isA<A2aException>().having(
            (e) => e.message,
            'message',
            contains('delivered to goal_builder inbox'),
          ),
        ),
      );
    });
  });

  group('A2aMailGateway.accept (inbound)', () {
    test('resolves a session display name and deposits the mail', () async {
      final fabric = _FakeFabric([
        const MailboxEntry(id: 'sess9/main', name: 'goal_builder'),
      ]);
      final ack = await A2aMailGateway.accept(_envelope(), fabric: fabric);
      expect(ack, 'delivered to sess9/main inbox');
      expect(fabric.sent, hasLength(1));
      final message = fabric.sent.single;
      expect(message.id, 'm1');
      expect(message.fromId, 'other/main@renderbox');
      expect(message.toId, 'sess9/main');
      expect(message.text, 'hi from renderbox');
      expect(message.hops, 2);
    });

    test('resolves an exact mailbox id and a name/main form', () async {
      final fabric = _FakeFabric([
        const MailboxEntry(id: 'sess9/main', name: 'goal_builder'),
      ]);
      await A2aMailGateway.accept(_envelope(to: 'sess9/main'), fabric: fabric);
      await A2aMailGateway.accept(
        _envelope(to: 'goal_builder/main'),
        fabric: fabric,
      );
      expect(fabric.sent.map((m) => m.toId), everyElement('sess9/main'));
    });

    test('an empty envelope id falls back to a generated one', () async {
      final fabric = _FakeFabric([
        const MailboxEntry(id: 'sess9/main', name: 'goal_builder'),
      ]);
      await A2aMailGateway.accept(
        const A2aMailEnvelope(
          id: '',
          from: 'x',
          to: 'goal_builder',
          text: 'a',
          sentAt: '',
        ),
        fabric: fabric,
      );
      expect(fabric.sent.single.id, isNotEmpty);
    });

    test('an unknown mailbox fails honestly', () async {
      final fabric = _FakeFabric(const []);
      await expectLater(
        A2aMailGateway.accept(_envelope(to: 'nobody'), fabric: fabric),
        throwsA(
          isA<StateError>().having(
            (e) => '$e',
            'message',
            contains('unknown mailbox "nobody"'),
          ),
        ),
      );
      expect(fabric.sent, isEmpty);
    });

    test(
      'an ambiguous mailbox name lists candidates instead of guessing',
      () async {
        final fabric = _FakeFabric([
          const MailboxEntry(id: 'sess1/main', name: 'dup'),
          const MailboxEntry(id: 'sess2/main', name: 'dup'),
        ]);
        await expectLater(
          A2aMailGateway.accept(_envelope(to: 'dup'), fabric: fabric),
          throwsA(
            isA<StateError>().having(
              (e) => '$e',
              'message',
              allOf(
                contains('ambiguous'),
                contains('sess1/main'),
                contains('sess2/main'),
              ),
            ),
          ),
        );
        expect(fabric.sent, isEmpty);
      },
    );
  });
}
