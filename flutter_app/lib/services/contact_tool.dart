// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/services/contact_service.dart';

/// Name of the agent tool that searches the user's system contacts.
const contactsSearchToolName = 'contacts_search';

/// Names of the agent tools that act on the user's system contacts.
const contactsAddToolName = 'contacts_add';
const contactsCallToolName = 'contacts_call';
const contactsSmsToolName = 'contacts_sms';

/// The shared availability gate: `null` when the contacts may be used,
/// otherwise the user-facing explanation (unsupported platform, or access
/// denied with where to enable it). Requests OS access on the first call.
Future<String?> _unavailable(ContactApi contacts) async {
  if (!await contacts.isAvailable) {
    return 'The system contacts are not supported on this platform.';
  }
  // The OS shows its access prompt at most once; later calls return the
  // stored decision without prompting again.
  if (!await contacts.requestAccess()) {
    return 'Contacts access was denied. The user can enable it in System '
        'Settings → Privacy & Security → Contacts (macOS) or Settings → '
        'Privacy & Security → Contacts (iOS), then ask again.';
  }
  return null;
}

/// Creates the `contacts_search` tool bound to [contacts].
///
/// Read-only: the tool searches contacts by name and never writes to the
/// address book. When the OS has not granted access yet the first call
/// requests it (the platform prompt appears once); a denial is reported
/// with where to enable it. The description/result texts are LLM-facing
/// and stay literal English (not UI copy).
AgentTool contactsSearchTool(ContactApi contacts) {
  return AgentTool(
    name: contactsSearchToolName,
    label: 'contacts_search',
    // Reading contacts mutates nothing.
    tier: ApprovalTier.read,
    description:
        "Search the user's system contacts (read-only). Use for questions "
        'like "what is Anna\'s phone number?" or before contacts_call/'
        'contacts_sms. Returns matching contacts with phone numbers and '
        'emails.',
    parameters: const {
      'type': 'object',
      'properties': {
        'query': {
          'type': 'string',
          'description':
              'Name (or part of it) to search for, case-insensitive '
              '(default: empty — lists the first contacts)',
        },
      },
    },
    execute: (arguments, cancelToken, onUpdate) async {
      final unavailable = await _unavailable(contacts);
      if (unavailable != null) return ToolExecutionResult.text(unavailable);
      final query = (arguments['query'] ?? '').toString().trim();
      final found = await contacts.searchContacts(query: query);
      return ToolExecutionResult.text(_render(found, query));
    },
  );
}

/// The phone/email list arguments the write tools share: a JSON list of
/// strings (a single comma-separated string is also accepted).
const _listProperties = {
  'phones': {
    'type': 'array',
    'items': {'type': 'string'},
    'description': 'Phone numbers (a comma-separated string also works)',
  },
  'emails': {
    'type': 'array',
    'items': {'type': 'string'},
    'description': 'Email addresses (a comma-separated string also works)',
  },
  'note': {'type': 'string', 'description': 'Optional note'},
};

