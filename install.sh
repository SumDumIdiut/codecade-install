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
#   bash install.sh errors         show error.log (single flat file, whole tree)
#   bash install.sh check-updates  pull temutalk/git-forge/tag, but only restart
#                                   whichever of those actually had a new commit
#                                   (says so plainly if nothing changed)
#   bash install.sh bundle <dest>  copy install.sh + all repos to <dest> (e.g. a
#                                   mounted USB drive) so it can be plugged into
#                                   any machine and run without needing network
#                                   access to re-clone from GitHub
#
# Every failure (failed clone/npm-install/service-start) is recorded verbosely
# to a single error.log, and every service's own output goes to a single
# service.log — one flat file each, not a directory of per-service/per-
# failure files, so nothing is lost even if nobody was watching the terminal
# when it broke.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
cd "$DIR" || exit 1
# Portable Node.js/cloudflared/ffmpeg (see ensure_portable_node etc below)
# live in .bin -- putting it on PATH here, once, means every nohup'd service
# below and anything they shell out to (e.g. temutalk invoking ffmpeg) finds
# them automatically, without threading find_node()/find_ffmpeg() through
# every call site individually.
export PATH="$DIR/.bin:$PATH"

TEMUTALK_REPO="https://github.com/SumDumIdiut/temutalk.git"
FORGE_REPO="https://github.com/SumDumIdiut/git-forge.git"
TAG_REPO="https://github.com/SumDumIdiut/tag.git"
CF_DOMAIN="codecade.co.za"
PORTAL_PORT="${PORTAL_PORT:-8080}"
TEMUTALK_PORT="${TEMUTALK_PORT:-3001}"
FORGE_PORT="${FORGE_PORT:-3000}"
TAG_RELAY_PORT="${TAG_RELAY_PORT:-3002}"
DEV_PANEL_PORT="${DEV_PANEL_PORT:-9091}"

# Runs a git command against a repo dir that might live on a filesystem
# without ownership tracking (FAT/exFAT USB drives, common for the bundled
# copy this script is designed to run from) -- git refuses those with
# "detected dubious ownership" otherwise. Scoped to just this invocation via
# -c, never touches the user's persistent gitconfig.
git_safe() {
  local dir="$1"; shift
  # "*" (not "$dir") because on Windows/git-bash, MSYS's POSIX-style path
  # (e.g. /e/temutalk) never string-matches git's own Windows-style resolved
  # repo path (E:/temutalk), so safe.directory="$dir" silently never applies
  # and every call still fails with "dubious ownership". Scoped to this one
  # -c invocation only -- never written to any persisted git config.
  git -c safe.directory='*' -C "$dir" "$@"
}

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
# Every err() call is also appended to error.log (single flat file, whole
# tree) with a timestamp — applies automatically to every existing call
# site, no need to touch them. For failures worth capturing full command
# output (not just the one-line message), see run_capturing() below.
err()  {
  echo "  ${C_RED}✗${C_RESET} $1"
  printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$1" >> "$DIR/error.log" 2>/dev/null
}

# ─── Self-update ──────────────────────────────────────────────────────────
# Runs before anything else on every startup (interactive or CLI dispatch)
# so this is always the latest version, whether it's a real clone of
# codecade-install (git pull) or a standalone file someone curl'd down
# (git-clone to a temp dir and replace if different). Silent/non-fatal if
# offline or the update itself fails — never blocks the rest of the script.
CODECADE_INSTALL_GIT_URL="https://github.com/SumDumIdiut/codecade-install.git"
self_update() {
  [ -n "${_CODECADE_SELF_UPDATED:-}" ] && return

  if [ -d "$DIR/.git" ] && git_safe "$DIR" remote get-url origin 2>/dev/null | grep -q "codecade-install"; then
    local before after
    before=$(git_safe "$DIR" rev-parse HEAD 2>/dev/null) || return
    git_safe "$DIR" fetch --quiet origin main 2>/dev/null || return
    after=$(git_safe "$DIR" rev-parse origin/main 2>/dev/null) || return
    if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
      info "Updating install.sh..."
      if git_safe "$DIR" reset --quiet --hard origin/main 2>/dev/null; then
        ok "install.sh updated — restarting."
        _CODECADE_SELF_UPDATED=1 exec bash "$DIR/install.sh" "$@"
      else
        warn "install.sh self-update failed — continuing with the current version."
      fi
    fi
  else
    # Deliberately git-clone rather than curl the raw file:
    # raw.githubusercontent.com sits behind a Varnish CDN with a 5-minute
    # per-edge cache (confirmed via response headers), so a host routed to a
    # stale edge could silently keep re-running an old version indefinitely.
    # git operations hit GitHub's actual backend directly, not that cache.
    command -v git >/dev/null 2>&1 || return
    local tmpdir; tmpdir="$(mktemp -d 2>/dev/null)" || return
    if git clone --depth 1 --quiet "$CODECADE_INSTALL_GIT_URL" "$tmpdir" 2>/dev/null \
       && [ -s "$tmpdir/install.sh" ] && bash -n "$tmpdir/install.sh" 2>/dev/null; then
      if ! cmp -s "$tmpdir/install.sh" "$DIR/install.sh"; then
        info "Updating install.sh..."
        if cp "$tmpdir/install.sh" "$DIR/install.sh" 2>/dev/null; then
          chmod +x "$DIR/install.sh" 2>/dev/null
          rm -rf "$tmpdir"
          ok "install.sh updated — restarting."
          _CODECADE_SELF_UPDATED=1 exec bash "$DIR/install.sh" "$@"
        else
          warn "install.sh self-update failed (couldn't write) — continuing with the current version."
        fi
      fi
    fi
    rm -rf "$tmpdir" 2>/dev/null
  fi
}

# ─── Platform detection ─────────────────────────────────────────────────────
# This script's primary target is a Linux server (terraserver), but it's also
# routinely run via Git Bash on Windows during development -- every portable
# download below (Node.js, cloudflared, ffmpeg) and the git-install fallback
# need an OS branch, not just a CPU-arch one.
detect_os() {
  case "$(uname -s)" in
    Linux*)                echo linux ;;
    Darwin*)                echo darwin ;;
    MINGW*|MSYS*|CYGWIN*)  echo windows ;;
    *)                      echo linux ;;
  esac
}

# Converts a Git-Bash POSIX-style path (/e/foo/bar) to the native Windows
# form (E:\foo\bar). MSYS auto-converts POSIX-looking arguments passed
# directly on a native .exe's command line, but NOT paths written into a
# config FILE that exe reads later -- confirmed live: cloudflared.exe
# refused a perfectly real, intact credentials file with "doesn't exist or
# is not a file" because config.yml's credentials-file: line still had the
# unconverted /e/... path in it. No-op on non-Windows.
to_native_path() {
  local p="$1"
  if [ "$(detect_os)" = "windows" ] && [[ "$p" =~ ^/([a-zA-Z])/(.*)$ ]]; then
    p="${BASH_REMATCH[1]^^}:/${BASH_REMATCH[2]}"
    p="${p//\//\\}"
  fi
  echo "$p"
}

# Extracts a .zip whose contents sit inside one top-level directory straight
# into $dest, stripping that top-level directory -- the same thing tar
# --strip-components=1 does for the .tar.gz/.tar.xz archives used elsewhere
# in this script. Needed because Git for Windows' bundled `tar` genuinely
# cannot read zip (confirmed live: "This does not look like a tar archive"
# on a real Node.js Windows zip -- it is NOT the bsdtar/libarchive build that
# some other MSYS2 distributions ship), whereas `unzip` is present in every
# Git for Windows install tested.
extract_zip_stripped() {
  local archive="$1" dest="$2"
  local tmp; tmp="$(mktemp -d 2>/dev/null)" || tmp="$DIR/.bin/.unzip-tmp-$$"
  mkdir -p "$tmp"
  if ! unzip -q "$archive" -d "$tmp"; then rm -rf "$tmp"; return 1; fi
  local root; root=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)
  if [ -z "$root" ]; then rm -rf "$tmp"; return 1; fi
  mkdir -p "$dest"
  cp -r "$root/." "$dest/"
  rm -rf "$tmp"
}

# Every download in this script goes through one of these two, so a slow or
# dead mirror (confirmed live: gyan.dev hung for 6+ minutes with zero
# progress on one run) can never hang the whole setup indefinitely -- it
# times out, the caller's `&&` chain fails, and the (already-required)
# fallback/soft-fail path takes over instead.
dl_curl()        { curl -L --progress-bar --connect-timeout 15 --max-time 300 "$@"; }
dl_curl_silent() { curl -sL --connect-timeout 15 --max-time 60  "$@"; }

# ─── System package installs (git, and ffmpeg's package-manager fallback) ───
# Everything else this script needs (Node.js, npm, cloudflared, Piper) is a
# portable static download with no root/package-manager involved at all --
# see ensure_portable_node/ensure_temutalk_portable_bins/ensure_temutalk_piper
# below. git is the one exception: unlike those, there's no single portable
# static git build to download (git itself needs a real install, with its
# libexec helpers and shared libs), and self_update() above already needs a
# working `git` just to fetch this script in the non-checkout branch -- so
# "nothing pre-installed" for git means "installed automatically by this
# script via whatever package manager the host already has", not a bundled
# binary. Covers every mainstream Linux package manager, plus Windows
# (choco/winget/scoop) and macOS (brew) -- not just apt.
pkg_install() {
  local pkg="$1"
  local _sudo=""
  [ "$(id -u 2>/dev/null)" != "0" ] && command -v sudo >/dev/null 2>&1 && _sudo="sudo"
  if command -v apt-get >/dev/null 2>&1; then
    $_sudo apt-get update -qq && $_sudo apt-get install -y "$pkg"
  elif command -v dnf >/dev/null 2>&1; then
    $_sudo dnf install -y "$pkg"
  elif command -v yum >/dev/null 2>&1; then
    $_sudo yum install -y "$pkg"
  elif command -v pacman >/dev/null 2>&1; then
    $_sudo pacman -Sy --noconfirm "$pkg"
  elif command -v apk >/dev/null 2>&1; then
    $_sudo apk add --no-cache "$pkg"
  elif command -v zypper >/dev/null 2>&1; then
    $_sudo zypper install -y "$pkg"
  elif command -v emerge >/dev/null 2>&1; then
    $_sudo emerge "$pkg"
  elif command -v xbps-install >/dev/null 2>&1; then
    $_sudo xbps-install -Sy "$pkg"
  elif command -v brew >/dev/null 2>&1; then
    brew install "$pkg"
  elif command -v choco >/dev/null 2>&1; then
    choco install -y "$pkg"
  elif command -v winget >/dev/null 2>&1; then
    winget install -e --id "$pkg" --accept-package-agreements --accept-source-agreements
  elif command -v scoop >/dev/null 2>&1; then
    scoop install "$pkg"
  else
    return 127
  fi
}

# Package name for `pkg_install git` differs across Windows package managers
# (winget/choco use their own catalog IDs, not the plain "git" every Linux
# manager and brew accept).
pkg_install_git() {
  if [ "$(detect_os)" = "windows" ]; then
    if command -v choco >/dev/null 2>&1; then choco install -y git; return; fi
    if command -v winget >/dev/null 2>&1; then winget install -e --id Git.Git --accept-package-agreements --accept-source-agreements; return; fi
    if command -v scoop >/dev/null 2>&1; then scoop install git; return; fi
    return 127
  fi
  pkg_install git
}

ensure_git() {
  command -v git >/dev/null 2>&1 && return
  # Git Bash *is* Git for Windows -- if this script is even running (it needs
  # bash), a working git is already on PATH in the overwhelming majority of
  # real cases. This only fires for the rare setup where bash exists without
  # it (e.g. a bare MSYS2 install).
  info "git not found — installing (requires a supported package manager)..."
  if pkg_install_git && command -v git >/dev/null 2>&1; then
    ok "git installed."
  else
    err "Could not install git automatically — no supported package manager found, or it failed. Install git manually and re-run."
    exit 1
  fi
}
ensure_git
self_update "$@"

mkdir -p .run
touch "$DIR/error.log" "$DIR/service.log"

