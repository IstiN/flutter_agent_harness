// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

/// Whether an enrollment name carries no useful human/host identity.
bool isGenericDeviceName(String? value) {
  final name = value?.trim().toLowerCase() ?? '';
  return name.isEmpty ||
      name == 'device' ||
      name == 'unknown' ||
      name == 'localhost' ||
      name == 'localhost.localdomain' ||
      name == '127.0.0.1';
}

/// Computes the display-worthy name sent at enrollment and used by repair.
///
/// Desktop uses a meaningful hostname, then an OS/user fallback. Mobile
/// prefers the owner-assigned device name, then the end-user-visible model.
/// The result is capped at the device's 64-rune friendly-name limit.
String enrollmentDeviceName({
  required String operatingSystem,
  String? hostname,
  String? user,
  String? deviceName,
  String? model,
  String? manufacturer,
}) {
  final os = operatingSystem.trim().toLowerCase();
  if (_isMobile(os)) {
    return _mobileDeviceName(
      os: os,
      deviceName: deviceName,
      model: model,
      manufacturer: manufacturer,
    );
  }
  return _desktopDeviceName(
    os: os,
    operatingSystem: operatingSystem,
    hostname: hostname,
    user: user,
  );
}

bool _isMobile(String os) => os == 'android' || os == 'ios';

String _mobileDeviceName({
  required String os,
  String? deviceName,
  String? model,
  String? manufacturer,
}) {
  final assigned = _usable(deviceName);
  if (assigned != null) return _cap(assigned);
  return _mobileModelDeviceName(
    os: os,
    model: model,
    manufacturer: manufacturer,
  );
}

String _mobileModelDeviceName({
  required String os,
  String? model,
  String? manufacturer,
}) {
  final humanModel = _usable(model);
  if (humanModel == null) return os == 'ios' ? 'iPhone' : 'Android device';
  return _cap(_mobileModelName(os, humanModel, manufacturer));
}

String _mobileModelName(String os, String humanModel, String? manufacturer) {
  if (os != 'android') return humanModel;
  return _androidModelName(humanModel, manufacturer);
}

String _androidModelName(String humanModel, String? manufacturer) {
  final maker = _usable(manufacturer);
  if (maker == null) return humanModel;
  return _withManufacturer(humanModel, maker);
}

String _withManufacturer(String humanModel, String maker) =>
    humanModel.toLowerCase().contains(maker.toLowerCase())
    ? humanModel
    : '$maker $humanModel';

String _desktopDeviceName({
  required String os,
  required String operatingSystem,
  String? hostname,
  String? user,
}) {
  final host = _usable(hostname);
  if (host != null) return _cap(host);
  final platform = _desktopPlatformName(os, operatingSystem);
  return _cap(_desktopNameWithUser(platform, user));
}

const _desktopPlatformLabels = <String, String>{
  'macos': 'macOS',
  'windows': 'Windows',
  'linux': 'Linux',
};

String _desktopPlatformName(String os, String operatingSystem) =>
    _desktopPlatformLabels[os] ??
    (operatingSystem.trim().isEmpty ? 'Device' : operatingSystem.trim());

String _desktopNameWithUser(String platform, String? user) {
  final shortUser = user?.trim().replaceAll(RegExp(r'\s+'), '-').trim();
  return shortUser == null || shortUser.isEmpty
      ? platform
      : '$platform ($shortUser)';
}

/// Reads the native platform's human device identity with safe fallbacks.
Future<String> platformEnrollmentDeviceName() async {
  final plugin = DeviceInfoPlugin();
  final os = Platform.operatingSystem;
  if (os == 'android') {
    try {
      final info = await plugin.androidInfo;
      return enrollmentDeviceName(
        operatingSystem: os,
        deviceName: info.name,
        model: info.model,
        manufacturer: info.manufacturer,
      );
    } on Object {
      return enrollmentDeviceName(operatingSystem: os);
    }
  }
  if (os == 'ios') {
    try {
      final info = await plugin.iosInfo;
      return enrollmentDeviceName(
        operatingSystem: os,
        deviceName: info.name,
        model: info.model,
      );
    } on Object {
      return enrollmentDeviceName(operatingSystem: os);
    }
  }
  String? hostname;
  try {
    hostname = Platform.localHostname;
  } on Object {
    // Some sandboxed desktop hosts cannot resolve a hostname.
  }
  final environment = Platform.environment;
  return enrollmentDeviceName(
    operatingSystem: os,
    hostname: hostname,
    user: environment['USER'] ?? environment['USERNAME'],
  );
}

String? _usable(String? value) {
  if (isGenericDeviceName(value)) return null;
  return value!.trim();
}

String _cap(String value) {
  final runes = value.runes;
  if (runes.length <= 64) return value;
  return String.fromCharCodes(runes.take(64));
}
