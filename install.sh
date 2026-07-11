#!/bin/bash
# codecade.co.za — master installer + control panel for the webdev portal.
# Clones/updates temutalk and git-forge, sets each up under a URL prefix
# (/temutalk, /forge), and runs both plus a landing portal behind one
# Cloudflare Tunnel pointed at codecade.co.za.
#
# Safe to run repeatedly — every step here is idempotent.
#
#   bash install.sh                first run: clone, install, setup, then TUI
#   bash install.sh start all      non-interactive start (used by the TUI itself)
#   bash install.sh status         JSON status snapshot
#   bash install.sh errors         list recorded errors (also in the errors/ folder)
#   bash install.sh bundle <dest>  copy install.sh + all repos to <dest> (e.g. a
#                                   mounted USB drive) so it can be plugged into
#                                   any machine and run without needing network
#                                   access to re-clone from GitHub
#
# Every failure (failed clone/npm-install/service-start) is recorded verbosely
# under errors/ — a running errors/errors.log transcript, plus a full-output
# snapshot file per failure — so nothing is lost even if nobody was watching
# the terminal when it broke.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
cd "$DIR" || exit 1

TEMUTALK_REPO="https://github.com/SumDumIdiut/temutalk.git"
FORGE_REPO="https://github.com/SumDumIdiut/git-forge.git"
TAG_REPO="https://github.com/SumDumIdiut/tag.git"
CF_DOMAIN="codecade.co.za"
PORTAL_PORT="${PORTAL_PORT:-8080}"
TEMUTALK_PORT="${TEMUTALK_PORT:-3001}"
FORGE_PORT="${FORGE_PORT:-3000}"
TAG_RELAY_PORT="${TAG_RELAY_PORT:-3002}"
DEV_PANEL_PORT="${DEV_PANEL_PORT:-9091}"

# ─── Colour helpers (matches temutalk/install.sh) ───────────────────────────
if [ -t 1 ]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
  C_BOLD=''; C_DIM=''; C_RESET=''; C_GREEN=''; C_RED=''; C_YELLOW=''; C_CYAN=''
fi
ok()   { echo "  ${C_GREEN}✓${C_RESET} $1"; }
info() { echo "  ${C_CYAN}..${C_RESET} $1"; }
warn() { echo "  ${C_YELLOW}!${C_RESET} $1"; }
# Every err() call is also appended to errors/errors.log with a timestamp —
# applies automatically to every existing call site, no need to touch them.
# For failures worth capturing full command output (not just the one-line
# message), see run_capturing() below.
err()  {
  echo "  ${C_RED}✗${C_RESET} $1"
  printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$1" >> "$DIR/errors/errors.log" 2>/dev/null
}

# ─── Self-update ──────────────────────────────────────────────────────────
# Runs before anything else on every startup (interactive or CLI dispatch)
# so this is always the latest version, whether it's a real clone of
# codecade-install (git pull) or a standalone file someone curl'd down
# (re-fetch the raw file and replace it if different). Silent/non-fatal if
# offline or the update itself fails — never blocks the rest of the script.
CODECADE_INSTALL_RAW_URL="https://raw.githubusercontent.com/SumDumIdiut/codecade-install/main/install.sh"
self_update() {
  [ -n "${_CODECADE_SELF_UPDATED:-}" ] && return

  if [ -d "$DIR/.git" ] && git -C "$DIR" remote get-url origin 2>/dev/null | grep -q "codecade-install"; then
    local before after
    before=$(git -C "$DIR" rev-parse HEAD 2>/dev/null) || return
    git -C "$DIR" fetch --quiet origin main 2>/dev/null || return
    after=$(git -C "$DIR" rev-parse origin/main 2>/dev/null) || return
    if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
      info "Updating install.sh..."
      if git -C "$DIR" reset --quiet --hard origin/main 2>/dev/null; then
        ok "install.sh updated — restarting."
        _CODECADE_SELF_UPDATED=1 exec bash "$DIR/install.sh" "$@"
      else
        warn "install.sh self-update failed — continuing with the current version."
      fi
    fi
  else
    command -v curl >/dev/null 2>&1 || return
    local tmp; tmp="$(mktemp 2>/dev/null)" || return
    if curl -fsSL --max-time 5 "$CODECADE_INSTALL_RAW_URL" -o "$tmp" 2>/dev/null && [ -s "$tmp" ] && bash -n "$tmp" 2>/dev/null; then
      if ! cmp -s "$tmp" "$DIR/install.sh"; then
        info "Updating install.sh..."
        if cp "$tmp" "$DIR/install.sh" 2>/dev/null; then
          chmod +x "$DIR/install.sh" 2>/dev/null
          rm -f "$tmp"
          ok "install.sh updated — restarting."
          _CODECADE_SELF_UPDATED=1 exec bash "$DIR/install.sh" "$@"
        else
          warn "install.sh self-update failed (couldn't write) — continuing with the current version."
        fi
      fi
    fi
    rm -f "$tmp" 2>/dev/null
  fi
}
self_update "$@"

mkdir -p logs .run errors

# Runs a command with combined stdout+stderr captured. On failure, saves the
# full output to a timestamped file under errors/ (referenced from the
# one-line err() message) instead of just letting it scroll past in the
# terminal — the detail survives even if you weren't watching when it broke.
run_capturing() {
  local label="$1"; shift
  local out; out="$(mktemp 2>/dev/null)" || { "$@"; return $?; }
  if "$@" > "$out" 2>&1; then
    rm -f "$out"
    return 0
  else
    local code=$?
    local dest="errors/$(date -u +%Y%m%d-%H%M%S)-${label}.log"
    mv "$out" "$dest" 2>/dev/null || cp "$out" "$dest" 2>/dev/null
    err "$label failed — full output: $dest"
    return "$code"
  fi
}

# Snapshots the tail of a running service's log into errors/ at the moment a
# start failure is detected, so the failure context survives even after the
# log file keeps growing / gets rotated later.
snapshot_log_on_failure() {
  local label="$1" logfile="$2"
  [ -f "$logfile" ] || return
  local dest="errors/$(date -u +%Y%m%d-%H%M%S)-${label}.log"
  tail -n 80 "$logfile" > "$dest" 2>/dev/null
  err "$label failed — check $logfile (snapshot: $dest)"
}

# ─── Clone / update the two app repos ───────────────────────────────────────
clone_or_update() {
  local dir="$1" url="$2" name="$3"
  if [ -d "$dir/.git" ]; then
    info "Updating $name..."
    git -C "$dir" pull --ff-only || warn "$name: git pull failed — continuing with existing checkout"
  else
    info "Cloning $name..."
    if run_capturing "clone-$name" git clone "$url" "$dir"; then
      ok "$name cloned."
    else
      exit 1
    fi
  fi
}

