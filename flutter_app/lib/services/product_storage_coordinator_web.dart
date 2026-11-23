import 'dart:js_interop';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

@JS('__fahFsUseStorageNamespace')
external void _useStorageNamespace(String? namespace);

/// Web namespace writer. fs_store.js closes FS, drive and cloud-session DB
/// handles before installing the new account namespace.
ProductStorageCoordinator createWebProductStorageCoordinator(
  FaProductConfig config,
) => ProductStorageCoordinator(config, _useStorageNamespace);
