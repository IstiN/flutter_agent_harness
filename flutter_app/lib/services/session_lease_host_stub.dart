import 'package:flutter/foundation.dart';

/// Web has no process id or native single-process application model.
int appHostPid() => 0;

/// Web can host multiple independent clients; no lease is displaced here.
bool singleProcessAppHost() => debugSingleProcessAppHost ?? false;

@visibleForTesting
bool? debugSingleProcessAppHost;
