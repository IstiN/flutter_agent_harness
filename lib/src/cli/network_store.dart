// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Credential persistence seam for `fa network`. Production uses the 0600
/// file store exported from `lib/io.dart`; tests can use [MemoryNetworkStore].
library;

import '../network/network_account.dart';

/// Account and device persistence for the CLI device-network commands.
abstract interface class NetworkCredentialStore {
  /// Reads the account, or null when signed out.
  Future<NetworkAccount?> readAccount();

  /// Reads the enrolled device, or null when not enrolled.
  Future<NetworkDeviceCredentials?> readDevice();

  /// Replaces the account document.
  Future<void> writeAccount(NetworkAccount account);

  /// Replaces the device document.
  Future<void> writeDevice(NetworkDeviceCredentials device);

  /// Deletes only the device pairing (used when switching accounts).
  Future<void> clearDevice();

  /// Deletes both account and device documents.
  Future<void> clear();
}

/// In-memory store for hermetic command tests.
final class MemoryNetworkStore implements NetworkCredentialStore {
  /// Current account.
  NetworkAccount? account;

  /// Current device.
  NetworkDeviceCredentials? device;

  @override
  Future<NetworkAccount?> readAccount() async => account;

  @override
  Future<NetworkDeviceCredentials?> readDevice() async => device;

  @override
  Future<void> writeAccount(NetworkAccount value) async => account = value;

  @override
  Future<void> writeDevice(NetworkDeviceCredentials value) async =>
      device = value;

  @override
  Future<void> clearDevice() async => device = null;

  @override
  Future<void> clear() async {
    account = null;
    device = null;
  }
}
