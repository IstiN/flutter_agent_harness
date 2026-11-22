import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('FaProductConfig stock compatibility', () {
    test(
      'stock has no cloud endpoint, feature, or renamed storage namespace',
      () {
        const config = FaProductConfig.stock;
        expect(config.isStock, isTrue);
        expect(config.displayName, 'Fa');
        expect(config.cloudSyncEnabled, isFalse);
        expect(config.storageNamespace(1), isNull);
        expect(config.featureFlags, isEmpty);
        expect(config.driveEndpoint, isNull);
        expect(config.sessionEndpoint, isNull);
      },
    );

    test('an explicit profile is branded even when its product id is fa', () {
      final config = FaProductConfig.fromJson(_valid(productId: 'fa'));
      expect(config.isStock, isFalse);
      expect(config.storageNamespace(1), 'fa-product:fa:schema:1');
    });
  });

  group('external profile validation', () {
    test(
      'parses brand, endpoint, legal and flag metadata without credentials',
      () {
        final config = FaProductConfig.fromJson(_valid());
        expect(config.productId, 'host-product');
        expect(config.displayName, 'Host Workspace');
        expect(config.brandAssets['icon192'], 'icons/icon-192.png');
        expect(config.themePackId, 'host-theme');
        expect(
          config.legalLinks['privacy'],
          Uri.parse('https://legal.example/privacy'),
        );
        expect(config.cloudSyncEnabled, isTrue);
        expect(config.storageNamespace(3), 'fa-product:host-product:schema:3');
      },
    );

    test('cloud remains off without the explicit flag or an endpoint', () {
      expect(
        FaProductConfig.fromJson(
          _valid(featureFlags: <Object?>[]),
        ).cloudSyncEnabled,
        isFalse,
      );
      expect(
        FaProductConfig.fromJson(
          _valid(driveEndpoint: null, sessionEndpoint: null),
        ).cloudSyncEnabled,
        isFalse,
      );
    });

    for (final invalid in <Map<String, Object?>>[
      _valid(productId: '../escape'),
      _valid(displayName: '<script>alert(1)</script>'),
      _valid(brandAssets: {'icon192': '/etc/passwd'}),
      _valid(brandAssets: {'icon192': '../secret.png'}),
      _valid(brandAssets: {'icon192': r'icons\secret.png'}),
      _valid(driveEndpoint: 'https://drive.example/#fragment'),
      _valid(apiEndpoint: 'http://api.example'),
      _valid(
        oauthCallback: 'https://other.example/callback',
        authEndpoint: null,
      ),
      _valid(featureFlags: <Object?>['cloudSync', 42]),
      _valid(legalLinks: {'privacy': 'javascript:alert(1)'}),
      _valid(apiKey: '[REDACTED:Sensitive-Value]'),
      _valid(
        extension: {
          'nested': {'refreshToken': 'secret'},
        },
      ),
    ]) {
      test(
        'rejects ${invalid.toString().substring(0, invalid.toString().length.clamp(0, 100))}',
        () {
          expect(
            () => FaProductConfig.fromJson(invalid),
            throwsFormatException,
          );
        },
      );
    }

    test('declarative host theme pack is public metadata, not code', () {
      final config = FaProductConfig.fromJson({
        ..._valid(),
        'themePackId': 'host-theme',
        'themePack': {
          'name': 'Host Theme',
          'version': '1.0.0',
          'colors': {
            'dark': {'accent': '#2E7D32'},
          },
        },
      });
      expect(config.themePack!['version'], '1.0.0');
      expect(config.themePackId, 'host-theme');
      expect(
        () => FaProductConfig.fromJson({
          ..._valid(),
          'themePackId': null,
          'themePack': {
            'name': 'Host Theme',
            'version': '1.0.0',
            'colors': <String, Object?>{},
          },
        }),
        throwsFormatException,
      );
      for (final themePack in [
        {
          'name': 'Host Theme',
          'version': '1.0.0',
          'colors': {
            'dark': {'accent': '</script><script>alert(1)</script>'},
          },
        },
        {
          'name': 'Host Theme</script><script>alert(1)</script>',
          'version': '1.0.0',
          'colors': <String, Object?>{},
        },
      ]) {
        expect(
          () => FaProductConfig.fromJson({
            ..._valid(),
            'themePackId': 'host-theme',
            'themePack': themePack,
          }),
          throwsFormatException,
        );
      }
      expect(
        () => FaProductConfig.fromJson({
          ..._valid(),
          'themePackId': 'wrong-slug',
          'themePack': {
            'name': 'Host Theme',
            'version': '1.0.0',
            'colors': <String, Object?>{},
          },
        }),
        throwsFormatException,
      );
    });

    test('schema upgrades and explicit drive aliases remain namespaced', () {
      final config = FaProductConfig.fromJson({
        ..._valid(),
        'storageSchemaVersion': 2,
        'driveAliases': ['/health', '/research-docs'],
      });
      expect(config.storageSchemaVersion, 2);
      expect(
        config.storageNamespace(config.storageSchemaVersion),
        'fa-product:host-product:schema:2',
      );
      expect(config.driveAliases, {'/health', '/research-docs'});
      expect(
        () =>
            FaProductConfig.fromJson({..._valid(), 'storageSchemaVersion': 0}),
        throwsFormatException,
      );
      expect(
        () => FaProductConfig.fromJson({
          ..._valid(),
          'driveAliases': ['/drive'],
        }),
        throwsFormatException,
      );
    });

    test(
      'loopback HTTP is allowed for deterministic local development only',
      () {
        final config = FaProductConfig.fromJson(
          _valid(apiEndpoint: 'http://127.0.0.1:8080/api'),
        );
        expect(config.apiEndpoint, Uri.parse('http://127.0.0.1:8080/api'));
      },
    );
  });

  group('OAuth callback and account fencing', () {
    test(
      'callback requires exact profile URI and expected non-empty state',
      () {
        final config = FaProductConfig.fromJson(_valid());
        final callback = config.oauthCallback!;
        expect(
          config.acceptsOAuthCallback(
            callback,
            expectedState: 'state-1',
            receivedState: 'state-1',
          ),
          isTrue,
        );
        expect(
          config.acceptsOAuthCallback(
            callback.replace(query: 'other=1'),
            expectedState: 'state-1',
            receivedState: 'state-1',
          ),
          isFalse,
        );
        expect(
          config.acceptsOAuthCallback(
            callback,
            expectedState: 'state-1',
            receivedState: 'forged',
          ),
          isFalse,
        );
      },
    );

    test(
      'account namespace uses immutable subject, isolates switches, hides raw ids',
      () {
        final config = FaProductConfig.fromJson(_valid());
        const a = CloudIdentity(
          tenantId: 'tenant-a',
          subject: 'subject-a',
          deviceId: 'device-a',
          authGeneration: 1,
        );
        const b = CloudIdentity(
          tenantId: 'tenant-a',
          subject: 'subject-b',
          deviceId: 'device-a',
          authGeneration: 1,
        );
        final aNamespace = config.accountNamespace(a, 1);
        expect(aNamespace, isNot(config.accountNamespace(b, 1)));
        expect(aNamespace, isNot(contains('tenant-a')));
        expect(aNamespace, isNot(contains('subject-a')));
        expect(aNamespace, config.accountNamespace(a.nextGeneration(), 1));
      },
    );

    test(
      'generation advance fences old work without moving the account cache',
      () {
        const identity = CloudIdentity(
          tenantId: 'tenant-a',
          subject: 'subject-a',
          deviceId: 'device-a',
          authGeneration: 1,
        );
        final active = identity.nextGeneration();
        expect(identity.canWriteFor(active), isFalse);
        expect(active.canWriteFor(active), isTrue);
        expect(identity.accountKey, active.accountKey);
      },
    );

    test('email is never accepted as the immutable subject', () {
      expect(
        () => const CloudIdentity(
          tenantId: 'tenant',
          subject: 'user\u0040example.com',
          deviceId: 'device',
          authGeneration: 1,
        ).validate(),
        throwsFormatException,
      );
    });
  });
}

