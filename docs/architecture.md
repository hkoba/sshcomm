# Architecture

## 1. Design goals and central ideas

The problem `sshcomm` sets out to solve has three parts:

- We want to use the convenient "Tcl-to-Tcl remote scripting" provided by `comm` (tcllib).
- But `comm`'s raw TCP connection is **plaintext and unauthenticated**, so it cannot be used across the Internet.
- We do **not want to pre-install any agent** on the remote host (we want to assume only `tclsh`).

These three concerns are addressed by the following three mechanisms.

1. **Tunneling via SSH port forwarding**
   `ssh -L lport:localhost:rport` forwards the local `lport` to the remote `rport`, and
   `comm`'s TCP traffic is routed through this tunnel. Encryption and authentication are delegated to SSH.

2. **Bootstrapping via code shipping**
   The local side serializes its own namespace (procs / variables / ensembles) into Tcl source
   (`::sshcomm::definition`), then feeds it into the remote `tclsh` over SSH's stdin to reconstruct it there.
   If `comm` is not present on the remote, `comm` itself is shipped over the same way.

3. **Connection authentication via cookie**
   Other processes on the remote could also connect to the forwarded `rport`.
   To prevent that, a one-time cookie is pre-registered over the already-established SSH control channel,
   and a connection is only accepted once that cookie is sent immediately after the forward socket is opened.

## 2. Namespace layout

```
::sshcomm                     Core API, connection pool, configuration, logging, utilities
  ::sshcomm::connection       (snit::type) Local-side connection object
  ::sshcomm::remote           Server code that runs on the remote (shipped via definition)
  ::sshcomm::client           deprecated API (create)
  ::sshcomm::utils            General-purpose utilities (utils.tcl / plugin) [active]
  ::sshcomm::git-ssh-proxy    GIT_SSH proxy generation (git-ssh-proxy.tcl / plugin) [near-deprecated]
::host-setup                  Declarative configuration-management DSL (hostsetup.tcl / plugin) [deprecated]
```

> For the positioning of `git-ssh-proxy` (near-deprecated) and `host-setup` (deprecated), see
> [plugins-and-hostsetup.md](plugins-and-hostsetup.md).

`::sshcomm::remote` **also exists as a definition inside the local process**, but the copy that actually
runs as the "server" is the one shipped to and reconstructed inside the remote `tclsh`. This is the key
point to understanding this library.

## 3. The two-channel model

Each connection has two kinds of channels with different characteristics.

### (a) Control channel — `mySSH`
- Concretely, this is the **stdin/stdout pipe of the SSH process** opened with `open [list | ssh ... tclsh] w+`
  (`sshcomm.tcl:298`).
- Used for:
  - The "poor man's RPC" of the initial handshake (`remote eval`, `sshcomm.tcl:321`)
  - Code shipping (`remote redefine` / `remote setup`)
  - Cookie registration (`remote eval [cookie-add ...]` from `forward new`)
  - Receiving keepalive lines and remote output (`remote readable`, `sshcomm.tcl:484`)
- On the remote side, `::sshcomm::remote::control` (`sshcomm.tcl:869`) watches stdin via `fileevent` and
  evaluates each complete Tcl command it receives with `uplevel #0`.

### (b) comm channel — the forwarded TCP socket
- The actual `comm` connection, created over the tunnel set up by `ssh -L`.
- A new socket is opened on every `comm new` (multiple `comm` connections can be multiplexed over a single SSH).
- This is where `comm::comm send` traffic flows.

> Division of labor: the control channel handles "meta instructions and authentication", while the comm
> channel carries "the actual RPC payload".

> **Socketizing the control channel (implemented, opt-in)**: In the default `pipe` mode the control channel
> occupies SSH's stdin/stdout pipe, so the application cannot freely use the remote's stdout/stderr.
> When `-control-channel socket` is specified, the control channel is **handed off** to a dedicated forward
> socket with cookie authentication (`accept__control`) right after `connect` completes; stdin is then
> detached, freeing the pipe for the application's stdout. From then on, control RPCs are sent and received
> using per-seq `vwait` plus demux (`control-readable`).
> For design details and open issues, see [improvement-notes.md](todo/improvement-notes.md) §0.

## 4. Connection establishment sequence

`connection connect` (`sshcomm.tcl:238`) consists of the following three stages.

### 4.1 `remote open` (`sshcomm.tcl:248`)

1. **Find a free remote port**: If `rport` is unspecified, `probe-remote-port` (`sshcomm.tcl:500`)
   launches `ssh ... tclsh` once and runs free-port detection on the remote using `socket -server ... 0`
   (`probe-port`, `sshcomm.tcl:130`) to obtain `rport`.
   It then waits via `after` for `-wait-after-probe` (default 150ms) (`XXX: event loop`).
