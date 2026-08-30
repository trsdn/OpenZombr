# AGENTS.md

Constraints and context for anyone — human or agent — changing this repository.

## What this is

A macOS menu bar watchdog for zombie-process exhaustion of `kern.maxprocperuid`. It
detects the condition, forecasts when `fork()` will start failing, and automatically
terminates the parent processes that are leaking zombies.

Read the incident section of `README.md` first. Every design decision here traces back to
measurements from that incident; changing behaviour without understanding them will
reintroduce bugs that were already paid for.

## Layout

```
Package.swift                 SwiftPM manifest (no Xcode project, and none should be added)
Makefile                      build / run / test / bundle / install / clean
scripts/build_swift_app.sh    produces dist/OpenZombr.app
Sources/OpenZombr/            library target OpenZombrKit
  App/                        SwiftUI App + NSApplicationDelegate
  Cleanup/                    policy, protection, signalling, reaper, cleanup service
  Logging/                    CSV evidence log
  Model/                      value types, severity, thresholds, formatting
  Monitoring/                 growth/ETA estimator, threshold hysteresis, ZombrModel
  Notifications/              alert copy and UNUserNotificationCenter delivery
  Preferences/                UserDefaults-backed settings, SMAppService login item
  Sampling/                   sysctl process table reader and sampler
  UI/                         menu bar content, preferences window
  Info.plist                  LSUIElement=true; `__VERSION__` substituted at bundle time
Sources/OpenZombrApp/         entry point; `--probe`, `--idle-watch`, `--log-probe`, `--login-item`
Tests/OpenZombrTests/         unit tests
```

## Hard constraints

* **Language split**: UI strings are German. Code, comments, commit messages and
  documentation are English.
* **Menu bar only.** `LSUIElement` in Info.plist, `.accessory` activation policy in the
  app delegate (the latter covers `swift run`, where there is no Info.plist). No Dock
  icon, no window on launch.
* **Never hardcode `kern.maxprocperuid`.** It is 4000 on the machine this was written
  for, but it is a tunable. Read it via sysctl; express thresholds as percentages of it.
* **`kern.maxprocperuid` is not the only ceiling, and on its own it is the wrong one.**
  `fork()` also fails at `RLIMIT_NPROC` (inherited from launchd at login, read with
  `getrlimit` — never by shelling out to `ulimit`/`launchctl`) and at `kern.maxproc`,
  which is shared with every other uid. The effective limit is the *minimum* of the three,
  with `kern.maxproc` reduced by the foreign slot count. Reading only `kern.maxprocperuid`
  let the app report "67,5 %, 1299 Slots frei" for nine hours while the machine could not
  fork; it never reached its critical threshold and never cleaned up once. An unreadable
  ceiling must count as "does not constrain", never as zero — a watchdog that sends SIGKILL
  must not manufacture pressure out of a failed syscall. Which ceiling binds must stay
  visible in the UI, the notifications, `--probe` and the CSV.
* **Do not shell out to `ps` on the polling path.** Every subprocess is a `fork()`, which
  is the exact operation that fails in the condition being monitored. Use
  `sysctl(KERN_PROC_ALL)`. Zombie state is `p_stat == SZOMB` (5).
* **Do not weaken the reaper's safety rules.** They live in exactly one place,
  `ZombieReaper.selectTargets`, and are ordered so that the unconditional protections
  (PID ≤ 1, foreign uid, own ancestry) are applied before the tunable ones (policy,
  threshold). No preference value may unlock them.
* **Process enumeration and signalling stay behind protocols** (`ProcessEnumerating`,
  `ProcessLimitReading`, `ProcessSignalling`, `Sleeping`) so the safety logic is testable
  without touching real processes. Any new safety rule needs a test that fails without it.
* **No secrets and no personal absolute paths** in committed files. Test fixtures use
  `/Users/x/...`.

## Testing expectations

`swift test` must pass. The suite is not decoration: `ReaperSafetyTests` exists to make
the destructive path impossible to regress. If you touch the cleanup logic, the following
must remain proven by tests:

* PID 1 and PID 0 are never targeted, at both the selection and signal-sending layers.
* The app's own process and every ancestor are protected, computed dynamically, even when
  an ancestor is the single worst offender.
* Ancestry is **recomputed from the live process table on every poll**, never captured at
  startup, so a process that stops being an ancestor stops being protected.
* Ancestry alone is insufficient and must never be the only guard: started by `launchd` at
  login the ancestor set is `{self, 1}`. A parent that still has a live child running a
  different executable is protected independently of ancestry. Note that "has live
  children" on its own does **not** discriminate — the leak itself is a stream of live
  children — so the check must exclude the parent's own self-spawns.
* Existence of a session child is not sufficient either. The wrappers reaped during the
  incident all had live `copilot` children; they were finished sessions whose child was
  still resident. A session child that has consumed no CPU for longer than the configured
  threshold (default 2 h) no longer protects its parent. The threshold must stay on the
  scale of hours: a 20 s sample showed the user's own session idle simply because they
  were between turns.
* No idle history means "busy", and one unreadable session child protects the parent.
  Absence of evidence must never read as evidence of idleness.
* "No candidates because everything is active" and "no candidates because a signal could
  not be read" must never render as the same message. The second is a degraded state and
  has its own skip reason, summary wording, menu marker and CSV column.
* The idle rule is right while there is room and wrong at the wall, so an emergency
  override exists: at or below 5 % free slots it may bypass `spareParentsWithActiveSession`
  for **one** parent per run, the largest offender. Without it the app watches the table
  fill and reports `no-targets`, which is what happened on 2026-08-29 against 2038 zombies
  — the offender held 526 of them but reset its idle clock every 45–60 min and so never
  reached two idle hours. The override may only ever relax that one tunable: PID ≤ 1,
  foreign uid and own ancestry are evaluated before it and stay unreachable; a parent with
  unreadable idle signals is never overridden; the allowlist and zombie threshold still
  apply, and a candidate they reject must not consume the run's single override. Idle
  candidates are still taken first. Every one of these boundaries needs a test.
* Idleness needs two independent signals — CPU duty cycle and session log age — and both
  must agree before a parent is reaped. CPU alone is not enough: a session delegates its
  work to short-lived grandchildren, so one running builds flat out measured 0.0000 %
  across eight consecutive samples. Files matching `telemetry` must stay excluded from the
  log age, because the leak itself writes them into the session's log directory.
* **The log age must never be derived from `mtime`.** The leak writes its own heartbeat
  into the session log every 30 s, so the file timestamp reports a wrapper that has been
  dead for 17 h as one second old — measured against pid 86183 holding 1022 zombies, which
  the app consequently never offered as a candidate. The age comes from the log *content*,
  read backwards from EOF and stopping at the first non-heartbeat line, because a full scan
  of a 253 MB log is not affordable on a machine already out of process slots. Heartbeat
  classification is a denylist: an unrecognised line counts as work and protects, and a
  file with no parseable timestamp makes the whole directory unknown.
* A PID is not an identity. Every target's start time and uid are re-read from the kernel
  and compared with the approved ones immediately before **each** signal, including before
  the SIGKILL escalation — the grace period is itself a reuse window, and the machine hands
  out 160 PIDs per 20 s while idle. An identity that differs, or one that cannot be read,
  aborts the termination; unreadable must never be treated as unchanged.
* Zombies themselves are never signalled.
* Only parents at or above the zombie threshold are targeted.
* The denylist overrides the allowlist, and an empty allowlist matches nothing.
* SIGTERM is sent before SIGKILL, SIGKILL is skipped when SIGTERM worked, and a failed
  SIGTERM delivery does not escalate.

`SysctlProcessEnumeratorTests` runs against the live machine and asserts only invariants
that hold on any Mac, because the process table changes between calls.

## Conventions

* Mirrors the layout and Makefile of the sibling apps (OpenOats, OpenDefendrWatchr).
* `CHANGELOG.md` follows Keep a Changelog and SemVer; `scripts/build_swift_app.sh` takes
  the bundle version from its newest release heading.
* Comments explain *why*, not *what*. Several comments record measured findings — do not
  delete them; they are the reason the code looks the way it does.
