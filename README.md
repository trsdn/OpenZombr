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

### The evidence log, and one known anomaly in the archive

Rows are appended to `zombie-evidence.csv`. The header is written when the file is
created, so if a later version adds a column the log is rotated aside to
`zombie-evidence.N.csv` and a fresh one started, rather than continuing to append wider
rows under a narrower header.

That check was added one row too late. **`zombie-evidence.1.csv` contains 86 rows of 13
fields under its matching 13-column header, and one final row of 14 fields** — written by
the build that had the new `session_signal` column but not yet the rotation check:

```
2026-08-28T18:09:53Z,801,239,4000,20.0,3199,0.00,,86183,agency,115,cpu_idle=unknown;log_age=8,poll,
```

A strict CSV reader will reject or misparse that last line. It is left in place
deliberately. This file exists to be evidence for a bug report, and an evidence file that
has been edited after the fact is worth less than one with a disclosed anomaly — so the
anomaly is disclosed here instead of being quietly repaired. Drop the final line when
parsing that particular archive; every file written since is internally consistent.

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

### Why two signals and not one: delegated work

**Do not remove the log signal as redundant.** It exists because of a specific measured
failure, and without that evidence in front of you the second signal looks like
belt-and-braces.

CPU duty cycle cannot see a session that delegates its work. Sampled at 15 s intervals
while session child 1394 ran `swift build` and `swift test` continuously:

```
t+15s 1394=0.0000%   t+60s 1394=0.0000%   t+105s 1394=0.0000%
t+30s 1394=0.0000%   t+75s 1394=0.0000%   t+120s 1394=0.0000%
t+45s 1394=0.0000%   t+90s 1394=0.0000%
```

Zero for the process, and zero for its whole subtree, while it was maximally busy. Each
build ran in a short-lived grandchild that exited before the next sample and took its
accumulated CPU with it. Independently reproduced over a 45 s window: 1:51.45 → 1:51.46,
a 0.01 s delta, 0.022 % duty — below even the tightened threshold.

So a CPU-only design classifies a flat-out session as idle, and it fails in the direction
that gets a live session killed. The log signal catches exactly this case: in the same
measurement the log age was 15 s while CPU had given up. The two signals fail in different
directions — CPU misses delegated work, logs miss CPU-bound work that writes nothing — so
each covers the other's blind spot.

#### Two independent idle signals, and both must agree

The first attempt used CPU duty cycle alone, with an activity threshold of 1 % of a core,
justified by a sample that put working sessions at 2.5–4.1 % and a heartbeat at 0.22 %.
Re-measurement showed that justification was wrong in both directions, and the second
error was serious.

Sampling every session child at 60 s intervals for 28 process-minutes:

| state | duty cycle |
|---|---|
| at rest | 0.0000 % |
| heartbeat, worst observed | 0.02 % |
| lowest observed while working | 1.29 % |

So 1 % sat only 1.3x below the floor of real work, not the order of magnitude claimed.
The threshold is now **0.1 %**, which is an order of magnitude below the observed working
floor and clear of everything observed at rest. Erring low is the safe direction: a lower
threshold makes processes look busier, and a busy process is protected.

The bigger problem was that **CPU is a weak signal here at all**. A session delegates its
work. Measured while a session ran builds continuously, sampling both the process and its
whole subtree every 15 s:

```
t+15s 1394=0.0000%  t+60s  1394=0.0000%  t+105s 1394=0.0000%
t+30s 1394=0.0000%  t+75s  1394=0.0000%  t+120s 1394=0.0000%
t+45s 1394=0.0000%  t+90s  1394=0.0000%
```

PID 1394 was maximally busy throughout. Its CPU reads zero because each build ran in a
short-lived grandchild that exited before the next sample, taking its accumulated CPU with
it. A design resting on CPU alone would classify a flat-out session as idle.

The session log does not have that weakness — it is written on every turn, whichever
process burns the cycles. In the same measurement:

| session | CPU says | log age says |
|---|---|---|
| 1394 (running builds) | idle | 0 s — active |
| 49871 | idle | 1 s — active |
| 86242 | idle | 28 s — active |
| 44194 (finished) | idle | 559 s — idle |

OpenZombr therefore reads `--log-dir` from the session child's arguments via
`KERN_PROCARGS2`. **Both signals must agree that the session is finished before anything is
reaped.** Either one reporting recent activity — or being unreadable — keeps the parent
protected, so a single mis-derived threshold cannot on its own cause a kill.

#### The log signal reads content, not `mtime` — and this took a second incident to learn

