// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be
// found in the LICENSE file.

/// The production static-site origin (fa1.dev, GitHub Pages) — the host
/// of the OAuth callback pages (`/oauth/callback`, `/oauth/aiin.html`,
/// `/oauth/openrouter.html`). Single source for the "production site"
/// fact so the web auth flows cannot drift apart (review of #1119).
const productionSiteOrigin = 'https://fa1.dev';
