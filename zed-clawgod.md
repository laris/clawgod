# zed-clawgod.sh — Zed ↔ ClawGod integration

Route Zed's **Claude Agent** through the ClawGod-patched Claude Code binary. A
standalone post-install helper (macOS / Linux) that touches **none** of
ClawGod's official files, so this fork rebases cleanly on upstream.

## Why it's needed

Zed's *External Agents → Claude Agent* doesn't run the `claude` on your `PATH`.
It launches the ACP adapter (`@agentclientprotocol/claude-agent-acp`), which
resolves the Claude binary as:

```
process.env.CLAUDE_CODE_EXECUTABLE  ??  @anthropic-ai/claude-agent-sdk-<platform>/claude
```

Two consequences:

1. Patching the `PATH` `claude` (what `install.sh` does) has **no effect** on Zed.
2. Zed's registry can silently bump that SDK-bundled binary via update pushes you
   don't see or control — so you lose ClawGod's maintenance workflow.

Setting `CLAUDE_CODE_EXECUTABLE` takes control back: the registry's SDK binary is
downloaded-but-**never run**, and ClawGod owns the binary that executes (and
re-patches it to the latest Claude on its own). The registry then controls only
the thin ACP protocol adapter, not Claude Code itself.

## What it does

Adds a `claude-clawgod` custom agent to Zed's `settings.json`:

```jsonc
"agent_servers": {
  // Added by ClawGod: routes Zed Claude ACP agent through the patched binary.
  "claude-clawgod": {
    "type": "custom",
    "command": "npx",
    "args": ["--yes", "@agentclientprotocol/claude-agent-acp"],
    "env": {
      "CLAUDE_CODE_EXECUTABLE": "/Users/you/.local/bin/clawgod",
      "HTTP_PROXY":  "http://127.0.0.1:10808",
      "HTTPS_PROXY": "http://127.0.0.1:10808",
      "NO_PROXY":    "localhost,127.0.0.1"
    }
  }
}
```

Design choices:

- **Adapter unpinned** — `npx` resolves the latest adapter each launch, staying
  aligned with ClawGod's always-latest patched binary (avoids protocol drift).
- **`CLAUDE_CODE_EXECUTABLE` = `~/.local/bin/clawgod`** — the durable launcher.
  Unlike `/opt/homebrew/bin/claude`, it's never clobbered by `claude update` or a
  brew reinstall.
- **Proxy on by default** — needed so `npx` can fetch the adapter; also propagates
  to the child (`clawgod → cli.cjs`). Override with `--proxy`, disable with
  `--no-proxy`.
- **No `model` / `effort` presets** — Zed's per-agent config UI manages those live.

The edit is additive (existing entries untouched), JSONC-safe (comments and
trailing commas preserved via surgical text insertion, not a reserialize),
validated before writing, and backed up to `settings.json.clawgod.bak`.

## Usage

```bash
bash zed-clawgod.sh                  # add (proxy default on)
bash zed-clawgod.sh --proxy URL      # use a specific proxy
bash zed-clawgod.sh --no-proxy       # omit proxy env
bash zed-clawgod.sh --force          # overwrite an existing entry (e.g. change proxy)
bash zed-clawgod.sh --remove         # remove the entry
bash zed-clawgod.sh --launcher PATH  # custom CLAUDE_CODE_EXECUTABLE
bash zed-clawgod.sh --settings PATH  # custom settings.json location
```

Then pick **claude-clawgod** from Zed's External Agents (`+`) menu.

Verify it's running the patched binary:

```bash
ps -axo pid,ppid,command | grep -E 'clawgod|cli\.cjs|claude-agent-acp' | grep -v grep
# expect: node .../claude-agent-acp  →  bun ~/.clawgod/cli.cjs ...
```

## Lifecycle notes

- **Run once.** You do *not* need to re-run on ClawGod updates — the launcher path
  is stable and `cli.cjs` is re-patched in place. Re-run only if Zed's
  `settings.json` is reset, or with `--force` to change options.
- **Before uninstalling ClawGod**, run `bash zed-clawgod.sh --remove` first.
  `clawgod --uninstall` deletes `~/.local/bin/clawgod` but knows nothing about
  this Zed entry, which would otherwise point at a deleted launcher.
- **Requirements:** `node` (already a ClawGod prerequisite) and `npx` on the shell
  PATH Zed launches agents with.
- **Windows** is not covered yet; on Windows the adapter may not spawn a `.cmd`
  target — set `CLAUDE_CODE_EXECUTABLE` to `bun.exe` + `%USERPROFILE%\.clawgod\cli.cjs`
  or run Zed under WSL.
