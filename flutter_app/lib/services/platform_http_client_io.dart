// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io' show Platform;

import 'package:cupertino_http/cupertino_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Returns a platform-native HTTP client.
///
/// iOS and macOS use [CupertinoClient] (NSURLSession) so DNS, proxies, and
/// VPNs resolve through the system networking stack. This avoids the
/// `dart:io` HttpClient "Failed host lookup" failures seen on some iOS
/// networks (especially DNS-over-HTTPS / content-filter setups). Other
/// platforms keep the standard [IOClient].
http.Client createPlatformHttpClientImpl() {
  if (Platform.isIOS || Platform.isMacOS) {
    return CupertinoClient.defaultSessionConfiguration();
  }
  return IOClient();
}
