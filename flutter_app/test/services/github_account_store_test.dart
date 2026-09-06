// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/github_account_store.dart';
import 'package:fa_ui/fa_ui.dart' show SessionKeysStore;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GithubAccountStore', () {
    test('starts disconnected; connect stores token + profile', () async {
      final keys = SessionKeysStore.inMemory();
      final store = GithubAccountStore(keys: keys);
      expect(store.isConnected, isFalse);
      expect(store.token, isNull);
      expect(store.login, isNull);

      await store.connect(
        token: 'gho_test123',
        login: 'octocat',
        avatarUrl: 'https://avatars.example/u/1',
      );
      expect(store.isConnected, isTrue);
      expect(store.token, 'gho_test123');
      expect(store.login, 'octocat');
      expect(store.avatarUrl, 'https://avatars.example/u/1');
    });

    test('reconnect overwrites the same entries (rotation)', () async {
      final keys = SessionKeysStore.inMemory();
      final store = GithubAccountStore(keys: keys);
      await store.connect(token: 'old', login: 'octocat');
      await store.connect(token: 'new', login: 'hubot');
      expect(store.token, 'new');
      expect(store.login, 'hubot');
      // No stale avatar from the previous account.
      expect(store.avatarUrl, isNull);
    });

    test('disconnect removes token AND profile', () async {
      final keys = SessionKeysStore.inMemory();
      final store = GithubAccountStore(keys: keys);
      await store.connect(
        token: 'gho_test123',
        login: 'octocat',
        avatarUrl: 'x',
      );
      await store.disconnect();
      expect(store.isConnected, isFalse);
      expect(store.login, isNull);
      expect(store.avatarUrl, isNull);
      for (final name in keys.names) {
        expect(GithubAccountStore.isGithubKey(name), isFalse);
      }
    });

    test('an empty token is rejected', () async {
      final store = GithubAccountStore(keys: SessionKeysStore.inMemory());
      expect(
        () => store.connect(token: '   ', login: 'octocat'),
        throwsArgumentError,
      );
      expect(store.isConnected, isFalse);
    });

    test('a stale profile without a token reads as disconnected', () async {
      final keys = SessionKeysStore.inMemory();
      final store = GithubAccountStore(keys: keys);
      await keys.set(GithubAccountStore.loginKey, 'ghost');
      expect(store.isConnected, isFalse);
      // …but the profile is still readable for a "reconnect required" row.
      expect(store.login, 'ghost');
    });

    test('isGithubKey marks the owned prefix', () {
      expect(GithubAccountStore.isGithubKey('FA_GITHUB_TOKEN'), isTrue);
      expect(GithubAccountStore.isGithubKey('FA_GITHUB_LOGIN'), isTrue);
      expect(GithubAccountStore.isGithubKey('OPENROUTER_API_KEY'), isFalse);
    });

    test('listeners are notified on connect/disconnect', () async {
      final keys = SessionKeysStore.inMemory();
      final store = GithubAccountStore(keys: keys);
      var notified = 0;
      store.addListener(() => notified++);
      await store.connect(token: 't', login: 'l');
      await store.disconnect();
      expect(notified, greaterThanOrEqualTo(2));
    });
  });
}
