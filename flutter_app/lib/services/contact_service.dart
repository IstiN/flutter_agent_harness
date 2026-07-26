// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

export 'package:fa/services/contact_service_stub.dart'
    if (dart.library.io) 'package:fa/services/contact_service_io.dart';

/// One system-contacts entry. [id] is the platform contact identifier —
/// stable enough to update/delete the contact later in the same session.
typedef Contact = ({
  String id,
  String name,
  List<String> phones,
  List<String> emails,
});

/// Access to the user's system contacts (Contacts.framework on macOS/iOS).
///
/// Use [createContactService] (conditionally imported above) to obtain the
/// platform implementation: the `fah/contacts` method channel on IO
/// platforms, a never-available stub on web. Tests inject fakes.
abstract interface class ContactApi {
  /// Whether this platform can read the system contacts at all.
  Future<bool> get isAvailable;

  /// Asks the OS for contacts access (prompts once, then returns the stored
  /// decision). True when contacts may be read.
  Future<bool> requestAccess();

  /// Contacts whose name contains [query] (case-insensitive); an empty
  /// query lists the first contacts. Empty when access is denied.
  /// Searches by name (and by phone digits when [query] has 3+ digits).
  /// An empty [query] lists the whole address book, paged by
  /// [limit]/[offset] — the dedup/cleanup workflow pages through it.
  Future<List<Contact>> searchContacts({
    required String query,
    int limit = 200,
    int offset = 0,
  });

  /// Creates a contact and returns its new platform id.
  Future<String> createContact({
    required String name,
    List<String>? phones,
    List<String>? emails,
    String? note,
  });

  /// Updates the contact with [id]; only the non-null fields are applied
  /// (a supplied [phones]/[emails] list REPLACES the existing entries).
  Future<void> updateContact({
    required String id,
    String? name,
    List<String>? phones,
    List<String>? emails,
    String? note,
  });

  /// Deletes the contact with [id].
  Future<void> deleteContact({required String id});

  /// Opens [url] with the platform handler (`tel:` / `sms:` for the call
  /// and SMS flows). False when the URL could not be opened.
  Future<bool> openUrl(String url);
}
