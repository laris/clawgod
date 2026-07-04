#!/bin/bash
set -e
# ─────────────────────────────────────────────────────────
#  zed-clawgod.sh — route Zed's Claude ACP agent through the
#  ClawGod-patched Claude Code binary.  (macOS / Linux)
#
#  Standalone post-install helper. Does NOT modify any of ClawGod's
#  official files, so a fork carrying only this script rebases cleanly
#  on upstream.
#
#  Why this is needed: Zed's "Claude Agent" launches the ACP adapter
#  (@agentclientprotocol/claude-agent-acp), which resolves the Claude
#  binary as  process.env.CLAUDE_CODE_EXECUTABLE ?? <SDK-bundled binary>.
#  It never consults the `claude` on your PATH, and Zed's registry can
#  silently bump that SDK-bundled binary out from under you. Pointing
#  CLAUDE_CODE_EXECUTABLE at the ClawGod launcher takes back control:
#  the registry's binary is downloaded-but-never-run; ClawGod owns the
#  binary and re-patches it to the latest Claude on its own.
#
#  What it adds — a `claude-clawgod` custom agent in Zed's settings.json:
#    - runs the ACP adapter via npx, UNPINNED (tracks latest, staying
#      aligned with ClawGod's always-latest patched binary)
#    - CLAUDE_CODE_EXECUTABLE = ~/.local/bin/clawgod  (the durable
#      launcher — never clobbered by `claude update` / brew, unlike
#      /opt/homebrew/bin/claude)
#    - proxy env (HTTP_PROXY/HTTPS_PROXY/NO_PROXY), on by default
#
#  The edit is additive (existing entries untouched), JSONC-safe
#  (comments + trailing commas preserved), validated before writing,
#  and backed up to settings.json.clawgod.bak.
#
#  Run it ONCE after installing ClawGod. You do NOT need to re-run it on
#  ClawGod updates — the launcher path is stable and cli.cjs is patched
#  in place. Re-run only if Zed's settings.json is reset, or with --force
#  to change options (e.g. a different proxy).
#
#  Usage:
#    bash zed-clawgod.sh                    # add (proxy default on)
#    bash zed-clawgod.sh --proxy URL        # use a specific proxy
#    bash zed-clawgod.sh --no-proxy         # omit proxy env
#    bash zed-clawgod.sh --force            # overwrite an existing entry
#    bash zed-clawgod.sh --remove           # remove the entry (run before
#                                           #   `clawgod --uninstall`)
#    bash zed-clawgod.sh --launcher PATH    # custom CLAUDE_CODE_EXECUTABLE
#    bash zed-clawgod.sh --settings PATH    # custom settings.json location
#
#  License: GPL-3.0 (same as ClawGod).
# ─────────────────────────────────────────────────────────

LAUNCHER="${CLAWGOD_LAUNCHER:-$HOME/.local/bin/clawgod}"
# Default proxy: prefer an already-exported one, else ClawGod's common
# local proxy. Override with --proxy, disable with --no-proxy.
PROXY_DEFAULT="http://127.0.0.1:10808"
PROXY="${HTTPS_PROXY:-${HTTP_PROXY:-$PROXY_DEFAULT}}"
USE_PROXY=1
REMOVE=""
FORCE=""
SETTINGS=""

GREEN='\033[0;32m'; RED='\033[0;31m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${RED}✗${NC} $1"; }
dim()  { echo -e "  ${DIM}$1${NC}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --proxy)     PROXY="$2"; USE_PROXY=1; shift 2 ;;
    --no-proxy)  USE_PROXY=0; shift ;;
    --launcher)  LAUNCHER="$2"; shift 2 ;;
    --settings)  SETTINGS="$2"; shift 2 ;;
    --remove)    REMOVE=1; shift ;;
    --force)     FORCE=1; shift ;;
    -h|--help)
      cat <<'HELP'
zed-clawgod.sh — route Zed's Claude ACP agent through the ClawGod-patched binary (macOS/Linux)

  bash zed-clawgod.sh                  add the claude-clawgod agent (proxy default on)
  bash zed-clawgod.sh --proxy URL      use a specific proxy
  bash zed-clawgod.sh --no-proxy       omit proxy env
  bash zed-clawgod.sh --force          overwrite an existing entry (e.g. change proxy)
  bash zed-clawgod.sh --remove         remove the entry (run before `clawgod --uninstall`)
  bash zed-clawgod.sh --launcher PATH  custom CLAUDE_CODE_EXECUTABLE (default ~/.local/bin/clawgod)
  bash zed-clawgod.sh --settings PATH  custom settings.json location

