# Agent Watch

A small macOS menu bar app that shows which **sessions and subagents** are running in
[Claude Code](https://claude.com/claude-code) and [OpenCode](https://opencode.ai), and **which model** each one uses.

It only reads the files both tools already write on your machine. It never writes to them,
never talks to the network, and does not need any plugin or hook in either tool.

## What you see

Click the menu bar icon. The list has three zones:

| Zone | What is in it |
| --- | --- |
| **Running now** | Anything generating a response right now, highlighted in green. A session stays here with its running subagents. |
| **Active · N** | Open sessions waiting for you: not running, but touched in the last 30 minutes. |
| **Recent · N** | The rest of the last 24 hours. Folded by default. |

Each row shows the agent, its model (`openai/gpt-6-luna (xhigh)`), the project folder and title,
tokens (`697.4k in · 27.2k out`) and a time label:

- a running subagent: how long it has been running (`running 1m 20s`)
- a finished subagent: how long it took (`took 2m 5s`, `failed after 40s`)
- a session: when it last did something (`3m ago`)

Click a row for a menu: copy the resume command, copy the session id, copy the folder path or
open the folder in Finder. The resume command is only offered for main sessions and looks like
`cd '/path/to/project' && claude --resume <id>` or `... && opencode --session <id>`.

The icon shows a count next to it while something runs. Failed or interrupted subagents trigger a
notification; a check box in the menu also notifies when one finishes cleanly.

### Usage tab

The **Usage** tab sums tokens per model for **today** or the **last 7 days** (calendar days, today included):
`in` and `out` plus cache reads, the number of model responses, and a bar relative to the busiest model.
It is built from every response in both tools, so a session that switched models is split correctly.
Cost appears only when the tool reports one.

At the top, **Plan limits** shows the limits each provider reports for your plan, e.g. Codex `Weekly · 2% used ·
resets in 6d 22h` and Claude `Session · 45% used · resets in 3h 16m` plus `Weekly`, with a bar that turns orange
at 80 % and red at 95 %. They are fetched only while the panel is open on the Usage tab, at most once a minute,
by running the provider's own tool for a moment. A tool that is not installed is simply absent. If one fails, a
note says so under the limits.

## It never spends tokens

Nothing this app does uses model tokens or your plan's quota. Everything it does outside your own files:

| Action | What it runs | Why it costs nothing |
| --- | --- | --- |
| Agents, usage, history | Reads files and a SQLite database, read-only | No network, no model |
| Claude limits | `claude -p "/usage"` (see above) | Claude Code owns the login: no token or credentials file is read. The text it prints (`Current session: 40% used · resets Oct 20 at 1:29pm (Atlantic/Canary)`) is parsed, so a wording change shows as "Limits unavailable", never as wrong numbers. |
| Codex limits | `codex app-server`, only `initialize`, `initialized` and `account/rateLimits/read` | An account read. No thread or turn is ever started; a test checks that nothing else is sent |
| Claude limits | `claude -p "/usage" --output-format json --safe-mode --no-session-persistence` | `/usage` is a local slash command: it reports 0 turns, 0 cost and 0 tokens |
| Row menu, notifications | Clipboard, Finder, local notifications | Local |

For Claude this is **verified on every call**, not assumed. The JSON result must report zero turns, zero API time,
zero cost, zero tokens and no model usage. If any of that is non-zero, or missing so it cannot be checked, the call is
rejected and the source **disables itself until the app restarts**, so a change in Claude Code can cost at most
one request. The command line is fixed by a test (the prompt is always the literal `/usage`), and
`--no-session-persistence` keeps these calls from leaving a transcript in your session list.

`in` and `out` are fresh tokens and leave out cache reads, which are far larger and much cheaper.

## Install

Requires macOS 14+ and a Swift 6 toolchain (Xcode).

```bash
scripts/build-app.sh
cp -R dist/AgentWatch.app ~/Applications/
open ~/Applications/AgentWatch.app
```

The app is signed ad hoc. The first time, macOS may ask you to allow it (right click → Open).
"Launch at login" and notifications only work from the packaged `.app`.

### Install from a release

Apple Silicon only (M1 or later), macOS 14 or newer.

1. Download `AgentWatch-<version>-arm64.zip` from the Releases page.
2. Optional: check it with `shasum -a 256 AgentWatch-<version>-arm64.zip`, which must match the `.sha256` file.
3. Unzip it and move `AgentWatch.app` to `/Applications`.
4. The app is signed ad hoc, not with an Apple certificate, so macOS blocks a downloaded copy the first time.
   Allow it once, either by trying to open it and then going to System Settings → Privacy & Security → **Open
   Anyway**, or by removing the download quarantine mark:

```bash
xattr -dr com.apple.quarantine /Applications/AgentWatch.app
```

An Apple certificate (Developer ID plus notarization) would remove that step, but it is not needed to run the app.

### Publish a release

```bash
scripts/package.sh 0.1.0
gh release create v0.1.0 dist/AgentWatch-0.1.0-arm64.zip dist/AgentWatch-0.1.0-arm64.zip.sha256 --title "Agent Watch 0.1.0"
```

To run from source without packaging, or to print the same data in a terminal:

```bash
swift run AgentWatchApp
swift run agentwatch-cli --hours 24
swift run agentwatch-cli --usage
```

## Where the data comes from

| Tool | Source | Notes |
| --- | --- | --- |
| Claude Code | `~/.claude/projects/<project>/<session>.jsonl` and `<session>/subagents/agent-*.jsonl` | The model comes from assistant messages only. A message is written once per content block and its output counter grows while it streams, so usage is counted once per message id, using the last row. |
| Codex limits | `codex app-server`, request `account/rateLimits/read` (JSON-RPC over stdio) | Codex owns the login: no token or credentials file is read, only the percentages come back. The protocol is marked experimental by Codex; it was checked against codex-cli 0.163. |
| OpenCode 2.x | `~/.local/share/opencode/opencode.db`, tables `session_v2` (sessions) and `session_message` (per-response model, tokens, cost) | Opened read-only. A session with a `parent_id` is a subagent. |

### How "running" is decided

Neither tool exposes a "running" flag, so it is inferred:

- **OpenCode**: a session updated after its last `time_idle` is mid-turn. `idle_outcome` keeps the result
  of the *previous* turn, so it is only trusted for finished subagents.
- **Claude Code session**: the last assistant message did not end with `end_turn` (or you wrote after it),
  and the transcript changed in the last 5 minutes.
- **Claude Code subagent**: finished once the parent transcript holds a `tool_result` for its `toolUseId`.
- Anything else without a final signal counts as running for 5 minutes, then as unknown.

## Limits

- Both formats are internal and unversioned. A tool update can change them; the adapters are isolated
  so that only one file needs to change.
- Cost is shown only when the tool reports it. OpenCode stores `0` for many models and Claude Code stores
  none; nothing is estimated from a price table.
- Tokens are per session or subagent. A session does not include the tokens of its subagents.
- Usage covers what is on disk. It is not the official usage or billing of Anthropic or OpenAI: those APIs
  need an organization admin key and measure API billing, not subscriptions.
- Plan limits are shown for **Codex and Claude**, and only when those tools are installed and signed in. Claude's
  come from `claude /usage`; the status line (which would change Claude Code's configuration, and clashes with
  other tools that already use it) and Anthropic's undocumented OAuth endpoint (which needs your session token)
  are not used.
- The Codex limit is named `codex`. Whether usage made through OpenCode with the same ChatGPT account counts
  against it has not been verified.
- "Active" is a time heuristic (30 minutes). It does not know whether the terminal is still open.
- Claude Code subagents are never reported as failed, because its transcripts have no such signal.

## Development

```bash
swift test
```

The package has four targets:

- `AgentCore`: model, status rules, tree and section logic, labels. No file system, no UI.
- `Adapters`: one reader per tool, behind the `AgentSource` protocol.
- `AgentWatchApp`: the menu bar UI. Thin glue with no rules of its own.
- `agentwatch-cli`: prints the same data in a terminal.

Test fixtures are synthetic. They mimic the real formats and never contain real transcripts.

The app icon and the menu bar glyph are drawn in code. To regenerate `Resources/AppIcon.icns`:

```bash
swift scripts/make-icon.swift
```
