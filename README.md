# OpenZombr

A macOS menu bar watchdog that detects — and automatically fixes — zombie-process
exhaustion of `kern.maxprocperuid`, the failure that makes a Mac unable to open a new
terminal.

Menu-bar-only (no Dock icon), SwiftUI + SwiftPM, no Xcode project. UI in German, code and
documentation in English.

---

## The incident this was built for

Machine: Mac mini M4 Pro (`Mac16,11`), 24 GB, macOS 26.6.2.

The symptom was simply: *at some point the terminal stops working, because you can no
longer open a new one.* The measured cause:

| Reading | Value |
| --- | --- |
| `kern.maxprocperuid` | 4000 |
| `kern.maxproc` | 6000 |
| Processes owned by the user | **3869** (97 % of the per-uid limit) |
| Of those, `<defunct>` zombies | **3326** |
| Leaking parents | exactly six `agency copilot` wrappers |
| Zombies per wrapper | ~600 after ~10 h uptime |
| Measured leak rate | **10 zombies/min (~600/h)** with six wrappers; ~8/min with fewer |
| Time from lockup at the moment of measurement | **~11 minutes** |

At ~97 % of the per-uid limit `fork()` begins failing with
`Resource temporarily unavailable`. That means no new terminal — and a great deal else
breaks at the same time, because almost everything on a Unix system forks.

The root cause is upstream: the `agency copilot` wrapper
(`~/.config/agency/CurrentVersion/agency copilot …`) repeatedly spawns
`agency send-telemetry-events` children and never calls `wait()` on them, so every child
stays in the process table as a zombie forever. The condition recurs roughly daily.

## What was tried, and what actually works

All of this was measured on the affected machine, and it is encoded directly in the app's
behaviour:

| Attempt | Result |
| --- | --- |
| `kill -9 <zombie_pid>` | **No-op.** A zombie is already dead. It cannot be killed; it only occupies a process-table slot until its parent reaps it. |
| `kill -CHLD <wrapper_pid>` — nudge the parent to reap | **Ineffective.** The zombie count did not move. |
| `kill <wrapper_pid>` (SIGTERM) | **Ignored.** The wrapper does not die. |
| `kill -9 <wrapper_pid>` (SIGKILL) | **Works.** The zombies are reparented to `launchd` (PID 1), which reaps them instantly. |

Verified effect of killing the six wrappers:

```
user processes: 3892 → 565
zombies:        3350 → 29
slots freed:    ~3400
```

Crucially, **the wrapper's live `copilot` child survives**. It is simply orphaned
(`ppid` becomes 1) and keeps running. This was verified explicitly, and it is the reason
automatic cleanup is safe here: killing a leaking wrapper is far less destructive than it
sounds.

Because a zombie can never be the target, **OpenZombr only ever signals parents**.

## What the app does

* Polls the process table every 60 s (configurable) via `sysctl(KERN_PROC_ALL)` — not
  `ps`, because shelling out would itself `fork()`, precisely the operation that is
  failing when things go wrong.
* Shows a live figure in the menu bar with normal / warning / critical appearance. The
  glyph changes *shape* as well as colour, so it stays readable in light and dark menu
  bars.
* Computes an **ETA to fork failure** from the observed growth rate, fitted over a
  10-minute window. This is the single most useful number: during the incident the
  machine was ~11 minutes from lockup and nothing said so.
* Thresholds are **percentages of `kern.maxprocperuid`** (default: warning 50 %,
  critical 75 %), read from sysctl at runtime and never hardcoded, so they stay correct
  if the limit changes.
* **Automatic cleanup** when the critical threshold is crossed: finds parents owning more
  than N zombies (default 100), terminates them, then re-samples and *verifies* the
  zombie count actually dropped. Toggleable, and also available on demand via
  *Jetzt aufräumen*.
* Notifies on threshold crossings and after every cleanup, with hysteresis so it notifies
  once per crossing rather than once per poll.
* Writes a CSV evidence log to `~/Library/Application Support/OpenZombr/` — this is the
  material for an upstream bug report against `agency`.

### Safety rules for the killer

These are the rules that matter most, and each one is covered by a unit test:

* **Never PID 1** (and never PID 0, the kernel task), and never a process owned by
  another uid.
* **Never the app's own process, nor any of its ancestors.** The ancestor chain is walked
  from the live process table on every poll and never hardcoded. This is not theoretical:
  during the incident the user's own chain was
  `bash → copilot(87594) → agency copilot(87537) → GitHub Copilot.app(4264)`, and PID
  87537 was an `agency` wrapper holding ~600 zombies — a perfect target by every other
  rule. Killing it would have severed the user's active session.
