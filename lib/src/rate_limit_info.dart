/// Structured rate-limit knowledge (issue #867): a provider 429 decodes ONCE
/// at the provider boundary into a [RateLimitInfo]; every surface renders
/// from that structure and the raw payload never reaches the transcript —
/// it only rides along ([RateLimitInfo.rawBody]) for logs and diagnostics.
///
/// Pure Dart and locale-free otherwise: hosts pass a BCP-47 language code
/// (`en`/`ru`) to the formatters, which share one human-duration vocabulary
/// (seconds → «через 45 сек», hours → «in 3 hours», days → «через 26 дней»).
library;

import 'dart:convert';

/// Parses a `Retry-After` header value into a [Duration].
///
/// Supports both forms defined by RFC 9110 (and handled by pi's
/// `getRetryAfterDelayMs`): delta-seconds (`"120"`) and an HTTP date
/// (`"Wed, 21 Oct 2015 07:28:00 GMT"`, also ISO-8601 as a fallback). The
/// result is clamped to be non-negative. Returns `null` for absent or
/// unparseable values.
Duration? parseRetryAfter(String? value, {DateTime? now}) {
  if (value == null) {
    return null;
  }
  final trimmed = value.trim();
  final seconds = int.tryParse(trimmed);
  if (seconds != null) {
    return Duration(seconds: seconds < 0 ? 0 : seconds);
  }
  final date = _parseHttpDate(trimmed) ?? DateTime.tryParse(trimmed);
  if (date == null) {
    return null;
  }
  final delta = date.difference(now ?? DateTime.now());
  return delta.isNegative ? Duration.zero : delta;
}

const _httpMonths = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

final _httpDatePattern = RegExp(
  r'^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
);

/// Parses the IMF-fixdate form of an HTTP date
/// (`Wed, 21 Oct 2015 07:28:00 GMT`). Returns `null` for anything else.
DateTime? _parseHttpDate(String value) {
  final match = _httpDatePattern.firstMatch(value);
  if (match == null) {
    return null;
  }
  final month = _httpMonths[match[2]!.toLowerCase()];
  if (month == null) {
    return null;
  }
  return DateTime.utc(
    int.parse(match[3]!),
    month,
    int.parse(match[1]!),
    int.parse(match[4]!),
    int.parse(match[5]!),
    int.parse(match[6]!),
  );
}

/// The structured decode of a provider 429 (issue #867). Every field is
/// nullable — unknown payload shapes degrade to the generic human message
/// instead of leaking `null` into a transcript.
final class RateLimitInfo {
  /// Creates the info; [rawBody] keeps the full payload for diagnostics.
  const RateLimitInfo({
    this.errorType,
    this.planType,
    this.resetsAt,
    this.resetsInSeconds,
    this.eligiblePromo,
    this.limitKind,
    this.brand,
    this.retryAfter,
    this.rawBody = '',
  });

  /// The payload's error discriminator when it names one
  /// (`usage_limit_reached` on ChatGPT-Codex).
  final String? errorType;

  /// The account plan the quota belongs to (`free`, `plus`, …).
  final String? planType;

  /// Server-derived absolute reset moment (UTC), from `resets_at` (unix
  /// seconds) or the provider's reset headers. Rendered in the device's
  /// time zone, never recomputed from the (possibly skewed) device clock.
  final DateTime? resetsAt;

  /// Server-derived seconds until the reset (`resets_in_seconds`) —
  /// immune to device clock skew, so it wins for the countdown.
  final int? resetsInSeconds;

  /// A promo the account is eligible for, when the payload advertises one.
  final String? eligiblePromo;

  /// Which advertised window the reset belongs to (`primary`/`secondary`
  /// or the provider's own limit name), when the headers named one.
  final String? limitKind;

  /// The provider display name enriching the plan title (`ChatGPT` on the
  /// codex adapter). `null` — the generic parse layer — keeps the title
  /// neutral: any endpoint or proxy can answer a 429 with a plan body.
  final String? brand;

  /// The provider-suggested wait parsed from the `Retry-After` header.
  final Duration? retryAfter;

  /// The full raw response body — diagnostics only, NEVER rendered on a
  /// user surface (issue #867 AC5).
  final String rawBody;

  Map<String, dynamic> toJson() => {
    if (errorType != null) 'errorType': errorType,
    if (planType != null) 'planType': planType,
    if (resetsAt != null) 'resetsAt': resetsAt!.millisecondsSinceEpoch,
    if (resetsInSeconds != null) 'resetsInSeconds': resetsInSeconds,
    if (eligiblePromo != null) 'eligiblePromo': eligiblePromo,
    if (limitKind != null) 'limitKind': limitKind,
    if (brand != null) 'brand': brand,
    if (retryAfter != null) 'retryAfterMs': retryAfter!.inMilliseconds,
    if (rawBody.isNotEmpty) 'rawBody': rawBody,
  };