Map<String, Object?> _valid({
  String productId = 'host-product',
  String displayName = 'Host Workspace',
  Object? brandAssets = const {'icon192': 'icons/icon-192.png'},
  Object? driveEndpoint = 'https://drive.example/v1',
  Object? sessionEndpoint = 'https://sessions.example/v1',
  Object? apiEndpoint = 'https://api.example/v1',
  Object? authEndpoint = 'https://auth.example/authorize',
  Object? oauthCallback = 'https://app.example/oauth/callback',
  Object? legalLinks = const {'privacy': 'https://legal.example/privacy'},
  List<Object?> featureFlags = const ['cloudSync'],
  Object? apiKey,
  Object? extension,
}) {
  final json = <String, Object?>{
    'productId': productId,
    'displayName': displayName,
    'description': 'A host-owned workspace',
    'brandAssets': brandAssets,
    'themePackId': 'host-theme',
    'authEndpoint': authEndpoint,
    'apiEndpoint': apiEndpoint,
    'driveEndpoint': driveEndpoint,
    'sessionEndpoint': sessionEndpoint,
    'oauthCallback': oauthCallback,
    'legalLinks': legalLinks,
    'featureFlags': featureFlags,
  };
  if (apiKey case final key?) json['apiKey'] = key;
  if (extension case final value?) json['extension'] = value;
  return json;
}
