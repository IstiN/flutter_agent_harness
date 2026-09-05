// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// VM/IO stubs for the AIIN web OAuth plumbing (the real implementation,
/// `aiin_oauth_web_impl.dart`, is selected on the web by the conditional
/// import in `aiin_web_auth.dart`). Never called off the web — the connect
/// flow gates on `kIsWeb` before reaching these.
library;

bool openAiinOAuthPopup() => false;

void navigateAiinOAuthPopup(String url) {}

void closeAiinOAuthPopup() {}

void attachAiinOAuthLinks() {}