The first version of this signal took the newest write in the log directory. That version
was measured to be worthless, and worse than worthless: it neutralised the whole feature.

On 2026-08-29 the `agency` wrapper pid 86183 was 17 h 12 m old and held **1022 zombies at
39 % of `kern.maxprocperuid`**. The app polled it for hours and never once offered it as a
candidate. From the evidence log:

```
…,86183,agency,1019,cpu_idle=27534;log_age=4,poll,
…,86183,agency,1019,cpu_idle=27534;log_age=4,cleanup,no-targets
```

CPU said 7.6 h idle, far past the two hour threshold. The log said 4 s. Both signals must
agree, so the log signal alone protected it, permanently. The fresh timestamp came from the
wrapper's own log file, and everything being written to it was this:

```
09:23:13.499Z DEBUG agency::send_telemetry_events: telem periodic flush: queue empty, nothing to commit
09:23:13.505Z DEBUG agency::send_telemetry_events: telem flush: spawned detached child pid=32302
09:24:13.503Z DEBUG agency::send_telemetry_events: telem flush: spawned detached child pid=32512
```

Every `spawned detached child` line **is** one of the zombies this app exists to remove.
Once every 30 s, the leak refreshed the very timestamp that was supposed to expose it as
dead. `queue empty, nothing to commit` — there was not even any telemetry to send; only the
flush timer was running.

This is the same failure class as the CPU signal before it, and the `telemetry_queues/`
filter before that: *the leak generates the signal that protects the leaker*. But the
direction is worse. CPU made an active session look idle, which is unsafe but visible. Here
a session dead for 17 h looked active forever, which is silent and total.

The file layer does not carry the information, so the signal is derived from the log
**content**. Scanning the same directory as of the moment the evidence above was captured:

```
$ OpenZombr --log-probe <session-log-dir> 2026-08-29T09:21:47Z
  agency_copilot_…86183.log — 1171 KiB, mtime-Alter unter 1 Min. → nur Heartbeat seit mindestens 6 Std. [17.0 ms]
  process-…-86242.log      — 247318 KiB, mtime-Alter unter 1 Min. → nur Heartbeat seit mindestens 6 Std. [60.3 ms]
```

against a live session on the same machine:

```
  agency_copilot_…31944.log —    73 KiB, mtime-Alter 1 Min. → Arbeit vor 11 Min. [3.7 ms]
  process-…-32002.log       —  4485 KiB, mtime-Alter 1 Min. → Arbeit vor  1 Min. [5.3 ms]
```

Three properties of the reader matter, and each is pinned by a test in
`SessionLogContentTests`:

* **It is a denylist of known heartbeats, never an allowlist of work.** Anything the reader
  does not recognise counts as real work and protects. These formats come from foreign code
  and will change; when they do, heartbeats stop matching and the guard becomes more
  cautious, never less. A file with no parseable timestamp at all is `unknown`, and one
  unknown file makes the whole directory unknown.
* **It reads backwards from EOF and stops at the first non-heartbeat line.** The dead
  session's `process-*.log` was **253 MB**; a full scan is not affordable on a machine that
  is by definition already out of process slots. 300 lines of heartbeat-only tail cover 75
  minutes, so reaching past the two hour threshold costs tens of kilobytes. The 253 MB file
  above was judged in 60 ms, against a 60 s poll interval. A hard byte budget bounds the
  pathological case, and exhausting it reports the oldest line actually seen — an upper
  bound on the last activity, which again errs towards "active".
* **What counts as a heartbeat was found by measurement, not by reading the code.** The
  non-obvious entry is `managed_settings_resolved`. The hourly policy self-fetch emits it
  as a *session event*, so it carries none of the policy module's own markers. Between
  02:00 and 09:25 on the day of the incident those eight hourly lines were the only
  non-heartbeat content in the entire 253 MB log — and one line an hour is enough to hold
  the measured age permanently below a two hour threshold. Conversely OTLP *trace* batches
  are deliberately **not** heartbeats: they carry span names such as `execute_tool bash` and
  appear only when work happens. Counted over the dead wrapper's whole 6140-line log, split
  at the last real work at `01:42:34`: the 7 h 39 min of dead time that followed contained
  **463 `signal=/v1/metrics` pushes and 0 trace batches** — the last two trace batches landed
  at `01:42:37`, three seconds after the final turn ended. Before that cut the same file held
  1128 trace batches. The two signals separate cleanly rather than narrowly, and that is the
  measurement the criterion rests on, not an assumption.