# Runs a command with combined stdout+stderr captured. On failure, the full
# output is appended directly into error.log (single flat file, whole tree)
# under a timestamped header, instead of a separate per-failure file and
# instead of just letting it scroll past in the terminal — the detail
# survives even if you weren't watching when it broke.
run_capturing() {
  local label="$1"; shift
  local out; out="$(mktemp 2>/dev/null)" || { "$@"; return $?; }
  if "$@" > "$out" 2>&1; then
    rm -f "$out"
    return 0
  else
    local code=$?
    err "$label failed"
    { printf -- '----- %s (%s) -----\n' "$label" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"; cat "$out"; echo; } \
      >> "$DIR/error.log" 2>/dev/null
    rm -f "$out"
    return "$code"
  fi
}

# Appends the tail of service.log into error.log at the moment a start
# failure is detected, under a timestamped header, so the failure context
# survives even after service.log keeps growing.
snapshot_log_on_failure() {
  local label="$1" logfile="$2"
  err "$label failed — check $logfile"
  [ -f "$logfile" ] || return
  { printf -- '----- %s (%s) -----\n' "$label" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"; tail -n 80 "$logfile"; echo; } \
    >> "$DIR/error.log" 2>/dev/null
}

# Wipes error.log and service.log so a fresh run is never confused with
# stale output from an earlier one (a real prior symptom: a since-fixed
# tunnel-credentials warning, and later a since-fixed EADDRINUSE race, both
# kept showing up in DIAGNOSTICS long after the actual fix landed, because
# nothing reliably cleared them between runs). Called wherever the program
# is actually being *run* -- the default interactive launch, `setup`, and
# do_start() -- but deliberately not from read-only/narrowly-scoped paths
# (`status`, `errors`, `check-updates`, a single `start <service>`), where
# wiping everyone else's recent output would be a surprising side effect of
# what's meant to be a targeted or read-only action.
clear_logs() {
  : > "$DIR/error.log" 2>/dev/null
  : > "$DIR/service.log" 2>/dev/null
}

update_checkout_hard() {
  local dir="$1"
  # Don't hardcode a branch name -- git-forge's default branch is "master",
  # temutalk/tag use "main". Whatever branch `git clone` originally checked
  # out is what HEAD already points at, so read that back instead of
  # guessing (this broke git-forge updates: "couldn't find remote ref main").
  local branch; branch=$(git_safe "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 1
  if git_safe "$dir" fetch --quiet origin "$branch" \
     && git_safe "$dir" reset --quiet --hard "origin/$branch"; then
    return 0
  fi
  # A corrupted .git/index (confirmed live: "index file smaller than
  # expected" -- the same USB-write-interruption failure mode documented on
  # clone_or_update() below) makes `fetch` itself fail, not just `reset
  # --hard` -- confirmed live that even `fetch` refuses with this exact
  # error on a truncated index, so a fix that only retried `reset --hard`
  # never actually ran (fetch's `|| return 1` triggered first). HEAD still
  # resolves fine either way, so clone_or_update()'s rev-parse-HEAD check
  # doesn't catch this. The index is disposable (`reset --hard` fully
  # rebuilds it from the target tree), so drop it and retry the whole
  # sequence once before giving up.
  rm -f "$dir/.git/index"
  git_safe "$dir" fetch --quiet origin "$branch" \
    && git_safe "$dir" reset --quiet --hard "origin/$branch"
}

# ─── Clone / update the two app repos ───────────────────────────────────────
clone_or_update() {
  local dir="$1" url="$2" name="$3"
  # A directory can end up with a ".git" folder that isn't actually a usable
  # repo -- e.g. an interrupted copy to another drive that pre-created the
  # file tree before writing any content. rev-parse HEAD is a cheap way to
  # tell "real checkout" from "hollow shell"; treat the latter as absent and
  # re-clone instead of failing `pull` forever with no way to self-heal.
  if [ -d "$dir/.git" ] && git_safe "$dir" rev-parse HEAD >/dev/null 2>&1; then
    info "Updating $name..."
    # fetch + reset --hard, not `pull`: these checkouts are entirely
    # auto-managed (nothing should ever hand-edit them), but things like the
    # CRLF-strip defense below DO edit temutalk/install.sh's working tree in
    # place -- a plain `pull --ff-only` then refuses forever with "local
    # changes would be overwritten by merge" the moment that happens once.
    # Discarding local changes on every update is the correct, idempotent
    # behavior here, not a risk.
    run_capturing "pull-$name" update_checkout_hard "$dir" \
      || warn "$name: git update failed — continuing with existing checkout (see error.log for details)"
  else
    if [ -d "$dir/.git" ]; then
      warn "$name: existing checkout looks corrupted (no valid HEAD) — removing and re-cloning."
      rm -rf "$dir"
    elif [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
      # A non-empty directory with no .git at all (e.g. leftover
      # node_modules/downloaded-binaries from an interrupted earlier run,
      # or setup killed mid-clone before .git even existed) -- `git clone`
      # refuses to clone into this and exits 1 below, hard-failing the
      # whole script before it ever reaches the TUI. Clear it first so a
      # fresh clone always has a real shot at succeeding.
      warn "$name: directory exists but isn't a git checkout — removing and re-cloning."
      rm -rf "$dir"
    fi
    info "Cloning $name..."
    if run_capturing "clone-$name" git clone "$url" "$dir"; then
      ok "$name cloned."
    else
      exit 1
    fi
  fi
}

# ─── Binary/tool lookup ──────────────────────────────────────────────────────
# $DIR/.bin/node-runtime/ is a full portable Node.js runtime this script
# downloads itself (see ensure_portable_node) — shared by every app (portal,
# git-forge, tag-relay, remote-admin, temutalk), not just temutalk, so
# nothing needs a system-wide Node.js install. $DIR/.bin/node itself is a
# flat wrapper script (not the runtime dir — kept separate so it can sit
# directly on PATH, see the `export PATH` near the top of this file) that
# execs into node-runtime/, same idea as the $DIR/.bin/npm wrapper below it.
# System node/npm are only ever a fallback, for hosts where someone already
# has it and the portable download hasn't run.
# -s (non-empty), not just -x: a 0-byte wrapper (confirmed live -- USB write
# corruption truncated one mid-session) would otherwise pass an -x-only
# check and get trusted, silently falling every service back to whatever
# system Node happens to be on PATH instead of the pinned portable one --
# which, unlike the portable v20, can be strict enough (v24 confirmed live)
# about package.json validation to crash on node_modules that were fine
# under the portable runtime. Silent version-mismatch fallback is worse than
# just falling back cleanly, so this check exists specifically to catch it.
find_node() {
  [ -s "$DIR/.bin/node" ] && { echo "$DIR/.bin/node"; return; }
  command -v node 2>/dev/null
}
find_npm() {
  [ -s "$DIR/.bin/npm" ] && { echo "$DIR/.bin/npm"; return; }
  command -v npm 2>/dev/null
}
# Old name kept as an alias -- temutalk used to bundle its own separate
# portable Node before the download was generalized to the whole stack.
find_temutalk_node() { find_node; }
find_cloudflared() {
  # Check the OS-correct name first, not just "whichever exists" -- a
  # leftover Linux binary from a previous run on a different machine
  # (confirmed live: a stale .bin/cloudflared from terraserver) would
  # otherwise get picked over a perfectly good .bin/cloudflared.exe sitting
  # right next to it, and "cannot execute binary file" doesn't make it
  # obvious why.
  if [ "$(detect_os)" = "windows" ]; then
    [ -s "$DIR/.bin/cloudflared.exe" ] && { echo "$DIR/.bin/cloudflared.exe"; return; }
  else
    [ -s "$DIR/.bin/cloudflared" ] && { echo "$DIR/.bin/cloudflared"; return; }
  fi
  [ -x "$DIR/temutalk/bin/linux/cloudflared" ] && { echo "$DIR/temutalk/bin/linux/cloudflared"; return; }
  command -v cloudflared 2>/dev/null
}

# ─── PID helpers ──────────────────────────────────────────────────────────────
pid_file()     { echo "$DIR/.run/$1.pid"; }
# Pidfiles are written as "<os>:<pid>", not a bare PID -- this whole tree
# runs off a portable drive that moves between machines, and PIDs from one
# OS mean nothing on another (confirmed live: a Windows-session PID left in
# a pidfile happened to match a genuinely running, completely unrelated
# Linux process on terraserver -- wireplumber, an audio daemon -- so
# `kill -0` succeeded by pure coincidence and every start_*() function
# believed the real service was "already running" and skipped starting it).
# A pidfile whose OS tag doesn't match detect_os right now is therefore
# always treated as stale, regardless of whether kill -0 would succeed.
proc_running() {
  local f; f=$(pid_file "$1")
  [ -f "$f" ] || return 1
  local raw; raw=$(cat "$f" 2>/dev/null)
  local tag="${raw%%:*}" pid="${raw##*:}"
  [ "$tag" = "$(detect_os)" ] || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
proc_pid() {
  local f; f=$(pid_file "$1")
  [ -f "$f" ] || return
  local raw; raw=$(cat "$f" 2>/dev/null)
  echo "${raw##*:}"
}
stop_proc() {
  local name="$1"
  if proc_running "$name"; then
    local pid; pid=$(proc_pid "$name")
    kill "$pid" 2>/dev/null
    # Wait for the process to actually exit (and so release its port)
    # before returning -- confirmed live: a caller that stops a service and
    # immediately starts a new one (do_check_updates) can otherwise race
    # the OS's socket cleanup and hit EADDRINUSE, because SIGTERM isn't
    # instantaneous and this used to return as soon as the signal was
    # merely sent, not once the process was actually gone. Escalates to
    # SIGKILL if it hasn't exited after 5s.
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
      sleep 0.2
      waited=$((waited + 1))
      if [ "$waited" -ge 25 ]; then
        kill -9 "$pid" 2>/dev/null
        break
      fi
    done
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
  "description": "Landing portal for codecade.co.za — proxies /temutalk, /forge and /tag to their backends, plus a dev panel for remote install.sh access and TemuTalk admin",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "http-proxy-middleware": "^2.0.6",
    "ws": "^8.14.2",
    "selfsigned": "^2.4.1"
  },
  "optionalDependencies": {
    "node-pty": "^1.1.0"
  }
}
PORTAL_PACKAGE_JSON

  cat > "$DIR/portal/server.js" <<'PORTAL_SERVER_JS'
const express = require('express');
const http = require('http');
const net = require('net');
const path = require('path');
const { createProxyMiddleware } = require('http-proxy-middleware');

const PORT = parseInt(process.env.PORT || '8080', 10);
const TEMUTALK_TARGET = process.env.TEMUTALK_TARGET || 'https://127.0.0.1:3001';
const FORGE_TARGET = process.env.FORGE_TARGET || 'http://127.0.0.1:3000';
const TAG_RELAY_TARGET = process.env.TAG_RELAY_TARGET || 'http://127.0.0.1:3002';
const DEV_PANEL_TARGET = process.env.DEV_PANEL_TARGET || 'https://127.0.0.1:9091';

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
// Plain HTTP only here (no ws:true) -- WS upgrades for /tag are handled by
// proxyTagWebSocket below instead, via a raw socket pipe. http-proxy-
// middleware's own WS handling corrupts every frame under this exact setup
// (confirmed live: connecting straight to relay-server works fine, but any
// connection through this middleware's ws:true path fails immediately with
// "Invalid WebSocket frame: RSV1 must be clear" -- with no compression
// extension even negotiated in the handshake, so it isn't a permessage-
// deflate issue, just something mechanically wrong in how it pipes frames).
const tagRelayProxy = createProxyMiddleware({
  target: TAG_RELAY_TARGET,
  changeOrigin: true,
  logLevel: 'warn',
});
// dev-panel.js's TLS cert is self-signed (same as temutalk's), and it's
// BASE_PATH-aware specifically for this mount: it detects the /panel
// prefix on each incoming request and rewrites every absolute link/
// fetch/WebSocket URL/cookie Path it emits to match, so it keeps working
// identically whether reached here or directly on its own port -- see
// detectPrefix() in dev-panel.js. ws:true because the panel's terminal
// tab is a real WebSocket (xterm.js), same as temutalk's own tab.
const devPanelProxy = createProxyMiddleware({
  target: DEV_PANEL_TARGET,
  changeOrigin: true,
  secure: false,
  ws: true,
  logLevel: 'warn',
});

app.use('/temutalk', temutalkProxy);
app.use('/forge', forgeProxy);
app.use('/tag', tagRelayProxy);
app.use('/panel', devPanelProxy);
app.use(express.static(path.join(__dirname, 'public')));

const server = http.createServer(app);

// Manual raw TCP pipe for /tag's WebSocket upgrades (see comment above the
// tagRelayProxy - the relay's own player<->host splice() does the exact
// same kind of pure byte-forwarding, which is what makes this reliable:
// no WS-frame-aware reparsing anywhere in the path to get wrong.
function proxyTagWebSocket(req, socket, head) {
  const target = new URL(TAG_RELAY_TARGET);
  const targetSocket = net.connect(target.port || 80, target.hostname, () => {
    let raw = `${req.method} ${req.url} HTTP/1.1\r\n`;
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      raw += `${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}\r\n`;
    }
    raw += '\r\n';
    targetSocket.write(raw);
    if (head && head.length) targetSocket.write(head);
    targetSocket.pipe(socket);
    socket.pipe(targetSocket);
  });
  targetSocket.on('error', () => socket.destroy());
  socket.on('error', () => targetSocket.destroy());
}

// Express only handles regular HTTP requests — WebSocket upgrades on the raw
// server have to be routed to the matching proxy instance by hand.
server.on('upgrade', (req, socket, head) => {
  if (req.url.startsWith('/temutalk')) return temutalkProxy.upgrade(req, socket, head);
  if (req.url.startsWith('/tag')) return proxyTagWebSocket(req, socket, head);
  if (req.url.startsWith('/panel')) return devPanelProxy.upgrade(req, socket, head);
  socket.destroy();
});

server.listen(PORT, () => {
  console.log(`\n  Portal running at http://localhost:${PORT}`);
  console.log(`    /temutalk -> ${TEMUTALK_TARGET}`);
  console.log(`    /forge    -> ${FORGE_TARGET}`);
  console.log(`    /tag      -> ${TAG_RELAY_TARGET}`);
  console.log(`    /panel    -> ${DEV_PANEL_TARGET}\n`);
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
// Everything here reuses temutalk's own key file, run dir and .env -- one
// login, one panel, no separate credentials to manage for the TemuTalk tab.
const TEMUTALK_DIR         = process.env.TEMUTALK_DIR || path.join(__dirname, '..', 'temutalk');
const TEMUTALK_RUN_DIR     = path.join(TEMUTALK_DIR, '.run');
const TEMUTALK_ENV_FILE    = path.join(TEMUTALK_DIR, '.env');
const KEY_HASH_FILE        = process.env.TEMUTALK_KEY_HASH_FILE || path.join(TEMUTALK_RUN_DIR, 'panel-key-hash');
const TEMUTALK_SERVER_PORT = parseInt(process.env.TEMUTALK_SERVER_PORT || '3001', 10);
const RUN_DIR = path.join(__dirname, '.run');

// Reachable two ways at once with this same running process: directly on
// its own port (:9091, unprefixed -- unchanged, original behavior) and
// proxied through the portal at codecade.co.za/panel (see portal/
// server.js's devPanelProxy, which preserves this prefix rather than
// stripping it, same as its /temutalk and /forge mounts). Detected fresh
// per-request from the incoming path rather than baked in at startup, so
// one process serves both correctly -- every response (route matching,
// emitted HTML's absolute fetch/WebSocket URLs, cookie Path) is built
// around whichever prefix that request actually arrived with.
const PROXY_PREFIX = '/panel';
function detectPrefix(pathname) {
  return (pathname === PROXY_PREFIX || pathname.startsWith(PROXY_PREFIX + '/')) ? PROXY_PREFIX : '';
}

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
function refreshSession(req, res, prefix) {
  if (!isAuthed(req)) return;
  const payload = `s:${Date.now() + SESSION_TTL_MS}`;
  res.setHeader('Set-Cookie', `panel_session=${signSession(payload)}; Path=${prefix || '/'}; HttpOnly; Secure; SameSite=Strict; Max-Age=${Math.floor(SESSION_TTL_MS / 1000)}`);
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

// ─── Fetch helper (proxy to temutalk's own server) ───────────────────────────
const tlsAgent = new https.Agent({ rejectUnauthorized: false });
function callServerJson(urlPath, method = 'GET', body = null) {
  return new Promise(resolve => {
    const bodyStr = body ? JSON.stringify(body) : null;
    const opts = {
      hostname: '127.0.0.1', port: TEMUTALK_SERVER_PORT, path: urlPath, method, agent: tlsAgent,
      headers: { 'Content-Type': 'application/json', ...(bodyStr ? { 'Content-Length': Buffer.byteLength(bodyStr) } : {}) },
    };
    const req = https.request(opts, res => {
      let d = '';
      res.on('data', c => d += c);
      res.on('end', () => { try { resolve(JSON.parse(d)); } catch { resolve(null); } });
    });
    req.on('error', () => resolve(null));
    req.setTimeout(5000, () => { req.destroy(); resolve(null); });
    if (bodyStr) req.write(bodyStr);
    req.end();
  });
}
function fetchServerJson(urlPath) { return callServerJson(urlPath); }

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
    "script-src 'unsafe-inline' https://cdn.jsdelivr.net; " +
    "connect-src 'self' wss: ws:; font-src https://cdn.jsdelivr.net; " +
    "img-src 'self' data: blob: https://i.scdn.co https://cdn.discordapp.com https://lh3.googleusercontent.com https://avatars.githubusercontent.com"
  );
  res.setHeader('Strict-Transport-Security', 'max-age=31536000');
}

// ─── Login page ───────────────────────────────────────────────────────────────
function loginPage(prefix = '') {
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
  <div class="drop-label" style="font-size:11px;margin-top:4px;opacity:.6">key.key</div>
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
  try{const r=await fetch('${prefix}/api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({keyContent:kc})});
  if(r.ok){location.reload();return;}const j=await r.json().catch(()=>({}));err.textContent=j.error||'Login failed';}
  catch(e2){err.textContent='Request failed: '+e2.message;}btn.disabled=false;}
</script></body></html>`;
}

// ─── Main panel page (Terminal + TemuTalk tabs) ──────────────────────────────
function page(prefix = '') {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>codecade Dev Panel</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.css">
<style>
*{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#0d1117;--sur:#161b22;--sur2:#21262d;--sur3:#2d333b;
  --bor:#30363d;--tx:#e6edf3;--sec:#8b949e;
  --acc:#58a6ff;--grn:#3fb950;--red:#f85149;--ylw:#d29922;--orn:#fb8f44;
  color-scheme:dark
}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:var(--bg);color:var(--tx);height:100dvh;display:flex;flex-direction:column;overflow:hidden;font-size:13px}

/* Header */
.hdr{display:flex;align-items:center;gap:10px;padding:0 14px;height:48px;background:var(--sur);border-bottom:1px solid var(--bor);flex-shrink:0;gap:8px}
.hdr-logo{font-weight:700;font-size:14px;white-space:nowrap}
.hdr-stats{display:flex;gap:6px;flex:1;overflow:hidden;align-items:center}
.stat-chip{font-size:11px;color:var(--sec);background:var(--sur2);border:1px solid var(--bor);border-radius:6px;padding:3px 8px;white-space:nowrap;display:flex;align-items:center;gap:4px}
.stat-chip .dot{width:6px;height:6px;border-radius:50%}
.dot-grn{background:var(--grn)}
.dot-ylw{background:var(--ylw)}
.dot-red{background:var(--red)}
.hdr-acts{display:flex;gap:6px;flex-shrink:0}
.hdr-btn{background:none;border:1px solid var(--bor);color:var(--sec);border-radius:7px;padding:5px 12px;cursor:pointer;font:inherit;font-size:12px;transition:.12s;white-space:nowrap}
.hdr-btn:hover{color:var(--tx);border-color:var(--sec)}
.hdr-btn.danger:hover{color:var(--red);border-color:var(--red)}

/* Tabs (shared visual style for both the outer Terminal/TemuTalk bar and the
   inner Chat/Devices/Accounts bar -- JS below scopes queries per-bar so they
   don't interfere with each other) */
.tabbar{display:flex;padding:0 8px;background:var(--sur);border-bottom:1px solid var(--bor);flex-shrink:0;gap:2px}
.tab{background:none;border:none;border-bottom:2px solid transparent;padding:9px 14px;cursor:pointer;color:var(--sec);font:inherit;font-size:13px;font-weight:500;display:flex;align-items:center;gap:6px;transition:.12s;white-space:nowrap;margin-bottom:-1px}
.tab:hover{color:var(--tx)}
.tab.on{color:var(--acc);border-bottom-color:var(--acc)}
.tbadge{background:var(--red);color:#fff;border-radius:10px;font-size:10px;padding:1px 5px;min-width:16px;text-align:center;font-weight:700;line-height:1.4}

/* Panes -- outer level uses .mainpane (distinct from inner .pane) so the
   ported TemuTalk sub-tab logic below can keep using generic .pane/.tab
   class names scoped to its own #tt-tabbar/#tt-panes wrapper without ever
   touching the outer Terminal/TemuTalk panes. */
.mainpane{display:none;flex:1;overflow:hidden;flex-direction:column}
.mainpane.on{display:flex}
.pane{display:none;flex:1;overflow:hidden;flex-direction:column}
.pane.on{display:flex}

/* Split layout */
.split{display:flex;flex:1;overflow:hidden}
.sidebar{width:240px;flex-shrink:0;border-right:1px solid var(--bor);display:flex;flex-direction:column;background:var(--sur);overflow:hidden}
.main{flex:1;display:flex;flex-direction:column;overflow:hidden}

/* Room list */
.search-wrap{padding:8px;border-bottom:1px solid var(--bor);flex-shrink:0}
.search-inp{width:100%;background:var(--sur2);border:1px solid var(--bor);border-radius:7px;padding:6px 10px;color:var(--tx);font:inherit;font-size:12px;outline:none}
.search-inp:focus{border-color:var(--acc)}
.rooms-scroll{flex:1;overflow-y:auto}
.rs-hdr{font-size:10px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--sec);padding:10px 12px 4px;opacity:.7}
.r-item{display:flex;align-items:center;gap:9px;padding:8px 10px;cursor:pointer;border-left:2px solid transparent;transition:.1s}
.r-item:hover{background:var(--sur2)}
.r-item.on{background:rgba(88,166,255,.07);border-left-color:var(--acc)}
.r-av{width:34px;height:34px;border-radius:50%;background:var(--sur2);display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:700;color:var(--sec);flex-shrink:0;overflow:hidden;position:relative}
.r-av img{width:100%;height:100%;object-fit:cover}
.r-type-badge{position:absolute;bottom:-1px;right:-1px;font-size:9px;background:var(--sur);border-radius:50%;width:14px;height:14px;display:flex;align-items:center;justify-content:center;line-height:1}
.r-inf{flex:1;min-width:0}
.r-name{font-size:13px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.r-prev{font-size:11px;color:var(--sec);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:2px}
.r-meta{display:flex;flex-direction:column;align-items:flex-end;gap:3px;flex-shrink:0}
.r-time{font-size:10px;color:var(--sec)}
.r-badge{background:var(--acc);color:#000;border-radius:10px;font-size:10px;font-weight:700;padding:1px 5px;min-width:16px;text-align:center}

/* Message area */
.msg-hdr{display:flex;align-items:center;justify-content:space-between;padding:8px 14px;border-bottom:1px solid var(--bor);background:var(--sur);flex-shrink:0;min-height:44px;gap:8px}
.msg-hdr-left{display:flex;align-items:center;gap:8px}
.msg-hdr-name{font-size:14px;font-weight:600}
.msg-hdr-type{font-size:11px;color:var(--sec);background:var(--sur2);border:1px solid var(--bor);border-radius:5px;padding:2px 7px}
.msg-hdr-acts{display:flex;gap:6px;align-items:center}
.msg-body{flex:1;overflow-y:auto;padding:12px 14px;display:flex;flex-direction:column;gap:6px}
.msg-empty{display:flex;flex-direction:column;align-items:center;justify-content:center;flex:1;color:var(--sec);gap:10px;padding:32px 0;text-align:center}
.msg-empty-ico{font-size:40px;opacity:.4}
.date-row{text-align:center;margin:4px 0}
.date-chip{display:inline-block;background:var(--sur2);border:1px solid var(--bor);border-radius:12px;padding:2px 10px;font-size:10px;color:var(--sec)}

/* Message bubbles */
.m-row{display:flex;gap:8px;align-items:flex-start}
.m-av-btn{background:none;border:none;cursor:pointer;padding:0;flex-shrink:0}
.m-bubble-col{flex:1}
.m-sender-name{font-size:11px;font-weight:600;color:var(--acc);margin-bottom:3px;background:none;border:none;cursor:pointer;padding:0;text-align:left;display:block}
.m-sender-name.admin-label{color:var(--ylw);cursor:default}
.bubble{background:var(--sur2);border-radius:0 8px 8px 8px;padding:7px 12px;font-size:13px;line-height:1.5;word-break:break-word;display:inline-block;max-width:540px}
.bubble.admin{background:rgba(210,153,34,.1);border-left:3px solid var(--ylw)}
.m-time{font-size:10px;color:var(--sec);margin-left:8px;opacity:.7}

/* Compose */
.compose{padding:8px 12px 10px;border-top:1px solid var(--bor);background:var(--sur);flex-shrink:0}
.compose-sender{display:flex;align-items:center;gap:6px;margin-bottom:7px}
.compose-sender-label{font-size:11px;color:var(--sec)}
.sender-pill{background:none;border:1px solid var(--bor);color:var(--sec);border-radius:20px;padding:3px 11px;font:inherit;font-size:11px;font-weight:600;cursor:pointer;transition:.12s}
.sender-pill:hover{border-color:var(--sec);color:var(--tx)}
.sender-pill.on{background:var(--sur2);border-color:var(--acc);color:var(--acc)}
.compose-row{display:flex;gap:6px;align-items:flex-end}
.compose-inp{flex:1;background:var(--sur2);border:1px solid var(--bor);border-radius:8px;padding:8px 10px;color:var(--tx);font:inherit;font-size:13px;resize:none;outline:none;line-height:1.4;min-height:36px;max-height:100px}
.compose-inp:focus{border-color:var(--acc)}
.compose-send{background:var(--acc);color:#000;border:none;border-radius:8px;padding:8px 16px;font:inherit;font-size:13px;font-weight:700;cursor:pointer;flex-shrink:0;white-space:nowrap;transition:opacity .12s}
.compose-send:hover{opacity:.85}
.compose-send:disabled{opacity:.4;cursor:default}

/* Clear button */
.btn-clear{background:none;border:1px solid rgba(248,81,73,.3);color:var(--red);border-radius:6px;padding:4px 10px;cursor:pointer;font:inherit;font-size:12px;transition:.12s;white-space:nowrap}
.btn-clear:hover{background:rgba(248,81,73,.08);border-color:var(--red)}

/* Devices */
.dev-scroll{flex:1;overflow-y:auto;padding:8px}
.dev-card{display:flex;align-items:center;gap:10px;background:var(--sur2);border:1px solid var(--bor);border-radius:9px;padding:10px 12px;margin-bottom:7px;cursor:pointer;transition:.12s}
.dev-card:hover{border-color:var(--sec)}
.dev-card.on{border-color:var(--acc);background:rgba(88,166,255,.05)}
.dev-av{width:36px;height:36px;border-radius:50%;background:var(--bor);display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:700;color:var(--sec);position:relative;flex-shrink:0}
.dev-dot{width:8px;height:8px;border-radius:50%;background:var(--grn);border:2px solid var(--sur2);position:absolute;bottom:1px;right:1px}
.dev-inf{flex:1;min-width:0}
.dev-name{font-size:13px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.dev-sub{font-size:11px;color:var(--sec);margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pills{display:flex;gap:4px;margin-top:5px;flex-wrap:wrap}
.pill{font-size:10px;padding:2px 7px;border-radius:4px;font-weight:600}
.pg{background:rgba(63,185,80,.12);color:#3fb950}
.pb{background:rgba(88,166,255,.12);color:#58a6ff}
.pn{background:rgba(248,81,73,.12);color:#f85149}
.det-body{flex:1;overflow-y:auto;padding:14px;display:flex;flex-direction:column;gap:10px}
.det-empty{display:flex;align-items:center;justify-content:center;flex:1;color:var(--sec)}
.det-card{background:var(--sur);border:1px solid var(--bor);border-radius:9px;padding:12px 14px}
.det-title{font-size:10px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:var(--sec);margin-bottom:8px}
.det-row{display:flex;justify-content:space-between;align-items:center;padding:5px 0;font-size:12px;gap:10px;border-bottom:1px solid var(--bor)}
.det-row:last-child{border-bottom:none}
.det-k{color:var(--sec);flex-shrink:0}
.det-v{text-align:right;word-break:break-all}
.alb-row{display:flex;gap:12px;align-items:center;margin-bottom:10px}
.alb-img{width:48px;height:48px;border-radius:6px;object-fit:cover;background:var(--sur2);flex-shrink:0}
.t-name{font-size:14px;font-weight:600}
.t-sub{font-size:11px;color:var(--sec);margin-top:2px}
.prog{height:3px;background:var(--sur2);border-radius:2px;margin:8px 0}
.prog-f{height:100%;background:var(--acc);border-radius:2px}

/* Terminal */
.term-wrap{flex:1;display:flex;flex-direction:column;background:#000;overflow:hidden}
.term-bar{display:flex;align-items:center;gap:8px;padding:7px 12px;background:var(--sur);border-bottom:1px solid var(--bor);flex-shrink:0}
.tdot{width:8px;height:8px;border-radius:50%;background:var(--bor);transition:.2s;flex-shrink:0}
.tdot.on{background:var(--grn)}
.tstat{font-size:12px;color:var(--sec)}
#terminal-wrap{flex:1;overflow:hidden}

/* Accounts */
.accs-body{flex:1;overflow-y:auto;padding:14px;display:flex;flex-direction:column;gap:16px}
.accs-sec{display:flex;flex-direction:column;gap:8px}
.accs-sec-hdr{font-size:10px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:var(--sec);padding-bottom:8px;border-bottom:1px solid var(--bor)}
.acc-item{display:flex;align-items:center;gap:10px;background:var(--sur);border:1px solid var(--bor);border-radius:8px;padding:10px 12px}
.acc-av{width:32px;height:32px;border-radius:50%;background:var(--sur2);display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:700;color:var(--sec);overflow:hidden;flex-shrink:0}
.acc-av img{width:100%;height:100%;object-fit:cover}
.acc-name{font-size:13px;font-weight:600}
.acc-key{font-size:11px;color:var(--sec);margin-top:2px}
.abtn{background:none;border:1px solid var(--bor);color:var(--sec);border-radius:6px;padding:4px 10px;cursor:pointer;font:inherit;font-size:12px;white-space:nowrap;transition:.12s}
.abtn:hover{color:var(--tx);border-color:var(--sec)}
.abtn.danger{border-color:rgba(248,81,73,.3);color:var(--red)}
.abtn.danger:hover{background:rgba(248,81,73,.08);border-color:var(--red)}
details summary{cursor:pointer;color:var(--sec);font-size:12px;padding:6px 0;user-select:none;list-style:none}
details summary::before{content:'▶ ';font-size:10px}
details[open] summary::before{content:'▼ '}
details summary:hover{color:var(--tx)}

/* Profile modal */
.pm-ov{display:none;position:fixed;inset:0;background:rgba(0,0,0,.65);z-index:100;align-items:center;justify-content:center}
.pm-ov.vis{display:flex}
.pm-box{background:var(--sur);border:1px solid var(--bor);border-radius:12px;padding:22px;width:360px;max-width:94vw}
.pm-box h3{font-size:15px;font-weight:700;margin-bottom:14px}
.pm-av-wrap{display:flex;justify-content:center;margin-bottom:14px}
.pm-av{width:56px;height:56px;border-radius:50%;background:var(--sur2);display:flex;align-items:center;justify-content:center;font-size:18px;font-weight:700;color:var(--sec);overflow:hidden}
.pm-av img{width:100%;height:100%;object-fit:cover}
.pm-field{margin-bottom:10px}
.pm-field label{display:block;font-size:10px;color:var(--sec);margin-bottom:4px;font-weight:700;text-transform:uppercase;letter-spacing:.07em}
.pm-inp{width:100%;background:var(--sur2);border:1px solid var(--bor);border-radius:6px;padding:7px 10px;color:var(--tx);font:inherit;font-size:13px;outline:none}
.pm-inp:focus{border-color:var(--acc)}
.pm-msg{min-height:16px;font-size:12px;margin-bottom:8px}
.pm-acts{display:flex;gap:8px}
.pm-save{flex:1;background:var(--acc);color:#000;border:none;border-radius:7px;padding:9px;cursor:pointer;font:inherit;font-weight:700;font-size:13px}
.pm-cancel{background:none;border:1px solid var(--bor);color:var(--sec);border-radius:7px;padding:9px 16px;cursor:pointer;font:inherit;font-size:13px}
</style>
</head>
<body>

<!-- Profile modal (TemuTalk tab) -->
<div class="pm-ov" id="pm-overlay">
  <div class="pm-box">
    <h3>&#9998; Edit Profile</h3>
    <div class="pm-av-wrap"><div class="pm-av" id="pm-av">?</div></div>
    <div class="pm-field"><label>Display Name</label><input class="pm-inp" id="pm-name" placeholder="Name…"></div>
    <div class="pm-field"><label>Avatar URL</label><input class="pm-inp" id="pm-avatar-url" placeholder="https://…" oninput="pmPreview()"></div>
    <div class="pm-msg" id="pm-msg"></div>
    <div class="pm-acts">
      <button class="pm-save" id="pm-save" onclick="pmSave()">Save</button>
      <button class="pm-cancel" onclick="pmClose()">Cancel</button>
    </div>
  </div>
</div>

<!-- Outer header -->
<header class="hdr">
  <div class="hdr-logo">&#9654; codecade Dev Panel</div>
  <div class="hdr-acts">
    <button class="hdr-btn danger" onclick="logout()">Sign out</button>
  </div>
</header>

<!-- Outer tabs: Terminal | TemuTalk -->
<nav class="tabbar" id="main-tabbar">
  <button class="tab on" data-maintab="terminal" onclick="switchMainTab('terminal')">&gt;_ Terminal</button>
  <button class="tab"    data-maintab="temutalk" onclick="switchMainTab('temutalk')">&#9654; TemuTalk</button>
</nav>

<!-- Terminal pane -->
<div class="mainpane on" id="pane-terminal">
  <div class="term-wrap">
    <div class="term-bar">
      <div class="tdot" id="term-dot"></div>
      <div class="tstat" id="term-status">Connecting&hellip;</div>
    </div>
    <div id="terminal-wrap"><div id="terminal"></div></div>
  </div>
</div>

<!-- TemuTalk pane (everything that used to be temutalk's own control-panel.js) -->
<div class="mainpane" id="pane-temutalk">
  <header class="hdr">
    <div class="hdr-logo">TemuTalk</div>
    <div class="hdr-stats" id="hdr-stats"></div>
    <div class="hdr-acts">
      <button class="hdr-btn" id="restart-btn" onclick="doRestart()">&#8635; Restart</button>
    </div>
  </header>

  <nav class="tabbar" id="tt-tabbar">
    <button class="tab on" data-tab="chat"     onclick="switchTab('chat')">&#128172; Chat <span class="tbadge" id="chat-badge" style="display:none">0</span></button>
    <button class="tab"    data-tab="devices"  onclick="switchTab('devices')">&#128241; Devices <span class="tbadge" id="dev-badge" style="display:none">0</span></button>
    <button class="tab"    data-tab="accounts" onclick="switchTab('accounts')">&#9881; Accounts</button>
  </nav>

  <div id="tt-panes">
    <!-- Chat pane -->
    <div class="pane on" id="pane-chat">
      <div class="split">
        <div class="sidebar">
          <div class="search-wrap">
            <input class="search-inp" id="room-search" placeholder="&#128269; Search rooms…" oninput="renderRooms()">
          </div>
          <div class="rooms-scroll" id="rooms-col"></div>
        </div>
        <div class="main">
          <div class="msg-hdr">
            <div class="msg-hdr-left">
              <div class="msg-hdr-name" id="m-hdr-name">Select a conversation</div>
              <div class="msg-hdr-type" id="m-hdr-type" style="display:none"></div>
            </div>
            <div class="msg-hdr-acts">
              <button class="btn-clear" id="clear-btn" onclick="clearRoom()" style="display:none">&#128465; Clear history</button>
            </div>
          </div>
          <div class="msg-body" id="msgs-wrap">
            <div class="msg-empty"><div class="msg-empty-ico">&#128172;</div><div>Select a conversation from the sidebar</div></div>
          </div>
          <div class="compose" id="m-compose" style="display:none">
            <div class="compose-sender">
              <span class="compose-sender-label">Send as</span>
              <button class="sender-pill on" id="sp-server" onclick="setSender('server')">&#128226; Admin</button>
              <button class="sender-pill"    id="sp-test"   onclick="setSender('testuser')">&#129514; Test User</button>
            </div>
            <div class="compose-row">
              <textarea class="compose-inp" id="m-inp" placeholder="Type a message… (Ctrl+Enter to send)" rows="2"
                onkeydown="if(event.key==='Enter'&&event.ctrlKey){event.preventDefault();panelSend();}"></textarea>
              <button class="compose-send" id="m-send" onclick="panelSend()">Send</button>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- Devices pane -->
    <div class="pane" id="pane-devices">
      <div class="split">
        <div class="sidebar" style="width:260px">
          <div class="search-wrap" style="padding:10px 8px 6px">
            <div style="font-size:10px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--sec)">Connected Devices</div>
          </div>
          <div class="dev-scroll" id="dev-list"></div>
        </div>
        <div class="main">
          <div class="det-body" id="det-body"><div class="det-empty">Select a device</div></div>
        </div>
      </div>
    </div>

    <!-- Accounts pane -->
    <div class="pane" id="pane-accounts">
      <div class="accs-body">
        <div class="accs-sec">
          <div class="accs-sec-hdr">Chat Accounts</div>
          <div id="accs-list"><div style="color:var(--sec);font-size:13px">Loading…</div></div>
        </div>
        <div class="accs-sec">
          <div class="accs-sec-hdr">Groups</div>
          <div id="groups-list"></div>
        </div>
        <div class="accs-sec">
          <details>
            <summary>Test User tools</summary>
            <div style="padding-top:10px;display:flex;flex-direction:column;gap:8px">
              <div class="acc-item" style="gap:12px">
                <div class="acc-av" style="background:rgba(88,166,255,.12);color:#58a6ff;font-size:10px">TU</div>
                <div style="flex:1;min-width:0">
                  <div class="acc-name">Test User</div>
                  <div class="acc-key">ID: test-user — send messages &amp; accept friend requests for testing</div>
                </div>
              </div>
              <div id="tu-reqs"></div>
              <button class="abtn" onclick="testFriendAll()" style="align-self:flex-start">&#128101; Friend with all users</button>
            </div>
          </details>
        </div>
      </div>
    </div>
  </div>
</div>

<script src="https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/xterm-addon-fit@0.8.0/lib/xterm-addon-fit.min.js"></script>
<script>
const MAIN_PORT=${TEMUTALK_SERVER_PORT};
// Interpolated once here from the server-detected prefix (see
// detectPrefix() in dev-panel.js) rather than re-templated at every call
// site below -- every same-origin fetch()/WebSocket URL in this page is
// built as PREFIX+'/whatever' so it resolves correctly whether this page
// was loaded directly (:9091, PREFIX='') or through the portal
// (codecade.co.za/panel, PREFIX='/panel').
const PREFIX='${prefix}';

// ── Outer tab switching (Terminal | TemuTalk) ─────────────────────────────────
function switchMainTab(name){
  document.querySelectorAll('#main-tabbar .tab').forEach(function(t){t.classList.toggle('on',t.dataset.maintab===name);});
  document.querySelectorAll('.mainpane').forEach(function(p){p.classList.remove('on');});
  var p=document.getElementById('pane-'+name);if(p)p.classList.add('on');
}

async function logout(){await fetch(PREFIX+'/api/logout',{method:'POST'});location.reload();}

// ── Terminal ──────────────────────────────────────────────────────────────────
var term=null,fit=null,termWs=null;
function termConnect(){
  if(!term){document.getElementById('term-status').textContent='xterm not loaded';return;}
  if(termWs&&termWs.readyState<2)termWs.close();
  var proto=location.protocol==='https:'?'wss:':'ws:';
  termWs=new WebSocket(proto+'//'+location.host+PREFIX+'/terminal');
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

// ── TemuTalk tab (ported from temutalk/control-panel.js) ─────────────────────
function esc(s){return String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
function ini(s){return(String(s||'?')[0]||'?').toUpperCase();}
function avErr(el){var s=document.createElement('span');s.textContent=(el.alt||'?')[0].toUpperCase();el.parentNode.replaceChild(s,el);}
function avHtml(name,url){
  if(url)return '<img src="'+esc(url)+'" alt="'+esc(name)+'" onerror="avErr(this)">';
  return '<span>'+ini(name)+'</span>';
}
function fmtDur(ms){var s=Math.floor(ms/1000),m=Math.floor(s/60);return m+':'+String(s%60).padStart(2,'0');}
function fmtUp(s){if(s<60)return s+'s';if(s<3600)return Math.floor(s/60)+'m';return Math.floor(s/3600)+'h '+Math.floor((s%3600)/60)+'m';}
function fmtTime(ts){return new Date(ts).toLocaleTimeString(undefined,{hour:'2-digit',minute:'2-digit'});}
function fmtDate(ts){
  var d=new Date(ts),n=new Date();
  if(d.toDateString()===n.toDateString())return 'Today';
  if(d.toDateString()===new Date(n-86400000).toDateString())return 'Yesterday';
  return d.toLocaleDateString();
}

var curTab='chat',curRoom=null,curDevice=null,activeSender='server';
var adminData={connectedDevices:[],offlineDevices:[],system:null};
var spyWs=null;
var spyRooms=new Map();spyRooms.set('global',{name:'Global Chat',type:'global'});
var spyMsgs=new Map();spyMsgs.set('global',[]);
var unread=new Map(),totalUnread=0;
var chatAccounts=[];
var pmKey=null;

// ── Tab switching (scoped to #tt-tabbar/#tt-panes so it never touches the
// outer Terminal/TemuTalk tabs above) ─────────────────────────────────────────
function switchTab(name){
  curTab=name;
  document.querySelectorAll('#tt-tabbar .tab').forEach(function(t){t.classList.toggle('on',t.dataset.tab===name);});
  document.querySelectorAll('#tt-panes .pane').forEach(function(p){p.classList.remove('on');});
  var p=document.getElementById('pane-'+name);if(p)p.classList.add('on');
  if(name==='chat'){renderRooms();if(curRoom)renderMsgs();}
  if(name==='devices'){renderDeviceList();if(curDevice)selectDevice(curDevice);}
  if(name==='accounts')loadAccounts();
}

// ── Room list ─────────────────────────────────────────────────────────────────
function roomIcon(type){
  if(type==='global')return '🌐';
  if(type==='group') return '👥';
  if(type==='dm')    return '💬';
  return '💬';
}

function renderRooms(){
  var col=document.getElementById('rooms-col');if(!col)return;
  var q=(document.getElementById('room-search')?.value||'').toLowerCase().trim();
  var global=[],groups=[],dms=[];
  spyRooms.forEach(function(r,id){
    if(q&&!(r.name||id).toLowerCase().includes(q))return;
    if(id==='global')global.push([id,r]);
    else if(id.startsWith('group:'))groups.push([id,r]);
    else dms.push([id,r]);
  });

  var h='';
  function section(title,rooms){
    if(!rooms.length)return;
    h+='<div class="rs-hdr">'+esc(title)+'</div>';
    rooms.forEach(function(pair){
      var id=pair[0],r=pair[1];
      var msgs=spyMsgs.get(id)||[];
      var last=msgs[msgs.length-1];
      var badge=unread.get(id)||0;
      var sel=curRoom===id;
      h+='<div class="r-item'+(sel?' on':'')+'" onclick="selectRoom(\\''+esc(id)+'\\')">';
      h+='<div class="r-av">'+avHtml(r.name||id,null)+'<div class="r-type-badge">'+roomIcon(r.type||'dm')+'</div></div>';
      h+='<div class="r-inf">';
      h+='<div class="r-name">'+esc(r.name||id)+'</div>';
      if(last)h+='<div class="r-prev">'+esc(last.fromName||'')+(last.fromName?': ':'')+esc((last.text||'').slice(0,40))+'</div>';
      else h+='<div class="r-prev" style="opacity:.4">No messages</div>';
      h+='</div>';
      h+='<div class="r-meta">';
      if(last)h+='<div class="r-time">'+fmtTime(last.ts)+'</div>';
      if(badge)h+='<div class="r-badge">'+badge+'</div>';
      h+='</div></div>';
    });
  }
  section('Global',global);
  section('Groups',groups);
  section('Direct Messages',dms);
  if(!h)h='<div style="padding:14px;color:var(--sec);font-size:12px">No results</div>';
  col.innerHTML=h;
}

function selectRoom(id){
  var wasUnread=unread.get(id)||0;
  curRoom=id;
  totalUnread=Math.max(0,totalUnread-wasUnread);
  unread.set(id,0);
  updateChatBadge();
  renderRooms();
  var r=spyRooms.get(id)||{name:id,type:'dm'};
  var nameEl=document.getElementById('m-hdr-name');
  var typeEl=document.getElementById('m-hdr-type');
  var clearBtn=document.getElementById('clear-btn');
  var compose=document.getElementById('m-compose');
  if(nameEl)nameEl.textContent=r.name||id;
  if(typeEl){
    var labels={global:'Global',group:'Group',dm:'DM'};
    typeEl.textContent=roomIcon(r.type||'dm')+' '+(labels[r.type]||'DM');
    typeEl.style.display='';
  }
  if(clearBtn)clearBtn.style.display='';
  if(compose)compose.style.display='';
  renderMsgs();
}

// ── Messages ──────────────────────────────────────────────────────────────────
function renderMsgs(){
  var wrap=document.getElementById('msgs-wrap');if(!wrap)return;
  if(!curRoom){
    wrap.innerHTML='<div class="msg-empty"><div class="msg-empty-ico">&#128172;</div><div>Select a conversation from the sidebar</div></div>';
    return;
  }
  var msgs=spyMsgs.get(curRoom)||[];
  if(!msgs.length){
    wrap.innerHTML='<div class="msg-empty"><div class="msg-empty-ico">&#128172;</div><div>No messages yet</div></div>';
    return;
  }
  var h='',lastDate='';
  msgs.forEach(function(m){
    var d=fmtDate(m.ts);
    if(d!==lastDate){h+='<div class="date-row"><span class="date-chip">'+esc(d)+'</span></div>';lastDate=d;}
    h+=buildMsgRow(m);
  });
  wrap.innerHTML=h;
  wrap.scrollTop=wrap.scrollHeight;
}

function buildMsgRow(m){
  var isAdmin=m.from==='panel-bot'||m.isPanelMsg;
  var av=isAdmin
    ?'<div class="r-av" style="background:rgba(210,153,34,.15);color:#d29922">&#128226;</div>'
    :'<button class="m-av-btn" onclick="pmOpen(\\''+esc((m.fromName||'').toLowerCase())+'\\')"><div class="r-av">'+avHtml(m.fromName,m.avatarUrl)+'</div></button>';
  var sender=isAdmin
    ?'<span class="m-sender-name admin-label">Server <span style="font-size:10px;background:rgba(210,153,34,.15);color:#d29922;border-radius:3px;padding:1px 5px">ADMIN</span></span>'
    :'<button class="m-sender-name" onclick="pmOpen(\\''+esc((m.fromName||'').toLowerCase())+'\\')">'+esc(m.fromName||'Unknown')+'</button>';
  var bubbleCls='bubble'+(isAdmin?' admin':'');
  return '<div class="m-row">'+av+'<div class="m-bubble-col">'+sender
    +'<span class="'+bubbleCls+'">'+esc(m.text||'')+'<span class="m-time">'+fmtTime(m.ts)+'</span></span>'
    +'</div></div>';
}

function appendMsg(m){
  var wrap=document.getElementById('msgs-wrap');if(!wrap)return;
  var empty=wrap.querySelector('.msg-empty');if(empty)wrap.innerHTML='';
  var row=document.createElement('div');
  row.innerHTML=buildMsgRow(m);
  wrap.appendChild(row.firstChild);
  wrap.scrollTop=wrap.scrollHeight;
}

// ── Clear (actually persists to server) ──────────────────────────────────────
async function clearRoom(){
  if(!curRoom)return;
  var name=spyRooms.get(curRoom)?.name||curRoom;
  if(!confirm('Clear all messages in "'+name+'"? This cannot be undone.'))return;
  var btn=document.getElementById('clear-btn');
  if(btn)btn.disabled=true;
  try{
    var r=await fetch(PREFIX+'/api/clear-room',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({room:curRoom})});
    var d=await r.json();
    if(!d.ok)alert(d.error||'Failed to clear');
  }catch(e){alert('Error: '+e.message);}
  if(btn)btn.disabled=false;
}

// ── Compose ───────────────────────────────────────────────────────────────────
function setSender(mode){
  activeSender=mode;
  document.getElementById('sp-server').classList.toggle('on',mode==='server');
  document.getElementById('sp-test').classList.toggle('on',mode==='testuser');
}

async function panelSend(){
  var room=curRoom;
  var inp=document.getElementById('m-inp');
  var text=(inp?.value||'').trim();
  if(!room||!text)return;
  var btn=document.getElementById('m-send');if(btn)btn.disabled=true;
  try{
    var endpoint=PREFIX+(activeSender==='testuser'?'/api/test-msg':'/api/panel-broadcast');
    var r=await fetch(endpoint,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({room:room,text:text})});
    var d=await r.json();
    if(d.ok){if(inp)inp.value='';inp?.focus();}
    else alert(d.error||'Failed');
  }catch(e){alert('Error: '+e.message);}
  if(btn)btn.disabled=false;
}

// ── Unread badge ──────────────────────────────────────────────────────────────
function updateChatBadge(){
  var el=document.getElementById('chat-badge');
  if(!el)return;
  el.textContent=totalUnread;
  el.style.display=totalUnread?'':'none';
}

// ── Devices ───────────────────────────────────────────────────────────────────
function renderDeviceList(){
  var col=document.getElementById('dev-list');if(!col)return;
  var devs=adminData.connectedDevices||[];
  var badge=document.getElementById('dev-badge');
  if(badge){badge.textContent=devs.length;badge.style.display=devs.length?'':'none';}
  if(!devs.length){col.innerHTML='<div style="color:var(--sec);font-size:12px;padding:4px">No devices connected</div>';return;}
  var h='';
  devs.forEach(function(d){
    var name=(d.user&&d.user.displayName)||d.deviceId.slice(0,10)+'…';
    var track=d.player&&d.player.track;
    var sub=d.radio?'&#128191; '+esc(d.radio.name||'Radio'):track?'&#9654; '+esc(track.name):'Connected';
    var sel=curDevice===d.deviceId;
    h+='<div class="dev-card'+(sel?' on':'')+'" onclick="selectDevice(\\''+esc(d.deviceId)+'\\')">';
    h+='<div class="dev-av"><span>'+ini(name)+'</span><div class="dev-dot"></div></div>';
    h+='<div class="dev-inf"><div class="dev-name">'+esc(name)+'</div>';
    h+='<div class="dev-sub">'+sub+'</div>';
    h+='<div class="pills">';
    if(d.authenticated)h+='<span class="pill pg">Spotify</span>';
    h+='<span class="pill pb">'+(d.tabs||0)+' tab'+(d.tabs!==1?'s':'')+'</span>';
    if(d.player&&d.player.isPlaying)h+='<span class="pill pg">Playing</span>';
    h+='</div></div></div>';
  });
  col.innerHTML=h;
}

function selectDevice(id){
  curDevice=id;
  renderDeviceList();
  var all=(adminData.connectedDevices||[]).concat(adminData.offlineDevices||[]);
  var d=null;for(var i=0;i<all.length;i++){if(all[i].deviceId===id){d=all[i];break;}}
  var body=document.getElementById('det-body');if(!body)return;
  if(!d){body.innerHTML='<div class="det-empty">Device not found</div>';return;}
  var name=(d.user&&d.user.displayName)||d.deviceId.slice(0,10)+'…';
  var p=d.player,t=p&&p.track;
  var h='';
  h+='<div class="det-card"><div class="det-title">Connection</div>';
  h+='<div class="det-row"><span class="det-k">Device ID</span><span class="det-v" style="font-family:ui-monospace,monospace;font-size:11px">'+esc(d.deviceId.slice(0,24))+'…</span></div>';
  h+='<div class="det-row"><span class="det-k">IP</span><span class="det-v">'+esc((d.ips||[]).join(', ')||'Unknown')+'</span></div>';
  h+='<div class="det-row"><span class="det-k">Tabs open</span><span class="det-v">'+(d.tabs||0)+'</span></div>';
  h+='<div class="det-row"><span class="det-k">Spotify</span><span class="det-v">'+(d.authenticated?'<span class="pill pg">Linked</span>':'<span class="pill pn">Not linked</span>')+'</span></div></div>';
  if(d.user){
    h+='<div class="det-card"><div class="det-title">Spotify Account</div>';
    h+='<div class="det-row"><span class="det-k">Name</span><span class="det-v">'+esc(d.user.displayName||'Unknown')+'</span></div>';
    h+='<div class="det-row"><span class="det-k">Email</span><span class="det-v">'+esc(d.user.email||'Unknown')+'</span></div>';
    h+='<div class="det-row"><span class="det-k">Plan</span><span class="det-v">'+esc(d.user.product||'Unknown')+'</span></div></div>';
  }
  if(t){
    var pct=t.durationMs?Math.min(100,(t.progressMs||0)/t.durationMs*100).toFixed(1):0;
    h+='<div class="det-card"><div class="det-title">Now Playing</div>';
    h+='<div class="alb-row">';
    h+=t.albumArt?'<img class="alb-img" src="'+esc(t.albumArt)+'" onerror="this.style.display=\\'none\\'">':'<div class="alb-img"></div>';
    h+='<div><div class="t-name">'+esc(t.name)+'</div><div class="t-sub">'+esc(t.artists||'')+'</div><div class="t-sub">'+esc(t.album||'')+'</div></div></div>';
    h+='<div class="prog"><div class="prog-f" style="width:'+pct+'%"></div></div>';
    h+='<div class="det-row"><span class="det-k">State</span><span>'+(p.isPlaying?'<span class="pill pg">&#9654; Playing</span>':'<span class="pill pn">Paused</span>')+'</span></div>';
    h+='<div class="det-row"><span class="det-k">Progress</span><span class="det-v">'+fmtDur(t.progressMs||0)+' / '+fmtDur(t.durationMs||0)+'</span></div>';
    if(p.device)h+='<div class="det-row"><span class="det-k">Output</span><span class="det-v">'+esc(p.device.name)+' ('+esc(p.device.type)+')</span></div>';
    h+='</div>';
  }
  if(d.radio){
    h+='<div class="det-card"><div class="det-title">Radio</div>';
    h+='<div class="det-row"><span class="det-k">Station</span><span class="det-v">'+esc(d.radio.name||'Unknown')+'</span></div></div>';
  }
  body.innerHTML=h;
}

// ── Admin data polling ────────────────────────────────────────────────────────
async function refreshAdmin(){
  try{
    var r=await fetch(PREFIX+'/api/admin');
    if(r.status===401){location.reload();return;}
    var j=await r.json();
    if(!j.overview)return;
    adminData=j.overview;
    var sys=adminData.system;
    var statsEl=document.getElementById('hdr-stats');
    if(statsEl&&sys){
      var load=sys.loadAvg&&sys.loadAvg[0]?sys.loadAvg[0].toFixed(2):'?';
      var loadColor=parseFloat(load)>2?'var(--red)':parseFloat(load)>1?'var(--ylw)':'var(--grn)';
      statsEl.innerHTML=
        '<div class="stat-chip">&#128421; '+esc(sys.hostname)+'</div>'+
        '<div class="stat-chip">&#9201; up '+fmtUp(sys.uptime)+'</div>'+
        '<div class="stat-chip"><div class="dot" style="background:'+loadColor+'"></div>load '+load+'</div>'+
        '<div class="stat-chip">RAM '+sys.memPct+'%</div>';
    }
    var n=(adminData.connectedDevices||[]).length;
    var badge=document.getElementById('dev-badge');
    if(badge){badge.textContent=n;badge.style.display=n?'':'none';}
    if(curTab==='devices'){renderDeviceList();if(curDevice)selectDevice(curDevice);}
  }catch(e){}
}

// ── Accounts ──────────────────────────────────────────────────────────────────
async function loadAccounts(){
  try{
    var r=await fetch(PREFIX+'/api/chat-accounts');
    if(!r.ok){document.getElementById('accs-list').innerHTML='<div style="color:var(--sec);font-size:13px">Could not load</div>';return;}
    var d=await r.json();
    chatAccounts=d.accounts||[];
    renderAccounts();
    renderGroups(d.groups||[]);
    loadTestReqs();
  }catch(e){}
}

function renderAccounts(){
  var el=document.getElementById('accs-list');if(!el)return;
  if(!chatAccounts.length){el.innerHTML='<div style="color:var(--sec);font-size:13px">No chat users yet</div>';return;}
  var h='';
  chatAccounts.forEach(function(a){
    h+='<div class="acc-item">';
    h+='<div class="acc-av">'+avHtml(a.name,a.avatarUrl)+'</div>';
    h+='<div style="flex:1;min-width:0"><div class="acc-name">'+esc(a.name)+'</div><div class="acc-key">'+esc(a.key)+'</div></div>';
    h+='<button class="abtn" onclick="pmOpen(\\''+esc(a.key)+'\\')">&#9998; Edit</button>';
    h+='</div>';
  });
  el.innerHTML=h;
}

function renderGroups(groups){
  var el=document.getElementById('groups-list');if(!el)return;
  if(!groups.length){el.innerHTML='<div style="color:var(--sec);font-size:13px">No groups yet</div>';return;}
  var h='';
  groups.forEach(function(g){
    h+='<div class="acc-item">';
    h+='<div class="acc-av" style="font-size:.9rem">&#128101;</div>';
    h+='<div style="flex:1;min-width:0"><div class="acc-name">'+esc(g.name)+'</div><div class="acc-key">'+g.memberCount+' member'+(g.memberCount!==1?'s':'')+'</div></div>';
    h+='<button class="abtn danger" onclick="deleteGroup(\\''+esc(g.id)+'\\')">&#128465;</button>';
    h+='</div>';
  });
  el.innerHTML=h;
}

async function deleteGroup(id){
  if(!confirm('Delete this group and all its messages?'))return;
  try{
    var r=await fetch(PREFIX+'/api/admin/chat-group/'+encodeURIComponent(id),{method:'DELETE'});
    var d=await r.json();
    if(d.ok)loadAccounts();else alert(d.error||'Delete failed');
  }catch(e){alert('Error: '+e.message);}
}

// ── Test user ─────────────────────────────────────────────────────────────────
async function loadTestReqs(){
  try{
    var r=await fetch(PREFIX+'/api/test-friend-reqs');
    var d=await r.json();
    var el=document.getElementById('tu-reqs');if(!el)return;
    var reqs=d.reqs||[];
    if(!reqs.length){el.innerHTML='<div style="color:var(--sec);font-size:12px">No pending friend requests</div>';return;}
    var h='<div style="font-size:11px;color:var(--sec);margin-bottom:6px">Pending friend requests:</div>';
    reqs.forEach(function(req){
      h+='<div class="acc-item" style="padding:8px 10px"><div class="acc-av" style="width:26px;height:26px">'
        +(req.avatarUrl?'<img src="'+esc(req.avatarUrl)+'" alt="" style="width:100%;height:100%;object-fit:cover;border-radius:50%">':'<span>'+ini(req.name)+'</span>')
        +'</div><div style="flex:1;min-width:0"><div class="acc-name">'+esc(req.name)+'</div></div>'
        +'<button class="abtn" onclick="testAcceptReq(\\''+esc(req.id)+'\\')">Accept</button></div>';
    });
    el.innerHTML=h;
  }catch(e){}
}

async function testFriendAll(){
  try{
    var r=await fetch(PREFIX+'/api/test-friend-all',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});
    var d=await r.json();
    if(d.ok)alert('Friended '+d.count+' user(s) with Test User.');
    else alert(d.error||'Failed');
  }catch(e){alert('Error: '+e.message);}
}

async function testAcceptReq(fromId){
  try{
    var r=await fetch(PREFIX+'/api/test-accept-req',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({fromId:fromId})});
    var d=await r.json();
    if(d.ok)loadTestReqs();else alert(d.error||'Failed');
  }catch(e){alert('Error: '+e.message);}
}

// ── Profile modal ─────────────────────────────────────────────────────────────
function pmOpen(key){
  pmKey=key;
  var acc=chatAccounts.find(function(a){return a.key===key;})||{name:key,avatarUrl:null};
  document.getElementById('pm-name').value=acc.name||'';
  document.getElementById('pm-avatar-url').value=acc.avatarUrl||'';
  document.getElementById('pm-msg').textContent='';
  pmPreview();
  document.getElementById('pm-overlay').classList.add('vis');
}
function pmClose(){document.getElementById('pm-overlay').classList.remove('vis');pmKey=null;}
function pmPreview(){
  var u=document.getElementById('pm-avatar-url').value;
  var n=document.getElementById('pm-name').value||pmKey||'?';
  document.getElementById('pm-av').innerHTML=avHtml(n,u||null);
}
async function pmSave(){
  if(!pmKey)return pmClose();
  var btn=document.getElementById('pm-save'),msg=document.getElementById('pm-msg');
  btn.disabled=true;msg.style.color='';msg.textContent='Saving…';
  var body={key:pmKey,name:document.getElementById('pm-name').value.trim(),avatarUrl:document.getElementById('pm-avatar-url').value.trim()||null};
  try{
    var r=await fetch(PREFIX+'/api/chat-account',{method:'PATCH',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
    var d=await r.json();
    if(d.ok){
      msg.style.color='#3fb950';msg.textContent='Saved';
      var idx=chatAccounts.findIndex(function(a){return a.key===pmKey;});
      if(idx>=0){chatAccounts[idx].name=d.name;chatAccounts[idx].avatarUrl=d.avatarUrl;}
      renderAccounts();setTimeout(pmClose,700);
    }else{msg.style.color='#f85149';msg.textContent=d.error||'Failed';}
  }catch(e){msg.style.color='#f85149';msg.textContent='Error: '+e.message;}
  btn.disabled=false;
}

// ── Header actions ────────────────────────────────────────────────────────────
async function doRestart(){
  var btn=document.getElementById('restart-btn');
  btn.textContent='Restarting…';btn.disabled=true;
  try{var r=await fetch(PREFIX+'/api/restart-server',{method:'POST'});var d=await r.json();btn.textContent=d.ok?'Done ✓':'Failed';}
  catch(e){btn.textContent='Error';}
  setTimeout(function(){btn.innerHTML='&#8635; Restart';btn.disabled=false;},3000);
}

// ── Ghost spy WebSocket ───────────────────────────────────────────────────────
async function spyConnect(){
  if(spyWs&&spyWs.readyState<2)return;
  try{
    var r=await fetch(PREFIX+'/api/ghost-token');if(!r.ok)return;
    var j=await r.json();if(!j.token)return;
    var proto=location.protocol==='https:'?'wss:':'ws:';
    var ghostId='ghost-'+Math.random().toString(36).slice(2);
    // Deliberately NOT run through PREFIX/the portal -- this connects
    // straight to temutalk's own port (MAIN_PORT), which is only reachable
    // when this page itself is loaded directly off the host (:9091, same
    // LAN/machine). Loaded through codecade.co.za/panel, location.hostname
    // is the public domain and this raw port was never tunneled (only the
    // portal's own port is), so the ghost-spy live chat view specifically
    // won't connect over that path -- everything else on this page (login,
    // terminal, the rest of the TemuTalk admin tab's REST calls) still
    // works fine either way, since those all go through PREFIX-aware
    // fetch()/'/terminal' above instead of a raw host:port.
    var wsHost=location.hostname+':'+MAIN_PORT;
    spyWs=new WebSocket(proto+'//'+wsHost);
    spyWs.onopen=function(){
      spyWs.send(JSON.stringify({type:'join',deviceId:ghostId}));
      spyWs.send(JSON.stringify({type:'chat:ghost-join',token:j.token}));
    };
    spyWs.onmessage=function(e){try{spyMsg(JSON.parse(e.data));}catch(err){}};
    spyWs.onclose=function(){setTimeout(spyConnect,5000);};
    spyWs.onerror=function(){spyWs.close();};
  }catch(e){}
}

function spyMsg(m){
  if(m.type==='chat:ghost-state'){
    spyMsgs.set('global',m.global||[]);
    (m.groups||[]).forEach(function(g){
      spyRooms.set(g.id,{name:g.name,type:'group'});
      spyMsgs.set(g.id,g.messages||[]);
    });
    (m.dms||[]).forEach(function(d){
      var msgs=d.messages||[];
      var parts=[...new Set(msgs.map(function(msg){return msg.fromName||'';}))].filter(Boolean);
      spyRooms.set(d.room,{name:parts.length?parts.join(' ↔ '):'DM',type:'dm'});
      spyMsgs.set(d.room,msgs);
    });
    if(curTab==='chat')renderRooms();
    if(curRoom)renderMsgs();
    if(!curRoom)selectRoom('global');
    return;
  }
  if(m.type==='chat:msg'){
    if(!spyMsgs.has(m.room))spyMsgs.set(m.room,[]);
    spyMsgs.get(m.room).push(m);
    if(curRoom===m.room)appendMsg(m);
    else{
      var n=(unread.get(m.room)||0)+1;
      unread.set(m.room,n);
      if(curTab!=='chat'){totalUnread++;updateChatBadge();}
      if(curTab==='chat')renderRooms();
    }
    return;
  }
  if(m.type==='chat:group-created'){
    spyRooms.set(m.group.id,{name:m.group.name,type:'group'});
    spyMsgs.set(m.group.id,[]);
    if(curTab==='chat')renderRooms();
    return;
  }
  if(m.type==='chat:group-deleted'){
    spyRooms.delete(m.groupId);spyMsgs.delete(m.groupId);
    if(curRoom===m.groupId){curRoom=null;renderRooms();renderMsgs();}
    return;
  }
  if(m.type==='chat:clear'){
    spyMsgs.set(m.room,[]);
    if(curRoom===m.room)renderMsgs();
    return;
  }
}

// ── Boot -- both tabs run in the background regardless of which is active,
// same as the original two panels did in isolation ────────────────────────────
initTerm();
renderRooms();
refreshAdmin();
setInterval(refreshAdmin,4000);
spyConnect();
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
  const pathname = new URL(req.url, 'http://x').pathname;
  const prefix = detectPrefix(pathname);
  const routePath = prefix ? (pathname.slice(prefix.length) || '/') : pathname;
  if (routePath === '/terminal' && isAuthed(req)) {
    wss.handleUpgrade(req, socket, head, ws => handleTerminalWs(ws));
  } else {
    socket.destroy();
  }
}

// ─── Request handler ──────────────────────────────────────────────────────────
async function handleRequest(req, res) {
  securityHeaders(res);
  const url = new URL(req.url, 'https://localhost');
  const prefix = detectPrefix(url.pathname);
  // Route matching below stays written exactly as it always was (bare
  // paths like '/api/login') by stripping the prefix here, once, up
  // front -- prefix only needs re-adding when generating a response
  // (page()/loginPage()'s emitted links, cookie Path).
  if (prefix) url.pathname = url.pathname.slice(prefix.length) || '/';
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
        res.setHeader('Set-Cookie', `panel_session=${signSession(payload)}; Path=${prefix || '/'}; HttpOnly; Secure; SameSite=Strict; Max-Age=${Math.floor(SESSION_TTL_MS / 1000)}`);
        sendJson(res, 200, { ok: true });
      } else {
        recordFailure(ip);
        sendJson(res, 401, { error: 'Invalid key file' });
      }
    });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/logout') {
    res.setHeader('Set-Cookie', `panel_session=; Path=${prefix || '/'}; HttpOnly; Secure; SameSite=Strict; Max-Age=0`);
    sendJson(res, 200, { ok: true });
    return;
  }

  if (url.pathname === '/') {
    if (isAuthed(req)) {
      refreshSession(req, res, prefix);
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(page(prefix));
    } else {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(loginPage(prefix));
    }
    return;
  }

  if (!isAuthed(req)) { sendJson(res, 401, { error: 'Not authenticated' }); return; }
  refreshSession(req, res, prefix);

  // ── TemuTalk tab: proxied to temutalk's own server ──────────────────────────
  if (req.method === 'GET' && url.pathname === '/api/admin') {
    const overview = await fetchServerJson('/api/admin/overview');
    sendJson(res, 200, { overview });
    return;
  }

  if (req.method === 'GET' && url.pathname === '/api/ghost-token') {
    const data = await fetchServerJson('/api/admin/ghost-token');
    sendJson(res, data ? 200 : 502, data || { error: 'Main server unavailable' });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/restart-server') {
    try {
      const pidFile = path.join(TEMUTALK_RUN_DIR, 'launcher.pid');
      const pid = parseInt(fs.readFileSync(pidFile, 'utf8').trim(), 10);
      if (!pid) { sendJson(res, 503, { error: 'Launcher PID not found' }); return; }
      process.kill(pid, 'SIGUSR1');
      sendJson(res, 200, { ok: true });
    } catch (e) {
      sendJson(res, 503, { error: e.message });
    }
    return;
  }

  if (req.method === 'GET' && url.pathname === '/api/chat-accounts') {
    const data = await callServerJson('/api/admin/chat-accounts');
    sendJson(res, data ? 200 : 502, data || { error: 'unavailable' });
    return;
  }

  if (req.method === 'PATCH' && url.pathname === '/api/chat-account') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const parsed = JSON.parse(body);
        const data = await callServerJson('/api/admin/chat-account', 'PATCH', parsed);
        sendJson(res, data ? 200 : 502, data || { error: 'unavailable' });
      } catch (e) { sendJson(res, 400, { error: e.message }); }
    });
    return;
  }

  if (req.method === 'DELETE' && url.pathname.startsWith('/api/admin/chat-group/')) {
    const groupId = decodeURIComponent(url.pathname.slice('/api/admin/chat-group/'.length));
    const data = await callServerJson(`/api/admin/chat-group/${encodeURIComponent(groupId)}`, 'DELETE');
    sendJson(res, data ? 200 : 502, data || { error: 'unavailable' });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/panel-broadcast') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const parsed = JSON.parse(body);
        const data = await callServerJson('/api/admin/panel-broadcast', 'POST', parsed);
        sendJson(res, data ? 200 : 502, data || { error: 'unavailable' });
      } catch (e) { sendJson(res, 400, { error: e.message }); }
    });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/clear-room') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const parsed = JSON.parse(body);
        const data = await callServerJson('/api/admin/clear-room', 'POST', parsed);
        sendJson(res, data ? 200 : 502, data || { error: 'unavailable' });
      } catch (e) { sendJson(res, 400, { error: e.message }); }
    });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/test-msg') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const parsed = JSON.parse(body);
        const data = await callServerJson('/api/admin/test-msg', 'POST', parsed);
        sendJson(res, data ? 200 : 502, data || { error: 'unavailable' });
      } catch (e) { sendJson(res, 400, { error: e.message }); }
    });
    return;
  }

  if (req.method === 'GET' && url.pathname === '/api/test-friend-reqs') {
    const data = await callServerJson('/api/admin/test-friend-reqs');
    sendJson(res, data ? 200 : 502, data || { error: 'unavailable' });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/test-accept-req') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const parsed = JSON.parse(body);
        const data = await callServerJson('/api/admin/test-accept-req', 'POST', parsed);
        sendJson(res, data ? 200 : 502, data || { error: 'unavailable' });
      } catch (e) { sendJson(res, 400, { error: e.message }); }
    });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/test-friend-all') {
    const data = await callServerJson('/api/admin/test-friend-all', 'POST', {});
    sendJson(res, data ? 200 : 502, data || { error: 'unavailable' });
    return;
  }

  if (req.method === 'GET' && url.pathname === '/api/env') {
    const KEYS = ['DISCORD_CLIENT_ID', 'DISCORD_CLIENT_SECRET', 'GOOGLE_CLIENT_ID', 'GOOGLE_CLIENT_SECRET'];
    const result = {};
    try {
      for (const line of fs.readFileSync(TEMUTALK_ENV_FILE, 'utf8').split('\n')) {
        const m = line.match(/^([A-Z_]+)=(.*)$/);
        if (m && KEYS.includes(m[1])) result[m[1]] = m[2].trim();
      }
    } catch {}
    sendJson(res, 200, result);
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/env') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', () => {
      try {
        const updates = JSON.parse(body);
        const KEYS = ['DISCORD_CLIENT_ID', 'DISCORD_CLIENT_SECRET', 'GOOGLE_CLIENT_ID', 'GOOGLE_CLIENT_SECRET'];
        let lines = [];
        try { lines = fs.readFileSync(TEMUTALK_ENV_FILE, 'utf8').split('\n'); } catch {}
        for (const key of KEYS) {
          if (!(key in updates)) continue;
          const val = String(updates[key]);
          const idx = lines.findIndex(l => l.match(new RegExp(`^${key}=`)));
          if (idx >= 0) lines[idx] = `${key}=${val}`; else lines.push(`${key}=${val}`);
        }
        fs.writeFileSync(TEMUTALK_ENV_FILE, lines.join('\n'));
        try {
          const pid = parseInt(fs.readFileSync(path.join(TEMUTALK_RUN_DIR, 'launcher.pid'), 'utf8').trim(), 10);
          if (pid) process.kill(pid, 'SIGUSR1');
        } catch {}
        sendJson(res, 200, { ok: true });
      } catch (e) { sendJson(res, 400, { error: e.message }); }
    });
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
server.listen(PORT, '0.0.0.0', () => console.log(`Dev panel on https://0.0.0.0:${PORT} (terminal -> ${INSTALL_SH}, temutalk -> 127.0.0.1:${TEMUTALK_SERVER_PORT})`));
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

  # Portable Node.js/npm first — every app below (portal, git-forge,
  # tag-relay, remote-admin, temutalk) needs it, and this is the one thing
  # that has to exist before find_npm() can find anything.
  ensure_portable_node
  ensure_portable_cloudflared

  local npm_bin; npm_bin=$(find_npm)
  if [ -z "$npm_bin" ]; then
    err "npm not found — portable Node.js download must have failed (see error.log above)."
    exit 1
  fi

  # --no-bin-links: this whole tree is designed to run from a portable USB
  # drive, which is usually exFAT/FAT32 for cross-OS compatibility -- those
  # filesystems can't hold symlinks at all, and npm's node_modules/.bin
  # wrapper scripts are symlinks. None of these apps are started via a
  # package.json bin script (all launched as `node server.js` directly), so
  # skipping bin-link creation costs nothing and avoids EPERM on install.
  info "Installing portal dependencies..."
  run_capturing "portal-npm-install" bash -c "cd '$DIR/portal' && '$npm_bin' install --no-audit --no-fund --no-bin-links --loglevel=error" \
    && ok "Portal dependencies installed."

  info "Installing git-forge dependencies..."
  run_capturing "git-forge-npm-install" bash -c "cd '$DIR/git-forge' && '$npm_bin' install --no-audit --no-fund --no-bin-links --loglevel=error" \
    && ok "git-forge dependencies installed."

  if [ -d "$DIR/tag/relay-server" ]; then
    info "Installing tag relay-server dependencies..."
    run_capturing "tag-relay-npm-install" bash -c "cd '$DIR/tag/relay-server' && '$npm_bin' install --no-audit --no-fund --no-bin-links --loglevel=error" \
      && ok "tag relay-server dependencies installed."
  else
    warn "tag/relay-server not found in the tag repo checkout — skipping."
  fi

  if [ -d "$DIR/remote-admin" ]; then
    info "Installing remote-admin dependencies..."
    run_capturing "remote-admin-npm-install" bash -c "cd '$DIR/remote-admin' && '$npm_bin' install --no-audit --no-fund --no-bin-links --loglevel=error" \
      && ok "remote-admin dependencies installed."
  else
    warn "remote-admin not found — skipping."
  fi

  info "Setting up temutalk (ffmpeg, Piper voice, USB key)..."
  ensure_ffmpeg
  ensure_temutalk_npm_deps
  ensure_temutalk_piper
  setup_temutalk_usb_key

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

  # temutalk/git-forge/tag are git checkouts; portal/remote-admin/.bin aren't
  # (portal is install.sh-generated, remote-admin lives directly in this
  # repo, .bin is the portable Node/cloudflared/ffmpeg downloads) -- all six
  # need to travel with the bundle for the destination to actually be
  # self-contained, not just the three git repos.
  for name in temutalk git-forge tag portal remote-admin .bin; do
    [ -d "$DIR/$name" ] || continue
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
    nohup "$node_bin" server.js >> "$DIR/service.log" 2>&1 & echo "$(detect_os):$!" > "$(pid_file forge)" )
  sleep 1
  if proc_running forge; then ok "git-forge started (PID $(proc_pid forge)) → :$FORGE_PORT"
  else snapshot_log_on_failure "forge-start" "$DIR/service.log"; fi
}

start_tag_relay() {
  if proc_running tag-relay; then warn "tag relay-server already running."; return; fi
  if [ ! -d "$DIR/tag/relay-server/node_modules" ]; then warn "tag/relay-server/node_modules missing — run setup first."; return; fi
  local node_bin; node_bin=$(find_node)
  if [ -z "$node_bin" ]; then err "node not found on PATH."; return; fi
  ( cd "$DIR/tag/relay-server" && BASE_PATH=/tag PORT="$TAG_RELAY_PORT" \
    nohup "$node_bin" server.js >> "$DIR/service.log" 2>&1 & echo "$(detect_os):$!" > "$(pid_file tag-relay)" )
  sleep 1
  if proc_running tag-relay; then ok "tag relay-server started (PID $(proc_pid tag-relay)) → :$TAG_RELAY_PORT"
  else snapshot_log_on_failure "tag-relay-start" "$DIR/service.log"; fi
}

# Token-authenticated exec/file-transfer service -- an SSH replacement for
# when direct SSH access to this machine is unreliable (see remote-admin.js
# for the actual endpoints and the auth model). Binds to 127.0.0.1 only by
# design; anything beyond that (LAN, or a Cloudflare Tunnel ingress rule) is
# a deliberate, separate step, not something this script does for you.
start_remote_admin() {
  if proc_running remote-admin; then warn "remote-admin already running."; return; fi
  if [ ! -d "$DIR/remote-admin/node_modules" ]; then warn "remote-admin/node_modules missing — run setup first."; return; fi
  local node_bin; node_bin=$(find_node)
  if [ -z "$node_bin" ]; then err "node not found on PATH."; return; fi
  ( cd "$DIR/remote-admin" && \
    nohup "$node_bin" remote-admin.js >> "$DIR/service.log" 2>&1 & echo "$(detect_os):$!" > "$(pid_file remote-admin)" )
  sleep 1
  if proc_running remote-admin; then ok "remote-admin started (PID $(proc_pid remote-admin)) → 127.0.0.1:3099"
  else snapshot_log_on_failure "remote-admin-start" "$DIR/service.log"; fi
}

# ─── TemuTalk's own setup steps, merged in from what used to be a separate
# temutalk/install.sh (deleted -- one install.sh for everything now, not one
# per app). ffmpeg/portable-Node/cloudflared/Piper/USB-key logic below is a
# direct port of what that script did, plus a real fix for the Piper
# symlink bug (see ensure_temutalk_piper).

# Static build (no root, no package manager) -- johnvansickle.com for Linux,
# gyan.dev's "essentials" build (a stable always-latest URL, by design meant
# for exactly this kind of automation) for Windows. Same "download once, no
# system deps" approach as Node.js/cloudflared/Piper below. Falls back to the
# host's package manager only if the download fails (offline mirror, etc) --
# no such fallback exists on Windows, so a failure there just stays a warning
# (ffmpeg is optional: only temutalk's audio features need it).
ensure_ffmpeg() {
  command -v ffmpeg >/dev/null 2>&1 && { ok "ffmpeg already installed."; return; }
  local ffmpeg_bin_name="ffmpeg"; [ "$(detect_os)" = "windows" ] && ffmpeg_bin_name="ffmpeg.exe"
  if [ -x "$DIR/.bin/$ffmpeg_bin_name" ]; then ok "Portable ffmpeg already present."; return; fi

  local os arch ff_arch
  os=$(detect_os)
  arch=$(uname -m)
  mkdir -p "$DIR/.bin"
  local tmp; tmp="$(mktemp -d 2>/dev/null)" || tmp="$DIR/.bin/.ffmpeg-dl-$$"
  mkdir -p "$tmp"

  if [ "$os" = "windows" ]; then
    info "Downloading portable ffmpeg (Windows)..."
    if dl_curl -o "$tmp/ffmpeg.zip" \
         "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip" \
       && extract_zip_stripped "$tmp/ffmpeg.zip" "$tmp/extracted" \
       && cp "$tmp/extracted/bin/ffmpeg.exe" "$DIR/.bin/ffmpeg.exe"; then
      rm -rf "$tmp"
      ok "Portable ffmpeg ready."
      return
    fi
    rm -rf "$tmp"
    warn "Portable ffmpeg download failed — no package-manager fallback on Windows. Skipping (only affects temutalk audio features)."
    return
  fi

  case "$arch" in
    aarch64|arm64) ff_arch=arm64  ;;
    armv7*|armhf)  ff_arch=armhf  ;;
    *)             ff_arch=amd64  ;;
  esac
  info "Downloading portable ffmpeg ($ff_arch)..."
  if dl_curl -o "$tmp/ffmpeg.tar.xz" \
       "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-${ff_arch}-static.tar.xz" \
     && tar -xJf "$tmp/ffmpeg.tar.xz" -C "$tmp" \
     && cp "$tmp"/ffmpeg-*-static/ffmpeg "$DIR/.bin/ffmpeg"; then
    chmod +x "$DIR/.bin/ffmpeg"
    rm -rf "$tmp"
    ok "Portable ffmpeg ready."
    return
  fi
  rm -rf "$tmp"

  warn "Portable ffmpeg download failed — falling back to the system package manager."
  if pkg_install ffmpeg && command -v ffmpeg >/dev/null 2>&1; then
    ok "Installed ffmpeg via package manager."
  else
    err "Could not install ffmpeg (portable download and package manager both failed)."
  fi
}
find_ffmpeg() {
  [ -x "$DIR/.bin/ffmpeg" ] && { echo "$DIR/.bin/ffmpeg"; return; }
  [ -x "$DIR/.bin/ffmpeg.exe" ] && { echo "$DIR/.bin/ffmpeg.exe"; return; }
  command -v ffmpeg 2>/dev/null
}