# ─── Binary/tool lookup ──────────────────────────────────────────────────────
find_node()       { command -v node 2>/dev/null; }
find_npm()        { command -v npm  2>/dev/null; }
# temutalk bundles its own portable Node (no system install required) — prefer
# that one for running temutalk specifically, matching its own install.sh.
find_temutalk_node() {
  [ -x "$DIR/temutalk/bin/linux/node" ] && { echo "$DIR/temutalk/bin/linux/node"; return; }
  find_node
}
find_cloudflared() {
  [ -x "$DIR/temutalk/bin/linux/cloudflared" ] && { echo "$DIR/temutalk/bin/linux/cloudflared"; return; }
  command -v cloudflared 2>/dev/null
}

# ─── PID helpers ──────────────────────────────────────────────────────────────
pid_file()     { echo "$DIR/.run/$1.pid"; }
proc_running() { local f; f=$(pid_file "$1"); [ -f "$f" ] && kill -0 "$(cat "$f" 2>/dev/null)" 2>/dev/null; }
proc_pid()     { local f; f=$(pid_file "$1"); [ -f "$f" ] && cat "$f"; }
stop_proc() {
  local name="$1"
  if proc_running "$name"; then
    kill "$(proc_pid "$name")" 2>/dev/null
    rm -f "$(pid_file "$name")"
    ok "$name stopped."
  else
    warn "$name wasn't running."
  fi
}

# ─── Portal (no repo of its own — install.sh is the source of truth) ────────
# The portal is just a thin reverse proxy + landing page tying the other
# three apps together, so unlike them it isn't its own GitHub repo — it's
# generated here, always overwritten to match this script exactly.
write_portal_files() {
  mkdir -p "$DIR/portal/public"

  cat > "$DIR/portal/package.json" <<'PORTAL_PACKAGE_JSON'
{
  "name": "codecade-portal",
  "version": "1.0.0",
  "description": "Landing portal for codecade.co.za — proxies /temutalk, /forge and /tag to their backends, plus a dev panel for remote install.sh access",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "http-proxy-middleware": "^2.0.6",
    "ws": "^8.14.2",
    "node-pty": "^1.1.0",
    "selfsigned": "^2.4.1"
  }
}
PORTAL_PACKAGE_JSON

  cat > "$DIR/portal/server.js" <<'PORTAL_SERVER_JS'
const express = require('express');
const http = require('http');
const path = require('path');
const { createProxyMiddleware } = require('http-proxy-middleware');

const PORT = parseInt(process.env.PORT || '8080', 10);
const TEMUTALK_TARGET = process.env.TEMUTALK_TARGET || 'https://127.0.0.1:3001';
const FORGE_TARGET = process.env.FORGE_TARGET || 'http://127.0.0.1:3000';
const TAG_RELAY_TARGET = process.env.TAG_RELAY_TARGET || 'http://127.0.0.1:3002';

const app = express();

// http-proxy-middleware preserves the mount prefix (/temutalk, /forge, /tag)
// in the proxied request by default — each backend is BASE_PATH-aware and
// expects it.
const temutalkProxy = createProxyMiddleware({
  target: TEMUTALK_TARGET,
  changeOrigin: true,
  secure: false, // temutalk's TLS cert is self-signed
  ws: true,
  logLevel: 'warn',
});
const forgeProxy = createProxyMiddleware({
  target: FORGE_TARGET,
  changeOrigin: true,
  logLevel: 'warn',
});
const tagRelayProxy = createProxyMiddleware({
  target: TAG_RELAY_TARGET,
  changeOrigin: true,
  ws: true, // /tag/relay/host, /relay/data/:token, /relay/join/:id are all WS upgrades
  logLevel: 'warn',
});

app.use('/temutalk', temutalkProxy);
app.use('/forge', forgeProxy);
app.use('/tag', tagRelayProxy);
app.use(express.static(path.join(__dirname, 'public')));

const server = http.createServer(app);

// Express only handles regular HTTP requests — WebSocket upgrades on the raw
// server have to be routed to the matching proxy instance by hand.
server.on('upgrade', (req, socket, head) => {
  if (req.url.startsWith('/temutalk')) return temutalkProxy.upgrade(req, socket, head);
  if (req.url.startsWith('/tag')) return tagRelayProxy.upgrade(req, socket, head);
  socket.destroy();
});

server.listen(PORT, () => {
  console.log(`\n  Portal running at http://localhost:${PORT}`);
  console.log(`    /temutalk -> ${TEMUTALK_TARGET}`);
  console.log(`    /forge    -> ${FORGE_TARGET}`);
  console.log(`    /tag      -> ${TAG_RELAY_TARGET}\n`);
});
PORTAL_SERVER_JS

  cat > "$DIR/portal/public/index.html" <<'PORTAL_INDEX_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>codecade.co.za</title>
