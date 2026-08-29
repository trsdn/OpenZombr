# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `--login-item [status|register|unregister]` reads back or changes the launch-at-login
  registration from a terminal. `SMAppService.mainApp` always acts on the *calling* bundle,
  so no external command can register the app on its behalf, and until now the only way to
  set it was the preferences toggle — and the only way to check it was to believe the
  toggle. The sibling app OpenDefendrWatchr died silently at a reboot and nobody noticed
  for 30 h; a watchdog whose autostart is asserted rather than verified is that failure
  waiting to happen. `requiresApproval` is reported as *not* effective, because the item
  exists in that state but macOS will not start it.

### Fixed

- A PID is not an identity. Targets were selected against a snapshot and then signalled by
  PID alone, so a target that exited between selection and delivery could have its number
  reissued to an unrelated process, which would then be killed. Measured: 160 PIDs are
  handed out every 20 seconds on the affected machine while it is *idle*, and the window
  spans both the grace period and — for manual cleanup reusing a stored snapshot — up to a
  full poll interval, which can be set to an hour. The start time and uid are now re-read
  from the kernel and compared immediately before each signal, including before the SIGKILL
  escalation. An identity that differs, or one that cannot be read at all, aborts the
  termination and is logged as `identity-changed`; unreadable is never treated as unchanged.
- Auto-cleanup no longer bypasses the threshold hysteresis. It fired on the raw severity of
  a single sample, defeating `ThresholdMonitor`'s two-sample confirmation for the one code
  path that sends SIGKILL. It now follows the confirmed severity; the menu bar still shows
  the immediate reading, where reacting to one sample is merely noisy rather than fatal.
- "Jetzt aufräumen" takes a fresh sample instead of acting on the stored snapshot, which
  could be a poll interval old.
- The session idle threshold is clamped to the log reader's horizon and the preferences
  slider derives its range from the same constant. The slider allowed up to 24 h while the
  reader only looks back 6 h, so any value above 6 h made the log signal unreachable and
  silently switched cleanup off — with no visible sign that it had.
- A stale reading is now announced in the menu before the numbers, and the model records
  when the last sample actually succeeded. A failing poll leaves the previous snapshot in
  place, so a blind watchdog used to look exactly like one reporting good news.

### Changed

- A sampling error shown in the menu is now German, matching the rest of the UI. The
  `sysctl` name and the `strerror` text stay untranslated, because those are the searchable
  part and a translated errno helps nobody.

### Documentation

- The README described candidate ordering as three tiers — no session, stale session,
  active session — but the sort key is the single boolean "is this session active?", so a
  wrapper with no session and one with a stale session are equally eligible and separated
  only by zombie count.
- "Only parents above the zombie threshold" was off by one: the guard skips below the
  threshold, so a parent holding exactly the configured number is a candidate.
- The by-hand verification recipe compared a uid-scoped `--probe` count against a
  whole-machine `ps` count. It agrees on a single-user Mac and silently stops agreeing
  anywhere else; the command is now filtered by uid, which is what `kern.maxprocperuid`
  is measured against.
- `--idle-watch` documented neither its defaults (300 s duration, 120 s threshold, sampled
  every 30 s) nor that its threshold default deliberately differs from the guard's two hour
  one. `--login-item unregister` was implemented but undocumented, and `AGENTS.md` still
  listed `--probe` as the only flag.
- The README claimed auto-cleanup was off by default; the code defaults it to on and the
  evidence log shows it running. The code is the intended behaviour — the leak recurs daily
  and unattended machines are the point — so the README now says so, and says plainly that
  the app will send SIGKILL without being asked.

## [0.2.0] - 2026-08-29

### Fixed

- **The log signal could never release the process this app was built for.** Read as the
  newest write in the session's `--log-dir`, it was refreshed every 30 s by the leak's own
  `telem flush: spawned detached child pid=…` heartbeat — each of those lines being one of
  the zombies to be cleaned up. Measured on 2026-08-29: `agency` wrapper 86183, 17 h old,
  1022 zombies at 39 % of `kern.maxprocperuid`, CPU idle for 7.6 h, log age reported as
  4 s, never offered as a candidate. Since both signals must agree, the log signal alone
  neutralised the whole cleanup feature. The age is now derived from the log *content*: the
  file tail is read backwards from EOF and the scan stops at the first line that is not a
  known heartbeat. The 253 MB log of that session is judged in 60 ms against a 60 s poll
  interval, and replaying the incident directory at its capture instant now reports "only
  heartbeat for at least 6 h" instead of 4 s.
  - Classification is a denylist of known heartbeats, so an unrecognised format counts as
    real work and protects; a file with no parseable timestamp is unknown, and one unknown
    file makes the whole directory unknown.
  - `managed_settings_resolved` is treated as a heartbeat. The hourly policy self-fetch
    emits it as a session event without the policy module's own markers, and between 02:00
    and 09:25 on the day of the incident those eight lines were the only non-heartbeat
    content in the entire log — enough on their own to hold the age below two hours forever.
  - OTLP *trace* batches are deliberately not heartbeats: they carry span names such as
    `execute_tool bash`. Counted over the dead wrapper's whole log and split at the last
    real work: 463 `signal=/v1/metrics` pushes and 0 trace batches in the 7 h 39 min of
    dead time that followed, against 1128 trace batches before it.
  - Files within one log directory are combined with `max`: any file showing work keeps the
    session active, because the directory is the session *child's* `--log-dir` and its
    `process-*.log` is the primary evidence. Replaying the incident directory at its capture
    instant shows both files heartbeat-only, so this does not reintroduce the defect.