The real work in that session stopped at `2026-08-29T01:42:34`. Everything after it was
heartbeat. That is 7.65 h before the measurement — which is what `cpu_idle=27534` had been
saying all along.

#### Aggregating across the files of one directory

A session's log directory holds more than one file, and they can disagree. In the incident
directory `agency_copilot_*.log` is the wrapper's own log and `process-*.log` belongs to the
session child. The rule is:

* **Any file showing work makes the whole directory active** (`max` over the per-file
  bounds). The directory is the *session child's* `--log-dir`, so its `process-*.log` is the
  primary evidence of whether the session is doing anything, and the wrapper's own log being
  quiet is the normal case — the wrapper never logs the session's work itself. Taking the
  oldest file instead would let a wrapper be reaped out from under a session that is visibly
  streaming output.
* **One file the reader cannot interpret at all makes the whole directory unknown**, which
  protects. Absence of evidence must never read as evidence of idleness.
* Empty files are skipped rather than counted as unreadable, or a zero-byte file would
  protect its wrapper forever.

This does not weaken the fix, and the difference is measurable rather than a matter of
opinion. Replaying the archived incident directory truncated at the capture instant
`2026-08-29T09:21:47Z` reports *both* files as heartbeat-only for at least six hours: the
child's log had also been silent since `01:42:34`. The wrapper would have been offered as a
candidate. The same directory reads "work under 1 min ago" *today* only because the orphaned
child was adopted by `launchd` after the wrapper was killed and now serves a live session —
which is precisely the case that must protect.

One earlier trap is still worth stating: the telemetry children that cause the leak write
their queue files into the same log directory. Session 44194 was finished with its process
log 612 s old, while a `telemetry_queue….jsonl.delivered` beside it was only 559 s old, so
files whose names contain `telemetry` are ignored outright.

### Auditing the guard before trusting it: `--idle-watch`

**Run this before you enable auto-cleanup.** It is the only way to see how the guard would
classify the processes on *your* machine without any risk of a kill: it polls, prints the
verdict for every wrapper with a session, and signals nothing, ever.

```
OpenZombr --idle-watch <Dauer in s> <Schwelle in s>
```

Pass a short threshold to see the behaviour without waiting out the two hour default. The
guard needs at least two readings, so a single `--probe` cannot show it, and the menu bar
app has the history but no textual output. Both of the design defects described above were
found with this mode rather than by reasoning.

Read it as: a wrapper you recognise as a live session must say `AKTIV (geschützt)`. If one
of your live sessions is ever released, do not enable auto-cleanup — send the output as a
bug report instead.

Its companion is `--log-probe`, which shows what the log reader makes of a single session
log directory, file by file, with the `mtime` it replaced beside each verdict and the cost
of the scan:

```
OpenZombr --log-probe <Verzeichnis> [ISO-Zeitpunkt]
```

The optional instant judges an archived directory as of the moment it was captured, which
is how the 2026-08-29 incident above is replayed on demand.

#### Beobachtet auf der betroffenen Maschine

Run with a deliberately reckless 2 minute threshold, before the log signal existed:

```
pid 86183 — Sitzung 86242, idle unter 1 Min. → AKTIV (geschützt)
pid 17831 — Sitzung 17890, idle unter 1 Min. → AKTIV (geschützt)
pid  1332 — Sitzung  1394, idle 5 Min.       → INAKTIV (freigegeben)
```

1332 was the user's own live session, released purely because they were between turns.
With both signals, at the same reckless threshold:

```
pid 86183 — Sitzung 86242, CPU-idle 2 Min., Log-Alter unter 1 Min. → AKTIV (geschützt)
pid  1332 — Sitzung  1394, CPU-idle 2 Min., Log-Alter unter 1 Min. → AKTIV (geschützt)
pid 49812 — Sitzung 49871, CPU-idle 2 Min., Log-Alter unter 1 Min. → AKTIV (geschützt)
```

The log signal holds all three, including the live one that CPU alone gave up. The shipped
default remains two hours; the point of the reckless threshold is that even it no longer
releases a live session.

#### "Keine Kandidaten" has two meanings, and they are reported separately

A quiet cleanup run can mean two very different things:

* every wrapper was read and found to be genuinely working, or
* one or more wrappers could not be read at all, so the app had no basis for a decision.

