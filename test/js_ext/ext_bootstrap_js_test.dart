/// Structural (non-evaluating) checks on the bootstrap JS sources: every
/// documented API is defined exactly once, braces balance, no module syntax,
/// each transport carries a distinct `__extEngineId`, and the stdio transport
/// keeps both of its event-loop branches. Real evaluation is covered by the
/// engine integration suites.
library;

import 'package:flutter_agent_harness/src/js_ext/ext_bootstrap_js.dart';
import 'package:test/test.dart';

int count(String haystack, String needle) => needle.allMatches(haystack).length;

void expectDefinedOnce(String src, String definition) {
  expect(count(src, definition), 1, reason: 'expected exactly one $definition');
}

void expectBalancedBraces(String src, String label) {
  final opens = '{'.allMatches(src).length;
  final closes = '}'.allMatches(src).length;
  expect(opens, closes, reason: '$label braces unbalanced: $opens vs $closes');
}

void main() {
  group('kExtBootstrapCoreJs', () {
    const core = kExtBootstrapCoreJs;

    test('defines every host entry point exactly once', () {
      for (final def in [
        'g.__extHandles =',
        'g.__extNextSeq =',
        'g.__extExpect =',
        'g.__extDeliver =',
        'g.__extCommit =',
        'g.__extInvoke =',
        'g.__extPing =',
        'g.__extIsPending =',
        'g.jsr = { ext: ext };',
      ]) {
        expectDefinedOnce(core, def);
      }
    });

    test('defines every documented jsr.ext.* method exactly once', () {
      // Registration surface: object keys in the `ext` definition.
      for (final key in [
        'registerTool:',
        'onHook:',
        'registerSlashCommand:',
        'registerProviderFlow:',
      ]) {
        expectDefinedOnce(core, key);
      }
      // Bridge surface: every documented JS → host method wired once.
      for (final wire in [
        "call('session.appendNote'",
        "call('session.enqueueFollowUp'",
        "call('fs.readFile'",
        "call('exec.run'",
        "call('keys.request'",
        "call('io.write'",
        "call('io.writeln'",
        "call('has'",
      ]) {
        expectDefinedOnce(core, wire);
      }
    });

    test('routes host calls through the transport; does not define one', () {
      expect(core, contains('g.__extTransport.call'));
      expect(
        core.contains('__extTransport ='),
        isFalse,
        reason: 'core must stay engine-agnostic; transports define it',
      );
      expect(core, contains('pending.set'));
      expect(core, contains('pending.delete'));
    });

    test('braces balance; no module or import syntax', () {
      expectBalancedBraces(core, 'core');
      expect(core.contains('import '), isFalse);
      expect(core.contains('require('), isFalse);
    });
  });

  group('transports', () {
    test('each defines a distinct __extEngineId exactly once', () {
      const ids = {
        kExtTransportStdioJs: 'qjs-process',
        kExtTransportSendMessageJs: 'flutter-js',
        kExtTransportPostMessageJs: 'web-worker',
      };
      for (final entry in ids.entries) {
        expect(count(entry.key, "g.__extEngineId ="), 1);
        expect(entry.key, contains("'${entry.value}'"));
        for (final other in ids.values.where((v) => v != entry.value)) {
          expect(
            entry.key.contains(other),
            isFalse,
            reason: '${entry.value} transport must not carry $other',
          );
        }
      }
      expect(ids.values.toSet(), hasLength(3));
    });

    test(
      'each defines __extTransport with a call method; braces balance; no imports',
      () {
        for (final src in [
          kExtTransportStdioJs,
          kExtTransportSendMessageJs,
          kExtTransportPostMessageJs,
        ]) {
          expect(count(src, 'g.__extTransport ='), 1);
          expect(src, contains('call: function (method, args)'));
          expect(src, contains('g.__extNextSeq()'));
          expect(src, contains('g.__extExpect(s)'));
          expectBalancedBraces(src, 'transport');
          expect(src.contains('import '), isFalse);
          expect(src.contains('require('), isFalse);
        }
      },
    );

    test('stdio transport frames JSON lines and keeps both loop branches', () {
      const src = kExtTransportStdioJs;
      expect(src, contains('std.out.puts'));
      expect(src, contains("JSON.stringify(obj) + '\\n'"));
      expect(src, contains('std.in.getline()'));
      expect(
        src,
        contains('typeof os.setTimeout'),
        reason: 'event-loop branch',
      );
      expect(src, contains('pumpUntil'));
      expect(
        src,
        contains('g.__extIsPending(s)'),
        reason: 'nested pump for bridge round-trips',
      );
      expect(src, contains('for (;;)'), reason: 'blocking fallback branch');
      expect(src, contains("g[msg.fn]"));
      expect(src, contains('__extDeliver(msg)'));
    });

    test(
      'send-message transport posts to the __ext_host channel, no stdin loop',
      () {
        const src = kExtTransportSendMessageJs;
        expect(src, contains("sendMessage('__ext_host'"));
        expect(src, contains('JSON.stringify({ seq: s, method: method, args:'));
        expect(src.contains('std.in.getline'), isFalse);
        expect(src.contains('onmessage'), isFalse);
      },
    );

    test(
      'post-message transport wraps in the __ext__ envelope and routes onmessage',
      () {
        const src = kExtTransportPostMessageJs;
        expect(src, contains("postMessage({ __ext__: { seq: s"));
        expect(count(src, 'g.onmessage ='), 1);
        expect(src, contains('__extDeliver(msg)'));
        expect(src, contains('typeof msg.invoke'));
        expect(src.contains('std.in.getline'), isFalse);
      },
    );
  });

  test('total bootstrap JS stays under the size budget', () {
    const total =
        kExtBootstrapCoreJs.length +
        kExtTransportStdioJs.length +
        kExtTransportSendMessageJs.length +
        kExtTransportPostMessageJs.length;
    final lines =
        (kExtBootstrapCoreJs +
                kExtTransportStdioJs +
                kExtTransportSendMessageJs +
                kExtTransportPostMessageJs)
            .split('\n')
            .length;
    expect(lines, lessThan(700), reason: 'JS sources total $lines lines');
    expect(total, greaterThan(0));
  });
}