<link rel="icon" href="data:,">
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    min-height: 100vh;
    display: flex; align-items: center; justify-content: center;
    font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
    background: #0b0d14; color: #e4e7f0;
    padding: 24px;
  }
  .wrap { width: 100%; max-width: 420px; }
  h1 { font-size: 22px; font-weight: 800; margin-bottom: 6px; letter-spacing: -0.01em; }
  .sub { color: #7b82a8; font-size: 13px; margin-bottom: 28px; }
  .card {
    display: flex; align-items: center; gap: 14px;
    padding: 16px 18px; margin-bottom: 12px;
    border-radius: 14px; border: 1.5px solid rgba(255,255,255,.09);
    background: rgba(255,255,255,.04);
    text-decoration: none; color: inherit;
    transition: background .15s, border-color .15s, transform .15s;
  }
  .card:hover { background: rgba(255,255,255,.08); border-color: rgba(255,255,255,.16); transform: translateY(-1px); }
  .icon {
    width: 40px; height: 40px; border-radius: 10px; flex-shrink: 0;
    display: flex; align-items: center; justify-content: center;
    font-size: 19px;
  }
  .icon.tt { background: rgba(124,108,248,.18); }
  .icon.fg { background: rgba(249,115,22,.18); }
  .icon.tag { background: rgba(62,245,168,.18); }
  .card-title { font-weight: 700; font-size: 14.5px; }
  .card-desc { color: #7b82a8; font-size: 12.5px; margin-top: 2px; }
  footer { margin-top: 24px; color: #4e5578; font-size: 11.5px; text-align: center; }
</style>
</head>
<body>
  <div class="wrap">
    <h1>codecade.co.za</h1>
    <p class="sub">Pick a service.</p>
    <a class="card" href="/temutalk/">
      <div class="icon tt">🎧</div>
      <div>
        <div class="card-title">TemuTalk</div>
        <div class="card-desc">Music, cast, chat, weather &amp; more</div>
      </div>
    </a>
    <a class="card" href="/forge/">
      <div class="icon fg">🔥</div>
      <div>
        <div class="card-title">Forge</div>
        <div class="card-desc">Self-hosted Git repositories</div>
      </div>
    </a>
    <a class="card" href="/tag/">
      <div class="icon tag">🏃</div>
      <div>
        <div class="card-title">Tag</div>
        <div class="card-desc">Browse live multiplayer servers</div>
      </div>
    </a>
    <footer>codecade.co.za</footer>
  </div>
</body>
</html>
PORTAL_INDEX_HTML

  cat > "$DIR/portal/dev-panel.js" <<'PORTAL_DEV_PANEL_JS'
'use strict';
const https  = require('https');
const http   = require('http');
const crypto = require('crypto');
const fs     = require('fs');
const path   = require('path');
const { WebSocketServer } = require('ws');

const PORT       = parseInt(process.env.DEV_PANEL_PORT || '9091', 10);
const INSTALL_SH = process.env.MASTER_INSTALL_SH || path.join(__dirname, '..', 'install.sh');
// Reuses temutalk's own panel key hash file -- same physical USB key file
// unlocks both panels, no separate key to generate/manage for this one.
const KEY_HASH_FILE = process.env.TEMUTALK_KEY_HASH_FILE || path.join(__dirname, '..', 'temutalk', '.run', 'panel-key-hash');
const RUN_DIR = path.join(__dirname, '.run');

let pty = null;
try { pty = require('node-pty'); } catch {}

// ─── Auth (identical scheme to temutalk/control-panel.js, same key file) ────
const SESSION_TTL_MS    = 4 * 60 * 60 * 1000;
const MAX_ATTEMPTS      = 5;
const ATTEMPT_WINDOW_MS = 5 * 60 * 1000;
const LOCKOUT_MS        = 10 * 60 * 1000;
const SESSION_SECRET    = crypto.randomBytes(32);

fs.mkdirSync(RUN_DIR, { recursive: true });

function timingSafeEqualStr(a, b) {
  const A = Buffer.from(a), B = Buffer.from(b);
  if (A.length !== B.length) { crypto.timingSafeEqual(A, A); return false; }
  return crypto.timingSafeEqual(A, B);
}
function verifyKeyContent(content) {
  if (!content || content.trim().length < 100) return false;
  const hash = crypto.createHash('sha256').update(content.trim()).digest('hex');
  try { return timingSafeEqualStr(hash, fs.readFileSync(KEY_HASH_FILE, 'utf8').trim()); } catch { return false; }
}
function signSession(payload) {
  return `${payload}.${crypto.createHmac('sha256', SESSION_SECRET).update(payload).digest('base64url')}`;
}
function verifySession(val) {
  if (!val) return false;
  const idx = val.lastIndexOf('.');
  if (idx < 0) return false;
  const payload = val.slice(0, idx), sig = val.slice(idx + 1);
  const expected = crypto.createHmac('sha256', SESSION_SECRET).update(payload).digest('base64url');
  if (!timingSafeEqualStr(sig, expected)) return false;
  const exp = parseInt(payload.split(':')[1], 10);
  return Number.isFinite(exp) && Date.now() < exp;
}
function parseCookies(req) {
  const out = {};
  for (const part of (req.headers.cookie || '').split(';')) {
    const eq = part.indexOf('=');
    if (eq >= 0) out[part.slice(0, eq).trim()] = part.slice(eq + 1).trim();
  }
  return out;
}
function isAuthed(req) { return verifySession(parseCookies(req).panel_session); }
function refreshSession(req, res) {
  if (!isAuthed(req)) return;
  const payload = `s:${Date.now() + SESSION_TTL_MS}`;
  res.setHeader('Set-Cookie', `panel_session=${signSession(payload)}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${Math.floor(SESSION_TTL_MS / 1000)}`);
}

const attempts = new Map();
function checkRateLimit(ip) {
  const now = Date.now(), rec = attempts.get(ip);
  if (!rec) return { allowed: true };
  if (rec.lockedUntil && now < rec.lockedUntil) return { allowed: false, retryAfterMs: rec.lockedUntil - now };
  if (now - rec.windowStart > ATTEMPT_WINDOW_MS) { attempts.delete(ip); return { allowed: true }; }
  return { allowed: true };
}
function recordFailure(ip) {
  const now = Date.now();
  let rec = attempts.get(ip);
  if (!rec || now - rec.windowStart > ATTEMPT_WINDOW_MS) rec = { count: 0, windowStart: now, lockedUntil: 0 };
  if (++rec.count >= MAX_ATTEMPTS) rec.lockedUntil = now + LOCKOUT_MS;
  attempts.set(ip, rec);
}
function recordSuccess(ip) { attempts.delete(ip); }

// ─── TLS ──────────────────────────────────────────────────────────────────────
function loadOrCreateCert() {
  const k = path.join(__dirname, '.devpanel-cert-key.pem'), c = path.join(__dirname, '.devpanel-cert-cert.pem');
  if (fs.existsSync(k) && fs.existsSync(c)) return { key: fs.readFileSync(k), cert: fs.readFileSync(c) };
  const { generate } = require('selfsigned');
  const pems = generate([{ name: 'commonName', value: 'codecade-dev-panel' }], { days: 3650, algorithm: 'sha256', keySize: 2048 });
  fs.writeFileSync(k, pems.private, { mode: 0o600 });
  fs.writeFileSync(c, pems.cert);
  return { key: pems.private, cert: pems.cert };
}

// ─── Shared helpers ───────────────────────────────────────────────────────────
function sendJson(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) });
  res.end(data);
}
function securityHeaders(res) {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('Content-Security-Policy',
    "default-src 'self'; style-src 'unsafe-inline' https://cdn.jsdelivr.net; " +
    "script-src 'unsafe-inline' https://cdn.jsdelivr.net; connect-src 'self' wss: ws:; font-src https://cdn.jsdelivr.net"
  );
  res.setHeader('Strict-Transport-Security', 'max-age=31536000');
}

