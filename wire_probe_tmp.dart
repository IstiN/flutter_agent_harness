import 'dart:convert';
import 'package:flutter_agent_harness/src/agent/agent_loop.dart';
import 'package:flutter_agent_harness/src/rate_limit_info.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:flutter_agent_harness/src/wire/wire_protocol.dart';

void main() {
  final p = AgentWireProtocol();

  // A. Precedence: is the anywhere-set honored for kinds WITH registry entries?
  final probe = AgentWireProtocol.redactForLog({
    'v': 1,
    'kind': 'secret_response', // HAS a registry entry {value}
    'id': 'x',
    'granted': true,
    'rawBody': 'TOP-LEVEL-STRAY',
  });
  print('A. rawBody redacted on kind WITH registry entry: ${probe['rawBody'] == '[REDACTED]'}');

  // B. Unknown message role -> FormatException escape?
  try {
    p.decodeEvent({
      'v': 1, 'kind': 'agent_end',
      'messages': [
        {'role': 'human', 'content': 'hi', 'timestamp': 0},
      ],
    });
    print('B. unknown role: decoded OK');
  } catch (e) {
    print('B. unknown role throws: ${e.runtimeType} (WireProtocolException? ${e is WireProtocolException})');
  }

  // C. Unknown content block type -> ?
  try {
    p.decodeEvent({
      'v': 1, 'kind': 'message_end',
      'message': {
        'role': 'assistant', 'content': [
          {'type': 'audio', 'data': 'x'},
        ],
        'api': 'a', 'provider': 'p', 'model': 'm',
        'usage': {'input': 1, 'output': 1, 'cacheRead': 0, 'cacheWrite': 0, 'totalTokens': 2, 'cost': {}},
        'stopReason': 'stop', 'timestamp': 0,
      },
    });
    print('C. unknown block type: decoded OK');
  } catch (e) {
    print('C. unknown block type throws: ${e.runtimeType} (WireProtocolException? ${e is WireProtocolException})');
  }

  // D. round-1 fixes verification:
  // D1. rawBody stripped from frames + redact-anywhere on foreign frames.
  final msg = AssistantMessage(
    content: const [TextContent(text: 'hi')],
    api: 'a', provider: 'p', model: 'm',
    usage: const Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: UsageCost()),
    stopReason: StopReason.error,
    rateLimit: const RateLimitInfo(planType: 'free', rawBody: 'RAW-429-BODY'),
    timestamp: DateTime.fromMillisecondsSinceEpoch(0),
  );
  final frame = p.encodeEvent(MessageEndEvent(msg));
  print('D1a. rawBody on frame: ${jsonEncode(frame).contains('RAW-429-BODY')}');
  final foreign = AgentWireProtocol.redactForLog({
    'v': 1, 'kind': 'message_end',
    'message': {'role': 'assistant', 'rateLimit': {'rawBody': 'RAW-429-BODY'}},
  });
  print('D1b. foreign-frame nested rawBody redacted: ${!(jsonEncode(foreign).contains('RAW-429-BODY'))}');

  // D2. frame version error type.
  try {
    p.decodeEvent({'v': 99, 'kind': 'agent_start'});
  } catch (e) {
    print('D2. v=99 -> ${e.runtimeType} (WireVersionError? ${e is WireVersionError})');
  }

  // D3. TypeError wrap.
  try {
    p.decodeEvent({'v': 1, 'kind': 'model_request', 'detail': {'messageCount': 1}, 'rawWireDump': 42});
  } catch (e) {
    print('D3. rawWireDump=42 -> ${e.runtimeType} (declared? ${e is WireProtocolException})');
  }

  // D4. stop reason loud.
  try {
    p.decodeEvent({
      'v': 1, 'kind': 'message_update',
      'message': frame['message'],
      'event': {'kind': 'done', 'reason': 'banana'},
    });
  } catch (e) {
    print('D4. unknown stop reason -> ${e.runtimeType}');
  }

  // D5. hello v ignored.
  final accepted = AgentWireProtocol.acceptHello({'v': 99, 'kind': 'hello', 'versions': [2, 1]});
  print('D5. hello v=99 versions=[2,1] negotiated to: ${accepted.protocol.version}');
}
