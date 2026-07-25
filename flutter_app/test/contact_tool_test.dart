// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/contact_service.dart';
import 'package:fa/services/contact_tool.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Configurable fake [ContactApi] — the host-side tests never touch the
/// real method channel.
final class FakeContactApi implements ContactApi {
  FakeContactApi({
    this.available = true,
    this.granted = true,
    List<Contact>? contacts,
  }) : contactsToReturn = contacts ?? const [];

  bool available;
  bool granted;
  List<Contact> contactsToReturn;
  int requestAccessCalls = 0;
  String? lastQuery;
  int nextId = 0;
  final created =
      <
        ({
          String name,
          List<String>? phones,
          List<String>? emails,
          String? note,
        })
      >[];
  String? updatedId;
  final deletedIds = <String>[];
  final openedUrls = <String>[];

  @override
  Future<bool> get isAvailable async => available;

  @override
  Future<bool> requestAccess() async {
    requestAccessCalls++;
    return granted;
  }

  @override
  Future<List<Contact>> searchContacts({required String query}) async {
    lastQuery = query;
    if (query.isEmpty) return contactsToReturn;
    final needle = query.toLowerCase();
    return contactsToReturn
        .where((contact) => contact.name.toLowerCase().contains(needle))
        .toList();
  }

  @override
  Future<String> createContact({
    required String name,
    List<String>? phones,
    List<String>? emails,
    String? note,
  }) async {
    created.add((name: name, phones: phones, emails: emails, note: note));
    return 'fake-id-${nextId++}';
  }

  @override
  Future<void> updateContact({
    required String id,
    String? name,
    List<String>? phones,
    List<String>? emails,
    String? note,
  }) async {
    updatedId = id;
  }

  @override
  Future<void> deleteContact({required String id}) async {
    deletedIds.add(id);
  }

  @override
  Future<bool> openUrl(String url) async {
    openedUrls.add(url);
    return true;
  }
}

/// Two sample contacts used across the call/SMS groups.
const _anna = (
  id: 'c-anna',
  name: 'Anna Ivanova',
  phones: ['+1 555 0100', '+1 555 0101'],
  emails: ['anna@example.com'],
);
const _bob = (
  id: 'c-bob',
  name: 'Bob Petrov',
  phones: <String>[],
  emails: ['bob@example.com'],
);

