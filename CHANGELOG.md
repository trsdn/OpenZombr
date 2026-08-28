# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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

[Unreleased]: https://github.com/trsdn/OpenZombr/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/trsdn/OpenZombr/releases/tag/v0.1.0