Defaults: launcher=~/.local/bin/clawgod, proxy=$HTTPS_PROXY / $HTTP_PROXY or http://127.0.0.1:10808
HELP
      exit 0 ;;
    *) shift ;;
  esac
done

echo ""
echo -e "${BOLD}  ClawGod → Zed integration${NC}"
echo ""

if ! command -v node >/dev/null 2>&1; then
  warn "node is required (the Zed settings edit is JSONC-safe via node)."
  dim  "Install Node.js >= 18: https://nodejs.org"
  exit 1
fi

# Non-fatal: the entry references the launcher by path, so it's fine to add
# it before ClawGod is installed — but warn so the user isn't surprised.
if [ "$REMOVE" != "1" ] && [ ! -e "$LAUNCHER" ]; then
  warn "ClawGod launcher not found at $LAUNCHER"
  dim  "Install ClawGod first:"
  dim  "  curl -fsSL https://github.com/0Chencc/clawgod/releases/latest/download/install.sh | bash"
  dim  "Continuing — the entry will point at $LAUNCHER once ClawGod is installed."
fi

# Assemble node args
NODE_ARGS=("$LAUNCHER")
[ -n "$SETTINGS" ] && NODE_ARGS+=("--settings" "$SETTINGS")
[ "$REMOVE" = "1" ] && NODE_ARGS+=("--remove")
[ "$FORCE" = "1" ]  && NODE_ARGS+=("--force")
if [ "$REMOVE" != "1" ] && [ "$USE_PROXY" = "1" ] && [ -n "$PROXY" ]; then
  NODE_ARGS+=("--proxy" "$PROXY")
fi

# Write the JSONC editor to a temp file and run it under node.
TMP_JS="$(mktemp -t zed-clawgod.XXXXXX)"
mv "$TMP_JS" "$TMP_JS.mjs"; TMP_JS="$TMP_JS.mjs"
trap 'rm -f "$TMP_JS"' EXIT
cat > "$TMP_JS" << 'NODE_EOF'
#!/usr/bin/env node
/**
 * Adds/updates/removes a `claude-clawgod` custom agent in Zed's settings.json.
 * Additive, JSONC-safe (comments + trailing commas preserved via surgical text
 * insertion), validated before writing, backed up to settings.json.clawgod.bak.
 *
 * Usage: node <this> <launcher> [--proxy URL] [--settings PATH] [--remove] [--force]
 */
import { readFileSync, writeFileSync, existsSync, copyFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir, platform } from 'node:os';

const ENTRY_KEY = 'claude-clawgod';
const MARKER = 'Added by ClawGod';

function candidatePaths() {
  const home = homedir();
  const out = [];
  if (platform() === 'win32') {
    const appdata = process.env.APPDATA || join(home, 'AppData', 'Roaming');
    out.push(join(appdata, 'Zed', 'settings.json'));
  }
  out.push(join(home, '.config', 'zed', 'settings.json'));
  return out;
}

// Strip // and /* */ comments and trailing commas — for VALIDATION only,
// never for the written output (which keeps the user's comments intact).
function stripJsonc(s) {
  let out = '', i = 0; const n = s.length; let inStr = false, q = '';
  while (i < n) {
    const c = s[i], d = s[i + 1];
    if (inStr) { out += c; if (c === '\\') { out += (d ?? ''); i += 2; continue; } if (c === q) inStr = false; i++; continue; }
    if (c === '"' || c === "'") { inStr = true; q = c; out += c; i++; continue; }
    if (c === '/' && d === '/') { while (i < n && s[i] !== '\n') i++; continue; }
    if (c === '/' && d === '*') { i += 2; while (i < n && !(s[i] === '*' && s[i + 1] === '/')) i++; i += 2; continue; }
    out += c; i++;
  }
  return out.replace(/,(\s*[}\]])/g, '$1');
}
const parseJsonc = (s) => JSON.parse(stripJsonc(s));

function pretty(obj, indent) {
  return JSON.stringify(obj, null, 2).split('\n')
    .map((ln, i) => (i === 0 ? ln : indent + ln)).join('\n');
}

