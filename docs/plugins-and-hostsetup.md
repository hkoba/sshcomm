# Plugin Mechanism and Auxiliary Modules (host-setup and others)

In addition to the `sshcomm.tcl` core itself, the repository includes a set of
auxiliary modules designed to be "shipped to a remote and used there". This
document explains that plugin mechanism and each of the auxiliary modules.

> **Active vs. deprecated status (as of 2026-06, author's policy)**
>
> | Module | Status | Notes |
> |---|---|---|
> | Plugin mechanism (`register-plugin` / `-plugins` shipping, §1) | **experimental** | No usage record for ~10 years. Exempt from tests (also marked `# EXPERIMENTAL` in `sshcomm.tcl`) |
> | Utilities in `utils.tcl` (`::sshcomm::utils`) | **active** | The core depends on them via `askpass-helper`. [api-reference.md](api-reference.md) §6 |
> | `hostsetup.tcl` (`::host-setup`, §2 / §3) | **deprecated** | Not used in recent years. Kept below as a record of its history and implementation |
> | `git-ssh-proxy.tcl` (§4) | **near-deprecated** | Unused for several years. The possibility of a future revival is left open |
>
> Note: `utils.tcl` calls `register-plugin`, but **the utilities themselves are used directly by the core and are active**.
> Only the path where they are "registered as a plugin and shipped in bulk" is experimental (dormant) — that is the distinction.
>
> For how deprecated modules are handled in packaging (the proposed separation), see
> [improvement-notes.md](todo/improvement-notes.md) §3.

## 1. Plugin Mechanism [experimental]

> ⚠️ **experimental**. Registration via `register-plugin` and bulk shipping to a remote via `-plugins`
> have no usage record for ~10 years and are exempt from tests. This is also noted as `# EXPERIMENTAL` in the
> `sshcomm.tcl` code. However, the utilities in `utils.tcl` themselves are used directly by the core and are active
> (see the distinction in the table above).

### How it works

- `sshcomm::register-plugin ?ns?` (`sshcomm.tcl:45`) registers a namespace into `pluginList`.
- `utils.tcl` / `hostsetup.tcl` / `git-ssh-proxy.tcl` check for the existence of
  `register-plugin` **at the moment they are loaded** before registering themselves
  (a defensive measure so they still work standalone even when `sshcomm` is not loaded).
- `sshcomm::ssh` (`sshcomm.tcl:33`) creates the `connection` with `-plugins [list-plugins]` attached.
- The `connection` uses `current-definition` (`:370`) to bundle `::sshcomm` plus the plugin namespaces
  into a `definition`, and ships it to the remote during `remote setup`.

In other words, a plugin is a mechanism for registering **"an additional namespace you want to ship to the remote together"**.

### Important note (packaging)

`pkgIndex.tcl` **loads only `sshcomm.tcl`**. Therefore:

- `package require sshcomm` alone does not register `utils` / `host-setup` / `git-ssh-proxy`.
- To use or ship them, the caller must explicitly `source` them.
- The `askpass-helper` in `sshcomm.tcl` (`:148`) calls `::sshcomm::utils::askpass`, so there is an
  implicit dependency that fails at runtime if utils is not loaded.

→ A candidate for improvement. See [improvement-notes.md](todo/improvement-notes.md).

## 2. host-setup — Declarative Configuration Management DSL (`hostsetup.tcl`) [deprecated]

> ⚠️ **deprecated**. `::host-setup` has not been used in recent years, and new usage is not recommended.
> The following is kept as a record of its design history and implementation. It is not needed for using the `sshcomm` core.

The `::host-setup` namespace is a small configuration management framework
(a tiny version of Ansible/Chef) that **converges host configuration using idempotent "rules/targets"**.
It was intended to be shipped to a remote with `sshcomm` and to apply the "desired state" on the remote side.

### 2.1 Basic concepts

- **rule**: A unit that groups related targets. Internally it is compiled into a single `snit::type`.
- **target**: An individual convergence unit. It has `check`/`ensure` (the decision) and `action` (the application).
- **check-all / apply-all**: Inspect/apply all targets in a rule in order (auto-generated on the type).

### 2.2 Defining a `rule` (`hostsetup.tcl:120`)

```tcl
rule etc-git {
    -title "..."          ;# Required. An error is raised if -title is missing
    -prefix ""            ;# Each option is expanded into an option on the type
    -etc /etc
    {-user
        help "Used for git config user.name"
        subst {[exec git config user.name]}   ;# Compute the default value with an expression
    } ""
} {
    target gitignore { ... }
    target git-init  { require "gitignore" ... }
    ...
}
```

- Specifying the rule name `__FILE__` makes the source file name (without extension) the rule name.
- `build-opts` (`:95`) parses the option specification and converts it into a sequence of `option` declarations.
  Each option can carry `help`/`default`/`subst`/`type` (UI hints such as `textarea`).
- The rule body is embedded into `type_template` (`:16`) via `string map` and compiled as a `snit::type`.
- On compilation failure, if the environment variable `DEBUG_HOSTSETUP` is true, an error is thrown that
  includes the detailed `snit::compile` result (debugging support).

### 2.3 The `target` macro (`hostsetup.tcl:198`, `snit::macro`)

Each target is defined with the following three elements.

| Key | Role |
|---|---|
| `check` / `ensure` | Decides "is the state desirable?". Returns `{boolean detail...}` (if `ensure` is omitted, `check` is reused) |
| `action` | The convergence processing to run when the state is undesirable |
| `require` | The names of other targets that must precede it (dependencies) |
| `doc` | A description |

The generated `ensure $target` method evaluates `check`, and then:

- true → `yes`
- false → runs `action`, then re-evaluates `check`

This is the **"decide → apply → re-decide"** idempotent loop (`hostsetup.tcl:225`).

### 2.4 Lifecycle hooks

- `initially body` (`:241`) → the `initialize` method. Called on `reset`.
- `finally body` (`:238`) → the `finalize` method. Called after a successful `apply-all`.
- `reset` (inside the template): initializes the `state*` variables and calls `initialize`.

### 2.5 Operations auto-generated on the type

From `type_template` (`hostsetup.tcl:16`):

- `{list target}` (typemethod): the list of target names
- `check-all`: inspect all targets. Returns `{NG ... OK ... DEBUG ...}` at the first NG
- `apply-all`: apply all targets. Returns the result after `finalize`
- `doc $target` / `check $target` / `ensure $target`: per-target operations

### 2.6 Registering and looking up rules

| proc | Description |
|---|---|
| `rule-new name args` (`:73`) | Create a `snit::type` instance from a rule name |
| `list-rules` (`:90`) | List registered rules |
| `find-rule` / `find-type-of-rule` (`:79`/`76`) | Rule name → definition/type |
| `list-targets-of-rule rule` (`:86`) | List a rule's targets |
| `load-builtin-actions` (`:273`) | Load `action/*.tcl` and record them as built-in rules |
| `is-builtin-rule` (`:283`) | Whether a rule is built-in (built-ins are allowed to be redefined) |
| `import-into` / `source-once` (`:251`/`257`) | Import auxiliary sources (prevents multiple sourcing) |

> Note: procs used inside a macro must be defined with `_proc` rather than `proc`
> (`from` / `__EXPAND` inside the `utils` variable, `:177`–). This is due to the compilation context of snit::macro.

## 3. Built-in Rules (`action/*.tcl`) [deprecated]

> ⚠️ Part of host-setup (§2), and likewise **deprecated**. Kept as concrete examples of the `host-setup` DSL.

The set of built-in rules loaded by `load-builtin-actions`. They also serve as concrete examples of the `host-setup` DSL.

### `etc-git` (`action/etc-git.tcl`)
Places `/etc` under git management. Targets: `gitignore` (install `.gitignore`) → `git-init`
(`git init --shared=0600`) → `git-config` (set user.name/email) → `commit-all`
(`git add -A && git commit` for uncommitted changes). Ordering is expressed with `require`.

### `sshd_config` (action/sshd_config.tcl)
Disables password login in `sshd_config`. Reads the config file in `initially`,
converges each target (`PasswordAuthentication no`, etc.) via `test`→`do APPEND/REPLACE/OK`, then
writes it back in `finally` and restarts sshd (auto-detecting `systemctl`/`service`).
It detects and replaces config lines with regular expressions, with a guard that raises an error on duplicate settings.

### `copy-uploaded-sysroot` (action/copy-uploaded-sysroot.tcl)
Expands and copies `/root/upload/sysroot/*` into `/`. The `target copied` detects
missing/size-diff/content-diff and copies only the differences (preserving mtime and attributes).
In addition, it converges the owner and permissions of `/root`, `/etc/pki/tls/private`, and `/etc/sudoers.d`.

## 4. git-ssh-proxy (`git-ssh-proxy.tcl`) [near-deprecated]

> ⚠️ **near-deprecated**. Unused for several years. However, if the need for multi-hop SSH / connection
> multiplexing returns it could be revived, so it is not removed and is kept as a record of the implementation.

An independent module (snit::type + CLI) that generates a `GIT_SSH` proxy script using SSH's **ControlMaster**.
An aid for multi-hop SSH (via a bastion) and connection multiplexing.

- `connect` (`:73`): establishes a master connection with `ssh -A -M -o ControlPath=...` and
  sets the path of the generated zsh script into `$::env(GIT_SSH)`.
- The generated script (`ourScriptTemplate`, `:91`) interprets ssh options with zsh's `zparseopts`, and
  if the target host is the same as the original host it goes via the master socket (`ssh -S`); if different, it
  performs a two-stage ssh using the original host as a bastion (`ssh -A -S $orig ssh -q $opts $host`).
- `scriptFn` (`:31`) chooses a temporary directory in the order `/run/user/<uid>` → `~/.ssh/tmp`.
- It can also be run directly as a CLI (`:127`, `tclsh git-ssh-proxy.tcl host ...`).

This is a component intended to combine with the `sshcomm` core's `-prefer-git-ssh` (prefer using `$GIT_SSH`),
so that sshcomm's own connections can go through a bastion or be multiplexed.