2. **Find a free local port**: If `lport` is unspecified / 0, obtain one with `::sshcomm::probe-port`.
3. **Assemble the ssh command**:
   ```
   set cmd [$self sshcmd {*}[$self forwarder] {*}$options(-ssh-args) {*}$host]
   ```
   - `forwarder` (`sshcomm.tcl:496`) = `-L lport:localhost:rport`
   - `-ssh-args` is inserted between the forwarder and the host (added in this branch, `15-ssh-args`)
   - With `-ssh-verbose`, `-v` is inserted right after `ssh`
4. **Add environment / sudo**: `-env-lang` adds `env LANG=...`; with `-sudo`, either
   `-sudo-askpass-path` (external helper → `sudo -A`) or `-sudo-askpass-command` (Tcl callback → `sudo -S`).
5. **Open the pipe**: `set mySSH [open [list | {*}$cmd] w+]`, configured to line buffering.
6. When using sudo via `-S` (askpass-command), wait for the `[sudo]` prompt with `remote expect` and
   send the password (`XXX: This can block`).

### 4.2 `remote prereq` (`sshcomm.tcl:383`)

1. Sanity check that `remote eval {list ok}` returns `"ok"`.
2. Try `package require comm` on the remote.
   - Success → `myRemoteHasOwnComm = yes`
   - Failure → ship `comm` itself via `::sshcomm::definition ::comm`, then `package provide` it and
     re-run `package require comm` (`myRemoteHasOwnComm = no`).

### 4.3 `remote setup` (`sshcomm.tcl:397`)

1. Configure the remote's stdout/stderr to line buffering.
2. `remote redefine` → `current-definition` (`sshcomm.tcl:375`) generates the definitions for the
   `::sshcomm` namespace plus plugin namespaces, and ships them via `remote eval`.
3. Start `::sshcomm::remote::setup $rport ...` on the remote (described below).
4. Confirm that the return value is `"OK port $rport"`.
5. On the local side, set `fileevent $mySSH readable [list $self remote readable]`, putting the control
   channel into asynchronous receive mode.

## 5. Structure of the remote-side server (`::sshcomm::remote`)

The server part that runs inside the shipped-to remote `tclsh`.

- **`setup port args`** (`sshcomm.tcl:752`):
  Destroys and recreates `comm::comm`, starts the server with `socket -server accept $port`, registers a
  30-second `keepalive` and a `control` fileevent on stdin, prints `"OK port $port"`, and finally enters
  the event loop with `vwait forever` so that it **does not read directly from stdin**.
- **`accept sock addr port`** (`sshcomm.tcl:773`):
  Inspects the source address; anything other than `0.0.0.0` / `127.0.0.1` is counted in `attackers` and
  closed immediately. Receives the first line as the cookie and validates/consumes it with `cookie-del`
  (`sshcomm.tcl:834`). Dispatches to the `accept__$kind` handler according to the cookie's `kind`.
  - `accept__comm` (`sshcomm.tcl:819`): connects the existing socket to `comm`'s machinery via
    `::comm::comm new $sock` plus `::comm::commIncoming`.
  - `accept__raw` (`sshcomm.tcl:814`): just returns the socket identifier (a raw socket for `rchan`).
- **`cookie-add` / `cookie-del`** (`sshcomm.tcl:828` / `827`): register, validate, and delete one-time cookies.
- **`keepalive msec`** (`sshcomm.tcl:864`): periodically prints `pid/timestamp` to stdout (connection keepalive / liveness).
- **`control fh`** (`sshcomm.tcl:869`): evaluates the **complete Tcl command** received from stdin with
  `uplevel #0`. This is the entry point for control-channel RPC.

## 6. The cookie-authentication flow (`forward new`)

How `forward new spec` (`sshcomm.tcl:417`) establishes a single forwarded connection:

1. **Generate a cookie**: `[clock seconds].[rand]`.
2. **Register it**: via the already-established control channel, `remote eval [cookie-add $cookie $spec]`.
   `spec` is the connection kind (`comm` or `raw`).
3. **Open the forward socket**: `socket $localhost $lport` (→ forwarded to remote `rport`).
4. **Send the cookie**: send the cookie as the socket's first line. Without it, the remote rejects the connection.

The remote `accept` side validates this cookie and passes it to the handler for the appropriate kind (see Section 5).

## 7. Creating the comm channel (`comm new`)

`comm new` (`sshcomm.tcl:437`):

1. `forward new comm` obtains a cookie-authenticated forward socket.
2. `comm init sock` (`sshcomm.tcl:448`) **manually reproduces `comm`'s connection establishment**:
   - `::comm::comm new $sock`
   - Assigns a comm id as `[list $myLastCommID $host]`
   - Calls `::comm::commNewConn` and writes `offerVers`/`port`/`defVers` to the socket
     (performing, on the already-open tunnel socket, the handshake that `comm` normally does via its own
     connect/listen).
3. For convenience, defines `proc ::$cid args "comm::comm send [list $cid] \$args"`
   (the `$cid command args...` sugar syntax; the code carries a `# Too much?` comment).

