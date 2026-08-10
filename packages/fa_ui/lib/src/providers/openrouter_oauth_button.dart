// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:url_launcher/url_launcher.dart';

import '../strings/fa_ui_strings.dart';

/// Callback invoked with the OpenRouter API key minted by the OAuth flow.
typedef OpenRouterOAuthSuccessCallback = void Function(String apiKey);

/// Callback that can capture the authorization code automatically.
///
/// The button calls this with the authorization URL before showing the manual
/// "paste the code" sheet. Implementations can start a localhost server, open
/// a deep link, or set up a web `postMessage` listener, then return the code.
/// Returning `null` falls back to the manual sheet.
typedef OpenRouterOAuthCaptureCallback = Future<String?> Function(Uri authUrl);

/// Callback invoked with the PKCE verifier before the browser is opened.
///
/// Hosts that use a full-page redirect flow (e.g. iOS Safari/PWA) can persist
/// the verifier keyed by [state] so the app can exchange the code after the
/// browser redirects back to the app URL.
typedef OpenRouterOAuthVerifierCallback =
    void Function(String state, String verifier);

/// A button that starts the OpenRouter OAuth PKCE flow.
///
/// By default the flow is **headless**: it opens the OpenRouter authorization
/// page in the user's browser (no `callback_url`), then asks the user to paste
/// the code shown on screen. This works on every platform and needs no
/// deep-link or localhost setup.
///
/// Hosts that support automatic callback capture can pass [callbackUrl] and
/// [onCapture]. [onCapture] is invoked with the authorization URL first; when
/// it returns a non-empty code the manual sheet is skipped and the key is
/// exchanged immediately.
class OpenRouterOAuthButton extends StatelessWidget {
  const OpenRouterOAuthButton({
    super.key,
    this.onSuccess,
    this.onCapture,
    this.onStoreVerifier,
    this.callbackUrl,
    this.exchange,
  });

  /// Called with the minted API key when the flow succeeds.
  final OpenRouterOAuthSuccessCallback? onSuccess;

  /// Called with the authorization URL before the manual sheet is shown.
  /// Implementations should launch the browser if needed and return the code
  /// captured through a redirect/deep link/postMessage. Returning `null` or
  /// an empty string falls back to the manual code-paste sheet.
  final OpenRouterOAuthCaptureCallback? onCapture;

  /// Called with the OAuth `state` and PKCE `verifier` before the browser is
  /// opened. Hosts that rely on a full-page redirect can persist the verifier
  /// here and look it up on app restart to exchange the returned code.
  final OpenRouterOAuthVerifierCallback? onStoreVerifier;

  /// When provided, the authorization URL includes this `callback_url` so the
  /// provider can redirect back automatically. Used together with [onCapture]
  /// for localhost servers, deep links, or web redirects.
  final String? callbackUrl;

  /// Override for the code-to-key exchange. Defaults to
  /// [exchangeOpenRouterCode]; tests inject a fake to avoid network calls.
  final Future<OpenRouterOAuthKey> Function(
    String code, {
    required String codeVerifier,
  })?
  exchange;

  @override
  Widget build(BuildContext context) {
    final strings = FaUiStrings.of(context);
    return OutlinedButton.icon(
      onPressed: () => _startFlow(context),
      icon: const Icon(Icons.open_in_browser, size: 18),
      label: Text(strings.settingsOpenRouterOAuthButton),
    );
  }

  Future<void> _startFlow(BuildContext context) async {
    final verifier = generateOpenRouterCodeVerifier();
    final challenge = generateOpenRouterCodeChallenge(verifier);
    final state = generateOpenRouterCodeVerifier();
    onStoreVerifier?.call(state, verifier);
    final authUrl = buildOpenRouterAuthUrl(
      codeChallenge: challenge,
      callbackUrl: callbackUrl,
      keyLabel: openRouterDefaultKeyLabel,
      state: state,
    );

    String? code;
    if (onCapture != null) {
      code = await onCapture!(authUrl);
    }

    if (code == null || code.isEmpty) {
      final launched = await launchUrl(
        authUrl,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) return;

      if (context.mounted) {
        code = await _showCodeSheet(context);
      }
    }
    if (code == null || code.isEmpty) return;
    if (!context.mounted) return;

    final strings = FaUiStrings.of(context);
    try {
      final key = await (exchange ?? exchangeOpenRouterCode)(
        code,
        codeVerifier: verifier,
      );

      if (context.mounted) {
        onSuccess?.call(key.key);
      }
    } on ConfigException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(strings.settingsOpenRouterOAuthError(e.message)),
          ),
        );
      }
    } on Object catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(strings.settingsOpenRouterOAuthError(e.toString())),
          ),
        );
      }
    }
  }

  Future<String?> _showCodeSheet(BuildContext context) async {
    final strings = FaUiStrings.of(context);
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          child: _OAuthCodeSheet(strings: strings),
        );
      },
    );
  }
}

class _OAuthCodeSheet extends StatefulWidget {
  const _OAuthCodeSheet({required this.strings});

  final FaUiStrings strings;

  @override
  State<_OAuthCodeSheet> createState() => _OAuthCodeSheetState();
}

class _OAuthCodeSheetState extends State<_OAuthCodeSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.strings.settingsOpenRouterOAuthSheetTitle,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(widget.strings.settingsOpenRouterOAuthSheetBody),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(
                labelText: widget.strings.settingsOpenRouterOAuthCodeLabel,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop(_controller.text.trim());
              },
              child: Text(widget.strings.settingsOpenRouterOAuthConfirmButton),
            ),
          ],
        ),
      ),
    );
  }
}
