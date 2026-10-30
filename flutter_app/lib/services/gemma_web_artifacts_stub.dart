// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/gemma_leftover_cleanup.dart';

/// Non-web fallback: the web OPFS seam is unreachable here (the cleanup
/// runs its IO walk instead). Throwing keeps an accidental web-seam call
/// loud instead of silently no-op.
GemmaWebArtifactStore createGemmaWebArtifactStore() =>
    throw UnsupportedError('The OPFS artifact store is web-only');