// ─── Login page ───────────────────────────────────────────────────────────────
function loginPage() {
  return `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>codecade Dev Panel</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:system-ui,sans-serif;background:#0d1117;color:#e6edf3;display:flex;align-items:center;justify-content:center;height:100dvh}
.box{background:#161b22;border:1px solid #30363d;border-radius:16px;padding:32px;width:360px}
h1{font-size:17px;font-weight:700;margin-bottom:4px}
.sub{color:#8b949e;font-size:13px;margin-bottom:24px}
.drop{border:2px dashed #30363d;border-radius:12px;padding:32px 16px;text-align:center;cursor:pointer;transition:.15s}
.drop:hover,.drop.over{border-color:#58a6ff;background:rgba(88,166,255,.05)}
.drop.ready{border-color:#3fb950;border-style:solid;background:rgba(63,185,80,.05)}
.drop-icon{font-size:2.2rem;margin-bottom:10px}
.drop-label{font-size:13px;color:#8b949e}
.drop-name{font-size:12px;color:#3fb950;margin-top:8px;font-family:ui-monospace,monospace}
input[type=file]{display:none}
.err{color:#f85149;font-size:13px;min-height:20px;margin:12px 0 4px;text-align:center}
button{width:100%;padding:11px;border:none;border-radius:10px;background:#238636;color:#fff;font:inherit;font-weight:600;font-size:14px;cursor:pointer;margin-top:4px;transition:background .15s}
button:hover:not(:disabled){background:#2ea043}
button:disabled{opacity:.4;cursor:default}
.hint{color:#484f58;font-size:12px;margin-top:14px;text-align:center}
</style></head>
<body><div class="box">
<h1>&#9654; codecade Dev Panel</h1>
<div class="sub">Drop your key file to unlock &mdash; same key as the TemuTalk panel</div>
<div class="drop" id="drop" onclick="document.getElementById('fi').click()">
  <div class="drop-icon">&#128190;</div>
  <div class="drop-label">Click to browse or drag &amp; drop</div>
  <div class="drop-label" style="font-size:11px;margin-top:4px;opacity:.6">temutalk.key</div>
  <div class="drop-name" id="fname"></div>
</div>
<input type="file" id="fi" accept=".key,*">
<div class="err" id="err"></div>
<button id="btn" disabled onclick="doLogin()">Unlock</button>
<div class="hint">Key file lives on the TemuTalk USB drive</div>
</div>
<script>
let kc='';
const drop=document.getElementById('drop'),btn=document.getElementById('btn'),err=document.getElementById('err');
function readFile(f){const r=new FileReader();r.onload=e=>{kc=e.target.result;document.getElementById('fname').textContent=f.name;drop.classList.add('ready');btn.disabled=false;err.textContent='';};r.readAsText(f);}
document.getElementById('fi').onchange=e=>{if(e.target.files[0])readFile(e.target.files[0]);};
drop.ondragover=e=>{e.preventDefault();drop.classList.add('over');};
drop.ondragleave=()=>drop.classList.remove('over');
drop.ondrop=e=>{e.preventDefault();drop.classList.remove('over');if(e.dataTransfer.files[0])readFile(e.dataTransfer.files[0]);};
async function doLogin(){err.textContent='';btn.disabled=true;
  try{const r=await fetch('/api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({keyContent:kc})});
  if(r.ok){location.reload();return;}const j=await r.json().catch(()=>({}));err.textContent=j.error||'Login failed';}
  catch(e2){err.textContent='Request failed: '+e2.message;}btn.disabled=false;}
</script></body></html>`;
}

