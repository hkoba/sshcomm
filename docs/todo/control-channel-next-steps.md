# Control channel on a dedicated socket — plan for the remaining work

On branch `17-control-socket`, "moving the control channel onto a dedicated socket" ([improvement notes](improvement-notes.md) §0) has been
implemented and verified through Phase 0–4 (opt-in via `-control-channel socket`; the default remains `pipe`).
This document records the plan for the **two remaining tasks**.

- Task 1: Exposing the remote **stderr** to the application (implementing `-remote-stderr merge|channel`)
- Task 2: Deciding **whether to flip the `-control-channel` default to `socket`**

Implemented groundwork (for reference): `control-handoff` / `control-readable` / `accept__control` /
`forward new` / `remote app-output` / `-on-remote-output` / `gen-cookie` in `sshcomm.tcl`, plus `docs/architecture.md` §3.

---

## Task 1: Exposing the remote stderr to the application

### Background (why this is hard)

The SSH pipe is opened with `open [list | ssh ... tclsh] w+`, which gives us **stdin+stdout only**.
The remote `tclsh`'s stderr merely flows, via ssh's stderr, into the stderr of the local ssh process,
and the current `-remote-stderr local` (the default) does not capture it. What `-on-remote-output` picks up is stdout only.
However, as described below, **if we capture the ssh process's stderr locally** we can capture it (with no remote-side changes).

### Preferred: `channel` — receive ssh's stderr on a local `chan pipe` (✅ implemented)

> **Implemented** (branch `17-control-socket`). It works with `-remote-stderr channel` plus the
> `-on-remote-stderr` callback, and has been integration-tested in both pipe and socket modes. The following are design notes.

`ssh host cmd` **relays the stderr of cmd (the remote tclsh) to the ssh process's stderr (fd 2)**.
In addition, sshcomm already launches ssh with **`ssh -T` (no PTY)**, so the remote stdout and stderr are
**kept on separate fds** (a PTY would merge them). Therefore, simply by redirecting ssh's fd 2 to a local `chan pipe`,
we can capture stderr separately **without any remote-side dup or `chan push` at all**.

```tcl
# Inside remote open:
lassign [chan pipe] mySSHError writeErr
set mySSH [open [list | {*}$cmd 2>@ $writeErr] w+]
close $writeErr   ;# ★mandatory: unless the parent releases the write end, mySSHError will never reach eof
fconfigure $mySSHError -buffering line
fileevent $mySSHError readable [list $self remote read-error]
```

`remote read-error` reads lines and dispatches them to `-on-remote-stderr` (a callback symmetric to
`-on-remote-output` on the stdout side).

- **Verified (confirmed in this environment)**:
  1. `2>@ $chan` separates a child process's stderr onto the `chan pipe` (it is not mixed with stdout).
  2. A remote `puts stderr` under `ssh -T 127.0.0.1 tclsh` reaches the local stderr pipe.
- **Advantages**:
  - No remote-side changes (the old proposal B, "remote dup / `chan push`", turned out to be unnecessary).
  - **Works in both modes** (this stderr pipe is orthogonal to `-control-channel`; it works in either pipe or socket mode).
  - Keeps stdout/stderr separated.
