import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// The verbatim 429 payload from the owner clip (issue #867) — everything
/// needed for a human message is in here, it just used to be dumped raw.
const clipBody =
    '{"error":{"type":"usage_limit_reached","message":"The usage limit has '
    'been reached","plan_type":"free","resets_at":1792439371,'
    '"eligible_promo":null,"resets_in_seconds":2280562}}';

RateLimitInfo clipInfo() =>
    parseRateLimitInfo(statusCode: 429, body: clipBody)!;

void main() {
  group('parseRateLimitInfo — ChatGPT-Codex usage-limit payload (AC1)', () {
    test('the verbatim clip payload decodes into the structured info', () {
      final info = clipInfo();
      expect(info.errorType, 'usage_limit_reached');
      expect(info.planType, 'free');
      expect(info.resetsAt, DateTime.utc(2026, 10, 19, 19, 49, 31));
      expect(info.resetsInSeconds, 2280562);
      expect(info.eligiblePromo, isNull);
      expect(info.rawBody, clipBody);
    });

    test('non-429 statuses never parse (rendering stays unchanged)', () {
      expect(parseRateLimitInfo(statusCode: 400, body: clipBody), isNull);
      expect(parseRateLimitInfo(statusCode: 500, body: 'oops'), isNull);
    });

    test('codex header resets feed the info when the body is silent', () {
      final info = parseRateLimitInfo(
        statusCode: 429,
        body: 'rate limited',
        headers: {
          'x-codex-secondary-used-percent': '100',
          'x-codex-secondary-reset-at': '2000000000',
        },
        headerResetsAt: 2000000000,
        limitKind: 'secondary',
      )!;
      expect(info.resetsAt, DateTime.utc(2033, 5, 18, 3, 33, 20));
      expect(info.limitKind, 'secondary');
      expect(info.planType, isNull);
    });
  });

  group('formatRateLimitMessage — the human line (AC2)', () {
    test('en: names the plan, human reset units, next step — never raw', () {
      final message = formatRateLimitMessage(clipInfo());
      expect(message, contains('ChatGPT Free plan limit reached.'));
      expect(message, contains(' — in 26 days.'));
      expect(message, contains('Next: switch to a model or provider'));
      expect(message.contains('{'), isFalse, reason: message);
      expect(message.contains('null'), isFalse, reason: message);
      expect(message.contains('usage_limit_reached'), isFalse);
    });

    test('ru: the goal wording family with human units', () {
      final message = formatRateLimitMessage(clipInfo(), localeCode: 'ru');
      expect(message, contains('Лимит плана Free ChatGPT исчерпан.'));
      expect(message, contains('через 26 дней'));
      expect(message, contains('Далее: переключитесь'));
      expect(message.contains('{'), isFalse, reason: message);
    });

    test('eligible promo gets its one-line mention', () {
      const body =
          '{"error":{"type":"usage_limit_reached","plan_type":"free",'
          '"resets_at":1792439371,"eligible_promo":"SUMMER50",'
          '"resets_in_seconds":2280562}}';
      final info = parseRateLimitInfo(statusCode: 429, body: body)!;
      expect(formatRateLimitMessage(info), contains('Promo available: SUMMER50.'));
      expect(
        formatRateLimitMessage(info, localeCode: 'ru'),
        contains('Доступно промо: SUMMER50.'),
      );
    });
  });

  group('formatHumanCountdown — magnitude table (E1)', () {
    test('ru', () {
      String ru(Duration d) => formatHumanCountdown(d, localeCode: 'ru');
      expect(ru(Duration(seconds: 45)), 'через 45 сек');
      expect(ru(Duration(minutes: 5)), 'через 5 мин');
      expect(ru(Duration(hours: 3)), 'через 3 часа');
      expect(ru(Duration(days: 26)), 'через 26 дней');
      // ru plural slots.
      expect(ru(Duration(days: 1)), 'через 1 день');
      expect(ru(Duration(days: 2)), 'через 2 дня');
      expect(ru(Duration(days: 11)), 'через 11 дней');
      expect(ru(Duration(hours: 1)), 'через 1 час');
      expect(ru(Duration(hours: 5)), 'через 5 часов');
    });

    test('en', () {
      String en(Duration d) => formatHumanCountdown(d);
      expect(en(Duration(seconds: 45)), 'in 45 sec');
      expect(en(Duration(minutes: 5)), 'in 5 min');
      expect(en(Duration(hours: 3)), 'in 3 hours');
      expect(en(Duration(days: 26)), 'in 26 days');
    });
  });

  group('formatResetStamp', () {
    test('ru day-month + 24h clock', () {
      expect(
        formatResetStamp(
          DateTime(2026, 10, 19, 22, 49),
          localeCode: 'ru',
        ),
        '19 октября в 22:49',
      );
    });

    test('en month-day + 24h clock', () {
      expect(
        formatResetStamp(DateTime(2026, 10, 19, 22, 49)),
        'October 19, 22:49',
      );
    });
  });

  group('degrade paths (AC4)', () {
    test('bare 429 with only Retry-After renders retry minutes', () {
      final info = parseRateLimitInfo(
        statusCode: 429,
        body: 'too many requests',
        headers: {'retry-after': '120'},
      )!;
      expect(info.planType, isNull);
      expect(info.resetsAt, isNull);
      expect(info.resetsInSeconds, isNull);
      expect(info.retryAfter, const Duration(minutes: 2));

      final message = formatRateLimitMessage(info);
      expect(message, contains('Rate limit reached.'));
      expect(message, contains('Try again in 2 min.'));
      expect(message.contains('null'), isFalse, reason: message);
      expect(
        formatRateLimitMessage(info, localeCode: 'ru'),
        contains('Повтор через 2 мин.'),
      );
    });

    test('an HTTP-date Retry-After degrades the same way', () {
      final info = parseRateLimitInfo(
        statusCode: 429,
        body: '',
        headers: {'Retry-After': 'Wed, 21 Oct 2015 07:28:00 GMT'},
        now: DateTime.utc(2015, 10, 21, 6, 28),
      )!;
      expect(info.retryAfter, const Duration(hours: 1));
      expect(
        formatRateLimitMessage(info, now: DateTime.utc(2015, 10, 21, 6, 28)),
        contains('Try again in 1 hour.'),
      );
    });

    test('a 429 with nothing usable renders the generic message', () {
      final info = parseRateLimitInfo(statusCode: 429, body: '')!;
      final message = formatRateLimitMessage(info);
      expect(message, contains('Rate limit reached.'));
      expect(message, contains('Try again later.'));
      expect(message.contains('null'), isFalse, reason: message);
      expect(
        formatRateLimitMessage(info, localeCode: 'ru'),
        contains('Попробуйте позже.'),
      );
    });

    test('an HTML 429 body never leaks markup into the message', () {
      final info = parseRateLimitInfo(
        statusCode: 429,
        body: '<html>blocked</html>',
      )!;
      expect(formatRateLimitMessage(info).contains('<'), isFalse);
    });
  });

  group('clock skew (E2)', () {
    test('the countdown comes from the server, not the device clock', () {
      final info = clipInfo();
      // Device believes the reset already passed (clock hours ahead of the
      // server's resets_at) — resets_in_seconds still says 26 days.
      final skewed = formatRateLimitMessage(
        info,
        now: DateTime.utc(2026, 10, 20, 20, 0, 0),
      );
      expect(skewed, contains('in 26 days'));

      // And without resets_in_seconds, the server's resets_at drives it.
      const body =
          '{"error":{"type":"usage_limit_reached","plan_type":"free",'
          '"resets_at":1792439371}}';
      final infoNoSeconds = parseRateLimitInfo(statusCode: 429, body: body)!;
      final message = formatRateLimitMessage(
        infoNoSeconds,
        now: DateTime.utc(2026, 10, 19, 19, 49, 31),
      );
      expect(message, contains('in 0 sec'));
    });
  });

  group('secondary-window-only reset (E3)', () {
    test('still one clear message, limit kind named', () {
      final info = parseRateLimitInfo(
        statusCode: 429,
        body: 'rate limited',
        headerResetsAt: 2000000000,
        limitKind: 'secondary',
      )!;
      final message = formatRateLimitMessage(
        info,
        now: DateTime.utc(2026, 1, 1),
      );
      expect(message, contains('Rate limit reached (secondary limit).'));
      expect(message, contains(RegExp(r'Resets .+ — in \d+ days')));
      expect(message.contains('{'), isFalse);
      expect(message.contains('null'), isFalse);
    });
  });

  group('render surfaces (AC5)', () {
    test('formatProviderError renders the human line with the 429 prefix',
        () {
      final error = ProviderHttpError(429, clipBody, rateLimit: clipInfo());
      final rendered = formatProviderError(error);
      expect(rendered, startsWith('429: '));
      expect(rendered.contains('{'), isFalse, reason: rendered);
      expect(rendered, contains('in 26 days'));
    });

    test('non-429 provider errors are unchanged (REG)', () {
      final rendered = formatProviderError(
        const ProviderHttpError(400, '{"bad":"request"}'),
      );
      expect(rendered, '400: {"bad":"request"}');
    });

    test('the raw payload rides the message JSON, not the rendered text', () {
      final message = AssistantMessage(
        content: const [],
        api: 'responses',
        provider: 'chatgpt',
        model: 'gpt-5-codex',
        usage: Usage.zero,
        stopReason: StopReason.error,
        errorMessage: '429: ${formatRateLimitMessage(clipInfo())}',
        rateLimit: clipInfo(),
        timestamp: DateTime.utc(2026, 9, 24),
      );
      final restored = AssistantMessage.fromJson(message.toJson());
      expect(restored.rateLimit?.rawBody, clipBody);
      expect(restored.rateLimit?.planType, 'free');
      expect(restored.errorMessage!.contains('{'), isFalse);
    });
  });

  group('parseRetryAfter (moved verbatim, issue #867)', () {
    test('delta seconds and HTTP dates still parse', () {
      expect(parseRetryAfter('120'), const Duration(minutes: 2));
      expect(
        parseRetryAfter('Wed, 21 Oct 2015 07:28:00 GMT'),
        isNotNull,
      );
      expect(parseRetryAfter('garbage'), isNull);
      expect(parseRetryAfter(null), isNull);
    });
  });
}
