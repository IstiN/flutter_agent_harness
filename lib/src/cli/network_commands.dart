// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Testable implementation of `fa network login|logout|enroll|status|
/// devices|rename`. All HTTP, OAuth-loopback, storage and output effects are
/// injected; production composition lives in `bin/fah_network.dart`.
library;

import 'dart:async';

import '../network/connector/device_api.dart';
import '../network/network_account.dart';
import '../network/network_account_client.dart';
import '../network/network_roster.dart';
import 'network_store.dart';

/// One bound OAuth callback endpoint. The redirect URI exists before
/// initiation, so its ephemeral port can be sent as `client_redirect_uri`.
abstract interface class NetworkOAuthCallbackReceiver {
  /// Loopback redirect registered with the auth service.
  Uri get redirectUri;

  /// Resolves with the final callback URI.
  Future<Uri> get callback;

  /// Releases the listener; idempotent.
  Future<void> close();
}

/// Starts a loopback callback receiver.
typedef NetworkStartOAuthReceiver =
    Future<NetworkOAuthCallbackReceiver> Function();

/// Opens an authorization URL in the system browser (or prints it when
/// browser launch is disabled).
typedef NetworkOpenAuthUrl = Future<void> Function(Uri authUrl);

/// Reads device rows from the device-socket roster for `--roster` debugging.
typedef NetworkRosterReader = Future<List<NetworkDeviceRow>> Function();

/// Interactive host prompt (the TUI's masked/free-form prompt in production).
typedef NetworkCommandPrompt =
    Future<String?> Function(String question, {bool secret});

/// Pure OAuth sequencing, shared by production and fake-receiver tests.
final class NetworkOAuthFlow {
  /// Builds the flow.
  NetworkOAuthFlow({
    required this.client,
    required this.startReceiver,
    required this.openUrl,
  });

  /// Auth HTTP client.
  final NetworkAccountClient client;

  /// Loopback receiver factory.
  final NetworkStartOAuthReceiver startReceiver;

  /// Browser opener.
  final NetworkOpenAuthUrl openUrl;

  /// Runs initiate → browser → validated loopback callback → exchange.
  Future<NetworkAccount> signIn({String provider = 'google'}) async {
    final receiver = await startReceiver();
    try {
      final initiated = await client.initiate(
        provider: provider,
        redirectUri: receiver.redirectUri,
      );
      await openUrl(initiated.authUrl);
      final callback = await receiver.callback;
      final error = callback.queryParameters['error'];
      if (error != null && error.isNotEmpty) {
        throw NetworkAuthException(
          callback.queryParameters['error_description'] ?? error,
        );
      }
      if (callback.queryParameters['state'] != initiated.state) {
        throw const NetworkAuthException(
          'sign-in state mismatch; callback rejected',
        );
      }
      final code = callback.queryParameters['code'];
      if (code == null || code.isEmpty) {
        throw const NetworkAuthException('sign-in callback carried no code');
      }
      return await client.exchange(code: code, state: initiated.state);
    } finally {
      await receiver.close();
    }
  }
}

/// Command-line controller. Secret values are accepted as inputs but never
/// included in output, usage errors, or status rendering.
final class NetworkCommandRunner {
  /// Builds a runner.
  NetworkCommandRunner({
    required this.store,
    required this.accountClient,
    required this.deviceClient,
    this.relayBaseUrl = networkRelayProductionUrl,
    this.deviceName = 'fa-cli',
    this.platform = 'unknown',
    this.startReceiver,
    this.openUrl,
    this.rosterReader,
    this.prompt,
    DateTime Function()? clock,
    void Function(String line)? out,
    void Function(String line)? error,
  }) : _clock = clock ?? DateTime.now,
       _out = out ?? _discard,
       _error = error ?? _discard;

  /// Credential persistence.
  final NetworkCredentialStore store;

  /// Account OAuth/refresh client.
  final NetworkAccountClient accountClient;

  /// Device enrollment/list/rename client.
  final DeviceEnrollmentClient deviceClient;

  /// OAuth receiver factory, absent on non-IO hosts.
  final NetworkStartOAuthReceiver? startReceiver;

  /// Browser opener, absent on non-IO hosts.
  final NetworkOpenAuthUrl? openUrl;

