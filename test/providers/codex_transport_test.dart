import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('isAllowedChatgptHost', () {
    test('allows the exact apex hosts', () {
      expect(isAllowedChatgptHost('chatgpt.com'), isTrue);
      expect(isAllowedChatgptHost('chat.openai.com'), isTrue);
      expect(isAllowedChatgptHost('chatgpt-staging.com'), isTrue);
    });

    test('allows subdomains of chatgpt.com and chatgpt-staging.com', () {
      expect(isAllowedChatgptHost('api.chatgpt.com'), isTrue);
      expect(isAllowedChatgptHost('a.b.chatgpt.com'), isTrue);
      expect(isAllowedChatgptHost('backend.chatgpt-staging.com'), isTrue);
    });

    test('rejects subdomains of chat.openai.com', () {
      expect(isAllowedChatgptHost('auth.chat.openai.com'), isFalse);
      expect(isAllowedChatgptHost('api.chat.openai.com'), isFalse);
    });

    test('rejects suffix tricks and unknown hosts', () {
      expect(isAllowedChatgptHost('evilchatgpt.com'), isFalse);
      expect(isAllowedChatgptHost('chatgpt.com.evil.example'), isFalse);
      expect(isAllowedChatgptHost('chatgpt-staging.com.evil.example'), isFalse);
      expect(isAllowedChatgptHost('notchatgpt.com'), isFalse);
      expect(isAllowedChatgptHost('openai.com'), isFalse);
      expect(isAllowedChatgptHost(''), isFalse);
    });

    test('is case-insensitive', () {
      expect(isAllowedChatgptHost('ChatGPT.COM'), isTrue);
      expect(isAllowedChatgptHost('EVILCHATGPT.COM'), isFalse);
    });
  });

  group('isAllowedCloudflareCookieName', () {
    test('allows every codex-rs allowlisted name', () {
      for (final name in [
        '__cf_bm',
        '__cflb',
        '__cfruid',
        '__cfseq',
        '__cfwaitingroom',
        '_cfuvid',
        'cf_clearance',
        'cf_ob_info',
        'cf_use_ob',
      ]) {
        expect(isAllowedCloudflareCookieName(name), isTrue, reason: name);
      }
    });

    test('allows cf_chl_ prefixed challenge cookies', () {
      expect(isAllowedCloudflareCookieName('cf_chl_proc'), isTrue);
      expect(isAllowedCloudflareCookieName('cf_chl_opt'), isTrue);
    });

    test('rejects everything else', () {
      expect(isAllowedCloudflareCookieName('__oailb'), isFalse);
      expect(
        isAllowedCloudflareCookieName('__Secure-next-auth.session-token'),
        isFalse,
      );
      expect(isAllowedCloudflareCookieName('cf_clearance_extra'), isFalse);
      expect(isAllowedCloudflareCookieName('cf_x'), isFalse);
      expect(isAllowedCloudflareCookieName('cf_chl'), isFalse);
      expect(isAllowedCloudflareCookieName(''), isFalse);
    });
  });

  group('codexRequestHeaders', () {
    test('emits every header when all parameters are given', () {
      final headers = codexRequestHeaders(
        accessToken: 'tok',
        accountId: 'acct-1',
        sessionId: 'sess-1',
        threadId: 'thread-1',
        subagent: 'reviews',
      );
      expect(headers, {
        'authorization': 'Bearer tok',
        'ChatGPT-Account-ID': 'acct-1',
        'session-id': 'sess-1',
        'thread-id': 'thread-1',
        'x-client-request-id': 'thread-1',
        'originator': 'codex_cli_rs',
        'x-openai-subagent': 'reviews',
      });
    });

    test('omits account id, honors custom originator, when minimal', () {
      final headers = codexRequestHeaders(
        accessToken: 'tok',
        sessionId: 'sess-1',
        threadId: 'thread-1',
        originator: 'custom_originator',
      );
      expect(headers.keys, [
        'authorization',
        'session-id',
        'thread-id',
        'x-client-request-id',
        'originator',
      ]);
      expect(headers['originator'], 'custom_originator');
      expect(headers['x-client-request-id'], 'thread-1');
    });
  });

  group('CodexCookieJar', () {
    test('keeps allowlisted cookies and drops the rest (live fixture)', () {
      final jar = CodexCookieJar();
      jar.store(Uri.parse('https://chatgpt.com/backend-api/codex/responses'), {
        'set-cookie':
            '__cf_bm=cf-token; Path=/; Domain=chatgpt.com; '
            'Expires=Fri, 28 Aug 2026 09:00:51 GMT, '
            '__oailb=oai-token; Path=/; Max-Age=3600; HttpOnly; Secure',
      });
      expect(
        jar.cookieHeader(
          Uri.parse('https://chatgpt.com/backend-api/codex/responses'),
        ),
        '__cf_bm=cf-token',
      );
    });

    test('splits joined cookies without splitting Expires commas', () {
      final jar = CodexCookieJar();
      jar.store(Uri.parse('https://chatgpt.com/'), {
        'set-cookie':
            '__cfruid=ruid-1; Path=/; Expires=Fri, 28 Aug 2026 09:00:51 GMT, '
            'cf_clearance=clear-1; Path=/; Expires=Sat, 29 Aug 2026 09:00:51 GMT, '
            '__cfseq=seq-1; Path=/',
      });
      expect(
        jar.cookieHeader(Uri.parse('https://chatgpt.com/x')),
        '__cfruid=ruid-1; cf_clearance=clear-1; __cfseq=seq-1',
      );
    });

    test('reads multiple set-cookie entries case-insensitively', () {
      final jar = CodexCookieJar();
      jar.store(Uri.parse('https://chatgpt.com/'), {
        'Set-Cookie': '__cf_bm=bm-1; Path=/',
        'SET-COOKIE': '__cflb=lb-1; Path=/',
        'X-Other': 'ignore',
      });
      expect(
        jar.cookieHeader(Uri.parse('https://chatgpt.com/')),
        '__cf_bm=bm-1; __cflb=lb-1',
      );
    });

    test('ignores non-https storage and lookups', () {
      final jar = CodexCookieJar();
      jar.store(Uri.parse('http://chatgpt.com/'), {
        'set-cookie': '__cf_bm=bm-1; Path=/',
      });
      expect(jar.cookieHeader(Uri.parse('http://chatgpt.com/')), isNull);
      expect(jar.cookieHeader(Uri.parse('https://chatgpt.com/')), isNull);
    });

    test(
      'ignores storage on disallowed hosts and leaks nothing across hosts',
      () {
        final jar = CodexCookieJar();
        jar.store(Uri.parse('https://evilchatgpt.com/'), {
          'set-cookie': '__cf_bm=bm-1; Path=/',
        });
        jar.store(Uri.parse('https://api.chat.openai.com/'), {
          'set-cookie': '__cf_bm=bm-2; Path=/',
        });
        jar.store(Uri.parse('https://chatgpt.com/'), {
          'set-cookie': '__cf_bm=bm-3; Path=/',
        });
        expect(jar.cookieHeader(Uri.parse('https://evilchatgpt.com/')), isNull);
        expect(
          jar.cookieHeader(Uri.parse('https://api.chat.openai.com/')),
          isNull,
        );
        expect(
          jar.cookieHeader(Uri.parse('https://chatgpt-staging.com/')),
          isNull,
        );
        expect(
          jar.cookieHeader(Uri.parse('https://chatgpt.com/anything')),
          '__cf_bm=bm-3',
        );
      },
    );

    test('scopes cookies to their path at a slash boundary', () {
      final jar = CodexCookieJar();
      jar.store(Uri.parse('https://chatgpt.com/backend-api/codex/responses'), {
        'set-cookie': '__cf_bm=api; Path=/backend-api',
      });
      expect(
        jar.cookieHeader(Uri.parse('https://chatgpt.com/backend-api/codex')),
        '__cf_bm=api',
      );
      expect(
        jar.cookieHeader(Uri.parse('https://chatgpt.com/backend')),
        isNull,
      );
      expect(
        jar.cookieHeader(Uri.parse('https://chatgpt.com/backendotic')),
        isNull,
      );
    });

    test('defaults the path to root so every path matches', () {
      final jar = CodexCookieJar();
      jar.store(Uri.parse('https://chatgpt.com/'), {
        'set-cookie': '__cfruid=ruid-1',
      });
      expect(
        jar.cookieHeader(Uri.parse('https://chatgpt.com/deep/nested')),
        '__cfruid=ruid-1',
      );
    });

    test('Max-Age<=0 and empty values delete stored cookies', () {
      final jar = CodexCookieJar();
      jar.store(Uri.parse('https://chatgpt.com/'), {
        'set-cookie': '__cf_bm=bm-1; Path=/; Max-Age=3600',
      });
      jar.store(Uri.parse('https://chatgpt.com/'), {
        'set-cookie': '__cf_bm=bm-1; Path=/; Max-Age=0',
      });
      expect(jar.cookieHeader(Uri.parse('https://chatgpt.com/')), isNull);

      jar.store(Uri.parse('https://chatgpt.com/'), {
        'set-cookie': '__cf_bm=bm-2; Path=/; Max-Age=3600',
      });
      jar.store(Uri.parse('https://chatgpt.com/'), {
        'set-cookie': '__cf_bm=bm-2; Path=/; Max-Age=-1',
      });
      expect(jar.cookieHeader(Uri.parse('https://chatgpt.com/')), isNull);

      jar.store(Uri.parse('https://chatgpt.com/'), {
        'set-cookie': '__cf_bm=bm-3; Path=/; Max-Age=3600',
      });
      jar.store(Uri.parse('https://chatgpt.com/'), {
        'set-cookie': '__cf_bm=; Path=/',
      });
      expect(jar.cookieHeader(Uri.parse('https://chatgpt.com/')), isNull);
    });

    test('re-set replaces the stored value', () {
      final jar = CodexCookieJar();
      jar.store(Uri.parse('https://chatgpt.com/'), {
        'set-cookie': '__cf_bm=old; Path=/',
      });
      jar.store(Uri.parse('https://chatgpt.com/'), {
        'set-cookie': '__cf_bm=new; Path=/',
      });
      expect(
        jar.cookieHeader(Uri.parse('https://chatgpt.com/')),
        '__cf_bm=new',
      );
    });

    test('ignores the Domain attribute and stays host-keyed', () {
      final jar = CodexCookieJar();
      jar.store(Uri.parse('https://chatgpt.com/'), {
        'set-cookie': '__cf_bm=bm-1; Path=/; Domain=api.chatgpt.com',
      });
      expect(
        jar.cookieHeader(Uri.parse('https://chatgpt.com/')),
        '__cf_bm=bm-1',
      );
      expect(jar.cookieHeader(Uri.parse('https://api.chatgpt.com/')), isNull);
    });

    test('malformed cookie strings are skipped', () {
      final jar = CodexCookieJar();
      jar.store(Uri.parse('https://chatgpt.com/'), {
        'set-cookie': 'novalue, =novalue2, __cf_bm=ok; Path=/',
      });
      expect(jar.cookieHeader(Uri.parse('https://chatgpt.com/')), '__cf_bm=ok');
    });
  });

  group('parseCodexRateLimits', () {
    test('parses the full header set, case-insensitively', () {
      final limits = parseCodexRateLimits({
        'X-Codex-Primary-Used-Percent': '12.5',
        'x-codex-primary-window-minutes': '60',
        'X-CODEX-PRIMARY-RESET-AT': '1790000000',
        'x-codex-secondary-used-percent': '3.25',
        'x-codex-secondary-window-minutes': '10080',
        'x-codex-secondary-reset-at': '1790000400',
        'x-codex-limit-name': 'Codex Pro',
      });
      expect(limits, isNotNull);
      expect(limits!.primary!.usedPercent, 12.5);
      expect(limits.primary!.windowMinutes, 60);
      expect(limits.primary!.resetsAt, 1790000000);
      expect(limits.secondary!.usedPercent, 3.25);
      expect(limits.secondary!.windowMinutes, 10080);
      expect(limits.secondary!.resetsAt, 1790000400);
      expect(limits.limitName, 'Codex Pro');
    });

    test('returns null when no codex headers are present', () {
      expect(parseCodexRateLimits({}), isNull);
      expect(
        parseCodexRateLimits({'content-type': 'application/json'}),
        isNull,
      );
    });

    test('treats garbage numbers as absent fields', () {
      expect(
        parseCodexRateLimits({
          'x-codex-primary-used-percent': 'abc',
          'x-codex-primary-window-minutes': 'soon',
          'x-codex-primary-reset-at': 'maybe',
          'x-codex-limit-name': 'Codex Pro',
        })!.primary,
        isNull,
      );
      final window = parseCodexRateLimits({
        'x-codex-primary-used-percent': '12.5',
        'x-codex-primary-window-minutes': 'soon',
        'x-codex-primary-reset-at': 'maybe',
      })!.primary;
      expect(window!.usedPercent, 12.5);
      expect(window.windowMinutes, isNull);
      expect(window.resetsAt, isNull);
    });

    test('a window needs a non-zero field beyond used percent', () {
      expect(
        parseCodexRateLimits({'x-codex-primary-used-percent': '0'}),
        isNull,
      );
      final zeroUsed = parseCodexRateLimits({
        'x-codex-primary-used-percent': '0',
        'x-codex-primary-reset-at': '1790000000',
      });
      expect(zeroUsed!.primary, isNotNull);
      expect(zeroUsed.primary!.usedPercent, 0);
      expect(zeroUsed.primary!.resetsAt, 1790000000);
      final zeroMinutes = parseCodexRateLimits({
        'x-codex-primary-used-percent': '0',
        'x-codex-primary-window-minutes': '5',
      });
      expect(zeroMinutes!.primary!.windowMinutes, 5);
    });

    test('keeps limits alive on limit name or a single window alone', () {
      final byName = parseCodexRateLimits({
        'x-codex-limit-name': 'Codex Pro',
        'x-codex-primary-used-percent': '0',
      });
      expect(byName!.primary, isNull);
      expect(byName.secondary, isNull);
      expect(byName.limitName, 'Codex Pro');

      final secondaryOnly = parseCodexRateLimits({
        'x-codex-secondary-used-percent': '7.5',
      });
      expect(secondaryOnly!.primary, isNull);
      expect(secondaryOnly.secondary!.usedPercent, 7.5);
      expect(secondaryOnly.limitName, isNull);
    });
  });
}
