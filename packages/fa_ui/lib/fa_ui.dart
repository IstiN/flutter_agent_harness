// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Reusable UI for apps embedding the Fa agent: the Fa brand theme and the
/// ready-made provider/model settings widgets, with host-side theme
/// ([FaUiTheme]) and string ([FaUiStrings]) customization.
library;

export 'src/host_config.dart';
export 'src/providers/connection.dart';
export 'src/providers/default_chat_model.dart';
export 'src/providers/media_slot_picker_page.dart';
export 'src/providers/provider_editor_page.dart';
export 'src/providers/provider_preset.dart';
export 'src/providers/providers_section.dart';
export 'src/stores/keychain_store.dart';
export 'src/stores/media_models_store.dart';
export 'src/stores/provider_registry.dart';
export 'src/stores/session_keys_store.dart';
export 'src/strings/fa_ui_strings.dart';
export 'src/theme/app_theme.dart';
export 'src/theme/fa_ui_theme.dart';
export 'src/utils/page_presentation.dart';
export 'src/utils/vision_models.dart';
export 'src/widgets/model_id_field.dart';