  /// Returns a copy enriched with the provider display name for the plan
  /// title. Only a branded adapter sets it — the codex endpoint IS the
  /// ChatGPT surface; the shared parse layer stays provider-neutral.
  RateLimitInfo withBrand(String brand) => RateLimitInfo(
    errorType: errorType,
    planType: planType,
    resetsAt: resetsAt,
    resetsInSeconds: resetsInSeconds,
    eligiblePromo: eligiblePromo,
    limitKind: limitKind,
    retryAfter: retryAfter,
    rawBody: rawBody,
    brand: brand,
  );

  factory RateLimitInfo.fromJson(Map<String, dynamic> json) => RateLimitInfo(
    errorType: json['errorType'] as String?,
    planType: json['planType'] as String?,
    resetsAt: json['resetsAt'] is int
        ? DateTime.fromMillisecondsSinceEpoch(
            json['resetsAt'] as int,
            isUtc: true,
          )
        : null,
    resetsInSeconds: json['resetsInSeconds'] as int?,
    eligiblePromo: json['eligiblePromo'] as String?,
    limitKind: json['limitKind'] as String?,
    brand: json['brand'] as String?,
    retryAfter: json['retryAfterMs'] is int
        ? Duration(milliseconds: json['retryAfterMs'] as int)
        : null,
    rawBody: json['rawBody'] as String? ?? '',
  );
}

/// Decodes a 429 response into a [RateLimitInfo]; `null` for any other
/// status (non-429 rendering is unchanged).
///
/// Generic parse layer: reads the JSON body's rate-limit fields (nested
/// under `error` when the payload nests them, top-level otherwise) and the
/// `Retry-After` header. Codex header resets arrive pre-parsed via
/// [headerResetsAt]/[limitKind] so this file stays provider-agnostic.
/// Unknown shapes still yield an info — all fields null-safe — because a
/// bare 429 must still render the friendly generic message.
RateLimitInfo? parseRateLimitInfo({
  required int statusCode,
  required String body,
  Map<String, String> headers = const {},
  int? headerResetsAt,
  String? limitKind,
  DateTime? now,
}) {
  if (statusCode != 429) return null;
  Map<String, dynamic>? payload;
  final trimmed = body.trim();
  if (trimmed.startsWith('{')) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        payload = error is Map<String, dynamic> ? error : decoded;
      }
    } on FormatException {
      // Not JSON — the fields below stay null; the message degrades.
    }
  }
  String? text(String key) =>
      payload?[key] is String ? payload![key] as String : null;
  int? intOf(String key) {
    final value = payload?[key];
    // Gateways and proxies in front of codex-shaped backends frequently
    // serialize numeric fields as strings; parse those instead of
    // silently dropping the advertised reset (review round 2).
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }
  final resetsAtUnix = intOf('resets_at') ?? headerResetsAt;
  return RateLimitInfo(
    errorType: text('type'),
    planType: text('plan_type'),
    eligiblePromo: text('eligible_promo'),
    resetsInSeconds: intOf('resets_in_seconds'),
    resetsAt: resetsAtUnix is int && resetsAtUnix > 0
        ? DateTime.fromMillisecondsSinceEpoch(resetsAtUnix * 1000, isUtc: true)
        : null,
    limitKind: limitKind,
    retryAfter: parseRetryAfter(_header(headers, 'retry-after'), now: now),
    rawBody: body,
  );
}

/// Case-insensitive header lookup (header casing varies by hop).
String? _header(Map<String, String> headers, String name) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == name) return entry.value.trim();
  }
  return null;
}

/// The one human message for a rate limit (issue #867): plan, server-derived
/// reset time in human units, and the next step — never the raw payload.
///
/// [localeCode] selects the `ru`/`en` wording (`xx_YY` codes match on the
/// language subtag). [now] is injectable for tests; the countdown prefers
/// [RateLimitInfo.resetsInSeconds] (server truth) over any wall-clock math,
/// so device clock skew cannot lie.
String formatRateLimitMessage(
  RateLimitInfo info, {
  String localeCode = 'en',
  DateTime? now,
}) {
  final ru = localeCode.toLowerCase().startsWith('ru');
  final buffer = StringBuffer(_rateLimitTitle(info, ru));
  final stamp = info.resetsAt == null
      ? null
      : formatResetStamp(info.resetsAt!.toLocal(), localeCode: localeCode);
  final countdown = _resetCountdown(info, now);
  if (stamp != null) {
    buffer.write(' ${ru ? 'Обновится' : 'Resets'} $stamp');
    if (countdown != null) {
      buffer.write(
        ' — ${formatHumanCountdown(countdown, localeCode: localeCode)}',
      );
    }
    buffer.write('.');
  } else if (countdown != null) {
    final phrase = formatHumanCountdown(countdown, localeCode: localeCode);
    buffer.write(' ${ru ? 'Повтор' : 'Try again'} $phrase.');
  } else {
    buffer.write(' ${ru ? 'Попробуйте позже.' : 'Try again later.'}');
  }
  if (info.eligiblePromo case final promo? when promo.isNotEmpty) {
    buffer.write(' ${ru ? 'Доступно промо' : 'Promo available'}: $promo.');
  }
  // OQ1 (lean yes): one next-step line, mirroring the compaction-failure
  // hint — say what unblocks the user instead of leaving them stuck.
  buffer.write('\n');
  buffer.write(
    ru
        ? 'Далее: переключитесь на модель или провайдера со свободной квотой '
              '(/model в CLI или настройки провайдера в приложении).'
        : 'Next: switch to a model or provider with available quota '
              '(/model in the CLI, or provider settings in the app).',
  );
  return buffer.toString();
}

