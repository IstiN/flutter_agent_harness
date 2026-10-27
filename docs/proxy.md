# Per-provider proxy config (issue #1921)

A provider in `~/.fah/config.yaml` can be given a proxy, and every request of
that provider — unary, SSE streaming, retries, model lists, and quota — goes
through that proxy, or fails with a clear error. There is **no direct
fallback**: with a `network:` block bound, direct egress for that provider is
disabled (fail-closed). No OS VPN, no root, no system settings — the binding
subject is strictly the LLM provider's API traffic (bash/web tools are
untouched).

## Config

```yaml
# ~/.fah/config.yaml
providers:
  kimi_me:                                 # provider name: a saved custom
    network:                               #   entry's name, or a catalog
      proxy: socks5://127.0.0.1:1080      #   provider name (anthropic,
      proxyUsername: user                  #   google, openrouter, …)
      proxyPasswordEnv: KIMI_PROXY_PASSWORD
```

| key | meaning |
|---|---|
| `proxy` | `http://host:port`, `https://host:port` (TLS to the proxy), or `socks5://host:port`. Missing ports default to 80 / 443 / 1080. IPv6 literals (`socks5://[::1]:1080`) work. |
| `proxyUsername` | optional proxy username (HTTP Basic / SOCKS5 RFC1929). |
| `proxyPasswordEnv` | env var NAME holding the password — secrets live in the environment, never in the config. |

Rules (enforced at parse time, bad config throws `ConfigException`):

- **Inline credentials are rejected.** `http://user:pass@host` throws — move
  them to `proxyUsername` + `proxyPasswordEnv`.
- Unknown keys throw (`proxyTtl`, …).
- Only `http`, `https`, and `socks5` schemes are accepted.
- `proxyUsername` without `proxyPasswordEnv` throws.
- A `proxyPasswordEnv` whose variable is unset fails at bind time with an
  actionable error naming the variable and the `request_secret` flow — the
  run never silently degrades to direct egress.

Providers with **no** `network:` block behave byte-for-byte as before (the
shared direct keep-alive client). The section round-trips through the
config writer, so `/provider` edits never drop a binding.

## Protocol notes

- **`http://` proxy** — dart:io native CONNECT (`HttpClient.findProxy`).
  Proxy auth rides the native 407 → `authenticateProxy` →
  `addProxyCredentials` retry; the credentials arm once, so a wrong
  password fails closed instead of looping. Target hostnames are sent to
  the proxy unresolved (no local DNS of provider hosts).
- **`https://` proxy** — the same CONNECT machinery over a TLS transport to
  the proxy. Self-signed corporate proxy certificates fail closed (there
  is deliberately no config key to bypass validation).
- **`socks5://`** — dart:io has no SOCKS support and a handshake-then-
  handoff connector is impossible on its public API (the http layer listens
  the factory-returned socket's stream, and a dart:io socket stream can
  never be re-listened after cancel). The connector therefore spins a
  loopback CONNECT→SOCKS5 relay bound to `127.0.0.1:<ephemeral>`: dart:io
  speaks native CONNECT to the relay and the relay performs the RFC1928
  CONNECT with RFC1929 username/password auth upstream. **Remote DNS
  always**: the target hostname is sent unresolved (ATYP 0x03) —
  `socks5://` means socks5h semantics; there is no local-resolve variant.
- **Isolation** — every bound provider gets its own client and connection
  pool; pools are never shared across proxies or providers.
- Each provider's client is wrapped fail-closed: any transport failure
  (proxy refused, 407, mid-stream drop) surfaces as the provider's error
  event: `Proxy for provider '<name>' failed: <reason>. Direct egress is
  disabled (fail-closed). Check network.proxy / proxyPasswordEnv.`

## Decisions taken on the card's open questions

1. **Both protocols in v1** (recommended default) — HTTP CONNECT and
   SOCKS5 both shipped.
2. **Model-list and quota requests honor the same gate** (recommended
   default) — a bound provider's `/models` fetches and quota adapters ride
   the same proxied client.

## CodeMie first-add fetch exception

A CodeMie connect runs a guided project/model fetch. On a re-login or a
credential refresh the fetch keys the existing entry's name and rides its
binding. On a **first add** the user-chosen entry name is only asked for
AFTER that fetch, so the very first project/model discovery of a brand-new
entry rides direct (one-shot; the saved chat stream, `/models` refreshes,
and every later fetch all honor the binding). Every other fetch path is
gated.

## No VPN clients, ever

fa does not manage VPN clients, tunnels, or system routes. To reuse an
existing VPN without root, run any client that exposes a LOCAL proxy port
and point fa at it:

- **sing-box / mihomo (clash)** — run the client with a mixed/HTTP inbound
  on `127.0.0.1:7890`, then `proxy: http://127.0.0.1:7890`.
- **Zero-install SSH recipe** — `ssh -D 1080 user@server` gives a SOCKS5
  port on localhost, then `proxy: socks5://127.0.0.1:1080`.

Both recipes are user-operated; fa only consumes the local port.
