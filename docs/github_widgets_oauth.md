# GitHub OAuth App for the widgets connect sheet (issue #35)

The public "Copilot Plugin" OAuth App is identity-only: GitHub pins its
consent screen, so its device-flow tokens can never publish. The connect
sheet therefore supports a **user-registered OAuth App** in three roles:

| Connect tab | Needs | Publishes? |
| --- | --- | --- |
| Token (PAT) | classic PAT with `public_repo` | yes |
| Device code | any OAuth App client id with device flow on | yes (with your own app) |
| Browser (web flow) | your OAuth App client id **and secret** | yes |

## Register the OAuth App

1. GitHub → Settings → Developer settings → **OAuth Apps** → **New OAuth App**.
2. Authorization callback URL: **`https://fa1.dev/oauth/callback`**
   (device flow ignores it; the Browser tab and the future fa1.dev web demo
   use it; a localhost callback for desktop auto-capture can be added later
   — GitHub allows multiple URLs per app).
3. Enable **Device Flow** on the app (needed by the Device code tab).
4. Copy the **Client ID** and generate a **Client Secret**.

## Configure the app at runtime (no rebuild)

Settings → Keys:

- `github_oauth_client_id` — the client id (enables the Device code and
  Browser tabs; without it the device tab falls back to the public Copilot
  plugin id and warns that its tokens are identity-only);
- `github_oauth_client_secret` — the client secret (the Browser tab needs
  it for the `POST /login/oauth/access_token` exchange).

Build-time alternative: `--dart-define=FA_GITHUB_CLIENT_ID=<id>`.

## The fa1.dev callback page

The fa1.dev site (repo `IstiN/fa1.dev`, hosted on GitHub Pages) needs a
static `oauth/callback/index.html` that shows the one-time code for pasting
back into the app:

```html
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>Fa — GitHub authorization</title>
<body style="font-family: system-ui, sans-serif; text-align: center;
             padding: 4rem 1rem;">
  <h1>Fa · GitHub</h1>
  <p id="msg">Your one-time code — paste it into the Fa app:</p>
  <p><code id="code" style="font-size: 1.6rem; letter-spacing: 2px;"></code>
     <button onclick="navigator.clipboard.writeText(code.textContent)">
       Copy</button></p>
  <script>
    const q = new URLSearchParams(location.search);
    const code = q.get('code'), err = q.get('error_description') || q.get('error');
    if (err) {
      document.getElementById('msg').textContent = 'GitHub error: ' + err;
      document.getElementById('code').textContent = '';
    } else if (code) {
      document.getElementById('code').textContent = code;
    } else {
      document.getElementById('msg').textContent =
        'No code in the URL — start the sign-in from the Fa app again.';
    }
  </script>
</body>
</html>
```

## Code map

- `flutter_app/lib/services/github_oauth_web_flow.dart` — authorize URL
  builder + code exchange (`exchangeGithubOauthCode`); the redirect
  constant is `githubOauthWebRedirectUri`.
- `flutter_app/lib/ui/widgets/github_connect_sheet.dart` — the three tabs;
  the Browser tab opens the authorize page once and exchanges the pasted
  code via the injectable `GithubOauthWebFlow`.
- Scope requested: `public_repo` (both flows); the sheet verifies the
  resulting token's `X-OAuth-Scopes` before storing the connection.