### Added

- GitHub Actions: `validate-swift` (debug and release build, full test suite, unsigned
  bundle assembly, `LSUIElement` check and a live `--probe` against the runner's own
  process table), `secret-scan`, and `release`. The release workflow fails if the bundle's
  `CFBundleShortVersionString` does not equal the tag, so a forgotten changelog heading
  cannot ship a mislabelled app.
- README: install-from-release instructions, including the checksum and quarantine steps
  the ad-hoc-signed build requires.
- `--log-probe <Verzeichnis> [ISO-Zeitpunkt]`, which prints the log reader's verdict for
  each file in a session log directory alongside the `mtime` it replaced and the cost of
  the scan. The optional instant judges an archived directory as of its capture time.

- Liveness-based protection: a parent that still has a live child running a *different*
  executable is never signalled. Ancestor protection only applies while the app is a
  descendant of the process in question, so under `launchd` — the launch-at-login case —
  the ancestor set collapses to `{self, 1}` and protects nothing. Liveness does not depend
  on how the app itself was started. Toggleable in preferences, on by default.
- Idle override: a session child that has consumed no CPU for longer than a configurable
  threshold (default 2 hours) no longer protects its parent. Without this the previous
  guard would have protected all six wrappers reaped during the incident, since each had a
  live `copilot` child that was resident but finished. Idleness is measured from
  accumulated CPU time deltas across polls, converted through the mach timebase.
- `sessionSignalUnavailable` as a skip reason distinct from `hasActiveSession`, plus a
  `session_signal` CSV column, a menu marker and dedicated summary wording, so a run that
  found nothing because it could not read the signals is not reported as a clean run.
- `--idle-watch` documented as the supported way to audit the guard before enabling
  auto-cleanup. It polls, prints a verdict per wrapper, and never signals anything.
- Session log age as a second, independent idle signal, read from the `--log-dir` argument
  via `KERN_PROCARGS2`. Both signals must agree that a session is finished before its
  parent can be reaped. CPU alone proved unreliable: a session running builds continuously
  measured 0.0000 % duty cycle across eight consecutive samples, because its work happened
  in short-lived grandchildren. Files whose names contain `telemetry` are excluded, since
  the leaking children write into the same directory.
- Activity threshold re-derived from measurement, from 1 % to 0.1 % of a core. The earlier
  value sat only 1.3x below the measured floor of real work rather than the order of
  magnitude intended.
- Candidate ordering is now idle-first: a parent with no live session is considered before
  one whose session is stale, which is considered before an active one.
- `liveChildCount` and `sessionChildCount` per offending parent, shown in `--probe`, and
  a `hat noch eine aktive Sitzung` skip reason so a spared process is always explainable.

### Fixed

- The menu bar showed only the severity glyph and dropped the count: `MenuBarExtra`
  renders a `Label` icon-only, so the figure has to be an explicit `HStack`.

## [0.1.0] - 2026-08-28

### Added

- Menu bar watchdog for zombie-process exhaustion of `kern.maxprocperuid`, reading the
  process table via `sysctl(KERN_PROC_ALL)` rather than shelling out to `ps`.
- Live menu bar figure with normal / warning / critical appearance, using SF Symbols so
  it stays legible in light and dark menu bars.
- Thresholds expressed as percentages of `kern.maxprocperuid` (defaults: warning 50 %,
  critical 75 %), with the limit read from sysctl at runtime.
- ETA to `fork()` failure, fitted by least squares over a 10-minute window of readings.
- Automatic cleanup of leaking parents on critical crossings, with SIGTERM → SIGKILL
  escalation, verification against a fresh reading, and a manual
  *Jetzt aufräumen* menu item.
- Safety rules for the killer: PID 0/1 protected, foreign uids protected, the app's own
  process and its dynamically resolved ancestor chain protected, zombies never signalled,
  and a fail-closed allowlist/denylist of process-name patterns defaulting to `agency`.
- Threshold notifications with confirmation and release-based hysteresis, so crossings
  notify once instead of once per poll.
- CSV evidence log under `~/Library/Application Support/OpenZombr/`, with rotation and a
  *Protokoll im Finder zeigen* menu item.
- Preferences window (German) for interval, thresholds, cleanup policy, notifications and
  launch at login via `SMAppService`.
- `--probe` mode printing one live reading for cross-checking against
  `ps -Ao stat | grep -c '^Z'`.

[Unreleased]: https://github.com/trsdn/OpenZombr/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/trsdn/OpenZombr/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/trsdn/OpenZombr/releases/tag/v0.1.0