/// Countdown for the reset: server-derived values only ([E2] clock-skew
/// safety); `Retry-After` counts only when no reset time was advertised.
Duration? _resetCountdown(RateLimitInfo info, DateTime? now) {
  final seconds = info.resetsInSeconds;
  if (seconds != null && seconds > 0) return Duration(seconds: seconds);
  final resetsAt = info.resetsAt;
  if (resetsAt != null) {
    final delta = resetsAt.difference(now ?? DateTime.now());
    return delta.isNegative ? null : delta;
  }
  final retry = info.retryAfter;
  return retry != null && retry.inSeconds > 0 ? retry : null;
}

String _rateLimitTitle(RateLimitInfo info, bool ru) {
  if (info.planType case final plan? when plan.isNotEmpty) {
    final capitalized = plan[0].toUpperCase() + plan.substring(1);
    // Neutral by default: the generic parse layer decodes 429s from ANY
    // provider/proxy — only a branded adapter (codex) names its vendor.
    // Blank/whitespace values (a future adapter deriving the name from
    // config) keep the title well-formed — no double or leading space
    // (review round 2).
    final brand = info.brand?.trim();
    final hasBrand = brand != null && brand.isNotEmpty;
    return ru
        ? 'Лимит плана $capitalized${hasBrand ? ' $brand' : ''} '
              'исчерпан.'
        : '${hasBrand ? '$brand ' : ''}$capitalized plan limit '
              'reached.';
  }
  final kind = switch (info.limitKind) {
    null || '' => '',
    'primary' => ru ? ' (основной лимит)' : ' (primary limit)',
    'secondary' => ru ? ' (вторичный лимит)' : ' (secondary limit)',
    final other => ' ($other)',
  };
  return ru
      ? 'Достигнут лимит запросов$kind.'
      : 'Rate limit reached$kind.';
}

const _ruMonths = [
  'января',
  'февраля',
  'марта',
  'апреля',
  'мая',
  'июня',
  'июля',
  'августа',
  'сентября',
  'октября',
  'ноября',
  'декабря',
];

const _enMonths = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// The absolute reset stamp in human units («19 октября в 22:49» /
/// `October 19, 22:49`). Pass the moment already converted to the wall
/// clock it should render in (the caller does `resetsAt.toLocal()`).
String formatResetStamp(DateTime at, {String localeCode = 'en'}) {
  final ru = localeCode.toLowerCase().startsWith('ru');
  final hh = at.hour.toString().padLeft(2, '0');
  final mm = at.minute.toString().padLeft(2, '0');
  return ru
      ? '${at.day} ${_ruMonths[at.month - 1]} в $hh:$mm'
      : '${_enMonths[at.month - 1]} ${at.day}, $hh:$mm';
}

/// A duration in human units, magnitude-grained: seconds under a minute,
/// minutes under an hour, hours under a day, days beyond («через 45 сек» /
/// «через 3 часа» / «через 26 дней»; `in 45 sec` / `in 3 hours`).
String formatHumanCountdown(Duration duration, {String localeCode = 'en'}) {
  final ru = localeCode.toLowerCase().startsWith('ru');
  final total = duration.inSeconds;
  final int value;
  final String unit;
  if (total < 60) {
    value = total;
    unit = ru ? 'сек' : 'sec';
  } else if (total < 3600) {
    value = duration.inMinutes;
    unit = ru ? 'мин' : 'min';
  } else if (total < 86400) {
    value = duration.inHours;
    unit = ru
        ? _ruPlural(value, 'час', 'часа', 'часов')
        : (value == 1 ? 'hour' : 'hours');
  } else {
    value = duration.inDays;
    unit = ru
        ? _ruPlural(value, 'день', 'дня', 'дней')
        : (value == 1 ? 'day' : 'days');
  }
  return ru ? 'через $value $unit' : 'in $value $unit';
}

/// Russian plural slot for `один/два/пять`-style counting.
String _ruPlural(int n, String one, String few, String many) {
  if (n % 10 == 1 && n % 100 != 11) return one;
  if (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 12 || n % 100 > 14)) {
    return few;
  }
  return many;
}