function findClose(raw, braceStart) {
  let depth = 0, inStr = false, q = '';
  for (let i = braceStart; i < raw.length; i++) {
    const c = raw[i], d = raw[i + 1];
    if (inStr) { if (c === '\\') { i++; continue; } if (c === q) inStr = false; continue; }
    if (c === '"' || c === "'") { inStr = true; q = c; continue; }
    if (c === '/' && d === '/') { while (i < raw.length && raw[i] !== '\n') i++; continue; }
    if (c === '/' && d === '*') { i += 2; while (i < raw.length && !(raw[i] === '*' && raw[i + 1] === '/')) i++; continue; }
    if (c === '{') depth++;
    else if (c === '}') { depth--; if (depth === 0) return i; }
  }
  return -1;
}

function firstBrace(raw) {
  let inStr = false, q = '';
  for (let i = 0; i < raw.length; i++) {
    const c = raw[i], d = raw[i + 1];
    if (inStr) { if (c === '\\') { i++; continue; } if (c === q) inStr = false; continue; }
    if (c === '"' || c === "'") { inStr = true; q = c; continue; }
    if (c === '/' && d === '/') { while (i < raw.length && raw[i] !== '\n') i++; continue; }
    if (c === '/' && d === '*') { i += 2; while (i < raw.length && !(raw[i] === '*' && raw[i + 1] === '/')) i++; continue; }
    if (c === '{') return i;
  }
  return -1;
}

// Return raw with the ENTRY_KEY block (and our comment line + trailing comma)
// removed, or null if it can't be located. Used by --remove and --force.
function removeEntryText(raw) {
  const km = raw.match(new RegExp('"' + ENTRY_KEY + '"\\s*:\\s*\\{'));
  if (!km) return null;
  const close = findClose(raw, km.index + km[0].length - 1);
  if (close < 0) return null;
  let end = close + 1;
  const trailing = raw.slice(end).match(/^\s*,/);
  if (trailing) end += trailing[0].length;
  let start = raw.lastIndexOf('\n', km.index - 1) + 1;      // keep the key's indent
  const prevStart = raw.lastIndexOf('\n', start - 2) + 1;   // line above
  if (raw.slice(prevStart, start).includes(MARKER)) start = prevStart;  // eat our comment
  return raw.slice(0, start) + raw.slice(end);
}

function backup(file) { try { copyFileSync(file, file + '.clawgod.bak'); } catch {} }

function snippet(launcher, proxy) {
  const env = { CLAUDE_CODE_EXECUTABLE: launcher };
  if (proxy) { env.HTTP_PROXY = proxy; env.HTTPS_PROXY = proxy; env.NO_PROXY = 'localhost,127.0.0.1'; }
  const entry = { type: 'custom', command: 'npx', args: ['--yes', '@agentclientprotocol/claude-agent-acp'], env };
  console.log('add this under "agent_servers" in your Zed settings.json:');
  console.log('    "' + ENTRY_KEY + '": ' + pretty(entry, '    '));
}

// ── parse args ──
const argv = process.argv.slice(2);
const remove = argv.includes('--remove');
const force = argv.includes('--force');
let settingsArg = null, proxy = null, launcher = null;
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--remove' || argv[i] === '--force') continue;
  if (argv[i] === '--settings') { settingsArg = argv[++i]; continue; }
  if (argv[i] === '--proxy') { proxy = argv[++i]; continue; }
  if (!launcher) launcher = argv[i];
}

// An explicit --settings is authoritative: if it doesn't exist we STOP; we do
// NOT fall back to auto-detection (which could edit an unrelated real config).
const file = settingsArg ? (existsSync(settingsArg) ? settingsArg : null)
                         : (candidatePaths().find(existsSync) || null);

if (!file) {
  if (!remove) { console.log('settings.json not found — Zed not detected, skipping.'); if (launcher) snippet(launcher, proxy); }
  process.exit(0);
}

let raw;
try { raw = readFileSync(file, 'utf8'); } catch { process.exit(0); }

let parsed;
try { parsed = parseJsonc(raw); }
catch (e) {
  console.log(file + ' did not parse (' + e.message + ') — skipping to avoid corruption.');
  if (!remove && launcher) snippet(launcher, proxy);
  process.exit(0);
}