// ─── Main panel page (terminal-only -- remote input into the master TUI) ────
function page() {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>codecade Dev Panel</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.css">
<style>
*{box-sizing:border-box;margin:0;padding:0}
:root{--bg:#0d1117;--sur:#161b22;--bor:#30363d;--tx:#e6edf3;--sec:#8b949e;--acc:#58a6ff;--grn:#3fb950;--red:#f85149;color-scheme:dark}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:var(--bg);color:var(--tx);height:100dvh;display:flex;flex-direction:column;overflow:hidden;font-size:13px}
.hdr{display:flex;align-items:center;gap:10px;padding:0 14px;height:48px;background:var(--sur);border-bottom:1px solid var(--bor);flex-shrink:0}
.hdr-logo{font-weight:700;font-size:14px;white-space:nowrap;flex:1}
.hdr-btn{background:none;border:1px solid var(--bor);color:var(--sec);border-radius:7px;padding:5px 12px;cursor:pointer;font:inherit;font-size:12px;transition:.12s}
.hdr-btn:hover{color:var(--red);border-color:var(--red)}
.term-wrap{flex:1;display:flex;flex-direction:column;background:#000;overflow:hidden}
.term-bar{display:flex;align-items:center;gap:8px;padding:7px 12px;background:var(--sur);border-bottom:1px solid var(--bor);flex-shrink:0}
.tdot{width:8px;height:8px;border-radius:50%;background:var(--bor);transition:.2s;flex-shrink:0}
.tdot.on{background:var(--grn)}
.tstat{font-size:12px;color:var(--sec)}
#terminal-wrap{flex:1;overflow:hidden}
</style>
</head>
<body>
<header class="hdr">
  <div class="hdr-logo">&#9654; codecade Dev Panel &mdash; install.sh</div>
  <button class="hdr-btn" onclick="logout()">Sign out</button>
</header>
<div class="term-wrap">
  <div class="term-bar">
    <div class="tdot" id="term-dot"></div>
    <div class="tstat" id="term-status">Connecting&hellip;</div>
  </div>
  <div id="terminal-wrap"><div id="terminal"></div></div>
</div>
<script src="https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/xterm-addon-fit@0.8.0/lib/xterm-addon-fit.min.js"></script>
<script>
async function logout(){await fetch('/api/logout',{method:'POST'});location.reload();}

var term=null,fit=null,termWs=null;
function termConnect(){
  if(!term){document.getElementById('term-status').textContent='xterm not loaded';return;}
  if(termWs&&termWs.readyState<2)termWs.close();
  var proto=location.protocol==='https:'?'wss:':'ws:';
  termWs=new WebSocket(proto+'//'+location.host+'/terminal');
  termWs.onopen=function(){
    document.getElementById('term-dot').classList.add('on');
    document.getElementById('term-status').textContent='Connected — running install.sh';
    if(fit)fit.fit();
    termWs.send(JSON.stringify({type:'resize',cols:term.cols,rows:term.rows}));
  };
  termWs.onmessage=function(e){try{var msg=JSON.parse(e.data);if(msg.type==='data')term.write(msg.data);}catch(err){term.write(e.data);}};
  termWs.onclose=function(){
    document.getElementById('term-dot').classList.remove('on');
    document.getElementById('term-status').textContent='Disconnected — reconnecting…';
    setTimeout(termConnect,3000);
  };
  termWs.onerror=function(){termWs.close();};
  term.onData(function(d){if(termWs&&termWs.readyState===1)termWs.send(JSON.stringify({type:'data',data:d}));});
  term.onResize(function(s){if(termWs&&termWs.readyState===1)termWs.send(JSON.stringify({type:'resize',cols:s.cols,rows:s.rows}));});
}
function initTerm(){
  try{
    term=new Terminal({cursorBlink:true,scrollback:10000,theme:{background:'#0d1117',foreground:'#e6edf3',cursor:'#58a6ff',selectionBackground:'#264f78'},fontFamily:'ui-monospace,Menlo,monospace',fontSize:13,lineHeight:1.2});
    fit=new FitAddon.FitAddon();
    term.loadAddon(fit);term.open(document.getElementById('terminal'));fit.fit();
    var tw=document.getElementById('terminal-wrap');
    if(tw)new ResizeObserver(function(){if(fit)fit.fit();}).observe(tw);
    termConnect();
  }catch(e){console.error('xterm:',e);document.getElementById('term-status').textContent='xterm failed to load';}
}
initTerm();
</script>
</body>
</html>`;
}

// ─── Terminal WebSocket ────────────────────────────────────────────────────────
const wss = new WebSocketServer({ noServer: true });

function handleTerminalWs(ws) {
  if (!pty) {
    ws.send(JSON.stringify({ type: 'data', data: '\r\n\x1b[31mnode-pty not installed — run: npm install node-pty\x1b[0m\r\n' }));
    ws.close();
    return;
  }
  let proc;
  try {
    proc = pty.spawn('bash', [INSTALL_SH], {
      name: 'xterm-256color', cols: 80, rows: 24,
      cwd: path.dirname(INSTALL_SH),
      env: { ...process.env, TERM: 'xterm-256color' },
    });
  } catch (e) {
    ws.send(JSON.stringify({ type: 'data', data: `\r\n\x1b[31mFailed to start install.sh: ${e.message}\x1b[0m\r\n` }));
    ws.close();
    return;
  }
  proc.onData(data => ws.readyState === 1 && ws.send(JSON.stringify({ type: 'data', data })));
  proc.onExit(() => ws.readyState < 2 && ws.close());
  ws.on('message', raw => {
    try { const m = JSON.parse(raw); if (m.type === 'data') proc.write(m.data); else if (m.type === 'resize') proc.resize(Math.max(1, m.cols), Math.max(1, m.rows)); } catch {}
  });
  ws.on('close', () => { try { proc.kill(); } catch {} });
}

function handleUpgrade(req, socket, head) {
  if (new URL(req.url, 'http://x').pathname === '/terminal' && isAuthed(req)) {
    wss.handleUpgrade(req, socket, head, ws => handleTerminalWs(ws));
  } else {
    socket.destroy();
  }
}

// ─── Request handler ──────────────────────────────────────────────────────────
function handleRequest(req, res) {
  securityHeaders(res);
  const url = new URL(req.url, 'https://localhost');
  const ip  = req.socket.remoteAddress || 'unknown';

  if (req.method === 'POST' && url.pathname === '/api/login') {
    const limit = checkRateLimit(ip);
    if (!limit.allowed) {
      sendJson(res, 429, { error: `Too many attempts — try again in ${Math.ceil(limit.retryAfterMs / 1000)}s` });
      return;
    }
    let body = '';
    req.on('data', c => { body += c; if (body.length > 8192) req.destroy(); });
    req.on('end', () => {
      let keyContent = '';
      try { keyContent = JSON.parse(body).keyContent || ''; } catch {}
      if (verifyKeyContent(keyContent)) {
        recordSuccess(ip);
        const payload = `s:${Date.now() + SESSION_TTL_MS}`;
        res.setHeader('Set-Cookie', `panel_session=${signSession(payload)}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${Math.floor(SESSION_TTL_MS / 1000)}`);
        sendJson(res, 200, { ok: true });
      } else {
        recordFailure(ip);
        sendJson(res, 401, { error: 'Invalid key file' });
      }
    });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/logout') {
    res.setHeader('Set-Cookie', `panel_session=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0`);
    sendJson(res, 200, { ok: true });
    return;
  }

  if (url.pathname === '/') {
    if (isAuthed(req)) {
      refreshSession(req, res);
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(page());
    } else {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(loginPage());
    }
    return;
  }

  res.writeHead(404, { 'Content-Type': 'text/plain' }); res.end('not found');
}

// ─── Server ───────────────────────────────────────────────────────────────────
const tls = loadOrCreateCert();
const server = https.createServer(tls, handleRequest);
server.on('upgrade', handleUpgrade);
server.on('error', err => {
  if (err.code === 'EADDRINUSE') console.error(`Port ${PORT} already in use`);
  else console.error('Server error:', err);
  process.exit(1);
});
server.listen(PORT, '0.0.0.0', () => console.log(`Dev panel on https://0.0.0.0:${PORT} (terminal -> ${INSTALL_SH})`));
PORTAL_DEV_PANEL_JS

  ok "Portal files written."
}

# ─── First-run / update setup ────────────────────────────────────────────────
do_setup() {
  clone_or_update temutalk "$TEMUTALK_REPO" temutalk
  clone_or_update git-forge "$FORGE_REPO" git-forge
  clone_or_update tag "$TAG_REPO" tag

  # Unlike the three apps above, the portal has no repo of its own — it's
  # thin enough (one proxy + one landing page) that install.sh just writes
  # it out directly, so it's fully reproducible from this script alone.
  write_portal_files

  local npm_bin; npm_bin=$(find_npm)
  if [ -z "$npm_bin" ]; then
    err "npm not found on PATH — install Node.js/npm to set up the portal and git-forge."
    exit 1
  fi

  info "Installing portal dependencies..."
  run_capturing "portal-npm-install" bash -c "cd '$DIR/portal' && '$npm_bin' install --no-audit --no-fund --loglevel=error" \
    && ok "Portal dependencies installed."

  info "Installing git-forge dependencies..."
  run_capturing "git-forge-npm-install" bash -c "cd '$DIR/git-forge' && '$npm_bin' install --no-audit --no-fund --loglevel=error" \
    && ok "git-forge dependencies installed."

  if [ -d "$DIR/tag/relay-server" ]; then
    info "Installing tag relay-server dependencies..."
    run_capturing "tag-relay-npm-install" bash -c "cd '$DIR/tag/relay-server' && '$npm_bin' install --no-audit --no-fund --loglevel=error" \
      && ok "tag relay-server dependencies installed."
  else
    warn "tag/relay-server not found in the tag repo checkout — skipping."
  fi

  info "Running temutalk's own first-run setup (system deps, portable Node, Piper, audio, USB key)..."
  # < /dev/null: belt-and-suspenders against temutalk/install.sh ever blocking
  # on an interactive read — it shouldn't in "setup" mode, but a subprocess
  # otherwise inherits our real TTY, and a stuck read here would silently
  # hang this whole script with no obvious cause.
  bash "$DIR/temutalk/install.sh" setup < /dev/null

  echo ""
  ok "Setup complete."
}

# ─── Bundle: copy install.sh + all repos to portable media ─────────────────
# So the whole stack (source, .git history, already-installed node_modules)
# can be plugged into any machine and run without needing network access to
# re-clone from GitHub — clone_or_update() above already treats an existing
# .git checkout as "already cloned" and only needs network for a `git pull`,
# which fails non-fatally offline and just runs with what's there.
do_bundle() {
  local dest="${1:-}"
  if [ -z "$dest" ]; then err "Usage: install.sh bundle <destination-dir>"; exit 1; fi
  if [ ! -d "$dest" ]; then err "Destination '$dest' does not exist or is not a directory."; exit 1; fi
  dest="$(cd "$dest" && pwd)"
  if [ "$dest" = "$DIR" ]; then err "Destination is the same directory install.sh is already running from."; exit 1; fi

  for name in temutalk git-forge tag; do
    if [ ! -d "$DIR/$name/.git" ]; then
      warn "$name isn't cloned locally yet — running setup first."
      do_setup
      break
    fi
  done

  local use_rsync=0
  command -v rsync >/dev/null 2>&1 && use_rsync=1

  info "Copying install.sh -> $dest/install.sh"
  cp "$DIR/install.sh" "$dest/install.sh"

  for name in temutalk git-forge tag; do
    info "Copying $name -> $dest/$name (this can take a while)..."
    if [ "$use_rsync" -eq 1 ]; then
      mkdir -p "$dest/$name"
      rsync -a --delete "$DIR/$name/" "$dest/$name/" \
        && ok "$name copied." || err "$name copy failed."
    else
      rm -rf "$dest/$name"
      cp -a "$DIR/$name" "$dest/$name" \
        && ok "$name copied." || err "$name copy failed."
    fi
  done

  echo ""
  ok "Bundle complete -> $dest"
  echo "  Plug this drive into any machine and run:  bash $dest/install.sh"
}

# ─── Start / stop — individual services ─────────────────────────────────────
start_forge() {
  if proc_running forge; then warn "git-forge already running."; return; fi
  local node_bin; node_bin=$(find_node)
  if [ -z "$node_bin" ]; then err "node not found on PATH."; return; fi
  ( cd "$DIR/git-forge" && BASE_PATH=/forge PORT="$FORGE_PORT" \
    nohup "$node_bin" server.js > "$DIR/logs/forge.log" 2>&1 & echo $! > "$(pid_file forge)" )
  sleep 1
  if proc_running forge; then ok "git-forge started (PID $(proc_pid forge)) → :$FORGE_PORT"
  else snapshot_log_on_failure "forge-start" "$DIR/logs/forge.log"; fi
}

start_tag_relay() {
  if proc_running tag-relay; then warn "tag relay-server already running."; return; fi
  if [ ! -d "$DIR/tag/relay-server/node_modules" ]; then warn "tag/relay-server/node_modules missing — run setup first."; return; fi
  local node_bin; node_bin=$(find_node)
  if [ -z "$node_bin" ]; then err "node not found on PATH."; return; fi
  ( cd "$DIR/tag/relay-server" && BASE_PATH=/tag PORT="$TAG_RELAY_PORT" \
    nohup "$node_bin" server.js > "$DIR/logs/tag-relay.log" 2>&1 & echo $! > "$(pid_file tag-relay)" )
  sleep 1
  if proc_running tag-relay; then ok "tag relay-server started (PID $(proc_pid tag-relay)) → :$TAG_RELAY_PORT"
  else snapshot_log_on_failure "tag-relay-start" "$DIR/logs/tag-relay.log"; fi
}

# Remote terminal into this very install.sh, gated behind the same physical
# USB key file that unlocks temutalk's own control panel (reads temutalk's
# panel-key-hash directly rather than managing a separate key).
start_dev_panel() {
  if proc_running dev-panel; then warn "Dev panel already running."; return; fi
  if [ ! -d "$DIR/portal/node_modules" ]; then warn "portal/node_modules missing — run setup first."; return; fi
  if [ ! -f "$DIR/temutalk/.run/panel-key-hash" ]; then
    warn "temutalk has no panel key enrolled yet — enroll the USB key via temutalk's install.sh first."
  fi
  local node_bin; node_bin=$(find_node)
  if [ -z "$node_bin" ]; then err "node not found on PATH."; return; fi
  ( cd "$DIR/portal" && DEV_PANEL_PORT="$DEV_PANEL_PORT" MASTER_INSTALL_SH="$DIR/install.sh" \
    TEMUTALK_KEY_HASH_FILE="$DIR/temutalk/.run/panel-key-hash" \
    nohup "$node_bin" dev-panel.js > "$DIR/logs/dev-panel.log" 2>&1 & echo $! > "$(pid_file dev-panel)" )
  sleep 1
  if proc_running dev-panel; then ok "Dev panel started (PID $(proc_pid dev-panel)) → :$DEV_PANEL_PORT"
  else snapshot_log_on_failure "dev-panel-start" "$DIR/logs/dev-panel.log"; fi
}

start_temutalk() {
  if proc_running temutalk; then warn "temutalk already running."; return; fi
  if [ ! -d "$DIR/temutalk/node_modules" ]; then warn "temutalk/node_modules missing — run setup first."; return; fi
  local node_bin; node_bin=$(find_temutalk_node)
  if [ -z "$node_bin" ]; then err "No Node.js binary available for temutalk."; return; fi
  ( cd "$DIR/temutalk" && BASE_PATH=/temutalk EXTERNAL_TUNNEL=1 PORT="$TEMUTALK_PORT" BASE_URL="https://${CF_DOMAIN}" \
    nohup "$node_bin" launcher.js > "$DIR/logs/temutalk.log" 2>&1 & echo $! > "$(pid_file temutalk)" )
  sleep 2
  if proc_running temutalk; then ok "temutalk started (PID $(proc_pid temutalk)) → :$TEMUTALK_PORT"
  else snapshot_log_on_failure "temutalk-start" "$DIR/logs/temutalk.log"; fi
}

start_portal() {
  if proc_running portal; then warn "Portal already running."; return; fi
  local node_bin; node_bin=$(find_node)
  if [ -z "$node_bin" ]; then err "node not found on PATH."; return; fi
  ( cd "$DIR/portal" && PORT="$PORTAL_PORT" \
    TEMUTALK_TARGET="https://127.0.0.1:$TEMUTALK_PORT" FORGE_TARGET="http://127.0.0.1:$FORGE_PORT" \
    TAG_RELAY_TARGET="http://127.0.0.1:$TAG_RELAY_PORT" \
    nohup "$node_bin" server.js > "$DIR/logs/portal.log" 2>&1 & echo $! > "$(pid_file portal)" )
  sleep 1
  if proc_running portal; then ok "Portal started (PID $(proc_pid portal)) → :$PORTAL_PORT"
  else snapshot_log_on_failure "portal-start" "$DIR/logs/portal.log"; fi
}

# Reuses temutalk's existing tunnel credentials in temutalk/.cloudflared/, but
# repoints the single ingress hostname at the portal instead of temutalk
# directly, since the portal is now the one thing the tunnel talks to.
_TUNNEL_TOKEN_FILE=""; _TUNNEL_CONFIG_FILE=""
write_tunnel_config() {
  local cf_dir="$DIR/temutalk/.cloudflared"
  [ -d "$cf_dir" ] || return 1
  local f
  for f in "$cf_dir/token.txt" "$HOME/.cloudflared/token.txt"; do
    if [ -f "$f" ]; then _TUNNEL_TOKEN_FILE="$f"; return 0; fi
  done
  local json; json=$(find "$cf_dir" -maxdepth 1 -regex '.*/[0-9a-fA-F-]\{36\}\.json' 2>/dev/null | head -1)
  [ -z "$json" ] && return 1
  local tunnel_id; tunnel_id=$(basename "$json" .json)
  _TUNNEL_CONFIG_FILE="$cf_dir/config.yml"
  cat > "$_TUNNEL_CONFIG_FILE" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${json}
ingress:
  - hostname: ${CF_DOMAIN}
    service: http://localhost:${PORTAL_PORT}
  - service: http_status:404
EOF
  return 0
}

start_tunnel() {
  if proc_running tunnel; then warn "Tunnel already running."; return; fi
  local cf_bin; cf_bin=$(find_cloudflared)
  if [ -z "$cf_bin" ]; then warn "cloudflared not found — running local only."; return; fi
  _TUNNEL_TOKEN_FILE=""; _TUNNEL_CONFIG_FILE=""
  if ! write_tunnel_config; then
    warn "No tunnel credentials in temutalk/.cloudflared — running local only."
    return
  fi
  local args=()
  if [ -n "$_TUNNEL_TOKEN_FILE" ]; then
    local ingress_cfg; ingress_cfg="$(mktemp)"
    cat > "$ingress_cfg" <<EOF
ingress:
  - hostname: ${CF_DOMAIN}
    service: http://localhost:${PORTAL_PORT}
  - service: http_status:404
EOF
    local token; token=$(tr -d '\r\n' < "$_TUNNEL_TOKEN_FILE")
    args=(tunnel --config "$ingress_cfg" run --token "$token")
  else
    local cert_file="$DIR/temutalk/.cloudflared/cert.pem"
    [ -f "$cert_file" ] && args+=(--origincert "$cert_file")
    args+=(--config "$_TUNNEL_CONFIG_FILE" tunnel run)
  fi
  nohup "$cf_bin" "${args[@]}" > "$DIR/logs/tunnel.log" 2>&1 &
  echo $! > "$(pid_file tunnel)"
  sleep 2
  if proc_running tunnel; then ok "Tunnel started (PID $(proc_pid tunnel)) → https://${CF_DOMAIN}"
  else snapshot_log_on_failure "tunnel-start" "$DIR/logs/tunnel.log"; fi
}

do_start() { start_forge; start_tag_relay; start_temutalk; start_portal; start_dev_panel; start_tunnel; }
do_stop()  { stop_proc tunnel; stop_proc dev-panel; stop_proc portal; stop_proc temutalk; stop_proc tag-relay; stop_proc forge; }

status_json() {
  local forge_run=false temutalk_run=false portal_run=false tunnel_run=false tag_relay_run=false dev_panel_run=false
  proc_running forge     && forge_run=true
  proc_running temutalk  && temutalk_run=true
  proc_running portal    && portal_run=true
  proc_running tunnel    && tunnel_run=true
  proc_running tag-relay && tag_relay_run=true
  proc_running dev-panel && dev_panel_run=true
  printf '{"forge":%s,"temutalk":%s,"portal":%s,"tunnel":%s,"tagRelay":%s,"devPanel":%s,"url":"https://%s"}\n' \
    "$forge_run" "$temutalk_run" "$portal_run" "$tunnel_run" "$tag_relay_run" "$dev_panel_run" "$CF_DOMAIN"
}

do_open_browser() {
  local url="https://${CF_DOMAIN}"
  echo "  URL: ${C_CYAN}${url}${C_RESET}"
  if ! proc_running portal; then warn "Portal isn't running — start it first."; return; fi
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 &
  elif command -v open     >/dev/null 2>&1; then open "$url" >/dev/null 2>&1 &
  else warn "No browser opener found — open the URL above manually."
  fi
}

do_check_updates() {
  info "Checking temutalk, git-forge and tag for updates..."
  clone_or_update temutalk "$TEMUTALK_REPO" temutalk
  clone_or_update git-forge "$FORGE_REPO" git-forge
  clone_or_update tag "$TAG_REPO" tag
  local npm_bin; npm_bin=$(find_npm)
  if [ -n "$npm_bin" ]; then
    run_capturing "git-forge-npm-install" bash -c "cd '$DIR/git-forge' && '$npm_bin' install --no-audit --no-fund --loglevel=error"
    [ -d "$DIR/tag/relay-server" ] && run_capturing "tag-relay-npm-install" bash -c "cd '$DIR/tag/relay-server' && '$npm_bin' install --no-audit --no-fund --loglevel=error"
  fi
  read -rp "  Restart running services to apply? [Y/n] " yn
  if [[ ! "$yn" =~ ^[Nn]$ ]]; then
    proc_running forge     && { stop_proc forge;     start_forge; }
    proc_running tag-relay && { stop_proc tag-relay; start_tag_relay; }
    proc_running temutalk  && { stop_proc temutalk;  start_temutalk; }
    ok "Restarted."
  fi
  _updates_available=0
  _last_update_check=$(date +%s)
}

do_view_logs() {
  echo "  ${C_DIM}Ctrl+C to return to the menu.${C_RESET}"
  sleep 1
  touch logs/forge.log logs/temutalk.log logs/portal.log logs/tunnel.log logs/tag-relay.log logs/dev-panel.log errors/errors.log
  tail -n 30 -f logs/forge.log logs/temutalk.log logs/portal.log logs/tunnel.log logs/tag-relay.log logs/dev-panel.log errors/errors.log
}

do_view_errors() {
  local n; n=$(find errors -maxdepth 1 -type f 2>/dev/null | wc -l)
  if [ "$n" -eq 0 ]; then
    warn "No errors recorded yet."
    return
  fi
  echo "  ${C_BOLD}errors/${C_RESET} ($n file(s))"
  ls -1t errors | sed 's/^/    /'
  echo ""
  if [ -f errors/errors.log ]; then
    echo "  ${C_DIM}Last 20 entries in errors.log:${C_RESET}"
    tail -n 20 errors/errors.log | sed 's/^/    /'
  fi
}

# ─── Non-interactive CLI dispatch ────────────────────────────────────────────
if [ "${1:-}" = "setup" ]; then do_setup; exit 0; fi
if [ "${1:-}" = "bundle" ]; then do_bundle "${2:-}"; exit 0; fi
if [ "${1:-}" = "start" ] || [ "${1:-}" = "stop" ]; then
  case "${2:-}" in
    forge|temutalk|portal|tunnel|tag-relay|dev-panel|all) ;;
    *) err "Usage: install.sh {start|stop} {forge|temutalk|portal|tunnel|tag-relay|dev-panel|all}"; exit 1 ;;
  esac
  case "$1-$2" in
    start-forge)     start_forge ;;
    start-temutalk)  start_temutalk ;;
    start-portal)    start_portal ;;
    start-tunnel)    start_tunnel ;;
    start-tag-relay) start_tag_relay ;;
    start-dev-panel) start_dev_panel ;;
    start-all)       do_start ;;
    stop-forge)      stop_proc forge ;;
    stop-temutalk)   stop_proc temutalk ;;
    stop-portal)     stop_proc portal ;;
    stop-tunnel)     stop_proc tunnel ;;
    stop-tag-relay)  stop_proc tag-relay ;;
    stop-dev-panel)  stop_proc dev-panel ;;
    stop-all)        do_stop ;;
  esac
  exit 0
