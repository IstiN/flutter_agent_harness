// The js_interop half of the bridge LLM relay: implements the pure
// `BridgeLlmRelay` interface from providers.dart over `faSw.bridge`
// (sw/bridge.js). ALL frame glue lives in bridge.js — this file only
// calls `sendLlm(req, onDelta)` and `status()` and adapts the result
// onto the provider event stream (relayTextStream).
//
// dart2js-only: never import from a VM test — fake BridgeLlmRelay there.
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter_agent_harness/src/cancel_token.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/event_stream.dart';
import 'package:flutter_agent_harness/src/model.dart';

import 'providers.dart';

@JS('faSw.bridge.sendLlm')
external JSPromise<JSAny?> _sendLlm(JSObject req, JSFunction onDelta);

@JS('faSw.bridge.status')
external JSObject _bridgeStatus();

/// Streams completions through the paired CLI's keyless proxy.
final class BridgeRelayClient implements BridgeLlmRelay {
  const BridgeRelayClient();

  @override
  bool get connected {
    try {
      final status = _bridgeStatus().dartify();
      return status is Map && status['phase'] == 'connected';
    } on Object {
      return false; // no bridge surface (scaffold SW) = link down
    }
  }

  @override
  AssistantMessageEventStream stream(
    Model model,
    Context context, {
    CancelToken? cancelToken,
    String? providerName,
  }) {
    final deltas = StreamController<String>();
    final events = relayTextStream(
      model,
      deltas.stream,
      cancelToken: cancelToken,
    );
    final request =
        {
              'baseUrl': model.baseUrl,
              'model': model.id,
              if (providerName != null && providerName.isNotEmpty)
                'provider': providerName,
              'messages': openAiRelayMessages(context),
            }.jsify()
            as JSObject;
    unawaited(
      _sendLlm(
        request,
        ((JSAny? delta) {
          final text = delta.isA<JSString>() ? (delta as JSString).toDart : '';
          if (!deltas.isClosed) deltas.add(text);
        }).toJS,
      ).toDart.then(
        (_) {
          if (!deltas.isClosed) deltas.close();
        },
        onError: (Object error) {
          if (!deltas.isClosed) deltas.addError('$error');
        },
      ),
    );
    return events;
  }
}
