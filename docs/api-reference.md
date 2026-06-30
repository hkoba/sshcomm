# API Reference

This is an implementation-based list of APIs, extracted from the code at the time of investigation (version 0.4).
The official manual (`sshcomm.man` and friends) is currently little more than a skeleton, so this document is more comprehensive.

## 1. Top-Level API (`::sshcomm`)

| Command | Definition | Description |
|---|---|---|
| `sshcomm::comm host ?args?` | `sshcomm.tcl:30` | Establishes a connection through the pool, creates a single `comm`, and returns the comm id. The shortest path. |
| `sshcomm::ssh host ?args?` | `sshcomm.tcl:33` | Creates a new `connection` object (including `-plugins [list-plugins]`). For the configurable style where you create multiple comms. |
| `sshcomm::connection %AUTO% -host host ?...?` | `sshcomm.tcl:172` | Creates a connection object directly (snit::type). |
| `sshcomm::configure ?-debuglevel n? ?-debugchan ch? ?-sshcmd cmd?` | `sshcomm.tcl:97` | Global configuration. Unknown options raise an error. |
| `sshcomm::register-plugin ?ns?` | `sshcomm.tcl:45` | **[experimental]** Registers a namespace as a plugin (defaults to the caller's current namespace). Unused for ~10 years; exempt from testing. |
| `sshcomm::list-plugins` | `sshcomm.tcl:53` | **[experimental]** Lists the registered plugin namespaces. |
| `sshcomm::list-connections` | `sshcomm.tcl:69` | Lists the host names in the pool. |
| `sshcomm::forget host` | `sshcomm.tcl:73` | Discards the given connection from the pool. |
| `sshcomm::forget-all` | `sshcomm.tcl:81` | Discards all connections in the pool. |

### Two Usage Styles

```tcl
# (1) Shortest: through the pool
set cid [sshcomm::comm $host]
comm::comm send $cid {script...}
$cid command args...    ;# syntactic sugar, but note that args is evaluated locally

# (2) Configurable, multiple comms
set ssh [sshcomm::ssh $host]                       ;# = connection %AUTO% -host $host -plugins ...
set c1 [$ssh comm new]
set c2 [$ssh comm new]
comm::comm send -async $c1 {script...}
comm::comm send -async $c2 {script...}
```

## 2. Options of `sshcomm::connection`

From `sshcomm.tcl:172` onward. Extracted from the `option` declarations (with default values).

| Option | Default | Purpose |
|---|---|---|
| `-host` | `""` | The connection target. `host` or `host:port`. **A list is allowed** (the last element is the host, and the preceding elements are treated as additional ssh arguments). |
| `-lport` | `""` | Local forwarding port (auto-discovered if empty/0). |
| `-rport` | `""` | Remote forwarding port (auto-discovered if empty). |
| `-localhost` | `127.0.0.1` | The local address to forward to (defaults to IPv4 to avoid IPv6). |
| `-sshcmd` | `""` | Explicitly specify the ssh command (skips the platform branching when set). |
| `-ssh-args` | `""` | Additional arguments inserted between the forwarder and the host (added on branch `15-ssh-args`). |
| `-ssh-verbose` | `no` | `ssh -v` (and `2>@ stderr`). |
| `-autoconnect` | `yes` | Whether to `connect` automatically in the constructor. |
| `-tclsh` | `tclsh` | The command name of the tclsh to launch on the remote. |
| `-sudo` | `no` | Launch tclsh on the remote via `sudo`. |
| `-sudo-askpass-path` | `""` | Path to an external askpass helper (→ `SUDO_ASKPASS` + `sudo -A`). |
| `-sudo-askpass-command` | `""` | A Tcl callback that returns the password (→ `sudo -S`). |
| `-env-lang` | `""` | The remote `LANG` environment variable. |
| `-debug` | `no` | Enables all debugging features (see below). |
| `-remote-config` | `{}` | Configuration passed to the remote `remote::setup` (e.g. `-verbose yes`). |
| `-plugins` | `{}` | **[experimental]** Additional plugin namespaces to transfer to the remote (unused for ~10 years; exempt from testing). |
| `-wait-after-probe` | `150` | Wait after port discovery (ms). |
| `-sshcmd-platform` | `""` | Explicitly specify `unix`/`windows`/`gcloud` (defaults to `tcl_platform`). |
| `-sshcmd-platform-options` | `""` | **[experimental]** Arguments to the platform command itself (e.g. gcloud's `--tunnel-through-iap`). For `gcloud sshcmd`; exempt from testing. |
| `-strict-host-key-checking` | `yes` | `-o StrictHostKeyChecking=...`. |
| `-forwardx11` | `yes` | `-Y` when `$DISPLAY` is set (`-X` for gcloud), `-x` when disabled. |
| `-prefer-git-ssh` | `yes` | Prefer `$::env(GIT_SSH)` if it is set. |
| `-ssh-options` | `""` | Additional options inserted right after ssh/gcloud. |
| `-control-channel` | `pipe` | With `socket`, hands off the control channel to a dedicated socket and opens up the remote stdout to the application ([architecture.md](architecture.md) §3). |
| `-on-remote-output` | `""` | A callback (command prefix) that receives each line of the remote stdout. Requires `-control-channel socket`. |
| `-remote-stderr` | `local` | How the remote stderr is handled. `local` (default; goes to the local stderr) / `channel` (captured via a local `chan pipe` and passed to `-on-remote-stderr`; works in both pipe/socket mode). `merge` is not implemented. |
| `-on-remote-stderr` | `""` | A callback that receives each line of the remote stderr. Requires `-remote-stderr channel`. |

### Side Effects of `-debug` (`sshcomm.tcl:196`)

Setting `-debug` to true:
- `-ssh-verbose yes`
- adds `-verbose yes` to `-remote-config`
- `sshcomm::configure -debuglevel 3 -debugchan stderr`
- sets `::comm::comm(debug)` to 1 when `-debug` is an integer `>= 3`

## 3. Main Methods of `connection` (snit ensemble)

| Method | Definition | Description |
|---|---|---|
| `connect ?args?` | `:238` | Runs `remote open`→`remote prereq`→`remote setup` in one shot. |
| `comm new` | `:437` | Creates a single comm channel and returns the comm id. |
| `comm init sock` | `:448` | Manually connects an existing socket to a comm. |
| `comm forget cid` | `:467` | Shuts down a comm and cleans up. |
| `comm list` | `:478` | Lists the comm ids that have been created. |
| `forward new spec` | `:417` | Establishes a forwarded connection with cookie authentication (`spec`=`comm`/`raw`). |
| `forwarder` | `:496` | Returns `-L lport:localhost:rport`. |
| `sshcmd ?args?` | `:514` | Assembles the ssh command line (with platform branching). |
| `unix sshcmd` | `:534` | Active. Generates the command for `ssh`. |
| `windows sshcmd` | `:561` | **active (important)**. For `plink`. Test coverage is missing → adding it is recommended. |
| `gcloud sshcmd` | `:574` | **[experimental]** For `gcloud compute ssh`. Almost unused; exempt from testing. |
| `probe-remote-port host` | `:500` | Discovers a free port on the remote. |
| `remote open/prereq/setup/...` | `:248` onward | The individual stages of establishing a connection (internal). |
| `remote eval command` | `:321` | Synchronous RPC over the control channel (poor man's RPC). |
| `rchan open cid fileName` | `:618` | **[experimental]** Streams a remote file to the local side (`r` only). |
| `rchan socketpair` | `:649` | **[experimental]** Creates a raw socket pair. |

## 4. Code Transfer API

| Command | Definition | Description |
|---|---|---|
| `sshcomm::definition ?ns? ?args?` | `sshcomm.tcl:674` | Serializes a namespace tree into re-evaluable Tcl source. |
| `sshcomm::definition-of-proc proc` | `sshcomm.tcl:662` | Reconstructs the definition of a single proc. |
| `sshcomm::namespace-ancestry ns` | `sshcomm.tcl:723` | Enumerates the ancestor namespaces. |

Example from the README:
```tcl
namespace eval foo {proc x {} {list X}}
snit::type Dog { option -name "no name"; method bark {} {return "$options(-name) barks."} }
comm::comm send $cid [sshcomm::definition ::foo ::Dog]
$cid foo::x          ;# => X
$cid Dog d -name Hachi
$cid d bark          ;# => Hachi barks.
```

## 5. Remote-Side API (`::sshcomm::remote`)

The server that runs (gets transferred) inside the remote `tclsh`. Mostly for internal use.

| Command | Definition | Description |
|---|---|---|
| `remote::setup port args` | `sshcomm.tcl:752` | Starts the server socket, keepalive, control registration, and `vwait`. |
| `remote::accept sock addr port` | `:773` | Accepts a connection, checks the address, verifies the cookie, and dispatches to a handler. |
| `remote::accept__comm` / `__raw` | `:819` / `:814` | Per-type handlers. |
| `remote::cookie-add cookie ?spec?` | `:828` | Registers a cookie. |
| `remote::cookie-del cookie ?specVar?` | `:834` | Verifies and consumes a cookie (1 on success / 0 on failure). |
| `remote::cget name default` | `:849` | Retrieves a remote setting. |
| `remote::keepalive msec` | `:864` | Emits periodic keepalive output. |
| `remote::control fh args` | `:869` | Receives a complete command from stdin and evaluates it. |
| `remote::fread fn args` | `:894` | Reads a remote file. |
| `remote::dputs args` | `:859` | Logs to stderr only when `-verbose` is set. |

## 6. Utility API (`::sshcomm::utils`, `utils.tcl`)

> Note: `pkgIndex.tcl` only loads `sshcomm.tcl`. To use `utils.tcl` you need a
> separate `source` (the `askpass-helper` in `sshcomm.tcl` depends on `::sshcomm::utils::askpass`).

Representative ones (`utils.tcl`):

- dict-related: `dict-default` / `dict-cut` / `dict-left-difference` / `dict-compare`
- list-related: `lines-of` / `lgrep` / `lsearch-and-get`
- file-related: `read_file` / `read_file_lines` / `write_file` / `write_file_raw` /
  `write_file_lines` / `append_file` / `file-has` / `filelist-having` / `for-chan-line`
- others: `scope_guard` (cleanup via an unset trace) / `shell-quote-string` /
  `catch-exec` / `catch-exec-noerror` / `default` / `is-empty` / `text-of-list-of-list`
- GUI: `askpass` (a Tk password-input dialog)
- sudo integration: `create-echopass` (generates a disposable script for `SUDO_ASKPASS`)

## 7. Deprecated API (`sshcomm.tcl:906` onward)

| Command | Description |
|---|---|
| `sshcomm::client::create host` | The old name for `sshcomm::comm host`. |
| `sshcomm::sshcmd` | The old argument-less sshcmd (replaced by the method version on `connection`). |

## 8. Running the Tests

```sh
# By default runs integration tests against 127.0.0.1 (must be registered in known_hosts beforehand)
tclsh sshcomm.test
tclsh sshcomm.test -remote user@host -debuglevel 3 -para 4 -wait 3
```

- `-remote` can be specified multiple times, comma-separated.
- The suite mixes unit tests that need no connection (`cget`/`cookie`/`unix sshcmd` string generation)
  with integration tests that require a real SSH ([improvement-notes.md](todo/improvement-notes.md)).
- **Testing policy**: [experimental] features (`gcloud sshcmd`, `-sshcmd-platform-options`, the plugin mechanism)
  are **exempt from writing tests**. On the other hand, `windows sshcmd` is active and important, so adding tests is desirable
  (see the status legend in [README.md](README.md) and improvement-notes §5).
