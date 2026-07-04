# Security Policy

Jotty is a local-first macOS app, but it does handle sensitive material: cloud
provider **API keys** and a **GitHub Personal Access Token**, all stored in the
macOS **Keychain**. We take reports about that surface seriously.

## Reporting a vulnerability

**Please do not open a public GitHub issue for a security problem.** A public
issue can expose users before a fix is available.

Instead, report privately through GitHub's private vulnerability reporting:

1. Go to the [Security tab](https://github.com/logic-loomer/jotty/security) of
   the repository.
2. Choose **Report a vulnerability** to open a private advisory only the
   maintainers can see.

If private reporting is unavailable to you, open a minimal public issue that says
only "requesting a private security contact" with **no technical detail**, and a
maintainer will open a private channel.

Please include, as far as you can:

- what the issue is and the impact you think it has,
- steps to reproduce (or a proof of concept),
- affected version / commit and your macOS + Xcode versions,
- any suggested fix.

We aim to acknowledge a report within a few days and will keep you updated as we
work on a fix. Please give us a reasonable window to release one before any
public disclosure. We are happy to credit you in the advisory if you would like.

## What is in scope

Things we especially want to hear about:

- **Secret exposure** - any path where an API key or the GitHub PAT could be
  written outside the Keychain (to `config.json`, UserDefaults, logs, temp files,
  crash reports, the eval scorecards under
  `~/Library/Application Support/Jotty/debug/`, etc.), or read back into the UI
  or shipped off-device.
- **Breaking the zero-network default** - the default config (Apple
  FoundationModels + local markdown) is supposed to make zero outbound network
  requests during a capture → extract → commit → rollover cycle. Any default-path
  network call is a security-relevant bug.
- **Unexpected network destinations** - capture text reaching any host other than
  the provider endpoint the user explicitly enabled (the full list is in the
  README's "Endpoints each provider hits" table).
- **Command / argument injection** - especially the "Send to Claude" Claude Code
  path (`claude "<prompt>"`) and the Ollama runtime management.
- **Signature-verification bypasses** in the Ollama download-and-launch flow.

## Security posture (for reference)

- **Secrets live in the Keychain only.** API keys and the GitHub PAT use
  `kSecClassGenericPassword`, are app-scoped and **not** iCloud-synced, and are
  never written to disk or read back into the UI. The only place a key reaches the
  running app is the Keychain; the only exception anywhere is CI's eval sweep,
  which reads keys from env vars for tests, never the app.
- **Zero-network by default.** No provider is contacted, and no key is needed,
  unless you explicitly choose a cloud provider. This is enforced by
  `PrivacyDefaultTests` on every build and by a documented manual packet-capture
  procedure in [docs/privacy-audit.md](docs/privacy-audit.md).
- **Lazy permissions.** Calendar and other OS permissions are requested only on
  first use, never at launch.
