part of 'fah.dart';

/// `fa network` composition root: all host effects (home directory, HTTP,
/// loopback OAuth, hostname/platform and terminal output) are resolved here;
/// the command runner and clients remain pure and fakeable.
Future<int> _runNetworkCommand(List<String> args) async {
  final httpClient = http.Client();
  try {
    final store = FileNetworkCredentialStore(_homeDir());
    final relayBaseUrl = _networkRelayBaseUrl();
    final deviceClient = DeviceEnrollmentClient(httpClient: httpClient);
    final runner = NetworkCommandRunner(
      store: store,
      accountClient: NetworkAccountClient(
        baseUrl: _networkAuthBaseUrl(),
        httpClient: httpClient,
      ),
      deviceClient: deviceClient,
      relayBaseUrl: relayBaseUrl,
      deviceName: _networkDeviceName(),
      platform: Platform.operatingSystem,
      startReceiver: NetworkOAuthLoopback.bind,
      openUrl: (uri) => openNetworkAuthUrl(uri, onStatus: stdout.writeln),
      rosterReader: () => _readNetworkRoster(
        store: store,
        devices: deviceClient,
        baseUrl: relayBaseUrl,
      ),
      out: stdout.writeln,
      error: stderr.writeln,
    );
    return await runner.run(args);
  } finally {
    httpClient.close();
  }
}

Future<List<NetworkDeviceRow>> _readNetworkRoster({
  required FileNetworkCredentialStore store,
  required DeviceEnrollmentClient devices,
  required String baseUrl,
}) async {
  final device = await store.readDevice();
  if (device == null) {
    throw const NetworkAuthException('not enrolled; run enroll first');
  }
  return readNetworkDeviceRoster(
    NetworkPresenceController(
      device: device,
      baseUrl: baseUrl,
      ticketProvider: () =>
          devices.wsTicket(baseUrl: baseUrl, deviceToken: device.deviceToken),
      transport: const IoConnectorTransport(),
      rosterClient: devices,
      dmKeyStore: store,
    ),
  );
}

/// Restores device-only presence. Account access-token expiry deliberately
/// does not gate this: after the one-time enrollment, the deviceToken owns
/// ws-ticket + presence until logout/revocation.
Future<CliNetworkPresence?> _restoreNetworkPresence() async {
  try {
    final store = FileNetworkCredentialStore(_homeDir());
    final account = await store.readAccount();
    final device = await store.readDevice();
    if (account == null || device == null) return null;
    final baseUrl = _networkRelayBaseUrl();
    final httpClient = http.Client();
    final devices = DeviceEnrollmentClient(httpClient: httpClient);
    return NetworkPresenceController(
      device: device,
      baseUrl: baseUrl,
      ticketProvider: () =>
          devices.wsTicket(baseUrl: baseUrl, deviceToken: device.deviceToken),
      transport: const IoConnectorTransport(),
      rosterClient: devices,
      dmKeyStore: store,
    );
  } on Object {
    // Corrupt/unreadable local network state must not prevent local coding.
    // Commands remain available to repair it; no credential-bearing error or
    // upstream URL is echoed here.
    stderr.writeln(
      'fa: network presence unavailable; run fa network status to inspect',
    );
    return null;
  }
}

String _networkRelayBaseUrl() {
  final value = Platform.environment['FA_NETWORK_BASE_URL']?.trim();
  return value == null || value.isEmpty ? networkRelayProductionUrl : value;
}

String _networkAuthBaseUrl() {
  final value = Platform.environment['FA_NETWORK_AUTH_URL']?.trim();
  return value == null || value.isEmpty ? networkAuthProductionUrl : value;
}

String _networkDeviceName() {
  final override = Platform.environment['FA_NETWORK_DEVICE_NAME']?.trim();
  if (override != null && override.isNotEmpty) return override;
  try {
    final hostname = Platform.localHostname.trim();
    return hostname.isEmpty ? 'fa-cli' : hostname;
  } on Object {
    return 'fa-cli';
  }
}