# Portable Node.js runtime shared by every app in the stack (portal,
# git-forge, tag-relay, remote-admin, temutalk) -- no system Node.js/npm
# install required, on Linux or Windows. Extracts the FULL upstream archive
# (not just the node binary) because npm itself lives alongside it --
# lib/node_modules/npm/ on Linux, node_modules/npm/ on Windows.
ensure_portable_node() {
  local os arch node_arch
  os=$(detect_os)
  arch=$(uname -m)
  case "$arch" in
    aarch64|arm64) node_arch=arm64  ;;
    arm*)          node_arch=armv7l ;;
    *)             node_arch=x64    ;;
  esac
  # Node has no 32-bit-ARM Windows build -- best-effort fall back to arm64.
  [ "$os" = "windows" ] && [ "$node_arch" = "armv7l" ] && node_arch=arm64

  mkdir -p "$DIR/.bin"

  # *_rel are relative to $DIR/.bin/ -- used inside the wrapper scripts below
  # so they resolve themselves at runtime instead of baking in $DIR as a
  # literal absolute path (this whole tree is designed to be plugged into
  # different machines/mount points; a wrapper generated while $DIR was
  # e.g. /media/terraserver/USB breaks the instant the same drive shows up
  # as E:\ on a different machine -- confirmed live).
  local platform_tag archive_ext node_bin_path npm_cli_path node_bin_rel npm_cli_rel
  if [ "$os" = "windows" ]; then
    platform_tag="win-${node_arch}"; archive_ext="zip"
    node_bin_rel="node-runtime/node.exe"
    npm_cli_rel="node-runtime/node_modules/npm/bin/npm-cli.js"
  else
    platform_tag="linux-${node_arch}"; archive_ext="tar.gz"
    node_bin_rel="node-runtime/bin/node"
    npm_cli_rel="node-runtime/lib/node_modules/npm/bin/npm-cli.js"
  fi
  node_bin_path="$DIR/.bin/$node_bin_rel"
  npm_cli_path="$DIR/.bin/$npm_cli_rel"

  # Skip the download if the actual runtime is already there -- but the
  # wrapper scripts below always get rewritten regardless (cheap, and self-
  # heals a wrapper that baked in a stale absolute path from a previous
  # machine/mount point, like the one above describes).
  #
  # -s (non-empty) catches a truncated-to-0-bytes file, but not a file
  # that's plausibly-sized yet still doesn't actually work -- confirmed
  # live on terraserver: a stray node binary left over from a much earlier,
  # unrelated setup (dated months before anything in this session) was a
  # full, correctly-sized, correctly-architected ELF executable that
  # segfaulted on every single invocation. Only actually running it proves
  # it works. This is the same reasoning as ensure_portable_cloudflared's
  # --version check below.
  if [ -s "$node_bin_path" ] && [ -s "$npm_cli_path" ] && "$node_bin_path" --version >/dev/null 2>&1; then
    :
  else
    info "Downloading portable Node.js ($platform_tag)..."
    local tarball
    tarball=$(dl_curl_silent "https://nodejs.org/dist/latest-v20.x/SHASUMS256.txt" \
      | grep "${platform_tag}\.${archive_ext}$" | awk '{print $2}' | head -1)
    if [ -z "$tarball" ]; then
      err "Could not determine latest Node.js build for $platform_tag."
      return
    fi
    rm -rf "$DIR/.bin/node-runtime"
    mkdir -p "$DIR/.bin/node-runtime"
    dl_curl -o "$DIR/.bin/node.archive" "https://nodejs.org/dist/latest-v20.x/${tarball}"
    if [ "$archive_ext" = "zip" ]; then
      extract_zip_stripped "$DIR/.bin/node.archive" "$DIR/.bin/node-runtime"
    else
      tar -xzf "$DIR/.bin/node.archive" -C "$DIR/.bin/node-runtime" --strip-components=1
    fi
    rm -f "$DIR/.bin/node.archive"
    chmod +x "$node_bin_path" 2>/dev/null
  fi

  # bin/node and bin/npm inside the extracted tree are frequently symlinks
  # (npm always is: bin/npm -> ../lib/node_modules/npm/bin/npm-cli.js) --
  # exFAT/FAT32 (this whole tree is designed to run from a portable USB
  # drive) can't hold symlinks, so tar silently drops them. Write real
  # wrapper scripts directly on $DIR/.bin (already on PATH, see the `export
  # PATH` near the top of this file) instead of relying on the extracted
  # tree's own links -- same fix already applied to Piper's .so link chain
  # below, and it sidesteps needing to know whether Windows' own npm/npm.cmd
  # wrappers extracted correctly too.
  #
  # $here is resolved at RUN time (dirname "$0"), not baked in as the
  # absolute $DIR from when this wrapper was generated -- otherwise a
  # wrapper written while this drive was e.g. /media/terraserver/USB stops
  # working the instant the same drive shows up as E:\ on another machine.
  cat > "$DIR/.bin/node" <<NODE_WRAPPER
