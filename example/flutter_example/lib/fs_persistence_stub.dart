// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'fs_persistence.dart';

/// Non-web fallback: no durable browser storage exists, so the snapshot
/// store is process memory only. Selected unless `dart.library.html` is
/// available (see the conditional import in `env_factory_stub.dart`).
FsSnapshotStore createFsSnapshotStore() => InMemoryFsSnapshotStore();