`comm forget` (`sshcomm.tcl:467`) does `comm shutdown` plus cleanup to avoid socket-name collisions.

## 8. Code shipping (`::sshcomm::definition`)

The core mechanism that serializes the local namespace tree into **re-evaluatable Tcl source**.

- `definition-of-proc proc` (`sshcomm.tcl:662`): reconstructs the `proc` definition as a string from
  `info args` / `info default` / `info body`.
- `definition {ns args}` (`sshcomm.tcl:674`): for the given namespace (and any additional namespaces),
  concatenates the following into one large script and returns it:
  - `namespace eval ... {}` for ancestor namespaces (`namespace-ancestry`, `sshcomm.tcl:723`)
  - all `proc` definitions underneath
  - all variables (arrays as `array set`, scalars as `set`)
  - `namespace export` patterns
  - `namespace ensemble` (if present, reconstructs `namespace ensemble create`; `-parameters` is conditionally stripped because it is unsupported on 8.5)
  - child namespaces, expanded **recursively**

This makes it possible to reproduce all of `::sshcomm` (plus namespaces passed via `-plugins`, and `::comm`
if needed) on the remote. `current-definition` (`sshcomm.tcl:375`) weaves in `-plugins` and calls this.

> The `definition` mechanism itself (shipping `::sshcomm` / `::comm`) is core and **active**, but
> **using `-plugins` to ship arbitrary additional plugins is experimental** (no real-world use in ~10 years,
> exempt from tests). For details, see [plugins-and-hostsetup.md](plugins-and-hostsetup.md) §1.

## 9. rchan (remote channel) — experimental feature

An experimental feature that streams the contents of a remote file/channel to the local side
(from `sshcomm.tcl:618` onward, defined separately via `snit::method`).

- **`rchan socketpair`** (`sshcomm.tcl:649`): creates a raw socket pair via `forward new raw` and returns
  `(localSock, remoteSock)`.
- **`rchan reader cid script`** (`sshcomm.tcl:628`): runs `script` on the remote to obtain a channel, then
  feeds it into the socket pair with `chan copy`. On completion, cleans up with `::sshcomm::close-all`.
- **`rchan open cid fileName`** (`sshcomm.tcl:618`): opens a remote file and returns it for reading
  (currently only `access=r` is supported).

## 10. sshcmd platform abstraction

The actual ssh command line to launch is assembled by `sshcmd` (`sshcomm.tcl:514`). If `-sshcmd` is not
specified explicitly, it dispatches to a platform-specific method according to `-sshcmd-platform`
(default is `tcl_platform(platform)`).

| Method | Status | Use | Skeleton of generated example |
|---|---|---|---|
| `unix sshcmd` (`:534`) | active | Ordinary `ssh` | `ssh [-ssh-options] -o StrictHostKeyChecking=... -T (-Y|-x) [-p port] {prefix} host` |
| `windows sshcmd` (`:561`) | **active (important)** | PuTTY `plink` | `plink [-P port] {prefix} host` |
| `gcloud sshcmd` (`:574`) | **experimental** | `gcloud compute ssh` | `gcloud compute ssh {platform-opts} host -- {opts}` |

> `windows sshcmd` lacks test coverage but has been used for years and is important. `gcloud sshcmd` is
> almost entirely unused and **experimental (exempt from tests)**. The code also marks it `# EXPERIMENTAL`.
> See the legend in [README.md](../README.md).

Related options:

- `-prefer-git-ssh` (default yes): if `$::env(GIT_SSH)` exists, use it instead of `ssh`/`gcloud`.
- `-strict-host-key-checking` (default yes) → `-o StrictHostKeyChecking=...`
- `-forwardx11` (default yes) + `$DISPLAY` set → `-Y` (gcloud uses `-X`); when disabled, `-x`
- `-ssh-options`: additional options inserted right after `ssh` / `gcloud` (e.g. `ssh -v`)
- `-sshcmd-platform-options` [experimental]: arguments to the platform command itself
  (e.g. `gcloud compute ssh --tunnel-through-iap`). Added for `gcloud sshcmd`; almost entirely unused, exempt from tests.
- `parse-host-port` (`sshcomm.tcl:609`): splits the `host:port` form and adds `-p` / `-P`.

> The three of `-ssh-args`, `-ssh-options`, and `-sshcmd-platform-options` differ in where they are inserted.
> For details and a proposed cleanup, see [improvement-notes.md](todo/improvement-notes.md).

## 11. Connection pool

Reuse of connections keyed by host name (`sshcomm.tcl:57` onward):

- `pooled_ssh host args`: reuse from the pool if present (**on the second and later calls, `args` is ignored**;
  there is a questioning comment in the code).
- `sshcomm::comm host` uses this pool; `sshcomm::ssh` creates a new one every time.
- `list-connections` / `forget host` / `forget-all`. The `connection` destructor also cleans up the pool entry.