  /// Socket-roster debug reader, absent on non-IO hosts.
  final NetworkRosterReader? rosterReader;

  /// Interactive prompt, null for headless `fa network` commands.
  final NetworkCommandPrompt? prompt;
  final DateTime Function() _clock;
  final void Function(String line) _out;
  final void Function(String line) _error;

  /// fa_network relay root.
  final String relayBaseUrl;

  /// Enrollment host name.
  final String deviceName;

  /// Enrollment host platform.
  final String platform;

  /// Runs [args] after the leading `network` word; returns a process exit code.
  Future<int> run(List<String> args) async {
    try {
      if (args.isEmpty || args.first == 'help' || args.first == '--help') {
        _out(usage);
        return args.isEmpty ? 64 : 0;
      }
      return await _dispatch(args);
    } on Object catch (error) {
      _error('fa network: $error');
      return 1;
    }
  }

  Future<int> _dispatch(List<String> args) async {
    return await switch (args.first) {
      'login' => _login(args.sublist(1)),
      'logout' => _logout(args.sublist(1)),
      'enroll' => _enroll(args.sublist(1)),
      'status' => _status(args.sublist(1)),
      'devices' => _devices(args.sublist(1)),
      'rename' => _rename(args.sublist(1)),
      _ => _usageError('unknown network command: ${args.first}'),
    };
  }

  /// Command reference printed by `fa network --help`.
  static const usage = '''
fa network login [--provider google]     OAuth loopback sign-in
fa network login --jwt <token>           Store a pasted account JWT (headless)
fa network logout                       Clear account + device credentials
fa network enroll [--name <hostname>]    Enroll this machine with the account JWT
fa network status                       Show account/device/phase (no secrets)
fa network devices                      List this account's devices and names
fa network devices --roster             Debug the device-socket roster frames
fa network rename <name>                Rename THIS device (1–64 characters)
fa network rename --clear               Clear THIS device's friendly name''';

  Future<int> _login(List<String> args) async {
    var options = _parseLoginArgs(args);
    if (options.error == '--jwt requires a token' &&
        args.length == 1 &&
        args.single == '--jwt' &&
        prompt != null) {
      final pasted = await prompt!('JWT token: ', secret: true);
      options = (jwt: pasted, provider: options.provider, error: null);
    }
    if (options.error case final error?) return _usageError(error);
    final jwt = options.jwt;
    final provider = options.provider;
    final NetworkAccount account;
    if (jwt != null) {
      if (jwt.trim().isEmpty) return _usageError('--jwt requires a token');
      account = NetworkAccount.fromJwt(jwt.trim());
    } else {
      final start = startReceiver;
      final open = openUrl;
      if (start == null || open == null) {
        return _usageError('OAuth loopback is unavailable on this host');
      }
      if (provider.trim().isEmpty) {
        return _usageError('--provider requires a name');
      }
      account = await NetworkOAuthFlow(
        client: accountClient,
        startReceiver: start,
        openUrl: open,
      ).signIn(provider: provider);
    }
    await _completeLogin(account);
    return 0;
  }

  Future<void> _completeLogin(NetworkAccount account) async {
    final previousAccount = await store.readAccount();
    final previousDevice = await store.readDevice();
    // Re-login/token refresh on the same account must not orphan the stored
    // device token and manufacture a duplicate enrollment on the next enroll.
    // An actual account switch still clears the old account's device pairing.
    if (previousDevice == null ||
        !_sameNetworkAccount(previousAccount, account)) {
      await store.clearDevice();
    }
    await store.writeAccount(account);
    _out('signed in: ${account.label}');
    _out(prompt == null ? 'next: fa network enroll' : 'next: /network enroll');
  }