* **Never a zombie.** Only parents above the zombie threshold are ever considered.
* **Never a process that still hosts an active session.** See below — this is the rule
  that keeps working once the app is launched at login.
* **SIGTERM before SIGKILL.** The known offender ignores SIGTERM, so escalation is
  required — but SIGTERM is still attempted first, escalation happens only after a grace
  period, and which signal actually worked is recorded.
* **Allowlist/denylist of name patterns**, defaulting to `agency` only, user-editable.
  Matching is plain case-insensitive substring, not regex, because a malformed regex
  silently matching everything would be a catastrophic failure mode for something that
  sends SIGKILL. An empty allowlist matches *nothing*: the policy is fail-closed.

### Why ancestry is not enough

Ancestor protection only works while OpenZombr is a *descendant* of the process it must
not kill. That holds when the app is started from a terminal inside a session, and it is
what caught the near-miss above. It does not hold in the deployment that matters:

Started at login by `launchd`, the app's parent is PID 1. Its ancestor set is therefore
just `{self, 1}` and protects **nothing** of the user's session tree — and `agency`
wrappers are exactly what the default allowlist targets. Ancestry silently stops
protecting anything at precisely the moment the app becomes a background daemon.

This was verified directly, by running the same binary two ways:

| How the process was started | Protected set |
| --- | --- |
| child of a shell inside a session | `{1, 1332, 1394, 4264, 22292, 22296}` |
| orphaned to `ppid = 1`, as under launchd | `{1, 22308}` |

(The set is recomputed from the live process table on every poll, so it can never go
stale — a former ancestor drops out as soon as it stops being one. That is what the two
different results above demonstrate.)

### The liveness guard

The guard that does survive launch-at-login is based on what the wrapper is *doing*, not
on how the app itself was started. The naive form of this does not work, and it is worth
saying why: **every** leaking wrapper has live children, because the leak *is* a stream of
short-lived children. Measured on the affected machine, all four wrappers looked identical
by that measure:

```
pid 86183 agency — 49 zombies, 2 live children
pid  1332 agency — 47 zombies, 2 live children   ← hosting the user's live session
pid 17831 agency — 11 zombies, 2 live children
```

The signal that *does* discriminate is a live child running a **different executable**.
The telemetry children `agency` spawns are themselves called `agency`; a wrapper doing
real work additionally has a `copilot` child, which is not a self-spawn. So OpenZombr
counts live children whose executable differs from the parent's, and:

* never signals a parent with such a child (default, toggleable in preferences), and
* orders candidates idle-first, so a wrapper with no session is always reaped before one
  that has work attached, regardless of zombie counts.

The honest consequence: on a machine where every wrapper is hosting a session, OpenZombr
will report *"Bereinigungs-Kandidaten: keine"* and clean nothing, rather than guess. In
the actual incident several of the six wrappers were left over from closed sessions and
would have had no session child at all.

### Killing a wrapper is survivable — but that is not the safety argument

Empirically verified during the incident: when an `agency` wrapper is SIGKILLed, its live
`copilot` child **survives**. It is simply orphaned, reparented to `launchd`, and keeps
running. Killing six wrappers took the machine from 3892 → 565 processes and 3350 → 29
zombies without terminating a single live session child.

This is why the "spare active sessions" toggle exists and can be turned off without
disaster. It is deliberately **not** the default, because *"the damage happened to be
recoverable"* is not a safety argument — it is a mitigation. The default is to leave a
working process alone and tell the user why.

## Build and install

```bash
make build      # debug build
make test       # unit tests
make probe      # print one live reading and exit
make bundle     # build dist/OpenZombr.app
make install    # install to /Applications and launch
```

Requires macOS 14+ and a Swift 6.1 toolchain. Launch at login is offered via
`SMAppService` and only works from the installed `.app`.

### Verifying the reader by hand

```bash
make probe
ps -Ao stat | grep -c '^Z'     # zombie count, all users
```

The two zombie counts should agree.

## Repository layout

```
Sources/OpenZombr/        app code (library target OpenZombrKit)
Sources/OpenZombrApp/     executable entry point
Tests/OpenZombrTests/     unit tests
scripts/                  .app bundling
```

See `AGENTS.md` for the constraints that apply when changing this repository.

## Licence

MIT. See `LICENSE`.