#!/bin/sh
here="\$(cd "\$(dirname "\$0")" && pwd)"
exec "\$here/$node_bin_rel" "\$@"
NODE_WRAPPER
  chmod +x "$DIR/.bin/node"

  cat > "$DIR/.bin/npm" <<NPM_WRAPPER
#!/bin/sh
here="\$(cd "\$(dirname "\$0")" && pwd)"
exec "\$here/$node_bin_rel" "\$here/$npm_cli_rel" "\$@"
NPM_WRAPPER
  chmod +x "$DIR/.bin/npm"
  ok "Portable Node.js ready."
}

ensure_portable_cloudflared() {
  local os cf_bin_name; os=$(detect_os)
  cf_bin_name="cloudflared"; [ "$os" = "windows" ] && cf_bin_name="cloudflared.exe"
  # -s (non-empty), not just -x: confirmed live on terraserver -- a 0-byte
  # cloudflared binary still had its executable bit set (exFAT can retain
  # permission bits independently of a truncated write), so this passed an
  # -x-only check and was never re-downloaded, then segfaulted on every
  # exec attempt. Same class of bug already fixed in find_node/find_npm/
  # find_cloudflared/ensure_portable_node -- this was the one remaining
  # call site still using the weaker check.
  #
  # The --version run is a second, independent check: also confirmed live,
  # a fully-sized, correctly-architected binary can still be broken (a
  # stray leftover from a much earlier, unrelated setup segfaulted on
  # every invocation despite passing every size/permission check). Only
  # actually running it proves it works.
  if [ -s "$DIR/.bin/$cf_bin_name" ] && "$DIR/.bin/$cf_bin_name" --version >/dev/null 2>&1; then
    ok "cloudflared already present."
    return
  fi

  local arch cf_arch
  arch=$(uname -m)
  if [ "$os" = "windows" ]; then
    case "$arch" in
      aarch64|arm64) cf_arch=windows-arm64 ;;
      *)             cf_arch=windows-amd64 ;;
    esac
  else
    case "$arch" in
      aarch64|arm64) cf_arch=linux-arm64 ;;
      arm*)          cf_arch=linux-arm   ;;
      *)             cf_arch=linux-amd64 ;;
    esac
  fi
  info "Downloading cloudflared ($cf_arch)..."
  mkdir -p "$DIR/.bin"
  local suffix=""; [ "$os" = "windows" ] && suffix=".exe"
  dl_curl -o "$DIR/.bin/${cf_bin_name}" \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${cf_arch}${suffix}"
  chmod +x "$DIR/.bin/${cf_bin_name}"
  ok "cloudflared ready."
}

