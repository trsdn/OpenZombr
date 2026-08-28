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
counts live children whose executable differs from the parent's, and never signals a
parent that has one (default, toggleable in preferences).

### That is still not enough on its own: the idle override

Existence of a session child is *also* not the signal. This was established against the
incident itself. Wrapper 60581 was one of the six that had to be killed, and its live
children at the time were:

```
60640 60581 S   .../copilot --no-auto-update --log-dir ...
93295 60581 Ss  .../agency send-telemetry-events --queue-file ...
```

A live `copilot` child — a different executable — so a rule based purely on *having* a
session child protects it. Killing it was nonetheless exactly right: it freed 308 slots
and the `copilot` child survived by reparenting to `launchd`. Every one of the six looked
like this. A guard that stopped at "has a session child" would have protected all six and
left the machine to hit the fork limit, which is to say it would have prevented the one
fix the app exists to perform.

The wrappers that needed reaping were **finished sessions whose `copilot` child was still
resident**. What separates those from a working session is not the child's existence but
its behaviour: a finished session stops consuming CPU. So OpenZombr samples accumulated
user + system CPU time (`proc_pidinfo(PROC_PIDTASKINFO)`, converted through the mach
timebase — the raw counters are in mach absolute time units, and skipping that conversion
under-reports by a factor of ~41.7 on Apple Silicon) for each session child on every poll.
A child whose CPU total has not moved has run for zero cycles in between.

The window has to be measured in **hours**. Sampling over 20 s during the incident showed
the user's *own* session child as idle, purely because they were between turns:

```
1394  1:12.56 -> 1:12.56  IDLE    <- the user's own session, just thinking
17890 0:30.89 -> 0:31.79  ACTIVE
86242 1:48.58 -> 1:49.20  ACTIVE
```

A short window would therefore reap a live session mid-thought. The default threshold is
**2 hours** of zero CPU, configurable: long enough that thinking, reading, or lunch is
never mistaken for a finished session, short enough that a machine leaking ~600 zombies an
hour is rescued well before the limit. The wrapper that gave the game away on the day had
been idle for five hours.

Candidates are ordered idle-first, so a wrapper with no session at all is reaped before
one whose session is merely stale, which is reaped before an active one is even
considered.

Two deliberate conservative choices:

* **No history means busy.** Idleness can only be established by observing two readings,
  so for the first couple of hours after OpenZombr starts, nothing is eligible through the
  idle override. That is correct: at that point the app genuinely does not know.
* **One unreadable child protects the parent.** A wrapper counts as idle only when *every*
  session child is known to be idle.

#### Idle heißt nicht „null CPU"

A session that is finished still ticks. Measured on the affected machine over a 3 minute
window:

| pid | role | ΔCPU over 180 s | duty cycle |
|---|---|---|---|
| 1394 | session between turns | +0.40 s | 0.22 % |
| 29624 | fresh wrapper spawn | +0.01 s | 0.006 % |
| 86242 | session doing work | +4.56 s | 2.5 % |
| 17890 | session doing work | +7.45 s | 4.1 % |

Treating *any* CPU increase as activity would therefore reset the idle clock on every
poll for ever, and the override could never fire — the same "never clean anything"
outcome it exists to remove. Activity is instead a rate: CPU consumed since the previous
poll divided by the time since it, compared against a threshold of **1 % of one core**.
That sits an order of magnitude above the measured heartbeat and an order of magnitude
below the measured floor of real work.

The rate is measured per poll, not since the last activity. Measuring it since the last
activity would dilute a genuine wake-up by however long the process had been idle
beforehand, so a session resuming after three hours would take hours to be recognised as
working again. A slow trickle cannot creep past the threshold either, because a trickle's
per-poll rate is below it by definition.

#### Beobachtet auf der betroffenen Maschine

`OpenZombr --idle-watch <Dauer> <Schwelle>` polls repeatedly and prints the
classification without signalling anything. It exists because the override cannot be
observed any other way: `--probe` takes a single reading and idleness needs at least two,
while the menu bar app has the history but no textual output. A short threshold shows the
behaviour without waiting out the two hour default.

Run over 5 minutes with a deliberately reckless 2 minute threshold:

```
pid 86183 agency — 74 Zombies, Sitzung 86242, idle unter 1 Min. → AKTIV (geschützt)
pid 17831 agency — 36 Zombies, Sitzung 17890, idle unter 1 Min. → AKTIV (geschützt)
pid  1332 agency — 71 Zombies, Sitzung  1394, idle 5 Min.       → INAKTIV (freigegeben)
```

Two wrappers whose sessions were working stayed protected throughout, one of them
(17831) oscillating in and out as its session did sporadic work — which is exactly the
required behaviour. The third, 1332, was **the user's own live session**, idle only
because they were between turns, and a two minute threshold released it. Nothing was
killed: 1332 sits far below the 100 zombie threshold.

That is the whole argument for the two hour default in one run. The signal discriminates
correctly, but only a window measured in hours separates "session finished" from "user is
thinking".

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