Both protect the process, but the second is a degraded state — the app is not deciding, it
is blind — and it should be visible rather than looking like a clean bill of health. So the
skip reason `sessionSignalUnavailable` is distinct from `hasActiveSession`, the run summary
says `Keine Kandidaten — bei N Prozessen sind die Sitzungssignale nicht lesbar`, affected
entries are marked `Signal unlesbar` in the menu, and every CSV row carries a
`session_signal` column holding `cpu_idle=…;log_age=…` with `unknown` for whichever signal
could not be read.

Note that this is the expected state for the first poll or two after launch, because
idleness needs at least two readings before it means anything.

### Killing a wrapper is survivable — but that is not the safety argument

Empirically verified during the incident: when an `agency` wrapper is SIGKILLed, its live
`copilot` child **survives**. It is simply orphaned, reparented to `launchd`, and keeps
running. Killing six wrappers took the machine from 3892 → 565 processes and 3350 → 29
zombies without terminating a single live session child.

This is why the "spare active sessions" toggle exists and can be turned off without
disaster. It is deliberately **not** the default, because *"the damage happened to be
recoverable"* is not a safety argument — it is a mitigation. The default is to leave a
working process alone and tell the user why.

## Install

### From a release

Download `OpenZombr-<version>.zip` from the
[releases page](https://github.com/trsdn/OpenZombr/releases), unzip it, and move
`OpenZombr.app` to `/Applications`.

The build is **ad-hoc signed, not notarised** — there is no Apple Developer ID behind this
project — so Gatekeeper will refuse the first launch. Clear the quarantine attribute
yourself, after checking the published SHA-256 against the downloaded file:

```bash
shasum -a 256 OpenZombr-<version>.zip     # compare with checksum.txt on the release
xattr -dr com.apple.quarantine /Applications/OpenZombr.app
open /Applications/OpenZombr.app
```

Given that this app sends `SIGKILL` to processes on your behalf, building it yourself from
source is the better option, and it is one command.

### From source

```bash
make build      # debug build
make test       # unit tests
make probe      # print one live reading and exit
make bundle     # build dist/OpenZombr.app
make install    # install to /Applications and launch
```

Requires macOS 14+ and a Swift 6.1 toolchain. Launch at login is offered via
`SMAppService` and only works from the installed `.app` — not from `swift run` and not from
a bundle sitting on an external volume, where the login-time launch would race the mount.

The preferences toggle is not the only way to reach it, and deliberately so: a watchdog
whose autostart is *asserted* rather than read back is one silent reboot away from being
gone unnoticed. `--login-item` sets and, more usefully, reports the registration from a
terminal, printing the raw `SMAppService.Status` next to the wording:

```bash
/Applications/OpenZombr.app/Contents/MacOS/OpenZombr --login-item register
/Applications/OpenZombr.app/Contents/MacOS/OpenZombr --login-item status
# Login-Item: registriert [status=1, wirksam=ja] — /Applications/OpenZombr.app
```

`requiresApproval` is reported as `wirksam=nein`. In that state the item exists but macOS
will not start it, which looks like success until the reboot that disproves it.

**Auto-cleanup is on by default.** That is deliberate — the leak recurs roughly daily and
an unattended machine is exactly the case this app exists for — but it means the app will
send `SIGKILL` without being asked, so **watch `--idle-watch` on your own machine before
you trust it**, and turn the switch off in the preferences if your process tree does not
look like the one it was tuned for. The guard is tuned for one specific leaking wrapper;
every safety rule in it was added because a measurement showed the previous set was
insufficient.

Before any signal is sent, the target's identity is re-read from the kernel and compared
with the one the safety rules approved — start time and uid, not just the PID. Selection
runs against a snapshot that may be up to one poll interval old, and this machine hands
out 160 PIDs every 20 seconds while idle, so a PID alone is not an identity. The check is
repeated before the `SIGKILL` escalation, because the grace period is itself a window in
which the target can exit and its number be reissued. An identity that differs, or that
cannot be read at all, aborts the termination and is logged as `identity-changed`.

## Continuous integration

| Workflow | Runs on | What it proves |
| --- | --- | --- |
| `validate-swift` | push to `master`, PRs | debug + release build, the full test suite, that the unsigned bundle assembles, that `LSUIElement` survives into `Info.plist`, and that `--probe` reads the runner's own process table |
| `secret-scan` | push to `master`, PRs | no credential-shaped strings in the tree or in the pushed commits |
| `release` | publishing a release | tests, a version-stamped bundle whose `CFBundleShortVersionString` must equal the tag, and a zip plus SHA-256 attached to the release |

The release workflow refuses to publish if the bundle version and the tag disagree, so a
forgotten `CHANGELOG.md` heading fails the build instead of shipping a mislabelled app.

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