# Kept as an alias -- this used to download node+cloudflared into
# temutalk/bin/linux/ specifically, before both were generalized into shared,
# stack-wide $DIR/.bin/ downloads used by every app (see ensure_portable_node
# and ensure_portable_cloudflared above).
ensure_temutalk_portable_bins() {
  ensure_portable_node
  ensure_portable_cloudflared
}

ensure_temutalk_npm_deps() {
  if [ -d "$DIR/temutalk/node_modules" ]; then
    ok "temutalk npm dependencies already installed."
    return
  fi
  local npm_bin; npm_bin=$(find_npm)
  if [ -z "$npm_bin" ]; then
    warn "npm not found — portable Node.js download must have failed (see error.log above). Re-run setup once that's resolved."
    return
  fi
  info "Installing temutalk npm dependencies..."
  # --no-bin-links: same reasoning as portal/git-forge/tag-relay above --
  # this runs from a portable USB drive (usually exFAT/FAT32, which can't
  # hold symlinks), and nothing here is launched via a bin script anyway.
  if ( cd "$DIR/temutalk" && "$npm_bin" install --no-audit --no-fund --no-bin-links --loglevel=error ); then
    ok "temutalk npm dependencies installed."
  else
    err "temutalk npm install failed — see output above."
  fi
}

