// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:http/http.dart' as http;

/// Non-web stub: the bridge only exists for the embedded web pane.
http.Client Function()? installOfficeHttpBridgeImpl() => null;