fi
if [ "${1:-}" = "status" ]; then status_json; exit 0; fi
if [ "${1:-}" = "errors" ]; then do_view_errors; exit 0; fi

# ─── First-run setup, then TUI ───────────────────────────────────────────────
echo ""
echo "  ${C_BOLD}codecade.co.za — Portal Installer${C_RESET}"
echo ""
do_setup

echo ""
warn "One-time manual step: temutalk now lives at /temutalk, so its Spotify"
warn "OAuth redirect URI changed. Update it in the Spotify Developer Dashboard:"
echo "     ${C_CYAN}https://${CF_DOMAIN}/temutalk/callback${C_RESET}"
warn "Spotify login will not work until this is updated."

MENU_LABELS=(
  "Start all"
  "Stop all"
  "Open in browser"
  "Check for updates"
  "View logs"
  "View errors"
  "Toggle Forge"
  "Toggle TemuTalk"
  "Toggle Portal"
  "Toggle Tunnel"
  "Toggle Tag relay"
  "Toggle Dev panel"
  "Bundle to a drive..."
  "Exit"
)
_menu_selected=0

# Reads one keypress, with a timeout so the menu loop periodically wakes up
# on its own (used to drive the quiet background update check below) even
# if nobody presses anything. Arrow keys arrive as a 3-byte escape sequence
# (ESC [ A/B/C/D) — a lone ESC (e.g. someone just tapping Escape) times out
# on the second read instead of hanging, and falls through as an ignored key.
read_key() {
  local key rest
  IFS= read -rsn1 -t 5 key
  if [ $? -gt 128 ]; then
    printf 'TIMEOUT'
    return
  fi
  if [ "$key" = $'\x1b' ]; then
    IFS= read -rsn2 -t 0.05 rest
    key+="$rest"
  fi
  printf '%s' "$key"
}