if (remove) {
  if (!raw.includes('"' + ENTRY_KEY + '"')) { console.log('no ' + ENTRY_KEY + ' entry present.'); process.exit(0); }
  const out = removeEntryText(raw);
  if (out == null) { console.log(ENTRY_KEY + ' present but not auto-removable — edit ' + file + ' by hand.'); process.exit(0); }
  try { parseJsonc(out); } catch { console.log('removal would break JSON — edit ' + file + ' by hand.'); process.exit(0); }
  backup(file);
  writeFileSync(file, out);
  console.log('removed ' + ENTRY_KEY + ' from ' + file);
  process.exit(0);
}

if (!launcher) { console.log('launcher path missing.'); process.exit(0); }

// Handle an existing entry.
let working = raw;
if (parsed.agent_servers && parsed.agent_servers[ENTRY_KEY]) {
  if (!force) {
    const cur = (parsed.agent_servers[ENTRY_KEY].env || {}).CLAUDE_CODE_EXECUTABLE;
    console.log(ENTRY_KEY + ' already configured (CLAUDE_CODE_EXECUTABLE=' + (cur || 'unset') + ').');
    console.log('re-run with --force to overwrite, or --remove to delete it.');
    process.exit(0);
  }
  const stripped = removeEntryText(working);
  if (stripped == null) { console.log(ENTRY_KEY + ' exists but not auto-editable — edit ' + file + ' by hand.'); process.exit(0); }
  working = stripped;  // fall through and insert a fresh entry
}

const env = { CLAUDE_CODE_EXECUTABLE: launcher };
if (proxy) { env.HTTP_PROXY = proxy; env.HTTPS_PROXY = proxy; env.NO_PROXY = 'localhost,127.0.0.1'; }
const entryObj = { type: 'custom', command: 'npx', args: ['--yes', '@agentclientprotocol/claude-agent-acp'], env };
const comment = '// ' + MARKER + ': routes Zed Claude ACP agent through the patched binary (CLAUDE_CODE_EXECUTABLE).';

let out;
const asm = working.match(/"agent_servers"\s*:\s*\{/);
if (asm) {
  const at = asm.index + asm[0].length;
  const lineStart = working.lastIndexOf('\n', asm.index - 1) + 1;
  const keyIndent = (working.slice(lineStart, asm.index).match(/^\s*/) || [''])[0];
  const ci = keyIndent + '  ';
  out = working.slice(0, at) + '\n' + ci + comment + '\n' + ci + '"' + ENTRY_KEY + '": ' + pretty(entryObj, ci) + ',' + working.slice(at);
} else {
  const rb = firstBrace(working);
  if (rb < 0) { console.log('could not locate root object — skipping.'); snippet(launcher, proxy); process.exit(0); }
  const ci = '  ', ci2 = '    ';
  out = working.slice(0, rb + 1) + '\n' + ci + '"agent_servers": {\n' + ci2 + comment + '\n' + ci2 + '"' + ENTRY_KEY + '": ' + pretty(entryObj, ci2) + '\n' + ci + '},' + working.slice(rb + 1);
}

let ok = false;
try {
  const p = parseJsonc(out);
  const e = p.agent_servers && p.agent_servers[ENTRY_KEY];
  ok = !!(e && e.env.CLAUDE_CODE_EXECUTABLE === launcher && (!proxy || e.env.HTTP_PROXY === proxy));
} catch {}
if (!ok) { console.log('automatic edit failed validation — not writing.'); snippet(launcher, proxy); process.exit(0); }

backup(file);
writeFileSync(file, out);
console.log((force ? 'updated ' : 'added ') + ENTRY_KEY + ' -> ' + file);
console.log('proxy: ' + (proxy || '(none)'));
console.log('backup: ' + file + '.clawgod.bak');
NODE_EOF

node "$TMP_JS" "${NODE_ARGS[@]}" | while IFS= read -r line; do echo "  $line"; done

echo ""
if [ "$REMOVE" = "1" ]; then
  info "Done. Removed the Zed integration entry."
else
  info "Done."
  dim  "Pick 'claude-clawgod' from Zed's External Agents (+) menu."
  dim  "Zed → adapter → $LAUNCHER → bun ~/.clawgod/cli.cjs → patched Claude Code."
  dim  "Before 'clawgod --uninstall', run: bash zed-clawgod.sh --remove"
fi
echo ""
