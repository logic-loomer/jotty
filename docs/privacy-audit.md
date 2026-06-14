# Privacy Audit: Zero-Network Default

Jotty's promise is that the **default configuration makes zero outbound network
requests**. The default is Apple Foundation Models (on-device) for extraction and
local markdown files for storage. This document is the manual audit procedure that
substantiates that claim, plus the endpoint table showing exactly what each
non-default provider would contact.

The claim has two complementary halves:

1. **Automated (CI-enforced):** `JottyTests/PrivacyDefaultTests` asserts that the
   default provider id is `apple-fm` and that the default extraction path constructs
   no HTTP client (`ProviderFactory.isAppleFM(.defaultValue)` is true; the default
   `make` returns `AppleFMProvider`; an unknown provider id degrades to Apple FM).
   This runs on every build and is the always-on guard against a regression that
   would wire a network client onto the default path.
2. **Manual (human-only):** live packet capture during a real
   capture -> extract -> commit -> rollover cycle, described below. Packet capture
   needs root and a real running app, so it cannot run in `xcodebuild test`; it is a
   release-time human pass, not a CI step.

Both halves are needed. The unit test proves the code does not build a network
client on the default path; the packet capture proves the running app, on a real
Mac, sends nothing over the wire.

## What "zero network" means here

- **Apple Foundation Models** runs entirely on-device. There is no endpoint.
- **Local markdown storage** writes files under `~/Documents/Jotty/` (or your
  configured folder). No sync, no upload.
- Loopback traffic (`127.0.0.1`) is not expected on the default path either, because
  Apple FM is in-process. Ollama is the only provider that uses loopback, and it is
  not the default.

So on the default config the correct expected result is: **no outbound packets at
all**, including no loopback.

## Manual procedure (human-only)

You need a second terminal (for the capture) and the running Jotty app. Use either
`tcpdump` (built in, needs `sudo`) or Little Snitch in alert mode. The steps below
show `tcpdump`; the Little Snitch variant is noted after.

### 1. Set the default config

In Settings, confirm:

- **Settings -> AI -> Provider** = Apple Foundation Models (the default).
- **Settings -> Storage** points at a local folder (the default
  `~/Documents/Jotty/`, or your local vault). Not a network volume.

No API keys are required for this path, and none should be entered. If you have
previously selected a cloud provider, switch back to Apple Foundation Models for the
audit.

### 2. Start the capture

In a separate terminal, start a capture that records every packet that is NOT
loopback and NOT a normal background OS chatter source you can account for. The
simplest assertion-friendly filter watches all non-loopback hosts:

```bash
sudo tcpdump -i any -n 'not host 127.0.0.1 and not host ::1'
```

Leave it running for the whole cycle. Because other apps on the Mac also use the
network, the cleanest signal comes from filtering to the Jotty process. To attribute
traffic to Jotty specifically, you can pair `tcpdump` with a per-process view such as
`nettop -p $(pgrep -x Jotty)` in a third pane, or run the audit on an otherwise quiet
machine and read the `tcpdump` output directly.

**Little Snitch variant:** put Little Snitch into alert mode (no silent allow rules
for Jotty), then drive the cycle. Any outbound connection attempt from Jotty raises a
prompt. On the default config, no prompt should appear.

### 3. Drive a full cycle

With the capture running, exercise the complete default-path loop:

1. **Capture:** press the global hotkey (default Cmd+N), type a brain-dump that
   contains at least one task with a time block, e.g.
   `block 1-2pm standup, email Jamie, domain renewal due Friday`.
2. **Extract:** press Cmd+Return. Apple FM extracts on-device; the Review state
   appears with the parsed rows.
3. **Commit:** accept the rows (Cmd+Return again) so they land in today's markdown
   file under `## Tasks`.
4. **Rollover:** trigger the rollover path. Either relaunch Jotty (rollover runs at
   launch) or, to exercise the midnight path, set the system clock just before
   00:00 and let the midnight timer fire. The rolled-forward tasks should appear in
   today's file.

### 4. Assert zero outbound packets

Read the capture output. On the default config the expected result is:

- **No outbound packets attributable to Jotty.** No connection to
  `api.anthropic.com`, `api.openai.com`, `generativelanguage.googleapis.com`, or
  `127.0.0.1:11434`.
- Loopback is filtered out above; even unfiltered, the default path has no reason to
  touch `127.0.0.1` because Apple FM is in-process.
- If Little Snitch was used, no Jotty outbound prompt was raised.

