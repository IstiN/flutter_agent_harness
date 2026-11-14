// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart' show LocalExecutionEnv;
import 'package:path/path.dart' as p;

/// Watches the real desktop store directory (not just the file, so atomic
/// replace/rename writes are observed too). Decorated local environments
/// unwrap to their IO delegate; in-memory/hosted environments return null.
Stream<void>? watchSessionNamesFile(ExecutionEnv env) {
  ExecutionEnv current = env;
  final seen = <ExecutionEnv>{};
  while (current is ForwardingFs && seen.add(current)) {
    current = current.delegate;
  }
  if (current is! LocalExecutionEnv) return null;
  final filePath = p.join(current.cwd, 'session_names.json');
  try {
    return Directory(current.cwd)
        .watch()
        .where((event) {
          return p.basename(event.path) == p.basename(filePath);
        })
        .map((_) {});
  } on Object {
    // A filesystem without watch support keeps the ordinary load/rename
    // behavior; an external change can still be picked up on the next load.
    return null;
  }
}
