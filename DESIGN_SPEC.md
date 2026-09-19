# codecade.co.za — System Design Specification

## 1. Overview

`codecade.co.za` is a small, self-hosted web platform consisting of four
independent applications served behind a single domain, deployed from a
single portable USB drive, and managed through a single installer script.
The system is designed to run on any machine — a Windows development
workstation or a Linux production server — with no manual pre-configuration
beyond having `git` available.

The four applications:

| Application | Purpose | Mount point |
|---|---|---|
| TemuTalk | Personal media, chat, and voice-assistant hub | `/temutalk` |
| git-forge | Self-hosted Git repository host | `/forge` |
| Tag (relay-server) | Multiplayer game matchmaking and relay | `/tag` |
| Portal | Landing page and reverse proxy tying the above together | `/` |

Two supporting services run alongside but are not proxied through the
portal:

| Service | Purpose | Exposure |
|---|---|---|
| Dev Panel | Remote terminal and TemuTalk administration console | Own port, key-gated |
| remote-admin | Token-authenticated remote exec/file-transfer API | Loopback only |

## 2. Goals

- **Single entrypoint.** One script (`install.sh`) handles cloning,
  dependency installation, service lifecycle, and diagnostics for the
  entire stack.
- **Self-contained.** No dependency may be assumed pre-installed on the
  host, with the sole exception of `git`. Node.js, npm, cloudflared,
  ffmpeg, and Piper are downloaded and managed by the installer itself.
- **Portable.** The entire working tree is designed to run from removable
  media (a USB drive) and to be relocated between machines without manual
  reconfiguration. No component may depend on an absolute filesystem path
  baked in at a prior run.
- **Cross-platform.** The installer must run correctly on both Linux
  (the production target) and Windows (the development environment),
  branching on OS where behavior genuinely differs rather than assuming
  one platform throughout.
- **Resilient by default.** Transient failures (a slow mirror, a
  corrupted cache file, an interrupted write) should be detected and
  recovered from automatically wherever practical, rather than requiring
  manual intervention.

## 3. Non-Goals

- This is not a multi-tenant or public-signup platform. Account creation
  across the constituent apps is either single-user or invite/trust-based.
- The installer does not manage TLS certificates for public endpoints;
  that responsibility belongs to the Cloudflare Tunnel layer in front of
  it.
- Horizontal scaling, load balancing, and high availability are explicitly
  out of scope. The system is designed to run as a single instance on a
  single host.

## 4. System Architecture

```
                          Cloudflare Tunnel
                       (codecade.co.za, HTTPS)
                                 |
                        +--------+--------+
                        |   Portal :8080   |
                        +--------+--------+
             +-----------+-------+-------+-----------+
             |           |               |           |
        /temutalk      /forge          /tag      (static
         :3001          :3000          :3002      landing
        (HTTPS)                                     page)
```

The portal is a thin Express reverse proxy with no state of its own. It
routes standard HTTP requests using `http-proxy-middleware`, and routes
WebSocket upgrade traffic for the Tag relay through a dedicated raw TCP
byte-pipe rather than the proxy middleware's own WebSocket handling, which
was found to corrupt frames under this configuration.

The Dev Panel and remote-admin services sit outside this proxy tree:

- **Dev Panel** (port 9091) is reachable directly and is gated by
  possession of a physical USB key file, not a password. It hosts both a
  browser-based remote terminal (running `install.sh` itself in a PTY) and
  a full administration console for TemuTalk.
- **remote-admin** (loopback only, port 3099) is a minimal
  token-authenticated HTTP API providing shell execution and file
  read/write, intended as a fallback path when direct SSH access to the
  production host is unavailable. It is intentionally not exposed beyond
  `127.0.0.1` by the installer; any further exposure (LAN, tunnel ingress)
  is a separate, deliberate operator decision.

## 5. Deployment Model

### 5.1 Physical medium

The canonical deployment artifact is a single USB drive, formatted
exFAT/FAT32 for cross-OS compatibility. The installer resolves its own
working directory relative to its own script location at every invocation,
so the same drive functions identically regardless of which machine or
drive letter/mount point it is currently attached to.

### 5.2 Bootstrap sequence

1. Ensure `git` is present, installing it via the host's package manager
   if not (the one unavoidable precondition, since `git` is required to
   fetch the installer itself in the non-checkout case).
2. Self-update: compare the running script against the latest committed
   version and replace/re-execute if different.
3. Clone or update the three application repositories.
4. Download and verify the portable runtime (Node.js, npm, cloudflared,
   ffmpeg) into a shared, OS-appropriate location.
5. Install per-application dependencies using the portable runtime, never
   a system-installed one.
6. Start services in a fixed order and verify each is actually running,
   not merely that its start command returned successfully.

### 5.3 Distribution

The installer supports bundling the entire tree — application checkouts,
generated files, and the downloaded portable runtime — to a fresh
destination, so a new deployment medium can be produced without requiring
network access to re-clone everything from source control.

## 6. Runtime Management

### 6.1 Process supervision

Each service is started as a detached background process with its PID
recorded to a dedicated file. Liveness is checked by signal probe against
the recorded PID, not by any heavier health-check protocol. On a failed
start, the tail of that service's log is captured to a timestamped
snapshot file so the failure is not lost even if no one was watching the
terminal at the time.

### 6.2 Portable runtime integrity

Because the runtime lives on removable media that can be relocated between
machines and is subject to write interruption, presence checks for the
portable Node.js/npm/cloudflared binaries verify non-empty content, not
merely file existence, before trusting them. A runtime found to be
missing or invalid is re-provisioned automatically the next time services
are started, rather than causing a silent fallback to a potentially
incompatible system-installed alternative.

### 6.3 Diagnostics

All recorded failures are appended to a single running log with UTC
timestamps, in addition to per-failure output snapshots. This log is
cleared at the start of every full service-start cycle so that a
previously resolved issue cannot be mistaken for a current one.

## 7. Security Model

| Surface | Mechanism |
|---|---|
| Dev Panel | Physical USB key; server stores only a salted hash of the key content, never the key itself |
| remote-admin | Bearer token, generated on first run, compared with constant-time equality |
| git-forge | Session cookies for browser use, per-user bearer tokens for CLI use; passwords hashed with bcrypt |
| TemuTalk OAuth | PKCE flow; third-party credentials held only in the browser, never persisted server-side |
| Public traffic | Terminated at the Cloudflare Tunnel; the origin host itself does not need an open inbound port |

## 8. Configuration Reference

| Setting | Default | Overridable via |
|---|---|---|
| Portal port | 8080 | `PORTAL_PORT` |
| TemuTalk port | 3001 | `TEMUTALK_PORT` |
| git-forge port | 3000 | `FORGE_PORT` |
| Tag relay port | 3002 | `TAG_RELAY_PORT` |
| Dev Panel port | 9091 | `DEV_PANEL_PORT` |
| remote-admin port | 3099 | `ADMIN_PORT` |
| Public domain | codecade.co.za | `CF_DOMAIN` |

## 9. Component Specifications

Each application has its own design specification covering its internal
architecture in detail:

- TemuTalk — `temutalk` repository, `DESIGN_SPEC.md`
- git-forge — `git-forge` repository, `DESIGN_SPEC.md`
- Tag — `tag` repository, `DESIGN_SPEC.md`

This document covers only the system-level integration of those
components and the installer that manages them.