# ─── Quiet background update check ──────────────────────────────────────────
# Only ever *notifies* — never auto-pulls or auto-restarts anything without
# the user explicitly choosing "Check for updates", so a running server never
# gets yanked out from under it unexpectedly. Gated to every 30 minutes;
# read_key()'s timeout above is what actually gives this a chance to run
# periodically while the TUI sits idle.
UPDATE_CHECK_INTERVAL_SEC=1800
_last_update_check=0
_updates_available=0
check_for_updates_quiet() {
  local now; now=$(date +%s)
  [ $(( now - _last_update_check )) -lt "$UPDATE_CHECK_INTERVAL_SEC" ] && return
  _last_update_check=$now
  _updates_available=0
  local name local_sha remote_sha
  for name in temutalk git-forge tag; do
    [ -d "$DIR/$name/.git" ] || continue
    git -C "$DIR/$name" fetch --quiet origin main 2>/dev/null || continue
    local_sha=$(git -C "$DIR/$name" rev-parse HEAD 2>/dev/null)
    remote_sha=$(git -C "$DIR/$name" rev-parse origin/main 2>/dev/null)
    [ -n "$local_sha" ] && [ -n "$remote_sha" ] && [ "$local_sha" != "$remote_sha" ] && _updates_available=1
  done
}

