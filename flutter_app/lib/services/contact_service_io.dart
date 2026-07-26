// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:flutter/services.dart';

import 'package:fa/services/contact_service.dart';

/// Whether the current platform has a native contacts backend:
/// Contacts.framework is wired up on macOS and iOS only (see
/// `MainFlutterWindow.swift` / `AppDelegate.swift`).
bool get contactsPlatformSupported => Platform.isMacOS || Platform.isIOS;

/// Creates the method-channel-backed [ContactApi] (IO platforms).
ContactApi createContactService() => const MethodChannelContactApi();

/// [ContactApi] over the `fah/contacts` method channel.
final class MethodChannelContactApi implements ContactApi {
  const MethodChannelContactApi();

  static const _channel = MethodChannel('fah/contacts');

  @override
  Future<bool> get isAvailable async => contactsPlatformSupported;

  @override
  Future<bool> requestAccess() async {
    if (!contactsPlatformSupported) return false;
    try {
      final granted = await _channel.invokeMethod<bool>('requestAccess');
      return granted ?? false;
    } on MissingPluginException {
      // No native handler (e.g. unit tests) — treat as denied.
      return false;
    }
  }

  @override
  Future<List<Contact>> searchContacts({required String query}) async {
    if (!contactsPlatformSupported) return const [];
    final List<dynamic>? raw;
    try {
      raw = await _channel.invokeListMethod<dynamic>('searchContacts', {
        'query': query,
      });
    } on MissingPluginException {
      return const [];
    }
    return [
      for (final entry in raw ?? const [])
        if (entry is Map) _parseContact(entry),
    ];
  }

  static Contact _parseContact(Map<dynamic, dynamic> map) {
    String? textOf(String key) {
      final value = map[key]?.toString();
      return value == null || value.isEmpty ? null : value;
    }

    List<String> listOf(String key) => [
      for (final item in (map[key] as List?) ?? const []) item.toString(),
    ];

    return (
      id: textOf('id') ?? '',
      name: textOf('name') ?? '(no name)',
      phones: listOf('phones'),
      emails: listOf('emails'),
    );
  }

  @override
  Future<String> createContact({
    required String name,
    List<String>? phones,
    List<String>? emails,
    String? note,
  }) async {
    _ensureSupported();
    try {
      final id = await _channel.invokeMethod<String>('createContact', {
        'name': name,
        'phones': ?phones,
        'emails': ?emails,
        'note': ?note,
      });
      return id ?? '';
    } on MissingPluginException {
      throw _unsupported();
    }
  }

  @override
  Future<void> updateContact({
    required String id,
    String? name,
    List<String>? phones,
    List<String>? emails,
    String? note,
  }) async {
    _ensureSupported();
    try {
      await _channel.invokeMethod<void>('updateContact', {
        'id': id,
        'name': ?name,
        'phones': ?phones,
        'emails': ?emails,
        'note': ?note,
      });
    } on MissingPluginException {
      throw _unsupported();
    }
  }

  @override
  Future<void> deleteContact({required String id}) async {
    _ensureSupported();
    try {
      await _channel.invokeMethod<void>('deleteContact', {'id': id});
    } on MissingPluginException {
      throw _unsupported();
    }
  }

  @override
  Future<bool> openUrl(String url) async {
    _ensureSupported();
    try {
      final opened = await _channel.invokeMethod<bool>('openUrl', {'url': url});
      return opened ?? false;
    } on MissingPluginException {
      throw _unsupported();
    } on PlatformException catch (e) {
      // e.g. no Phone/Messages handler on this device (Simulator).
      throw StateError(e.message ?? 'Cannot open $url');
    }
  }

  static void _ensureSupported() {
    if (!contactsPlatformSupported) throw _unsupported();
  }

  static StateError _unsupported() =>
      StateError('The system contacts are not supported on this platform.');
}