String _textOf(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((b) => b.text).join();

void main() {
  group('contactsSearchTool', () {
    test('is a read-tier tool and renders a readable list', () async {
      final contacts = FakeContactApi(contacts: [_anna, _bob]);
      final tool = contactsSearchTool(contacts);
      expect(tool.tier, ApprovalTier.read);

      final result = await tool.execute(const {'query': 'anna'}, null, null);

      expect(contacts.lastQuery, 'anna');
      final text = _textOf(result);
      expect(text, contains('Contacts matching "anna":'));
      expect(
        text,
        contains(
          '- Anna Ivanova — +1 555 0100, +1 555 0101 — anna@example.com',
        ),
      );
      expect(text, isNot(contains('Bob')));
    });

    test('an empty query lists everything', () async {
      final contacts = FakeContactApi(contacts: [_anna, _bob]);
      final tool = contactsSearchTool(contacts);

      final result = await tool.execute(const {}, null, null);

      expect(contacts.lastQuery, '');
      final text = _textOf(result);
      expect(text, contains('Contacts:'));
      expect(text, contains('Anna Ivanova'));
      expect(text, contains('Bob Petrov — bob@example.com'));
    });

    test('no matches answers with a "no contacts" text', () async {
      final tool = contactsSearchTool(FakeContactApi());

      final result = await tool.execute(const {'query': 'zzz'}, null, null);

      expect(_textOf(result), contains('No contacts matching "zzz"'));
    });

    test('denied access requests once, then reports guidance', () async {
      final contacts = FakeContactApi(granted: false);
      final tool = contactsSearchTool(contacts);

      final result = await tool.execute(const {}, null, null);

      expect(contacts.requestAccessCalls, 1);
      final text = _textOf(result);
      expect(text, contains('denied'));
      expect(text, contains('Privacy & Security → Contacts'));
    });

    test('unsupported platform answers with a clean note', () async {
      final contacts = FakeContactApi(available: false);
      final tool = contactsSearchTool(contacts);

      final result = await tool.execute(const {}, null, null);

      expect(_textOf(result), contains('not supported on this platform'));
      expect(contacts.requestAccessCalls, 0);
    });
  });

  group('contactsAddTool', () {
    test('creates the contact and renders a confirmation', () async {
      final contacts = FakeContactApi();
      final tool = contactsAddTool(contacts);
      expect(tool.tier, ApprovalTier.write);

      final result = await tool.execute(
        const {
          'name': 'Anna Ivanova',
          'phones': ['+1 555 0100'],
          'emails': ['anna@example.com'],
          'note': 'Met at the conference',
        },
        null,
        null,
      );

      expect(contacts.created, hasLength(1));
      expect(contacts.created.single.name, 'Anna Ivanova');
      expect(contacts.created.single.phones, ['+1 555 0100']);
      expect(contacts.created.single.emails, ['anna@example.com']);
      expect(contacts.created.single.note, 'Met at the conference');
      final text = _textOf(result);
      expect(text, contains('Created Anna Ivanova — +1 555 0100'));
      expect(text, contains('id: fake-id-0'));
    });

    test('a comma-separated string works for phones', () async {
      final contacts = FakeContactApi();
      final tool = contactsAddTool(contacts);

      await tool.execute(
        const {'name': 'Bob', 'phones': '+1 555 0100, +1 555 0101'},
        null,
        null,
      );

      expect(contacts.created.single.phones, ['+1 555 0100', '+1 555 0101']);
    });

    test('missing name answers with an error text', () async {
      final contacts = FakeContactApi();
      final tool = contactsAddTool(contacts);

      final result = await tool.execute(const {}, null, null);

      expect(_textOf(result), contains('name is required'));
      expect(contacts.created, isEmpty);
    });

    test('denied access reports guidance and writes nothing', () async {
      final contacts = FakeContactApi(granted: false);
      final tool = contactsAddTool(contacts);

      final result = await tool.execute(const {'name': 'X'}, null, null);

      expect(_textOf(result), contains('denied'));
      expect(contacts.created, isEmpty);
    });
  });

  group('contactsCallTool', () {
    test(
      'is write-tier and opens a tel: URL for the matched contact',
      () async {
        final contacts = FakeContactApi(contacts: [_anna, _bob]);
        final tool = contactsCallTool(contacts);
        expect(tool.tier, ApprovalTier.write);

        final result = await tool.execute(const {'match': 'anna'}, null, null);

        expect(contacts.openedUrls, ['tel:+1 555 0100']);
        expect(
          _textOf(result),
          contains('Calling Anna Ivanova at +1 555 0100'),
        );
      },
    );

    test('unknown match errors and calls nothing', () async {
      final contacts = FakeContactApi(contacts: [_anna]);
      final tool = contactsCallTool(contacts);

      final result = await tool.execute(const {'match': 'zzz'}, null, null);

      expect(_textOf(result), contains('No contact matching "zzz"'));
      expect(contacts.openedUrls, isEmpty);
    });

    test('ambiguous match asks to be more specific', () async {
      final contacts = FakeContactApi(
        contacts: [
          _anna,
          (
            id: 'c-anna2',
            name: 'Anna Smirnova',
            phones: const ['+7 900 0000'],
            emails: const [],
          ),
        ],
      );
      final tool = contactsCallTool(contacts);

      final result = await tool.execute(const {'match': 'anna'}, null, null);

      final text = _textOf(result);
      expect(text, contains('Several contacts match "anna"'));
      expect(text, contains('Anna Ivanova'));
      expect(text, contains('Anna Smirnova'));
      expect(contacts.openedUrls, isEmpty);
    });

    test('an exact name wins over other partial matches', () async {
      final contacts = FakeContactApi(
        contacts: [
          _anna,
          (
            id: 'c-anna2',
            name: 'Anna Smirnova',
            phones: const ['+7 900 0000'],
            emails: const [],
          ),
        ],
      );
      final tool = contactsCallTool(contacts);

      await tool.execute(const {'match': 'Anna Ivanova'}, null, null);

      expect(contacts.openedUrls, ['tel:+1 555 0100']);
    });

    test('a contact without a phone number cannot be called', () async {
      final contacts = FakeContactApi(contacts: [_bob]);
      final tool = contactsCallTool(contacts);

      final result = await tool.execute(const {'match': 'bob'}, null, null);

      expect(_textOf(result), contains('Bob Petrov has no phone number'));
      expect(contacts.openedUrls, isEmpty);
    });
  });

  group('contactsSmsTool', () {
    test('is write-tier and opens a pre-filled sms: URL', () async {
      final contacts = FakeContactApi(contacts: [_anna]);
      final tool = contactsSmsTool(contacts);
      expect(tool.tier, ApprovalTier.write);

      final result = await tool.execute(
        const {'match': 'anna', 'text': 'Running late, sorry!'},
        null,
        null,
      );

      expect(contacts.openedUrls, [
        'sms:+1 555 0100?&body=Running%20late%2C%20sorry!',
      ]);
      final text = _textOf(result);
      expect(text, contains('Anna Ivanova'));
      expect(text, contains('Running late, sorry!'));
    });

    test('missing text answers with an error text', () async {
      final contacts = FakeContactApi(contacts: [_anna]);
      final tool = contactsSmsTool(contacts);

      final result = await tool.execute(const {'match': 'anna'}, null, null);

      expect(_textOf(result), contains('text is required'));
      expect(contacts.openedUrls, isEmpty);
    });

    test('unknown match errors and texts nothing', () async {
      final contacts = FakeContactApi(contacts: [_anna]);
      final tool = contactsSmsTool(contacts);

      final result = await tool.execute(
        const {'match': 'zzz', 'text': 'hi'},
        null,
        null,
      );

      expect(_textOf(result), contains('No contact matching "zzz"'));
      expect(contacts.openedUrls, isEmpty);
    });
  });
}
