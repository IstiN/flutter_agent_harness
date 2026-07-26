import 'package:fa/services/analytics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    // Never leak a recorder across tests.
    AppAnalytics.install(null);
  });

  test('a custom sink receives events with params', () {
    final events = <(String, Map<String, Object>)>[];
    AppAnalytics.install((name, params) => events.add((name, params)));

    AppAnalytics.instance.appStart(analyticsAvailable: true);
    AppAnalytics.instance.bootstrapResult('chat');
    AppAnalytics.instance.connectResult(
      success: true,
      providerKind: 'openai-completions',
      isCustomProvider: true,
      isOnDevice: false,
    );
    AppAnalytics.instance.keyAction('set', 'OPENROUTER_API_KEY');

    expect(events.map((e) => e.$1), [
      'app_start',
      'bootstrap_result',
      'connect_result',
      'key_action',
    ]);
    expect(events[2].$2['success'], isTrue);
    expect(events[2].$2['is_custom_provider'], isTrue);
    expect(events[3].$2['key_name'], 'OPENROUTER_API_KEY');
  });

  test('message metadata is bucketed, never raw', () {
    final events = <(String, Map<String, Object>)>[];
    AppAnalytics.install((name, params) => events.add((name, params)));

    AppAnalytics.instance.messageSent(hasAttachments: false, textLength: 12);
    AppAnalytics.instance.messageSent(hasAttachments: true, textLength: 5000);
    AppAnalytics.instance.modelsFetchResult(3);
    AppAnalytics.instance.modelsFetchResult(900);

    expect(events[0].$2['length_bucket'], '<=50');
    expect(events[1].$2['length_bucket'], '>1000');
    expect(events[1].$2['has_attachments'], isTrue);
    expect(events[2].$2['count_bucket'], '<=10');
    expect(events[3].$2['count_bucket'], '>200');
  });

  test('the noop default drops events without throwing', () {
    AppAnalytics.install(null);
    expect(() => AppAnalytics.instance.sessionAction('new'), returnsNormally);
  });
}