Any outbound packet from Jotty on the default config is a finding and a release
blocker.

### 5. Record the result

Note the date, macOS version, Jotty version, the exact filter used, and the
outcome (pass / fail with captured lines). A pass reads, plainly: "Default config
(Apple Foundation Models + local markdown): zero outbound packets observed across a
full capture -> extract -> commit -> rollover cycle."

## Endpoint table (non-default providers)

These are the only network destinations Jotty contacts, and only when you select the
corresponding non-default provider. Settings -> AI surfaces this same list before you
enable a provider, and Settings -> Advanced shows the zero-network summary plus this
table. The values come from the single source of truth, `ProviderEndpoints` in
`Jotty/Settings/AITab.swift`.

| Provider | Endpoint |
|---|---|
| Apple Foundation Models (default) | none - runs entirely on this Mac |
| Ollama | `http://127.0.0.1:11434` (local daemon, loopback only) |
| Claude | `https://api.anthropic.com/v1/messages` |
| OpenAI | `https://api.openai.com/v1/chat/completions` |
| Gemini | `https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent` |

Apple Foundation Models and Ollama are on-device (Ollama via loopback only). Claude,
OpenAI, and Gemini are cloud providers: selecting one and committing a capture sends
the capture text to that endpoint. API keys for the cloud providers live only in the
macOS Keychain, never in `config.json` or any file on disk.

## Inbox network posture (Phase 7)

The Unified Inbox is held to the same zero-network default. The default,
unconfigured config reaches no inbox endpoint at all.

- **No network on the default config.** With no source configured, the inbox makes no
  request. `InboxService.refresh()` self-guards on having at least one configured
  source, so opening the menubar with no Personal Access Token set issues no inbox
  call and shows no Suggested section.
- **One reachable endpoint in this version: `api.github.com`.** GitHub is the only
  shipped source. It is contacted **only when a PAT is configured**, and only for two
  reads per refresh: your assigned issues (`https://api.github.com/issues?filter=assigned`)
  and review-requested pull requests (`https://api.github.com/search/issues`). No
  other inbox endpoint is reachable in this version.
- **Refresh is lazy and opt-in.** With a source configured, the inbox refreshes when
  you open the menubar (the same lazy trigger as the calendar read). The only other
  trigger is the **Settings → Integrations** "Check periodically" toggle, which is
  **OFF by default** (and floored at a 5-minute interval when on). There is no
  background polling unless you opt in.
- **The PAT lives in the Keychain only.** The GitHub Personal Access Token is written
  to the macOS Keychain (`kSecClassGenericPassword`, app-scoped, not iCloud-synced)
  via the same path as the cloud-provider API keys. It is never written to
  `config.json`, UserDefaults, logs, or any file on disk, and is never read back into
  the UI after it is saved.

### Inbox transparency registry

The full five-source registry is surfaced in **Settings → Integrations**, listing
every planned endpoint whether or not the source is built, so the complete inbox
network surface is visible. The values come from the static `InboxSourceCatalog`
source of truth.

| Source | Status | Endpoint |
|---|---|---|
| GitHub | Built | `https://api.github.com` |
| Gmail | Planned (extension point) | `https://gmail.googleapis.com` |
| Slack | Planned (extension point) | `https://slack.com/api` |
| Linear | Planned (extension point) | `https://api.linear.app` |
| Notion | Planned (extension point) | `https://api.notion.com` |

Only GitHub is reachable in this version; the Planned rows are transparency
disclosures of future endpoints, not active network destinations.

### Auditing the inbox path

The manual capture procedure above extends to the inbox unchanged. To confirm the
default-config posture, run the `tcpdump` / Little Snitch capture from
[Manual procedure](#manual-procedure-human-only) with **no PAT set** and open the
menubar: no connection to `api.github.com` should appear, and no Suggested section
should render. To audit the configured path, set a PAT, open the menubar, and confirm
the only inbox connection is to `api.github.com` (the two reads above) — and that no
request fires on the default config or while the periodic toggle is OFF and the
menubar is closed.

## Why the live capture is human-only

`xcodebuild test` runs the suite against fakes (no real network, no real Calendar, no
real login-item registration) so it stays deterministic and fast. Packet capture
needs root, a real running app, and a quiet host, none of which fit a unit test. The
`PrivacyDefaultTests` unit assertions are the automated complement that runs every
build; this manual capture is the release-time confirmation that the running binary
behaves as the unit tests claim.