# Piper (local text-to-speech, no client install required) -- the assistant's
# voice replies are synthesized server-side and streamed to the browser as
# WAV, so no client device needs anything installed for voice replies to
# work.
ensure_temutalk_piper() {
  local arch piper_arch
  arch=$(uname -m)
  case "$arch" in
    aarch64|arm64) piper_arch=aarch64 ;;
    arm*)          piper_arch=armv7l  ;;
    *)             piper_arch=x86_64  ;;
  esac

  if [ ! -x "$DIR/temutalk/bin/linux/piper/piper" ]; then
    info "Downloading Piper TTS ($piper_arch)..."
    mkdir -p "$DIR/temutalk/bin/linux/piper"
    dl_curl -o /tmp/piper.tar.gz \
      "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_${piper_arch}.tar.gz"
    tar -xzf /tmp/piper.tar.gz -C "$DIR/temutalk/bin/linux/piper" --strip-components=1
    rm -f /tmp/piper.tar.gz
    # The USB drive this whole tree runs from is usually exFAT/FAT32 (cross-
    # OS compatibility), which can't hold symlinks -- tar's extraction above
    # silently fails to create Piper's libFOO.so -> libFOO.so.N -> libFOO.
    # so.N.N.N link chain (the real, fully-versioned file itself extracts
    # fine; only the link levels on top of it fail), which then breaks
    # Piper's dynamic linking at runtime with no obvious error until you
    # actually try to synthesize speech. Repair by copying the real file
    # over every missing link-name level instead of relying on symlinks,
    # the same workaround already used for npm's --no-bin-links.
    # NOTE: globbing for the missing plain ".so" names directly (as an
    # earlier version of this fix tried) doesn't work -- those names don't
    # exist yet, so the glob matches nothing. Walk forward instead from
    # each fully-versioned file that DID extract (foo.so.N.N.N), filling in
    # every less-specific name (foo.so.N.N, foo.so.N, foo.so) that's absent.
    local f base
    for f in "$DIR/temutalk/bin/linux/piper/"*.so.*; do
      [ -f "$f" ] || continue
      base="$f"
      while [[ "$base" =~ \.[0-9][0-9a-zA-Z]*$ ]]; do
        base="${base%.*}"
        [ -e "$base" ] || cp "$f" "$base"
      done
    done
    chmod +x "$DIR/temutalk/bin/linux/piper/piper" "$DIR/temutalk/bin/linux/piper/piper_phonemize" 2>/dev/null
    ok "Piper ready."
  else
    ok "Piper already present."
  fi

  if [ ! -f "$DIR/temutalk/voices/en_US-lessac-medium.onnx" ]; then
    info "Downloading Piper voice (en_US-lessac-medium)..."
    mkdir -p "$DIR/temutalk/voices"
    dl_curl -o "$DIR/temutalk/voices/en_US-lessac-medium.onnx" \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx"
    dl_curl_silent -o "$DIR/temutalk/voices/en_US-lessac-medium.onnx.json" \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json"
    ok "Voice ready."
  else
    ok "Piper voice already present."
  fi
}

