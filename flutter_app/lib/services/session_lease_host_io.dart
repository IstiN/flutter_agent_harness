import 'dart:io';

import 'package:flutter/foundation.dart';

/// Real process id for diagnostics and stale-owner support.
int appHostPid() => pid;

/// iOS/Android have one primary application process per installed bundle.
/// A different app bootId can therefore only belong to the previous process.
bool singleProcessAppHost() =>
    debugSingleProcessAppHost ?? (Platform.isIOS || Platform.isAndroid);

@visibleForTesting
bool? debugSingleProcessAppHost;
