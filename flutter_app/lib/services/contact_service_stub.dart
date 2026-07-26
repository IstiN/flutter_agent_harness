// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/contact_service.dart';

/// Whether the current platform has a native contacts backend (macOS/iOS).
/// Always false here — this stub is selected where `dart:io` is unavailable
/// (web), so callers degrade to a clean "not supported" note.
bool get contactsPlatformSupported => false;

/// Creates the platform [ContactApi]. On web there are no system contacts,
/// so the service reports itself unavailable and every call is a no-op.
ContactApi createContactService() => const _UnavailableContactApi();

final class _UnavailableContactApi implements ContactApi {
  const _UnavailableContactApi();

  @override
  Future<bool> get isAvailable async => false;

  @override
  Future<bool> requestAccess() async => false;

  @override
  Future<List<Contact>> searchContacts({
    required String query,
    int limit = 200,
    int offset = 0,
  }) async => const [];

  @override
  Future<String> createContact({
    required String name,
    List<String>? phones,
    List<String>? emails,
    String? note,
  }) => throw StateError(
    'The system contacts are not supported on this platform.',
  );

  @override
  Future<void> updateContact({
    required String id,
    String? name,
    List<String>? phones,
    List<String>? emails,
    String? note,
  }) => throw StateError(
    'The system contacts are not supported on this platform.',
  );

  @override
  Future<void> deleteContact({required String id}) => throw StateError(
    'The system contacts are not supported on this platform.',
  );

  @override
  Future<bool> openUrl(String url) => throw StateError(
    'The system contacts are not supported on this platform.',
  );
}