/// Creates the `contacts_add` tool bound to [contacts].
///
/// Tier write: creating a contact mutates the user's address book, so the
/// approval gate applies. Texts are LLM-facing and stay literal English.
AgentTool contactsAddTool(ContactApi contacts) {
  return AgentTool(
    name: contactsAddToolName,
    label: 'contacts_add',
    tier: ApprovalTier.write,
    description:
        "Add a contact to the user's system contacts. Confirm the details "
        'with the user before calling. Returns the new contact id.',
    parameters: const {
      'type': 'object',
      'properties': {
        'name': {
          'type': 'string',
          'description': 'Full name of the contact (required)',
        },
        ..._listProperties,
      },
      'required': ['name'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      final unavailable = await _unavailable(contacts);
      if (unavailable != null) return ToolExecutionResult.text(unavailable);
      final name = (arguments['name'] ?? '').toString().trim();
      if (name.isEmpty) {
        return ToolExecutionResult.text('Error: name is required.');
      }
      final phones = _stringList(arguments, 'phones');
      final emails = _stringList(arguments, 'emails');
      final note = _text(arguments, 'note');
      final id = await contacts.createContact(
        name: name,
        phones: phones,
        emails: emails,
        note: note,
      );
      return ToolExecutionResult.text(
        'Created ${_renderContact((id: id, name: name, phones: phones ?? const [], emails: emails ?? const []))} (id: $id).',
      );
    },
  );
}

/// Creates the `contacts_call` tool bound to [contacts].
///
/// Tier write: placing a call is a user-visible action, so the approval
/// gate applies — the tool confirms the resolved contact in its result.
/// On device it opens a `tel:` URL with the contact's first phone number.
AgentTool contactsCallTool(ContactApi contacts) {
  return AgentTool(
    name: contactsCallToolName,
    label: 'contacts_call',
    tier: ApprovalTier.write,
    description:
        'Call one of the user\'s contacts. First search with '
        'contacts_search, confirm the person with the user, then call this '
        'with `match` set to the contact name. Opens the phone dialer with '
        'the contact\'s first phone number.',
    parameters: const {
      'type': 'object',
      'properties': {
        'match': {
          'type': 'string',
          'description':
              'Which contact: name text (case-insensitive) as listed by '
              'contacts_search (required)',
        },
      },
      'required': ['match'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      final unavailable = await _unavailable(contacts);
      if (unavailable != null) return ToolExecutionResult.text(unavailable);
      final found = await _find(contacts, arguments);
      if (found.error != null) return ToolExecutionResult.text(found.error!);
      final contact = found.contact!;
      if (contact.phones.isEmpty) {
        return ToolExecutionResult.text(
          '${contact.name} has no phone number — cannot call.',
        );
      }
      final phone = contact.phones.first;
      final opened = await contacts.openUrl('tel:$phone');
      if (!opened) {
        return ToolExecutionResult.text(
          'Could not open the dialer for ${contact.name} ($phone).',
        );
      }
      return ToolExecutionResult.text('Calling ${contact.name} at $phone.');
    },
  );
}

/// Creates the `contacts_sms` tool bound to [contacts].
///
/// Tier write: sending a text is a user-visible action, so the approval
/// gate applies. On device it opens an `sms:` URL pre-filled with [text];
/// the user still presses send in the Messages app.
AgentTool contactsSmsTool(ContactApi contacts) {
  return AgentTool(
    name: contactsSmsToolName,
    label: 'contacts_sms',
    tier: ApprovalTier.write,
    description:
        'Send an SMS to one of the user\'s contacts. First search with '
        'contacts_search, confirm the person and the exact message with '
        'the user, then call this with `match` set to the contact name '
        'and `text` set to the message. Opens the Messages app pre-filled.',
    parameters: const {
      'type': 'object',
      'properties': {
        'match': {
          'type': 'string',
          'description':
              'Which contact: name text (case-insensitive) as listed by '
              'contacts_search (required)',
        },
        'text': {
          'type': 'string',
          'description': 'The message body to pre-fill (required)',
        },
      },
      'required': ['match', 'text'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      final unavailable = await _unavailable(contacts);
      if (unavailable != null) return ToolExecutionResult.text(unavailable);
      final text = _text(arguments, 'text');
      if (text == null) {
        return ToolExecutionResult.text('Error: text is required.');
      }
      final found = await _find(contacts, arguments);
      if (found.error != null) return ToolExecutionResult.text(found.error!);
      final contact = found.contact!;
      if (contact.phones.isEmpty) {
        return ToolExecutionResult.text(
          '${contact.name} has no phone number — cannot send an SMS.',
        );
      }
      final phone = contact.phones.first;
      final url = 'sms:$phone?&body=${Uri.encodeComponent(text)}';
      final opened = await contacts.openUrl(url);
      if (!opened) {
        return ToolExecutionResult.text(
          'Could not open the Messages app for ${contact.name} ($phone).',
        );
      }
      return ToolExecutionResult.text(
        'Opened the Messages app to text ${contact.name} at $phone: "$text"',
      );
    },
  );
}

String? _text(Map<String, dynamic> arguments, String key) {
  final value = arguments[key]?.toString().trim();
  return value == null || value.isEmpty ? null : value;
}

/// Reads a string-list argument: a JSON list of strings, or a single
/// comma-separated string. Null when absent/empty.
List<String>? _stringList(Map<String, dynamic> arguments, String key) {
  final raw = arguments[key];
  final items = <String>[];
  if (raw is List) {
    for (final item in raw) {
      final text = item.toString().trim();
      if (text.isNotEmpty) items.add(text);
    }
  } else if (raw != null) {
    for (final part in raw.toString().split(',')) {
      final text = part.trim();
      if (text.isNotEmpty) items.add(text);
    }
  }
  return items.isEmpty ? null : items;
}

/// Result of [_find]: either the matched [contact] or an [error] text.
typedef _FindResult = ({Contact? contact, String? error});

/// Searches with the `match` argument and resolves a single contact:
/// an exact (case-insensitive) name match wins over partial matches; an
/// ambiguous or unknown match answers with a recoverable error.
Future<_FindResult> _find(
  ContactApi contacts,
  Map<String, dynamic> arguments,
) async {
  final matchText = (arguments['match'] ?? '').toString().trim();
  if (matchText.isEmpty) {
    return (contact: null, error: 'Error: match is required.');
  }
  final found = await contacts.searchContacts(query: matchText);
  if (found.isEmpty) {
    return (contact: null, error: 'No contact matching "$matchText".');
  }
  final needle = matchText.toLowerCase();
  final exact = found
      .where((contact) => contact.name.toLowerCase() == needle)
      .toList();
  if (exact.length == 1) return (contact: exact.single, error: null);
  if (found.length == 1) return (contact: found.single, error: null);
  final lines = [
    'Several contacts match "$matchText" — be more specific:',
    for (final contact in found) '- ${_renderContact(contact)}',
  ];
  return (contact: null, error: lines.join('\n'));
}

String _render(List<Contact> contacts, String query) {
  if (contacts.isEmpty) {
    return query.isEmpty
        ? 'No contacts found.'
        : 'No contacts matching "$query".';
  }
  final header = query.isEmpty ? 'Contacts:' : 'Contacts matching "$query":';
  final lines = [
    header,
    for (final contact in contacts) '- ${_renderContact(contact)}',
  ];
  return lines.join('\n');
}

String _renderContact(Contact contact) {
  final buffer = StringBuffer(contact.name);
  if (contact.phones.isNotEmpty) {
    buffer.write(' — ${contact.phones.join(', ')}');
  }
  if (contact.emails.isNotEmpty) {
    buffer.write(' — ${contact.emails.join(', ')}');
  }
  return buffer.toString();
}