menu() {
  while true; do
    check_for_updates_quiet
    clear
    echo "  ${C_BOLD}╔══════════════════════════════════════╗${C_RESET}"
    echo "  ${C_BOLD}║      codecade.co.za — Portal TUI      ║${C_RESET}"
    echo "  ${C_BOLD}╚══════════════════════════════════════╝${C_RESET}"
    echo ""
    proc_running forge     && echo "  Forge    : ${C_GREEN}running${C_RESET} (PID $(proc_pid forge))"     || echo "  Forge    : ${C_DIM}stopped${C_RESET}"
    proc_running tag-relay && echo "  Tag relay: ${C_GREEN}running${C_RESET} (PID $(proc_pid tag-relay))" || echo "  Tag relay: ${C_DIM}stopped${C_RESET}"
    proc_running temutalk  && echo "  TemuTalk : ${C_GREEN}running${C_RESET} (PID $(proc_pid temutalk))"  || echo "  TemuTalk : ${C_DIM}stopped${C_RESET}"
    proc_running portal    && echo "  Portal   : ${C_GREEN}running${C_RESET} (PID $(proc_pid portal))"    || echo "  Portal   : ${C_DIM}stopped${C_RESET}"
    proc_running tunnel    && echo "  Tunnel   : ${C_GREEN}running${C_RESET} (PID $(proc_pid tunnel))"     || echo "  Tunnel   : ${C_DIM}stopped${C_RESET}"
    proc_running dev-panel && echo "  Dev panel: ${C_GREEN}running${C_RESET} (PID $(proc_pid dev-panel))" || echo "  Dev panel: ${C_DIM}stopped${C_RESET}"
    echo "  URL      : https://${CF_DOMAIN}"
    if [ "$_updates_available" -eq 1 ]; then
      echo "  ${C_YELLOW}Updates available — select \"Check for updates\" to pull.${C_RESET}"
    fi
    local _err_count; _err_count=$(find errors -maxdepth 1 -type f 2>/dev/null | wc -l)
    if [ "$_err_count" -gt 0 ]; then
      echo "  ${C_RED}$_err_count error file(s) recorded — select \"View errors\".${C_RESET}"
    fi
    echo ""
    echo "  ${C_DIM}↑/↓ to move, Enter to select${C_RESET}"
    echo ""
    for i in "${!MENU_LABELS[@]}"; do
      if [ "$i" -eq "$_menu_selected" ]; then
        echo "  ${C_CYAN}▸ ${MENU_LABELS[$i]}${C_RESET}"
      else
        echo "    ${MENU_LABELS[$i]}"
      fi
    done

    local key; key=$(read_key)
    case "$key" in
      TIMEOUT)
        continue
        ;;
      $'\x1b[A')
        _menu_selected=$(( (_menu_selected - 1 + ${#MENU_LABELS[@]}) % ${#MENU_LABELS[@]} ))
        continue
        ;;
      $'\x1b[B')
        _menu_selected=$(( (_menu_selected + 1) % ${#MENU_LABELS[@]} ))
        continue
        ;;
      "") ;; # Enter -- fall through and act on the selected item
      q|Q)
        echo ""; echo "  Bye."
        exit 0
        ;;
      *)
        continue
        ;;
    esac

    echo ""
    case "$_menu_selected" in
      0) do_start ;;
      1) do_stop ;;
      2) do_open_browser ;;
      3) do_check_updates ;;
      4) do_view_logs ;;
      5) do_view_errors ;;
      6) if proc_running forge;     then stop_proc forge;     else start_forge;     fi ;;
      7) if proc_running temutalk;  then stop_proc temutalk;  else start_temutalk;  fi ;;
      8) if proc_running portal;    then stop_proc portal;    else start_portal;    fi ;;
      9) if proc_running tunnel;    then stop_proc tunnel;    else start_tunnel;    fi ;;
      10) if proc_running tag-relay; then stop_proc tag-relay; else start_tag_relay; fi ;;
      11) if proc_running dev-panel; then stop_proc dev-panel; else start_dev_panel; fi ;;
      12)
        read -rp "  Destination path (e.g. a mounted USB drive): " bundle_dest
        [ -n "$bundle_dest" ] && do_bundle "$bundle_dest"
        ;;
      13)
        echo "  Bye."
        exit 0
        ;;
    esac
    echo ""
    read -rp "  Press Enter to continue..." _
  done
}

menu
