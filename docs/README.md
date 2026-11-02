# sshcomm Developer Documentation

*🌐 Language: **English** (this page) / [日本語](README.ja.md)*

This directory collects the **results of a full code investigation** of the
`sshcomm` library — an internal design documentation set to support future
improvement work.

For end-user usage, see the repository-root [`../README.md`](../README.md).
This directory focuses on "what is going on inside," "why it is the way it is,"
and "where it should be fixed."

## What sshcomm is (in one line)

[tcllib's `comm`](https://core.tcl-lang.org/tcllib/doc/trunk/embedded/md/tcllib/files/modules/comm/comm.md)
lets Tcl interpreters send Tcl scripts to each other over a TCP socket, but the
channel is **plaintext and unauthenticated**. `sshcomm` tunnels that `comm`
traffic **through an SSH port-forward** and adds **cookie-based connection
authentication**, giving you secure remote scripting.

Its defining feature is that **nothing needs to be pre-installed on the remote**.
All the remote needs is `tclsh`; even without the `comm` package, the local side
serializes its own namespace definitions (including `comm` itself) and ships them
over SSH stdin to be reconstructed inside the remote interpreter.

## Documentation map

| File | Contents |
|---|---|
| [architecture.md](architecture.md) | Overall architecture: two-channel model, connection-establishment sequence, cookie authentication, code shipping, remote-server structure, sshcmd platform abstraction |
| [api-reference.md](api-reference.md) | Public API, `connection` option list, methods, remote API, `utils`, deprecated API |
| [plugins-and-hostsetup.md](plugins-and-hostsetup.md) | Plugin mechanism, auxiliary modules (`host-setup` [deprecated], `git-ssh-proxy` [near-deprecated]) |
| [improvement-notes.md](todo/improvement-notes.md) | Improvement notes. **Top-priority theme = moving the control channel onto a dedicated socket**, known `XXX`/`BUG` markers, technical debt, Tcl 9 support, packaging, security, tests |
| [control-channel-next-steps.md](todo/control-channel-next-steps.md) | **Plan for the remaining work** on the control-channel socketization (Phases 0–4 implemented): remote stderr exposure (`-remote-stderr merge\|channel`), the `-control-channel` default-flip decision |

> **About line numbers**: the `sshcomm.tcl:NNN` / `:NNN` line numbers still found
> in these docs are **no longer maintained** (they were only indicative when
> written, and are often stale). **The anchor is the symbol name** (proc /
> method / option name), so grep by name.

## Development direction (as of 2026-06)

- **Top-priority improvement theme**: separate the control channel off the SSH
  stdin/stdout pipe onto a `forward new raw`-style dedicated socket, so the
  remote's **stdout/stderr can be opened to the application**.
  Detailed analysis in [improvement-notes.md](todo/improvement-notes.md) §0.
- **`hostsetup.tcl` (`::host-setup`) is deprecated**, **`git-ssh-proxy.tcl` is
  near-deprecated** (may revive in the future). `utils.tcl` is active.
  → see [plugins-and-hostsetup.md](plugins-and-hostsetup.md).
- **Rarely-used features are marked "experimental" and exempted from tests**:
  `gcloud sshcmd`, `-sshcmd-platform-options`, the plugin mechanism (`-plugins`
  transfer). Conversely `windows sshcmd` has no tests yet but has been used for
  years and is **active and important** (tests are wanted).

## Feature-status legend

These docs and the code comments classify each feature into three tiers.

| Tier | Meaning | Tests |
|---|---|---|
| **active** | used and maintained day to day | in scope (worth adding if missing) |
| **experimental** | barely used, unstable API, may change/be removed | **exempt** |
| **deprecated** | legacy, not recommended for new use | exempt |

| Feature | Tier | Notes |
|---|---|---|
| `connection` / `comm` / `definition` / `remote` (core) | active | the core |
| `unix sshcmd` | active | has tests |
| `windows sshcmd` (`plink`) | active (important) | no tests yet → adding recommended |
| `utils.tcl` utilities | active | the core depends on it (`askpass-helper`) |
| `rchan` (`rchan open` / `socketpair`) | experimental | partially tested |
| `gcloud sshcmd` | experimental | test-exempt |
| `-sshcmd-platform-options` | experimental | added for gcloud. test-exempt |
| plugin mechanism (`register-plugin` / `-plugins` transfer) | experimental | no real usage in ~10 years. test-exempt |
| `host-setup` (`hostsetup.tcl` / `action/*.tcl`) | deprecated | |
| `git-ssh-proxy.tcl` | deprecated (nearly) | may revive |

## Basics

- **Version**: 0.4 (`pkgIndex.tcl` / `package provide sshcomm 0.4`)
- **Dependencies**: `snit`, `comm` (both from tcllib). Declares `require Tcl 8.5`
- **Verified environment (at investigation time)**: Tcl 9.0.2 / snit 2.3.4 / comm 4.7.3
- **Author**: Hiroaki Kobayashi (hkoba) / Copyright 2005-2020
- **Repository**: https://github.com/hkoba/sshcomm

## File list (repository root)

| File | Role |
|---|---|
| `sshcomm.tcl` | The core. The `::sshcomm` namespace, `sshcomm::connection` (local-side object), `definition` (code shipping), `::sshcomm::remote` (remote-side server) |
| `utils.tcl` | `::sshcomm::utils` general-purpose utilities (dict/file/askpass, etc.). A plugin |
| `hostsetup.tcl` | [deprecated] `::host-setup` declarative configuration-management DSL. A plugin |
| `action/*.tcl` | [deprecated] host-setup built-in rules (`etc-git` / `sshd_config` / `copy-uploaded-sysroot`) |
| `git-ssh-proxy.tcl` | [near-deprecated] `GIT_SSH` proxy generator using SSH ControlMaster. A plugin and a CLI |
| `sshcomm.test` | `tcltest`-based test suite |
| `pkgIndex.tcl` | Package index (loads only `sshcomm.tcl`) |
| `sshcomm.man` / `.ja.man` / `.html` | doctools manual (currently little more than a skeleton) |
| `README.md` | End-user usage and installation instructions |
