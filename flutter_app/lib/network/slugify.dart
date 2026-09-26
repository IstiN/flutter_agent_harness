// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Turns a human display name into the server's network-name slug
/// (fa_network `validNetworkName`: `^[a-z0-9][a-z0-9-]*$`, 3–64 chars):
/// lowercases, folds any run of non-alphanumerics into one hyphen, trims
/// hyphens at the edges. Returns null when nothing usable remains.
String? slugifyNetworkName(String input) {
  final slug = input
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.length < 3 || slug.length > 64) return null;
  return slug;
}
