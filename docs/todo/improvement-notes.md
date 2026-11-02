# Improvement Notes

A catalog of discussion points, technical debt, and improvement candidates uncovered during investigation, for use when making future improvements to `sshcomm`. Priorities reflect not only the investigator's assessment but also **the author's intentions**.

> **Author's policy notes (as of 2026-06)**
> - **Top-priority theme**: separate the control channel from the SSH stdin/stdout pipe onto a dedicated socket (next section).
> - `hostsetup.tcl` (`::host-setup`) has not been used recently and is **deprecated**.
> - `git-ssh-proxy.tcl` has likewise gone unused for several years and is **mostly deprecated** (the possibility of a future revival is left open).
>   → For the status of deprecated modules, see
>   [plugins-and-hostsetup.md](../plugins-and-hostsetup.md). In this document it affects §3 "Packaging" and
>   §9 "Priorities".

## 0. Top-priority theme: separate the control channel onto a dedicated socket

> This theme is the improvement the author most wants to tackle, and at the same time it is a **foundational improvement that resolves at the root** both the `remote redefine` × keepalive conflict in §1 and the `remote eval`/`lread` cross-talk in §8.
>
> **Progress (branch `17-control-socket`)**: Phases 0–4 implemented. With `-control-channel socket` (opt-in,
> **default remains `pipe`**), handoff works, and opening remote stdout to the application (the `-on-remote-output`
> callback), per-seq `vwait` demux, non-hang on disconnect, clean teardown, and a CSPRNG cookie have all been
> confirmed by integration tests. Opening remote **stderr to the application is also implemented** (`-remote-stderr channel` plus
> `-on-remote-stderr`, using a local `chan pipe` approach, supporting both pipe and socket modes).
> **The plan for remaining work is in [control-channel-next-steps.md](control-channel-next-steps.md)**:
> (optional) `-remote-stderr merge`, and, once stable, switching the `-control-channel` default to `socket`
> (author's call; note that the current socket teardown is unix-only). The 0.1–0.8 below are the original design memo.

### 0.1 Goal

To **open the stdout/stderr of the remote `tclsh` to the application**.
We want the local application to be able to freely receive the output of `puts` / `puts stderr` from scripts run remotely.

### 0.2 The current constraint — why this isn't possible today

The control channel `mySSH` is opened with `open [list | ssh ... tclsh] w+` (`sshcomm.tcl:298`), so it is the
**SSH process's stdin/stdout pipe = the remote `tclsh`'s stdin/stdout itself**.
The control protocol is multiplexed onto this single pipe.

- Remote side: `fileevent stdin readable [list ... control stdin]` (`:766`) **occupies stdin as the control-command receiver**.
- Remote side: `keepalive` (`:864`) periodically writes `pid`/timestamps to **stdout**.
- Local side: the synchronous response to `remote eval` is read from **stdout** via `remote lread` (`:348`).

Consequently, if the remote application uses stdout/stderr, its output **cross-talks** with keepalive lines and `remote eval` responses.
This is a direct consequence of stdin/stdout being **occupied** as the "transport for the control protocol," and it is the same root cause as the keepalive conflict in §1 and the cross-talk in §8.

### 0.3 Proposal — move the control channel onto a dedicated socket derived from `forward new raw`

`forward new raw` (`:417`) plus `accept__raw` (`:814`) is a mechanism that establishes a Cookie-authenticated **bidirectional raw TCP socket** over an SSH forward, and it is already implemented for the rchan feature.
If we use this as the control channel, we can free up stdin/stdout.

- **Control channel = dedicated raw socket** (bidirectional dialogue: sending commands plus receiving responses).
- **SSH stdin/stdout pipe = opened for the application** (the bare standard I/O of the remote `tclsh`).

> The `rchan` feature could also achieve this, but `rchan open` is read-only and `rchan` is fundamentally geared toward channel copying, so it leans one-directional. Because the control channel requires bidirectional round-trips, **the bidirectional socket of `forward new raw` is the natural fit**.

### 0.4 The bootstrap chicken-and-egg problem and its solution

Cookie registration for `forward new` is done via the "already-established control channel" (`remote eval [cookie-add ...]`).
If we want the control channel itself to be a raw socket, the question becomes how to perform the very first Cookie registration.

→ This is solved by a **staged design: perform the bootstrap over the SSH pipe as before, and move only the control channel once setup completes**.

1. Open the SSH pipe, feed in the `definition`, and complete through `remote setup` (this stays as it is today).
2. Over the SSH pipe, register `cookie-add $cookie control` exactly once, and stand up one raw socket using the equivalent of `forward new` (**the last step of bootstrap**).
3. On the remote side, add a new control accept handler (e.g. `accept__control`) that attaches `control`'s `fileevent` to the incoming socket. Switch the output target of `keepalive` to this socket as well.
4. **Remove the remote stdin `fileevent`.** From then on, the SSH pipe's stdin/stdout belongs to the application.
5. Switch subsequent Cookie registration for `comm new` / `forward new` to go **via the control socket**.

### 0.5 Footholds from existing assets (good news)

- **`remote::control` is already generic**: `control fh args` (`:869`) is implemented to read complete commands from an arbitrary channel `fh` and evaluate them; it is merely being called as `control stdin`. It can be reused simply by swapping in `control $controlSock`. **The design is already in a form that is easy to separate.**
- **`forward new raw` / `accept__raw` already exist**: the foundation for the control socket can be used as-is.
- **The `comm init` (`:448`) technique of "manually layering a protocol onto an existing socket"** serves as a reference when building a `fileevent`-based control protocol onto the control socket.

### 0.6 Changes on the local side

- Change the `readable` handler of `mySSH` (`remote readable`, `:484`) from interpreting the control protocol to **passing through / calling back the application output** (e.g. provide a channel/callback API for reading remote stdout).
- **Opening stderr**: currently `2>@ stderr` is used only when `-ssh-verbose` is set (`:294`). To pass stderr to the application, we need to always direct it to a Tcl channel (which means revisiting the redirect design at `open` time).
- **Liveness monitoring**: detection currently relies on the SSH pipe's `eof` (`:488`). Once keepalive moves to the control socket, we need **liveness monitoring of the control socket** separately from the SSH pipe.
- **Shutdown sequence**: the destructor brings down the remote over the SSH pipe with `puts $mySSH "exit"` (`:222`). Once control moves to a separate socket, we need to sort out which channel `exit` is sent from.

### 0.7 Side effects (simultaneously resolving existing issues)

- §1 `sshcomm.tcl:368` `remote redefine` × keepalive conflict → resolved.
- §8 `remote eval`/`lread` stdout cross-talk → resolved.
- Non-blocking read on accept and the Cookie length limit were **already resolved ahead of time in groundwork (b)** (`read-cookie`). Phase 2's making `control` non-blocking is a separate matter (handling partial lines across the socket).

### 0.8 Issues / risks

- The bootstrap ordering becomes more complex. For a staged migration, it is safer to provide a **switching option such as `-control-channel pipe|socket`** for the time being, keeping both modes coexisting.
- Fallback and error handling on control-socket establishment failure or disconnect.
- Security is, if anything, improved: since the control channel evaluates arbitrary code with `uplevel #0`, putting it on a dedicated socket where Cookie authentication plus localhost restriction (`:777`) are effective is reasonable (and consistent with §2).

## 1. Known issues explicitly noted in the code (`XXX` / `BUG` comments)

Markers left by the implementers themselves. The most reliable starting points for improvement.

| Location | Description | Gist of the original comment |
|---|---|---|
| `sshcomm.tcl:62` | The pool keys only on host, ignoring `args` from the second call onward | `XXX: $args are ignored for the second call. Is this ok?` |
| `sshcomm.tcl:255` | The wait after port discovery is a blocking `after` | `XXX: event loop` |
| `sshcomm.tcl:302` | May block while waiting on the sudo askpass prompt | `XXX: This can block` |
| `sshcomm.tcl:368` | `remote redefine` may not work while keepalive is running | `XXX:BUG This may not work when ... keepalive is active.` |
| `sshcomm.tcl:407` | Should record the remote pid | `XXX: Should record remote pid` |
| `sshcomm.tcl:456` | The comm channel selection is hard-coded | `set chan ::comm::comm; # XXX: ok??` |
| `sshcomm.tcl:443` | Growing a proc per comm id may be excessive | `# Too much?` |
| ~~`accept`'s Cookie read is not non-blocking~~ | **✅ resolved** (groundwork (b)) | Former `XXX: Should use non blocking read`. Replaced by `read-cookie` (event-driven) |
| ~~No length limit on the Cookie line~~ | **✅ resolved** (groundwork (b)) | Former `XXX: Should limit read length`. `read-cookie` adds a cap plus a timeout |

### Items requiring particular attention

- **`remote redefine` × keepalive conflict (`:368`)**: because keepalive periodically writes to stdout on the control channel, the synchronous read of `remote eval` (`remote lread`, `:348`) may cross-talk with keepalive lines. The comment suggests "use `comm::comm send $cid [sshcomm::definition $ns]` instead." → **This can be resolved at the root by moving the control channel onto a dedicated socket per §0** (the top-priority theme).
- **Blocking `after` (`:255`) and sudo wait (`:302`)**: these do not mesh with the event loop, so embedding sshcomm into a GUI/asynchronous application can cause it to freeze. Making them asynchronous is desirable.

## 2. Security discussion points

- ~~**Cookie randomness quality**~~ → **✅ resolved (Phase 4)**: `::sshcomm::gen-cookie` hex-encodes 144 bits sourced from `/dev/urandom` (falling back to the old `clock+rand` in environments where it cannot be obtained). Since the control socket is a path to arbitrary code execution, it was made CSPRNG-based.
- **Only counting attackers (`sshcomm.tcl:778`, `789`)**: non-localhost / invalid-Cookie connections are merely counted; there is no active blocking, rate limiting, or notification. It remains observational only.
- **Arbitrary code execution in `remote::control` (`sshcomm.tcl:886`)**: strings received over the control channel are evaluated with `uplevel #0`. This is a design premise (a trusted channel protected by SSH), but it is safer to make the trust boundary explicit in the documentation.
- **A not-confident comment in `shell-quote-string` (`utils.tcl:162`)**: `# XXX: Is this enough for /bin/sh's "...string..." quoting?`. If there is a shell-mediated path, this is a candidate for review.

## 3. Packaging / loading

- **`pkgIndex.tcl` loads only `sshcomm.tcl`**:
  `utils.tcl` / `hostsetup.tcl` / `git-ssh-proxy.tcl` are not loaded by `package require sshcomm`.
  - `askpass-helper` at `sshcomm.tcl:153` depends on `::sshcomm::utils::askpass`, so if utils is not loaded it raises a runtime error — an **implicit dependency**.
  - Improvement ideas: (a) `source` `utils.tcl` at the top of `sshcomm.tcl`; (b) regenerate `pkgIndex.tcl` with `pkg_mkIndex` and register each file as a separate package; (c) document the dependency explicitly.
- **Version management**: `0.4` is scattered across `pkgIndex.tcl`, `package provide`, and the man page (`vset VERSION`). Consolidating them into a single source of truth would ease maintenance.
- **Leftover `.cvsignore`**: a remnant from CVS. If the migration to git is complete, it's a cleanup candidate.
- **Separating deprecated modules**: `hostsetup.tcl` (deprecated) and `git-ssh-proxy.tcl` (mostly deprecated) are already not loaded by `pkgIndex.tcl` and rely on the caller's explicit `source`. With deprecation as the occasion, we'd like to either move them aside into a `deprecated/` (or `attic/`) directory, or clearly distinguish them in the docs and packaging from the **active ones (`sshcomm.tcl` / `utils.tcl`)**. Note that `utils.tcl` is active (the core depends on it via `askpass-helper`), so it must be treated separately from the deprecated group.

## 4. Tcl 9 support

- The declaration is `require Tcl 8.5`, but the investigation environment runs on **Tcl 9.0.2 / snit 2.3.4 / comm 4.7.3**.
- Tcl 9 has several incompatible changes (the default encoding, behavior around `chan`/`file`, the handling of octal literals `0NNN`, etc.). For example, numbers like `040700` in `action/copy-uploaded-sysroot.tcl`, or permission notations like `00775` at `git-ssh-proxy.tcl:84`, need checking.
- Improvement ideas: if you want to keep both 8.5 and 9 working, run both series in CI. Alternatively, raise the lower bound to 8.6/9 to simplify.

## 5. Tests

The current state of `sshcomm.test`:

- **Unit (no connection required)**: `remote::cget`, `cookie-add/del`, and string generation for `unix sshcmd`.
  → These can always run in CI.
- **Integration (requires a real SSH)**: real connections to `127.0.0.1` etc., comm send/receive, rchan, the pool, and parallel connections.
  → These assume `known_hosts` registration and `StrictHostKeyChecking`, making them hard to run in CI.
- Improvement ideas:
  - **Clearly separate** connection-free tests from real-connection tests (via constraints or file splitting), and keep the former always green in GitHub Actions or similar.
  - **Add string-generation tests for `windows sshcmd`** (currently `unix` only). `windows` has no test coverage yet, but it is an important feature in long-standing use, so we'd like to build out table-driven tests for it just like `unix`.
  - **`gcloud sshcmd` / `-sshcmd-platform-options` / the plugin mechanism are [experimental], so they are exempt from tests** (see the status legend in [README.md](../README.md)). Tests will be added if and when gcloud returns to regular use.
  - A comment at the end of the test (`:291`–) notes that xauth/connection errors during parallel connections are unhandled. Investigation into the root cause of the contention remains a carryover.

### Test-exemption policy (experimental)

Features that are barely used are designated **"experimental"** and exempted from test authoring.
Mark them in the code with `# EXPERIMENTAL` as well, corresponding to the legend in this document and in [README.md](../README.md).

| Feature | Category | Tests |
|---|---|---|
| `unix sshcmd` | active | yes |
| `windows sshcmd` | active (important) | none yet → **recommended to add** |
| `gcloud sshcmd` | experimental | **exempt** |
| `-sshcmd-platform-options` | experimental | **exempt** |
| plugin mechanism (`register-plugin`/`-plugins`) | experimental | **exempt** |
| `rchan` (`open`/`socketpair`) | experimental | partial |

## 6. API consistency / naming

There are **three** paths for injecting ssh arguments, differing in insertion position and meaning. Users find this easy to confuse.

| Option | Insertion position | Intended use |
|---|---|---|
| `-ssh-options` (`:533`) | immediately after `ssh`/`gcloud` (at the head of the option group) | ssh global options such as `-v` |
| `-ssh-args` (`:179`, added in this branch) | between the forwarder and the host (toward the end of the command) | additional arguments you want placed right before the host |
| `-sshcmd-platform-options` [experimental] (`:529`) | arguments to the platform command itself | e.g. `gcloud compute ssh --tunnel-through-iap`. For `gcloud sshcmd`; test-exempt |

- Improvement ideas: make the roles of the three explicit in the documentation (see [architecture.md](../architecture.md) §10), or organize/consolidate them in the future. At minimum, we'd like to include usage examples in the README/man page showing how to choose among them.
- The hidden feature of making `-host` a **list** so that leading elements become ssh arguments (commit `2982612`) also somewhat overlaps in function with `-ssh-args`. We'd like to document its intent and recommended usage.

## 7. Documentation gaps

- **`sshcomm.man` / `.ja.man` / `.html` are nearly skeletons**. The `description` cuts off right after `[para]`. The real content exists only in the README and the code.
- Using this `docs/` directory as the primary source, fleshing out the doctools manual would make the distribution package complete.
- The README's recruiting comment "let me know if you know how to create a package release with a GitHub workflow" (`README.md:56`) can be picked up as a TODO for release automation.

## 8. Refactoring candidates (design level)

- **Making `::sshcomm::remote` a snit type**: `sshcomm.tcl:736` says `# XXX: This should be snit too, but remote migration of snit::type is not yet...`, so the remote-side code is not yet snit-based. If `definition` could be extended to transfer snit::type, the symmetry between local and remote code would improve.
- **`comm init` (`:448`) is tightly coupled to comm internals**: it depends on `comm`'s internal API such as `commNewConn`/`offerVers`/`defVers`. This makes it fragile against version differences in `comm`. Adding a version-compatibility layer would make it more robust.
- **Logging (`dlog`, `:110`)**: when `-debugchan` is empty, it merely accumulates into `debugLog`, with no path to retrieve it later (no read-out API). Either provide a means of recovery or clean this up.

## 9. Priorities (reflecting the author's intentions)

"The author's top-priority theme" and "ease of getting started (low risk)" are separate axes, so the ordering below takes both into account.

1. **[Top priority] Moving the control channel onto a dedicated socket (§0)**. The big item the author most wants to tackle, and a foundational improvement that sweeps away the keepalive conflict and stdout cross-talk. Because it entails a design change, completing items 2–3 below first as **groundwork** provides a safety net when reworking it.
2. **Groundwork (a) test development**: separating connection-free tests and putting them in CI, plus adding string-generation tests for `windows sshcmd` (§5). The foundation for regression detection. `gcloud` is exempt as it is experimental.
3. **Groundwork (b) explicitly noted small fixes**: ✅ done. Replaced `accept`'s Cookie read with `read-cookie` (non-blocking plus length cap plus timeout) and added connection-free unit tests (§0.7).
4. **Low-risk, high-impact documentation work**: fleshing out the man page, documenting how to choose among the `-ssh-*` trio, and **making the deprecations (`hostsetup` / `git-ssh-proxy`) explicit** (§6, §7, [plugins-and-hostsetup.md](../plugins-and-hostsetup.md)).
5. **Packaging cleanup**: resolving the `pkgIndex` / utils implicit dependency, and separating the deprecated modules (§3).
6. **Carryovers**: making the blocking `after` / sudo wait asynchronous (§1), Tcl 9 support (§4), making `remote` a snit type, and loosening the `comm` internal dependency (§8).