  static ({String? jwt, String provider, String? error}) _parseLoginArgs(
    List<String> args,
  ) {
    String? jwt;
    var provider = 'google';
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--jwt') {
        if (++i >= args.length) {
          return (
            jwt: jwt,
            provider: provider,
            error: '--jwt requires a token',
          );
        }
        jwt = args[i];
      } else if (arg.startsWith('--jwt=')) {
        jwt = arg.substring('--jwt='.length);
      } else if (arg == '--provider') {
        if (++i >= args.length) {
          return (
            jwt: jwt,
            provider: provider,
            error: '--provider requires a name',
          );
        }
        provider = args[i];
      } else if (arg.startsWith('--provider=')) {
        provider = arg.substring('--provider='.length);
      } else {
        // Do not echo a positional value: it may be a pasted token whose
        // --jwt flag was accidentally omitted.
        return (jwt: jwt, provider: provider, error: 'unknown login option');
      }
    }
    return (jwt: jwt, provider: provider, error: null);
  }

  Future<int> _logout(List<String> args) async {
    if (args.isNotEmpty) return _usageError('logout takes no arguments');
    await store.clear();
    _out('signed out; account and device credentials cleared');
    return 0;
  }

  Future<int> _enroll(List<String> args) async {
    final options = _parseEnrollArgs(args, deviceName);
    if (options.error case final error?) return _usageError(error);
    var name = options.name;
    final explicitName = options.explicitName;
    if (explicitName && (name.trim().isEmpty || name.runes.length > 128)) {
      return _usageError('device name must contain 1–128 characters');
    }
    final account = await store.readAccount();
    if (account == null) return _usageError('not signed in; run login first');
    final existing = await store.readDevice();
    if (existing != null) {
      _out('already enrolled: ${existing.deviceId}');
      _out('personal network: ${existing.personalNetworkId ?? 'unknown'}');
      _printEnrollmentNextSteps();
      return 0;
    }
    if (!explicitName && prompt != null) {
      final answer = await prompt!('Device name (empty = $deviceName): ');
      if (answer == null) {
        _out('enrollment cancelled');
        return 1;
      }
      if (answer.trim().isNotEmpty) name = answer;
    }
    if (name.trim().isEmpty || name.runes.length > 128) {
      return _usageError('device name must contain 1–128 characters');
    }
    final fresh = await _freshAccount(account);
    final enrollment = await deviceClient.enrollDevice(
      baseUrl: relayBaseUrl,
      jwt: fresh.accessToken,
      name: name.trim(),
      platform: platform,
    );
    final device = NetworkDeviceCredentials(
      deviceId: enrollment.deviceId,
      deviceToken: enrollment.deviceToken,
      personalNetworkId: enrollment.personalNetworkId,
      name: name.trim(),
      platform: platform,
    );
    await store.writeDevice(device);
    _out('enrolled: ${device.deviceId}');
    _out('personal network: ${device.personalNetworkId ?? 'unknown'}');
    _printEnrollmentNextSteps();
    return 0;
  }

  static ({String name, bool explicitName, String? error}) _parseEnrollArgs(
    List<String> args,
    String initialName,
  ) {
    var name = initialName;
    var explicitName = false;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--name') {
        if (++i >= args.length) {
          return (
            name: name,
            explicitName: explicitName,
            error: '--name requires a value',
          );
        }
        name = args[i];
        explicitName = true;
      } else if (arg.startsWith('--name=')) {
        name = arg.substring('--name='.length);
        explicitName = true;
      } else {
        return (
          name: name,
          explicitName: explicitName,
          error: 'unknown enroll option: $arg',
        );
      }
    }
    return (name: name, explicitName: explicitName, error: null);
  }

  void _printEnrollmentNextSteps() {
    _out('sessions appear in the app Devices surface (Devices → session row)');
    _out('only live sessions are steerable; wake sleepers from Devices');
  }

  Future<int> _status(List<String> args) async {
    if (args.isNotEmpty) return _usageError('status takes no arguments');
    final account = await store.readAccount();
    final device = await store.readDevice();
    _out('account: ${account?.label ?? 'signed out'}');
    if (account?.expiresAt case final expiry?) {
      _out(
        'access expiry: ${expiry.toIso8601String()} '
        '(${account!.isExpired(_clock()) ? 'expired' : 'valid'})',
      );
    } else if (account != null) {
      _out('access expiry: not declared');
    }
    final deviceLabel = device == null
        ? 'not enrolled'
        : '${device.deviceId} (${device.friendlyName ?? device.name ?? 'unnamed'})';
    _out('device: $deviceLabel');
    _out('personal network: ${device?.personalNetworkId ?? '-'}');
    _out(
      'phase: ${account == null
          ? 'signed_out'
          : device == null
          ? 'signed_in'
          : 'enrolled'}',
    );
    return 0;
  }

  Future<int> _devices(List<String> args) async {
    if (args.length == 1 && args.single == '--roster') {
      final read = rosterReader;
      if (read == null) return _usageError('socket roster is unavailable');
      final rows = await read();
      _out('roster devices: ${rows.length}');
      for (final row in rows) {
        _out(row.format());
        for (final session in row.formatSessions()) {
          _out(session);
        }
      }
      return 0;
    }
    if (args.isNotEmpty) {
      return _usageError('devices accepts only --roster');
    }
    final account = await _requireAccount();
    final fresh = await _freshAccount(account);
    final devices = await deviceClient.listDevices(
      baseUrl: relayBaseUrl,
      jwt: fresh.accessToken,
    );
    _out('devices: ${devices.length}');
    for (final device in devices) {
      final enrollmentName = device.friendlyName == null
          ? ''
          : ' (host: ${device.name})';
      final revoked = device.revokedAt == null ? '' : ' [revoked]';
      _out('${device.deviceId}  ${device.displayName}$enrollmentName$revoked');
    }
    return 0;
  }

  Future<int> _rename(List<String> args) async {
    final request = _parseRenameArgs(args);
    if (request.error case final error?) return _usageError(error);
    final name = request.name;
    final device = await store.readDevice();
    if (device == null) return _usageError('not enrolled; run enroll first');
    final account = await _requireAccount();
    final fresh = await _freshAccount(account);
    final friendly = await deviceClient.renameDevice(
      baseUrl: relayBaseUrl,
      jwt: fresh.accessToken,
      deviceId: device.deviceId,
      name: name,
    );
    await store.writeDevice(
      NetworkDeviceCredentials(
        deviceId: device.deviceId,
        deviceToken: device.deviceToken,
        personalNetworkId: device.personalNetworkId,
        name: device.name,
        friendlyName: friendly.isEmpty ? null : friendly,
        platform: device.platform,
        dmPrivateKeys: device.dmPrivateKeys,
      ),
    );
    _out(
      friendly.isEmpty
          ? 'friendly name cleared: ${device.deviceId}'
          : 'renamed ${device.deviceId}: $friendly',
    );
    return 0;
  }

  static ({String name, String? error}) _parseRenameArgs(List<String> args) {
    if (args.contains('--clear') && args.length != 1) {
      return (name: '', error: '--clear cannot be combined with a name');
    }
    final clear = args.length == 1 && args.first == '--clear';
    if (!clear && args.isEmpty) {
      return (name: '', error: 'rename requires a name, or --clear');
    }
    final name = clear ? '' : args.join(' ').trim();
    if (!clear && name.isEmpty) {
      return (name: '', error: 'rename requires a name');
    }
    if (name.runes.length > 64) {
      return (name: '', error: 'friendly name must be at most 64 characters');
    }
    return (name: name, error: null);
  }

  bool _sameNetworkAccount(NetworkAccount? previous, NetworkAccount next) {
    if (previous == null) return false;
    final previousSubject = previous.subject?.trim();
    final nextSubject = next.subject?.trim();
    if (previousSubject?.isNotEmpty == true ||
        nextSubject?.isNotEmpty == true) {
      return previousSubject?.isNotEmpty == true &&
          nextSubject?.isNotEmpty == true &&
          previousSubject == nextSubject;
    }
    final previousEmail = previous.email?.trim().toLowerCase();
    final nextEmail = next.email?.trim().toLowerCase();
    return previousEmail != null &&
        previousEmail.isNotEmpty &&
        nextEmail != null &&
        previousEmail == nextEmail;
  }

  Future<NetworkAccount> _requireAccount() async {
    final account = await store.readAccount();
    if (account == null) {
      throw const NetworkAuthException('not signed in; run login first');
    }
    return account;
  }

  Future<NetworkAccount> _freshAccount(NetworkAccount account) async {
    if (!account.isExpired(_clock())) return account;
    final refresh = account.refreshToken;
    if (refresh == null || refresh.isEmpty) {
      throw const NetworkAuthException(
        'access token expired; run fa network login --jwt <token>',
      );
    }
    final refreshed = await accountClient.refresh(refresh);
    await store.writeAccount(refreshed);
    return refreshed;
  }

  int _usageError(String message) {
    _error('fa network: $message');
    _error(usage);
    return 64;
  }

  static void _discard(String _) {}
}