- **Caveats**:
  1. The **`close $writeErr` immediately after `open` is mandatory** (for eof; it ensures only the child holds the write end).
  2. ssh's own diagnostics (`-v` output, `Warning:`, connection errors, etc.) ride on the same stderr. It is therefore
     **mutually exclusive** with the existing `-ssh-verbose` `2>@ stderr` (which sends ssh's stderr to the local stderr) — fd 2 can have only one destination.
     Their precedence needs to be reconciled (e.g. when `-remote-stderr channel` is set, the verbose diagnostics also go to the pipe).
  3. **Close `mySSHError` in the destructor too.** fd hygiene: a later ssh child might inherit the read end, but that is harmless
     (the write end was already closed by the parent right away and is not inherited, so this connection's stderr eof arrives correctly).
  4. Alternative sshcmds such as `gcloud` work the same way as long as they "relay cmd's stderr to their own process's stderr"
     (gcloud is experimental; to be confirmed).
- **Test**: in the connection-required integration test, verify that in both socket and pipe modes the `E` of
  `comm send {puts stderr "E"; flush stderr; list ok}` is delivered to `-on-remote-stderr`.

### Optional: `merge` — fold stderr into stdout (the pipe)

A simpler variant for when you want stdout/stderr combined into a single stream. It merges the `remote open` redirection into stdout
(equivalent to `2>@1`; the Tcl version needs checking) and delivers them mixed into `-on-remote-output` in socket mode.
With `channel` (above) available, this is basically unnecessary. If the application wants them mixed, it can just bundle `channel`'s two callbacks.

### Order of work (Task 1)

1. **Implement `channel`** (the stderr pipe in `remote open` + `close $writeErr` + `remote read-error` +
   `-on-remote-stderr` dispatch + reconciling the exclusivity with `-ssh-verbose` + closing in the destructor + the integration test).
2. (Optional) `merge`, separately, if requested. Low priority, since `channel` largely covers it.

> Note: an earlier version described `channel` as "hard because it needs a remote-side dup", but we have now empirically
> confirmed that the local stderr pipe approach above (the author's suggestion) makes it **remote-change-free and works in both modes**.

---

## Task 2: Whether to make `socket` the default for `-control-channel`

### Current state

The default is `pipe` (fully backward compatible). `socket` is opt-in. The goal (exposing the remote stdout) is already achieved with socket.

### Obstacles to flipping the default to `socket` (important)

- **socket-mode teardown is unix-only**: in socket mode the destructor uses `exec kill {*}[pid $mySSH]`
  (because after the remote exits, ssh lingers on the forwarding channel and `close $mySSH` would hang).
  Since **`exec kill` does not work on Windows (`plink`)**, making `socket` the default would **break Windows**.
  → Before flipping the default, porting the socket-mode teardown (a way to terminate the ssh child on Windows) is mandatory.
- **Newness**: the socket path has a short track record. A certain soak period is desirable.
- **Connection cost**: the handoff adds one extra round trip (connect becomes slightly slower).
- **stderr handling**: while Task 1 is undecided, with a socket default the stderr (unless `merge` is specified) still goes to the
  local stderr as before, and remains unreadable by the application. It is natural to consider the default flip and the stderr policy as a set.

### Recommendation

- For now, **keep the default at `pipe`** (socket stays opt-in).
- Conditions for considering a flip: (a) make the socket teardown portable (or make the default flip **unix-only**, branching on
  `tcl_platform`), (b) settle the Task 1 (stderr) policy, (c) complete the soak.
- Alternative: leave the overall default unchanged and select the default **per platform** (socket on unix, pipe on Windows),
  or document "explicit opt-in recommended" and leave the default as is.

### Order of work (Task 2)

1. Make the socket teardown portable (turn `exec kill` into a platform-specific termination of `pid $mySSH`;
   on Windows, `taskkill` etc., or investigate ssh multiplexing / `-O exit`-style approaches).
2. Try a unix-only default flip (socket default only when `tcl_platform(platform) eq "unix"`).
3. Decide on the overall default after the soak.

---

## Summary (list of remaining tasks)

| # | Task | Size | Prerequisites |
|---|---|---|---|
| 1a | ✅ **done** `-remote-stderr channel` (receive ssh stderr on a local `chan pipe`, dispatch to `-on-remote-stderr`; both modes) | small | — |
| 1b | (optional) `-remote-stderr merge` (fold stderr into stdout, socket-only) | small | largely covered by 1a |
| 2a | make socket teardown portable (drop `exec kill`) | medium | Windows test environment |
| 2b | flip the `-control-channel` default (unix-only first) | small | 2a, 1, soak |

Keep each task consistent with the design notes in [improvement notes](improvement-notes.md) §0.
For testing, follow the existing policy: prioritize connection-free unit tests, and place the parts requiring a real ssh under `-integration`.
