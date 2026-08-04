// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The inline media players live in the `fa_ui` package; this shim keeps
/// the app's existing import paths working.
library;

export 'package:fa_ui/fa_ui.dart'
    show
        audioFileExtensions,
        videoFileExtensions,
        SandboxMediaKind,
        sandboxMediaKind,
        mediaPathInText,
        formatMediaDuration,
        SandboxAudioController,
        SandboxAudioControllerFactory,
        SandboxVideoController,
        SandboxVideoControllerFactory,
        AudioplayersAudioController,
        defaultVideoControllerFactory,
        VideoPlayerSandboxController,
        SandboxAudioPlayer,
        SandboxVideoPlayer,
        showFahMediaDialog;
