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
* **SIGTERM before SIGKILL.** The known offender ignores SIGTERM, so escalation is
  required — but SIGTERM is still attempted first, escalation happens only after a grace
  period, and which signal actually worked is recorded.
* **Allowlist/denylist of name patterns**, defaulting to `agency` only, user-editable.
  Matching is plain case-insensitive substring, not regex, because a malformed regex
  silently matching everything would be a catastrophic failure mode for something that
  sends SIGKILL. An empty allowlist matches *nothing*: the policy is fail-closed.

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
