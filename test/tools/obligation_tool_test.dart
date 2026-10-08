// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// Issue #1380 — the `obligation_mark_done` tool: discovery (no id lists
/// the open obligations), explicit close (id + status pass-through to the
/// host callback), and the graceful null-callback contract shared with
/// ask/request_secret.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  test('null callback yields the graceful cannot-execute result', () async {
    final tool = obligationMarkDoneTool();
    final result = await tool.execute(const {'id': 'whatever'}, null, null);
    expect(result, isA<ToolExecutionResult>());
  });

  test(
    'no id is the discovery mode: the host lists open obligations',
    () async {
      String? closedId;
      final tool = obligationMarkDoneTool(
        close: (id, status) async {
          if (id.isEmpty) {
            return 'open obligations (close with {"id": "..."}):\n'
                '- obl-1 [owner-rule] always run tests\n'
                '- obl-2 [open-ask] could you fix the flake';
          }
          closedId = id;
          return 'closed';
        },
      );
      final result = await tool.execute(const {}, null, null);
      expect(closedId, isNull);
      expect(result, isA<ToolExecutionResult>());
    },
  );

  test('close passes id and status through to the host callback', () async {
    final calls = <(String, String)>[];
    final tool = obligationMarkDoneTool(
      close: (id, status) async {
        calls.add((id, status));
        return '$id marked $status. 1 open obligation(s) remain.';
      },
    );
    await tool.execute(
      const {'id': 'obl-7', 'status': 'superseded'},
      null,
      null,
    );
    expect(calls.single, ('obl-7', 'superseded'));

    // Status omitted defaults to done.
    await tool.execute(const {'id': 'obl-8'}, null, null);
    expect(calls.last, ('obl-8', 'done'));
  });
}
