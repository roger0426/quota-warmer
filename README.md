# QuotaWarmer (hardened fork)

> **This is a personal fork of [bcanozgur/quota-warmer](https://github.com/bcanozgur/quota-warmer)**, based on upstream v1.4.4 (`df8dfee`). It narrows what the app can reach and what it keeps on disk; see [How this fork differs](#how-this-fork-differs-from-upstream) and read [Risks](#risks-read-before-installing) before installing. It is currently shared with a few friends for testing; there are no releases, Homebrew cask or update checks. Problems go to [this fork's issues](https://github.com/roger0426/quota-warmer/issues), not upstream.

QuotaWarmer is a compact macOS menu bar app that manages your Claude Code and Codex CLI capacity — it keeps your own rolling quota windows in view and, when you ask it to, ready to use the moment they reset.

By default it only **monitors**: it watches live quota snapshots and shows each provider's window directly in the menu bar. Switch a tool to **Auto-warm** and it will also send a single minimal warm-up command through your own logged-in CLI the instant a fresh 5-hour window opens — then verify the window actually started.

<p align="center">
  <img src="docs/images/quota-warmer-menu-dark.png" alt="QuotaWarmer menu bar popover showing Claude and Codex session and weekly quota bars" width="360">
</p>

## Highlights

### Quota at a glance

- **Menu bar status**: each pinned provider shows its glyph, a mode/health dot, the 5-hour countdown and its quota percentage — Claude and Codex side by side, each pinnable independently.
- **Session and weekly windows**: both windows per provider, with reset countdowns.
- **Pace bars**: a knob on every bar marks how much of the window's *time* is left. When quota runs faster than time, the row says how far behind you are and when the quota will run out (`13% short · Runs out in 2h 0m`).
- **Left or used**: a per-provider **↓% / ↑%** toggle switches between quota *left* (bar drains from 100%) and quota *used* (bar fills from 0%, like claude.ai's Usage page). The menu bar percentage follows the same choice.
- **Colorful quota bars**: bars turn **blue → orange at 50% used → red at 80% used**, in Claude-style colors. Prefer the classic look? Turn off *Colorful Quota Bars* in Settings for single-color bars.
- **Light, dark or system theme**: a sidebar button cycles **System ◐ → Light ☀︎ → Dark ☾**. System follows macOS, including live switches.
- **Estimated API-equivalent cost**: today, yesterday and the last 30 days per provider, from local CLI logs. Prices come from the catalog built into the app (this fork does not download catalog updates), and unknown models are shown as unpriced instead of `$0.00`.

### Warm-ups

- **Three modes per tool**: **Off**, **Monitor** (watch quota, never send anything — the default), or **Auto-warm** (claim fresh windows automatically). A global pause stops every automatic warm-up at once.
- **Window claim receipt**: after a warm-up, QuotaWarmer re-checks quota to confirm the window actually opened — so "sent" never quietly means "missed."
- **Morning pre-warm**: optionally wakes a sleeping Mac at a time you type in (weekdays only if you like) so a fresh window is already running when you sit down.
- **Low-cost, isolated warm-ups**: a pinned cheap model, one turn, no tools, no session saved, run from an empty temp directory.

### Reliability

- **Live quota tracking**: reset decisions use fresh server quota snapshots; local logs are display context only.
- **Rate-limit guard**: failed checks and warm-ups back off exponentially instead of hammering the provider.
- **Quiet credentials**: background checks never raise a Keychain password dialog. After `claude auth login`, the app re-checks automatically within seconds. The Claude access token is held only in memory while the app runs: this fork keeps no copy of it in the Keychain or on disk, and removes the copy older builds left behind.
- **Liveness watchdog**: if the app ever stops checking quota, the menu bar and popover say so instead of looking healthy.

### Everyday use

- **Manual controls**: refresh quota or warm a provider directly from the popover; collapse either provider card.
- **Right-click menu**: jump to stats or settings, set the diagnostics level, or quit.
- **Desktop widget**: one battery-style gauge per account, showing quota used. The outer ring is the session window and the inner ring the weekly one; a ring turns red at 80% used, and a white dot marks how far through the window the clock is. The widget is sandboxed and only reads the `status.json` the app writes; add it from the desktop's Edit Widgets… gallery after the app has run once from `/Applications`.
- **History and notifications**: recent checks, warm-ups and failures in Settings; optional reminders before a window resets and when a window is claimed. (This fork has no in-app update check.)
- **Launch at login**: runs quietly as a menu bar utility.
- **Statusline**: show live quota in Claude Code's status line, tmux or starship (see [Statusline](#statusline)).

## How this fork differs from upstream

| Area | Upstream v1.4.4 | This fork |
| --- | --- | --- |
| Network | `api.anthropic.com`, `chatgpt.com`, plus daily model/price catalog downloads from `raw.githubusercontent.com` and update checks on `api.github.com` | Only `api.anthropic.com` and `chatgpt.com`. Catalog download and update check are switched off in code; `scripts/check-egress-hosts.py` fails CI if a new host appears |
| Claude token copy | Mirrored into the app's own Keychain item (`com.quotawarmer.app.claude-oauth-cache`) | Held in memory only; the old Keychain item is deleted on launch |
| Running the CLIs | Command built as a shell string for `zsh -lc` (model name filtered to `[a-z0-9.-]`) | Arguments passed as an array to a fixed `exec "$@"` script, so no value is parsed as shell syntax. Relaunch after a language change works the same way |
| Claude warm-up / token refresh | Isolated warm-up, with an unisolated fallback command | `--safe-mode` also on the token refresh; the unisolated fallback is removed |
| Codex warm-up | `--ignore-user-config` (global `~/.codex/hooks.json` still runs) | Also `--disable hooks`, unused features off, one-line system prompt: about 9,100 input tokens instead of 15,200 in our test |
| Warm-up size check | — | History flags a warm-up that used more tokens than expected (Claude 5,000, Codex 20,000), a sign the isolation stopped working |
| Warm-up model | Picked from the remote catalog | Per account under Settings → Accounts → Warm-up model (bundled list with prices, or a custom id) |
| Desktop widget | — | Sandboxed WidgetKit extension that only reads `status.json` |
| Accounts | Built-in account cannot be removed | Built-in account can be removed and added back |
| Identity on disk | Bundle ID `com.quotawarmer.app`, data in `~/Library/Application Support/QuotaWarmer` | Bundle ID `io.github.roger0426.quotawarmer`, data in `~/Library/Application Support/io.github.roger0426.quotawarmer` and logs in `~/Library/Logs/io.github.roger0426.quotawarmer`, so the two never share settings or files |
| GitHub Actions | Release, auto-release, labeler, stale, catalog watch | Build and test only (`ci.yml`) |

**Coming from upstream (or an earlier build of this fork)?** On first launch the app copies your settings and the `~/Library/Application Support/QuotaWarmer` folder into its own locations, once, and leaves the originals untouched. Things macOS ties to the bundle ID do not carry over: turn **Launch at login** on again, allow notifications again, and re-add the desktop widget. If both apps are installed, `quotawarmer://` links may open either one.

Unchanged from upstream, and still worth knowing: Keychain reads without a prompt, Morning pre-warm needs administrator rights, local transcripts are read for cost estimates, and the Codex reset-credit feature. All of these are covered under Risks.

## Risks (read before installing)

This app runs with your user account's full permissions and handles the credentials of two paid services. Know what it does before you install it:

- **It reads your Claude Code and Codex login tokens.** Claude's comes from the Keychain item `Claude Code-credentials` (or `CLAUDE_CODE_OAUTH_TOKEN`, or `~/.claude/.credentials.json`); Codex's from `~/.codex/auth.json` or the Keychain item `Codex Auth`. Keychain reads go through `/usr/bin/security`, which Claude Code's item already trusts, so **macOS shows no prompt**. Any program running as you can do the same; this app does not make that worse, but you will not see a dialog telling you it happened.
- **It calls private, undocumented endpoints** with those tokens: `api.anthropic.com/api/oauth/usage` and `chatgpt.com/backend-api/wham/usage`. They can change or disappear without notice, and whether calling them, or sending automatic warm-ups, is allowed under Anthropic's and OpenAI's terms has not been checked. Use it at your own risk; if you are unsure, leave every tool on **Monitor** (which only reads quota) or **Off**.
- **Warm-ups spend your quota.** Auto-warm runs your own logged-in CLI once per fresh window, a small request on a cheap model. If the CLI changes and the isolation stops working, a warm-up can cost more; History flags unusually large warm-ups, but check it from time to time.
- **It reads your full local transcripts** (`~/.claude/projects/*/*.jsonl`, `~/.codex/sessions/**/*.jsonl`) to estimate cost. Nothing from them leaves your Mac, but the app can see everything you have typed into either CLI.
- **The warm-up runs through a login shell** (`zsh -lc`), so your `~/.zprofile` and similar files are loaded each time.
- **Morning pre-warm (off by default) runs as root** to set a daily `pmset repeat wakeorpoweron` schedule, which changes your Mac's system-wide wake schedule. Turning the feature off removes it; to check by hand, run `pmset -g sched`, and `sudo pmset repeat cancel` clears it.
- **Codex reset credits**: the app can show and, only after you confirm, spend a Codex reset credit. Spending one cannot be undone.
- **The build is ad-hoc signed and not notarized by Apple.** macOS cannot vouch for who built it, and you must clear the quarantine flag to open it. Only install a build from someone you trust, or build it yourself from this repository.
- **The repository includes AI agent configuration** (`CLAUDE.md`, `AGENTS.md`, `.claude/`, `.codex/`, `.agents/`) inherited from upstream. Claude Code or Codex loads it automatically when you open the repo; read it first if you work on the code with an agent.
- **Shortcuts and the URL scheme**: any web page can open a `quotawarmer://` link, so links are limited to opening the panel and refreshing quota. The *Warm Up Now* and *Set Mode* Shortcuts actions can change behaviour, so only run Shortcuts you trust.

QuotaWarmer never bypasses or raises your limits and never uploads your credentials anywhere except the two providers' own servers.

## How It Works

Claude Code and Codex CLI use rolling quota windows. If a window starts only when you remember to open the CLI, part of the available time can be wasted.

QuotaWarmer keeps the app running in the menu bar and periodically checks quota state for monitored providers. For a tool set to Auto-warm, when a fresh reset is detected it runs a minimal warm-up command from an isolated temporary working directory:

```bash
claude --model haiku --effort low --settings '{"alwaysThinkingEnabled":false}' --safe-mode --strict-mcp-config --system-prompt 'Reply with one word.' --no-session-persistence --max-turns 1 --tools '' --output-format json -p hi
codex exec --model gpt-5.6-luna -c 'model_reasoning_effort="low"' -c 'model_instructions_file="…/warmup-instructions.md"' --skip-git-repo-check --ephemeral --ignore-user-config --ignore-rules --disable hooks --disable apps … hi
```

Both commands pin a bounded low-cost model and do not fall back to the user's default model. The Claude run skips your `CLAUDE.md`, MCP servers, skills and thinking, so a warm-up costs about 1,000 tokens (930 in our test). Codex ignores user configuration for this isolated run while continuing to use the existing Codex authentication. The warm-up model lists live in `Sources/QuotaWarmer/Resources/*-models.json`; if a CLI rejects a model, the next one in the list is tried. To use a different model for one account, pick it under Settings → Accounts → Warm-up model: the menu lists the bundled models with their price (USD per million tokens, input / output), and Custom… takes any model id. If the CLI rejects your choice, the default list is used and History says so.

**Morning pre-warm** uses a daily `pmset repeat wakeorpoweron` schedule, so changing it asks for your administrator password once. Waking is best-effort on battery with the lid closed.

Local activity is scanned from:

```text
~/.claude/projects/*/*.jsonl
~/.codex/sessions/YYYY/MM/DD/*.jsonl
```

These logs help the UI show context, but stale local activity does not trigger automatic warm-ups.

Token costs shown in the popover are estimates using public API-equivalent rates, not actual Claude or ChatGPT subscription charges. A period containing an unknown or unpriced model is marked unavailable instead of being reported as `$0.00`.

## Requirements

| Dependency | Requirement |
| --- | --- |
| macOS | 14.0 Sonoma or later |
| Xcode | 16+ for local builds |
| Claude Code | Installed and available on your shell `PATH` |
| Codex CLI | Installed and available on your shell `PATH` |

QuotaWarmer shows setup guidance on first launch if a required CLI is missing.

## Install

This fork has no releases or Homebrew cask yet. The upstream cask installs upstream's app, not this one.

### Test build from CI

Every push builds an ad-hoc signed `QuotaWarmer.zip`, kept for 14 days:

1. Open a green run of the **CI** workflow in this repo's [Actions](https://github.com/roger0426/quota-warmer/actions) tab (you need to be signed in to GitHub) and download the `QuotaWarmer-<commit>` artifact.
2. Unzip it until you have **QuotaWarmer.app**, and drag it to **Applications**.
3. Clear the quarantine flag (below), then launch it.

Or [build it yourself](#build-from-source).

### First launch (Gatekeeper)

QuotaWarmer is ad-hoc signed but **not Apple-notarized**, so macOS quarantines it on
download. Clear the quarantine once after installing:

```bash
xattr -dr com.apple.quarantine "/Applications/QuotaWarmer.app"
```

…or right-click **QuotaWarmer.app** in Applications and choose **Open** the first time.

## Statusline

After every successful quota check, QuotaWarmer writes the live quota to
`~/Library/Application Support/io.github.roger0426.quotawarmer/status.json` (per account: session and weekly
used/left percent, reset times, freshness, mode; never tokens or credentials).
`scripts/quotawarmer-statusline.sh` turns it into one line:

```text
Claude 58% left · 2h13m | Codex 18% used · 43m (stale 12m)
```

Each account uses its own left/used setting from the app. Data older than 5 minutes is marked
`(stale …)`, accounts set to Off are skipped, and the script always exits 0 (`QuotaWarmer: no data`
when the app hasn't written the file yet). It needs nothing beyond macOS.

Install the script from a clone of this repository (read it first; it is short):

```bash
mkdir -p ~/.local/bin && cp scripts/quotawarmer-statusline.sh ~/.local/bin/ && chmod +x ~/.local/bin/quotawarmer-statusline.sh
```

**Claude Code** — add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.local/bin/quotawarmer-statusline.sh --only claude"
  }
}
```

**tmux** — in `~/.tmux.conf`:

```text
set -g status-interval 30
set -g status-right '#(~/.local/bin/quotawarmer-statusline.sh --pinned)'
```

**starship** — in `~/.config/starship.toml`:

```toml
[custom.quota]
command = "~/.local/bin/quotawarmer-statusline.sh --only claude"
when = true
format = "[$output]($style) "
```

Options: `--only claude,codex.work` (tools or account ids), `--pinned` (accounts pinned to the
menu bar), `--weekly` (append `wk 31%`), `--mode used|remaining` (override the app setting),
`--stale-after SECONDS` (default 300), `--file PATH` (or `QUOTAWARMER_STATUS_FILE`).

The file's format is versioned by `schemaVersion` (currently 1); see
`Sources/QuotaWarmer/Models/QuotaStatus.swift`. Consumers should judge freshness from `fetchedAt`,
since the file is only rewritten when a check succeeds.

## URL Scheme, Shortcuts & Hotkey

**URL scheme** — `quotawarmer://` is read/open/refresh only. Any web page can open a URL, so
links can never send a warm-up or change a mode or setting; unknown actions and parameters are ignored.

```text
quotawarmer://open[?tab=main|history|settings]
quotawarmer://refresh[?provider=claude|codex|<account key>]
```

`refresh` only polls monitored accounts, respects the rate-limit backoff, and is limited to once
per account per 30 s. Try it with `open "quotawarmer://refresh?provider=claude"`.

**Shortcuts / Spotlight** — QuotaWarmer provides App Intents: *Get Quota* (session/weekly used and
left %, reset times, freshness, for a chosen account), *Refresh Quota*, *Set Mode* (Off / Monitor /
Auto-warm), *Pause Auto-warm*, *Resume Auto-warm* and *Warm Up Now* (asks for confirmation, then uses
the same path as the popover's Warm button). Find them in the Shortcuts app under QuotaWarmer.

**Global hotkey** — Settings → Shortcuts. Off by default; opens the popover from anywhere
(default ⌃⌥Q once enabled). Uses a system hotkey, so no Accessibility permission is needed.

## Build From Source

Install XcodeGen, generate the project, and open it in Xcode:

```bash
brew install xcodegen
git clone https://github.com/roger0426/quota-warmer.git
cd quota-warmer
xcodegen generate
open QuotaWarmer.xcodeproj
```

CLI build:

```bash
xcodebuild -project QuotaWarmer.xcodeproj -scheme QuotaWarmer build
```

Build a local Release app, replace any existing `/Applications/QuotaWarmer.app`, clear quarantine, and launch it:

```bash
scripts/local-package.command
```

Run the regression suites (the same command CI runs):

```bash
swift test
```

The suites live in `Tests/RegressionTests/`:

- `Tests/RegressionTests/quota-extractor-regression.swift` — quota parsing, warm-up commands, cost estimates
- `Tests/RegressionTests/quota-display-regression.swift` — left/used display, bar colors, menu-bar text, theme cycle, wake-time input, `quotawarmer://` URL parsing, hotkey spec
- `Tests/RegressionTests/accounts-history-regression.swift` — multi-account identity, quota history, the `status.json` export, migration from upstream's bundle ID

## Project Structure

```text
Sources/QuotaWarmer/
  Models/       Shared app and quota types
  Services/     Quota checks, scheduling, notifications, warm-up commands
  Views/        SwiftUI menu bar label, popover, provider, and settings screens
  Assets.xcassets/
project.yml     XcodeGen project definition
Tests/         Regression suites (run with `swift test`; Package.swift is test-only)
scripts/       Packaging helpers, statusline script, model-catalog checker
```

## Release Process

This fork does not publish releases yet. CI (`.github/workflows/ci.yml`) builds, tests, checks outbound hosts and uploads an ad-hoc signed `QuotaWarmer.zip` artifact on every push. Upstream's release, auto-release and Homebrew workflows were removed.

## License

MIT, as stated by upstream's README. Upstream's repository does not include a separate `LICENSE` file; this fork's changes are offered under the same terms.