# ─── TemuTalk's USB key security ────────────────────────────────────────────
# Physical-USB-drive-gated access to the dev panel's remote terminal +
# TemuTalk admin tab (see start_dev_panel below, which reads the hash this
# writes) -- only the SHA-256 hash is stored server-side, the raw key never
# leaves the USB drive.
TEMUTALK_USB_LABEL="${TEMUTALK_USB_LABEL:-}"
TEMUTALK_KEY_HASH_FILE="$DIR/temutalk/.run/panel-key-hash"

find_temutalk_usb_mount() {
  local user; user=$(whoami)
  if [ -n "$TEMUTALK_USB_LABEL" ]; then
    local p
    for p in "/media/$user/$TEMUTALK_USB_LABEL" "/run/media/$user/$TEMUTALK_USB_LABEL" "/mnt/$TEMUTALK_USB_LABEL" "/media/$TEMUTALK_USB_LABEL"; do
      [ -d "$p" ] && { echo "$p"; return; }
    done
    return
  fi
  # Prefer a mounted drive that already carries a key.key, so the same
  # logical key drive keeps being found even if the OS assigns it a
  # different mount name after a replug/reboot; otherwise fall back to
  # whichever removable drive is present, for first-time key generation.
  #
  # -w is required on the fallback candidate -- confirmed live under WSL,
  # where Windows drives are auto-mounted at /mnt/c, /mnt/d, etc: with no
  # real USB plugged in, this loop happily "found" /mnt/c (the entire
  # Windows C:\ root) as a candidate, tried to write key.key there,
  # silently failed (Permission denied), and still went on to claim
  # success. /mnt isn't exclusively removable media on plenty of real Linux
  # setups either, not just WSL, so this check matters generally, not just
  # for this one environment.
  local root d candidate=""
  for root in "/media/$user" "/run/media/$user" "/media" "/mnt"; do
    [ -d "$root" ] || continue
    for d in "$root"/*/; do
      [ -d "$d" ] || continue
      d="${d%/}"
      if [ -f "$d/key.key" ]; then echo "$d"; return; fi
      [ -z "$candidate" ] && [ -w "$d" ] && candidate="$d"
    done
  done
  [ -n "$candidate" ] && echo "$candidate"
}

setup_temutalk_usb_key() {
  if [ -f "$TEMUTALK_KEY_HASH_FILE" ] && [ -s "$TEMUTALK_KEY_HASH_FILE" ]; then
    ok "USB key already enrolled."
    return
  fi
  local usb; usb=$(find_temutalk_usb_mount)
  if [ -z "$usb" ]; then
    warn "USB drive not found — plug in the TemuTalk USB and run: bash install.sh enroll"
    return
  fi
  local key_file="$usb/key.key"
  if [ -f "$key_file" ]; then
    info "Existing key found on USB — enrolling..."
  else
    info "Generating 1000-character key on USB..."
    mkdir -p "$DIR/temutalk/.run"
    tr -dc 'A-Za-z0-9+/=' < /dev/urandom 2>/dev/null | head -c 1000 > "$key_file"
    # Confirmed live: a write that silently failed (permission denied on a
    # bad USB-detection fallback) still printed "Key written" and then
    # "Key hash enrolled" below, with nothing ever actually enrolled --
    # verify the file is really there with real content before saying so.
    if [ ! -s "$key_file" ]; then
      err "Failed to write key to $key_file — check permissions on the USB mount."
      return
    fi
    ok "Key written to $key_file"
  fi
  mkdir -p "$DIR/temutalk/.run"
  if ! sha256sum < "$key_file" | cut -c1-64 > "$TEMUTALK_KEY_HASH_FILE"; then
    err "Failed to hash $key_file — USB key not enrolled."
    return
  fi
  chmod 600 "$TEMUTALK_KEY_HASH_FILE"
  ok "Key hash enrolled. Dev panel now requires this USB to be plugged in."
}

# Remote terminal + TemuTalk admin panel (chat spy/moderation, devices,
# accounts), gated behind the same physical USB key file that unlocks
# temutalk's own control panel (reads temutalk's panel-key-hash directly
# rather than managing a separate key). The TemuTalk tab proxies straight
# through to temutalk's own server, same as temutalk/control-panel.js does.
start_dev_panel() {
  if proc_running dev-panel; then warn "Dev panel already running."; return; fi
  if [ ! -d "$DIR/portal/node_modules" ]; then warn "portal/node_modules missing — run setup first."; return; fi
  if [ ! -f "$DIR/temutalk/.run/panel-key-hash" ]; then
    warn "temutalk has no panel key enrolled yet — run: bash install.sh enroll"
  fi
  local node_bin; node_bin=$(find_node)
  if [ -z "$node_bin" ]; then err "node not found on PATH."; return; fi
  ( cd "$DIR/portal" && DEV_PANEL_PORT="$DEV_PANEL_PORT" MASTER_INSTALL_SH="$DIR/install.sh" \
    TEMUTALK_DIR="$DIR/temutalk" TEMUTALK_KEY_HASH_FILE="$DIR/temutalk/.run/panel-key-hash" \
    TEMUTALK_SERVER_PORT="$TEMUTALK_PORT" \
    nohup "$node_bin" dev-panel.js >> "$DIR/service.log" 2>&1 & echo "$(detect_os):$!" > "$(pid_file dev-panel)" )
  sleep 1
  if proc_running dev-panel; then ok "Dev panel started (PID $(proc_pid dev-panel)) → :$DEV_PANEL_PORT"
  else snapshot_log_on_failure "dev-panel-start" "$DIR/service.log"; fi
}

start_temutalk() {
  if proc_running temutalk; then warn "temutalk already running."; return; fi
  if [ ! -d "$DIR/temutalk/node_modules" ]; then warn "temutalk/node_modules missing — run setup first."; return; fi
  local node_bin; node_bin=$(find_temutalk_node)
  if [ -z "$node_bin" ]; then err "No Node.js binary available for temutalk."; return; fi
  ( cd "$DIR/temutalk" && BASE_PATH=/temutalk EXTERNAL_TUNNEL=1 EXTERNAL_PANEL=1 PORT="$TEMUTALK_PORT" BASE_URL="https://${CF_DOMAIN}" \
    nohup "$node_bin" launcher.js >> "$DIR/service.log" 2>&1 & echo "$(detect_os):$!" > "$(pid_file temutalk)" )
  sleep 2
  if proc_running temutalk; then ok "temutalk started (PID $(proc_pid temutalk)) → :$TEMUTALK_PORT"
  else snapshot_log_on_failure "temutalk-start" "$DIR/service.log"; fi
}

start_portal() {
  if proc_running portal; then warn "Portal already running."; return; fi
  local node_bin; node_bin=$(find_node)
  if [ -z "$node_bin" ]; then err "node not found on PATH."; return; fi
  ( cd "$DIR/portal" && PORT="$PORTAL_PORT" \
    TEMUTALK_TARGET="https://127.0.0.1:$TEMUTALK_PORT" FORGE_TARGET="http://127.0.0.1:$FORGE_PORT" \
    TAG_RELAY_TARGET="http://127.0.0.1:$TAG_RELAY_PORT" DEV_PANEL_TARGET="https://127.0.0.1:$DEV_PANEL_PORT" \
    nohup "$node_bin" server.js >> "$DIR/service.log" 2>&1 & echo "$(detect_os):$!" > "$(pid_file portal)" )
  sleep 1
  if proc_running portal; then ok "Portal started (PID $(proc_pid portal)) → :$PORTAL_PORT"
  else snapshot_log_on_failure "portal-start" "$DIR/service.log"; fi
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
  # Match via bash's own regex engine, not `find -regex` -- find's regex
  # dialect varies by platform (GNU find defaults to "emacs", which doesn't
  # support \{36\} intervals at all; BusyBox find on Alpine-based hosts
  # doesn't support -regex/-regextype in the first place). This silently
  # matched nothing against a real, perfectly intact credentials file every
  # single time (confirmed live against GNU find) until this was rewritten.
  local json="" candidate
  for candidate in "$cf_dir"/*.json; do
    [ -f "$candidate" ] || continue
    [[ "$(basename "$candidate")" =~ ^[0-9a-fA-F-]{36}\.json$ ]] && { json="$candidate"; break; }
  done
  [ -z "$json" ] && return 1
  local tunnel_id; tunnel_id=$(basename "$json" .json)
  _TUNNEL_CONFIG_FILE="$cf_dir/config.yml"
  cat > "$_TUNNEL_CONFIG_FILE" <<EOF
tunnel: ${tunnel_id}
credentials-file: $(to_native_path "$json")
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
    [ -f "$cert_file" ] && args+=(--origincert "$(to_native_path "$cert_file")")
    args+=(--config "$(to_native_path "$_TUNNEL_CONFIG_FILE")" tunnel run)
  fi
  nohup "$cf_bin" "${args[@]}" >> "$DIR/service.log" 2>&1 &
  echo "$(detect_os):$!" > "$(pid_file tunnel)"
  sleep 2
  if proc_running tunnel; then ok "Tunnel started (PID $(proc_pid tunnel)) → https://${CF_DOMAIN}"
  else snapshot_log_on_failure "tunnel-start" "$DIR/service.log"; fi
}

do_start() {
  clear_logs
  # Only call ensure_portable_node/ensure_portable_cloudflared at all when
  # the runtime isn't already known-good -- once confirmed present AND
  # actually runnable (not just non-empty -- confirmed live on terraserver
  # that a fully-sized, correctly-architected binary can still segfault on
  # every invocation), skip them entirely instead of re-running their
  # checks on every single start. Self-healing still applies: if the
  # runtime was truncated, is genuinely missing, or doesn't actually run
  # since the last start, this still catches it and repairs it before
  # anything launches, so services never silently fall back to whatever
  # (potentially incompatible) system Node happens to be on PATH.
  if ! { [ -s "$DIR/.bin/node" ] && [ -s "$DIR/.bin/npm" ] && "$DIR/.bin/node" --version >/dev/null 2>&1; }; then
    ensure_portable_node
  fi
  local cf_bin_name="cloudflared"; [ "$(detect_os)" = "windows" ] && cf_bin_name="cloudflared.exe"
  if ! { [ -s "$DIR/.bin/$cf_bin_name" ] && "$DIR/.bin/$cf_bin_name" --version >/dev/null 2>&1; }; then
    ensure_portable_cloudflared
  fi
  start_forge; start_tag_relay; start_temutalk; start_portal; start_dev_panel; start_remote_admin; start_tunnel
}
do_stop()  { stop_proc tunnel; stop_proc remote-admin; stop_proc dev-panel; stop_proc portal; stop_proc temutalk; stop_proc tag-relay; stop_proc forge; }

status_json() {
  local forge_run=false temutalk_run=false portal_run=false tunnel_run=false tag_relay_run=false dev_panel_run=false remote_admin_run=false
  proc_running forge         && forge_run=true
  proc_running temutalk      && temutalk_run=true
  proc_running portal        && portal_run=true
  proc_running tunnel        && tunnel_run=true
  proc_running tag-relay     && tag_relay_run=true
  proc_running dev-panel     && dev_panel_run=true
  proc_running remote-admin  && remote_admin_run=true
  printf '{"forge":%s,"temutalk":%s,"portal":%s,"tunnel":%s,"tagRelay":%s,"devPanel":%s,"remoteAdmin":%s,"url":"https://%s"}\n' \
    "$forge_run" "$temutalk_run" "$portal_run" "$tunnel_run" "$tag_relay_run" "$dev_panel_run" "$remote_admin_run" "$CF_DOMAIN"
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

# Checks each repo's local HEAD against its own SHA *before* pulling
# anything, so this can report "no updates" truthfully and only touch
# (npm install + restart) the specific services whose repo actually moved
# -- previously this pulled/npm-installed/prompted-to-restart-all-three
# unconditionally, every single time, even when nothing had changed.
do_check_updates() {
  info "Checking temutalk, git-forge and tag for updates..."
  local changed_temutalk=0 changed_forge=0 changed_tag=0

  local name before
  for name in temutalk git-forge tag; do
    before=""
    if [ -d "$DIR/$name/.git" ] && git_safe "$DIR/$name" rev-parse HEAD >/dev/null 2>&1; then
      before=$(git_safe "$DIR/$name" rev-parse HEAD 2>/dev/null)
    fi
    case "$name" in
      temutalk)  clone_or_update temutalk  "$TEMUTALK_REPO" temutalk ;;
      git-forge) clone_or_update git-forge "$FORGE_REPO"    git-forge ;;
      tag)       clone_or_update tag       "$TAG_REPO"      tag ;;
    esac
    local after; after=$(git_safe "$DIR/$name" rev-parse HEAD 2>/dev/null)
    # No prior HEAD (fresh clone) counts as changed too -- there's new code
    # on disk that's never been running yet.
    if [ -z "$before" ] || [ "$before" != "$after" ]; then
      case "$name" in
        temutalk)  changed_temutalk=1 ;;
        git-forge) changed_forge=1 ;;
        tag)       changed_tag=1 ;;
      esac
    fi
  done

  if [ "$changed_temutalk" -eq 0 ] && [ "$changed_forge" -eq 0 ] && [ "$changed_tag" -eq 0 ]; then
    ok "No updates found — everything already up to date."
    _updates_available=0
    _last_update_check=$(date +%s)
    return
  fi

  echo "  Updates found:"
  [ "$changed_temutalk" -eq 1 ] && echo "    - temutalk"
  [ "$changed_forge" -eq 1 ]    && echo "    - git-forge"
  [ "$changed_tag" -eq 1 ]      && echo "    - tag"

  local npm_bin; npm_bin=$(find_npm)
  if [ -n "$npm_bin" ]; then
    [ "$changed_forge" -eq 1 ] && run_capturing "git-forge-npm-install" \
      bash -c "cd '$DIR/git-forge' && '$npm_bin' install --no-audit --no-fund --no-bin-links --loglevel=error"
    [ "$changed_tag" -eq 1 ] && [ -d "$DIR/tag/relay-server" ] && run_capturing "tag-relay-npm-install" \
      bash -c "cd '$DIR/tag/relay-server' && '$npm_bin' install --no-audit --no-fund --no-bin-links --loglevel=error"
  fi

  read -rp "  Restart affected services to apply? [Y/n] " yn
  if [[ ! "$yn" =~ ^[Nn]$ ]]; then
    [ "$changed_forge" -eq 1 ]    && proc_running forge     && { stop_proc forge;     start_forge; }
    [ "$changed_tag" -eq 1 ]      && proc_running tag-relay && { stop_proc tag-relay; start_tag_relay; }
    [ "$changed_temutalk" -eq 1 ] && proc_running temutalk  && { stop_proc temutalk;  start_temutalk; }
    ok "Restarted affected services."
  fi
  _updates_available=0
  _last_update_check=$(date +%s)
}

do_view_logs() {
  echo "  ${C_DIM}Ctrl+C to return to the menu.${C_RESET}"
  sleep 1
  touch "$DIR/service.log"
  tail -n 30 -f "$DIR/service.log"
}

do_view_errors() {
  local n; n=$(wc -l < "$DIR/error.log" 2>/dev/null || echo 0)
  if [ "$n" -eq 0 ]; then
    warn "No errors recorded yet."
    return
  fi
  echo "  ${C_BOLD}error.log${C_RESET} ($n line(s))"
  echo ""
  sed 's/^/    /' "$DIR/error.log"
}

# ─── Non-interactive CLI dispatch ────────────────────────────────────────────
if [ "${1:-}" = "setup" ]; then clear_logs; do_setup; exit 0; fi
if [ "${1:-}" = "bundle" ]; then do_bundle "${2:-}"; exit 0; fi
if [ "${1:-}" = "start" ] || [ "${1:-}" = "stop" ]; then
  case "${2:-}" in
    forge|temutalk|portal|tunnel|tag-relay|dev-panel|remote-admin|all) ;;
    *) err "Usage: install.sh {start|stop} {forge|temutalk|portal|tunnel|tag-relay|dev-panel|remote-admin|all}"; exit 1 ;;
  esac
  case "$1-$2" in
    start-forge)         start_forge ;;
    start-temutalk)      start_temutalk ;;
    start-portal)        start_portal ;;
    start-tunnel)        start_tunnel ;;
    start-tag-relay)     start_tag_relay ;;
    start-dev-panel)     start_dev_panel ;;
    start-remote-admin)  start_remote_admin ;;
    start-all)           do_start ;;
    stop-forge)          stop_proc forge ;;
    stop-temutalk)       stop_proc temutalk ;;
    stop-portal)         stop_proc portal ;;
    stop-tunnel)         stop_proc tunnel ;;
    stop-tag-relay)      stop_proc tag-relay ;;
    stop-dev-panel)      stop_proc dev-panel ;;
    stop-remote-admin)   stop_proc remote-admin ;;
    stop-all)            do_stop ;;
  esac
  exit 0
fi
if [ "${1:-}" = "status" ]; then status_json; exit 0; fi
if [ "${1:-}" = "errors" ]; then do_view_errors; exit 0; fi
if [ "${1:-}" = "check-updates" ]; then do_check_updates; exit 0; fi
if [ "${1:-}" = "enroll" ]; then setup_temutalk_usb_key; exit 0; fi

# ─── First-run setup, then TUI ───────────────────────────────────────────────
# Reaching here means the program is actually being *run* (no narrowly-
# scoped or read-only CLI verb matched above) -- start with clean logs.
clear_logs
echo ""
echo "  ${C_BOLD}codecade.co.za — Portal Installer${C_RESET}"
echo ""
do_setup

# Three subtabs instead of one long flat list -- CONTROL for whole-stack
# actions, SERVICES for toggling one process at a time, DIAGNOSTICS for
# everything read-only/investigative. Parallel arrays (icon/name) index by
# tab number; each tab's own item labels live in their own array below so
# the menu loop can look one up by name via a nameref (`local -n`).
TAB_ICONS=("⚡" "▣" "◈")
TAB_NAMES=("CONTROL" "SERVICES" "DIAGNOSTICS")

CONTROL_LABELS=(
  "Start all"
  "Stop all"
  "Open in browser"
  "Bundle to a drive..."
  "Exit"
)
SERVICES_LABELS=(
  "Toggle Forge"
  "Toggle TemuTalk"
  "Toggle Portal"
  "Toggle Tunnel"
  "Toggle Tag relay"
  "Toggle Dev panel"
  "Toggle Remote-admin"
)
DIAGNOSTICS_LABELS=(
  "Check for updates"
  "View logs"
  "View errors"
)

_tab_selected=0
_menu_selected=0

# Reads one keypress, with a timeout so the menu loop periodically wakes up
# on its own (used to drive the quiet background update check below, and to
# keep the status display live) even if nobody presses anything. 1s, not
# the original 5s -- the status rows (running/stopped) only actually
# refresh on each loop iteration, so 5s made the whole dashboard feel
# noticeably laggy for something showing live service state. Arrow keys
# arrive as a 3-byte escape sequence (ESC [ A/B/C/D) — a lone ESC (e.g.
# someone just tapping Escape) times out on the second read instead of
# hanging, and falls through as an ignored key.
read_key() {
  local key rest
  IFS= read -rsn1 -t 1 key
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
  local name branch local_sha remote_sha
  for name in temutalk git-forge tag; do
    [ -d "$DIR/$name/.git" ] || continue
    # git-forge's default branch is "master", temutalk/tag use "main" --
    # read HEAD's branch back instead of assuming (see update_checkout_hard).
    branch=$(git_safe "$DIR/$name" rev-parse --abbrev-ref HEAD 2>/dev/null) || continue
    git_safe "$DIR/$name" fetch --quiet origin "$branch" 2>/dev/null || continue
    local_sha=$(git_safe "$DIR/$name" rev-parse HEAD 2>/dev/null)
    remote_sha=$(git_safe "$DIR/$name" rev-parse "origin/$branch" 2>/dev/null)
    [ -n "$local_sha" ] && [ -n "$remote_sha" ] && [ "$local_sha" != "$remote_sha" ] && _updates_available=1
  done
}

# A colored "● running (PID n)" / "○ stopped" status line -- used by the
# menu's header block below, one call per service.
print_status_row() {
  local label="$1" proc_name="$2"
  if proc_running "$proc_name"; then
    printf "  ${C_GREEN}●${C_RESET} %-10s ${C_GREEN}running${C_RESET} ${C_DIM}(PID %s)${C_RESET}\n" "$label" "$(proc_pid "$proc_name")"
  else
    printf "  ○ %-10s stopped\n" "$label"
  fi
}

menu() {
  while true; do
    check_for_updates_quiet
    clear
    echo "  ${C_CYAN}${C_BOLD}╔══════════════════════════════════════╗${C_RESET}"
    echo "  ${C_CYAN}${C_BOLD}║      codecade.co.za — Portal TUI      ║${C_RESET}"
    echo "  ${C_CYAN}${C_BOLD}╚══════════════════════════════════════╝${C_RESET}"
    echo "  ${C_CYAN}✦ web · chat · games · everything, together ✦${C_RESET}"
    echo ""

    print_status_row "Forge"     forge
    print_status_row "Tag relay" tag-relay
    print_status_row "TemuTalk"  temutalk
    print_status_row "Portal"    portal
    print_status_row "Tunnel"    tunnel
    print_status_row "Dev panel" dev-panel
    print_status_row "Admin"     remote-admin
    echo "  ${C_DIM}URL${C_RESET}          https://${CF_DOMAIN}"

    if [ "$_updates_available" -eq 1 ]; then
      echo "  ${C_YELLOW}⚠ Updates available — see DIAGNOSTICS → Check for updates.${C_RESET}"
    fi
    local _err_count; _err_count=$(wc -l < "$DIR/error.log" 2>/dev/null || echo 0)
    if [ "$_err_count" -gt 0 ]; then
      echo "  ${C_RED}⚠ $_err_count line(s) in error.log — see DIAGNOSTICS → View errors.${C_RESET}"
    fi
    echo ""

    # Tab bar: the active tab gets brackets + bold/color, inactive ones stay
    # plain (not dim -- dim text is too low-contrast to read comfortably on
    # a lot of terminal color schemes, and these are real navigation
    # options, not throwaway detail) -- deliberately not width-aligned to an
    # underline, since bash's ${#str} counts *bytes* for multi-byte icons
    # like ⚡ under some locales and *characters* under others, which would
    # throw off any padding math unpredictably depending on what locale
    # this actually runs under. Bracket-wrapping needs no character
    # counting at all, so it can't misalign no matter what.
    local tab_line="  "
    for t in "${!TAB_NAMES[@]}"; do
      local label="${TAB_ICONS[$t]} ${TAB_NAMES[$t]}"
      if [ "$t" -eq "$_tab_selected" ]; then
        tab_line+="${C_CYAN}${C_BOLD}[ ${label} ]${C_RESET}"
      else
        tab_line+="  ${label}  "
      fi
      tab_line+="  "
    done
    echo "$tab_line"
    echo ""
    echo "  ${C_DIM}↑/↓ move   ←/→ switch tabs   Enter select   q quit${C_RESET}"
    echo ""

    local -n _current_labels="${TAB_NAMES[$_tab_selected]}_LABELS"
    for i in "${!_current_labels[@]}"; do
      if [ "$i" -eq "$_menu_selected" ]; then
        echo "    ${C_CYAN}${C_BOLD}▸ ${_current_labels[$i]}${C_RESET}"
      else
        echo "      ${_current_labels[$i]}"
      fi
    done

    local key; key=$(read_key)
    case "$key" in
      TIMEOUT)
        continue
        ;;
      $'\x1b[A')
        _menu_selected=$(( (_menu_selected - 1 + ${#_current_labels[@]}) % ${#_current_labels[@]} ))
        continue
        ;;
      $'\x1b[B')
        _menu_selected=$(( (_menu_selected + 1) % ${#_current_labels[@]} ))
        continue
        ;;
      $'\x1b[D')
        _tab_selected=$(( (_tab_selected - 1 + ${#TAB_NAMES[@]}) % ${#TAB_NAMES[@]} ))
        _menu_selected=0
        continue
        ;;
      $'\x1b[C')
        _tab_selected=$(( (_tab_selected + 1) % ${#TAB_NAMES[@]} ))
        _menu_selected=0
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
    case "$_tab_selected" in
      0) # CONTROL
        case "$_menu_selected" in
          0) do_start ;;
          1) do_stop ;;
          2) do_open_browser ;;
          3)
            read -rp "  Destination path (e.g. a mounted USB drive): " bundle_dest
            [ -n "$bundle_dest" ] && do_bundle "$bundle_dest"
            ;;
          4)
            echo "  Bye."
            exit 0
            ;;
        esac
        ;;
      1) # SERVICES
        case "$_menu_selected" in
          0) if proc_running forge;        then stop_proc forge;        else start_forge;        fi ;;
          1) if proc_running temutalk;     then stop_proc temutalk;     else start_temutalk;     fi ;;
          2) if proc_running portal;       then stop_proc portal;       else start_portal;       fi ;;
          3) if proc_running tunnel;       then stop_proc tunnel;       else start_tunnel;       fi ;;
          4) if proc_running tag-relay;    then stop_proc tag-relay;    else start_tag_relay;    fi ;;
          5) if proc_running dev-panel;    then stop_proc dev-panel;    else start_dev_panel;    fi ;;
          6) if proc_running remote-admin; then stop_proc remote-admin; else start_remote_admin; fi ;;
        esac
        ;;
      2) # DIAGNOSTICS
        case "$_menu_selected" in
          0) do_check_updates ;;
          1) do_view_logs ;;
          2) do_view_errors ;;
        esac
        ;;
    esac
    echo ""
    read -rp "  Press Enter to continue..." _
  done
}

menu
