import Foundation
import OpenZombrKit

/// `--idle-watch [seconds] [idleThresholdSeconds]` polls repeatedly and prints how the
/// idle override classifies the wrappers that are really on this machine.
///
/// It exists because the override cannot be observed any other way: `--probe` takes a
/// single reading and idleness needs at least two, while the menu bar app has the history
/// but no textual output. Pass a short threshold to see the classification without waiting
/// out the two hour default. It never signals anything — it only reports.
if CommandLine.arguments.contains("--idle-watch") {
    let numbers = CommandLine.arguments.compactMap(Double.init)
    let duration = numbers.first ?? 300
    let threshold = numbers.dropFirst().first ?? 120
    let sampler = ZombieSampler()
    let tracker = IdleTracker()
    let enumerator = SysctlProcessEnumerator()
    let deadline = Date().addingTimeInterval(duration)

    print("idle-watch: \(Int(duration)) s, Schwelle \(Int(threshold)) s, Abfrage alle 30 s")
    while true {
        let now = Date()
        do {
            let entries = try enumerator.enumerateProcesses()
            let base = try sampler.sample(now: now)
            let snapshot = sampler.applyingIdle(
                to: base, entries: entries, tracker: tracker, now: now)
            print("--- \(ISO8601DateFormatter().string(from: now)) — \(snapshot.zombieCount) Zombies")
            for offender in snapshot.offenders.prefix(8) where offender.sessionChildCount > 0 {
                let idle = offender.sessionIdleSeconds
                let active = offender.isSessionActive(idleThreshold: threshold)
                print(
                    "  pid \(offender.pid) \(offender.name) — \(offender.zombieCount) Zombies, "
                        + "Sitzung \(offender.sessionChildPIDs.map(String.init).joined(separator: ",")), "
                        + "CPU-idle " + (idle.map(Formatting.duration) ?? "unbekannt")
                        + ", Log-Alter "
                        + (offender.sessionLogAgeSeconds.map(Formatting.duration) ?? "unbekannt")
                        + " → " + (active ? "AKTIV (geschützt)" : "INAKTIV (freigegeben)"))
            }
        } catch {
            FileHandle.standardError.write(Data("idle-watch failed: \(error)\n".utf8))
            exit(1)
        }
        if Date() >= deadline { break }
        Thread.sleep(forTimeInterval: 30)
    }
    exit(0)
}

/// `--log-probe <Verzeichnis> [ISO-Zeitpunkt]` prints what the content-based log reader
/// makes of one session log directory, file by file, with the wall-clock cost of the scan.
///
/// This exists because the log signal is the one that silently neutralised the whole
/// feature once already: `mtime` said 4 s while the session had been dead for 17 h. Being
/// able to point the reader at a directory and see its verdict is how that is kept honest.
if let index = CommandLine.arguments.firstIndex(of: "--log-probe") {
    guard index + 1 < CommandLine.arguments.count else {
        FileHandle.standardError.write(Data("usage: --log-probe <Verzeichnis>\n".utf8))
        exit(2)
    }
    let directory = CommandLine.arguments[index + 1]
    let reader = SessionLogReader()
    // An optional ISO-8601 instant lets an archived directory be judged as of the moment
    // it was captured, which is how the incident of 2026-08-29 is replayed.
    let now =
        (index + 2 < CommandLine.arguments.count
            ? ISO8601DateFormatter().date(from: CommandLine.arguments[index + 2]) : nil) ?? Date()
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory))?.sorted() ?? []
    print("log-probe: \(directory)")
    for name in names {
        let path = (directory as NSString).appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else { continue }
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
        let modified =
            ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
                as? Date) ?? now
        let ignored = SessionLogProbe.ignoredNameFragments.contains {
            name.lowercased().contains($0)
        }
        let started = Date()
        let bound = reader.activityBound(ofFileAt: path, now: now)
        let elapsed = Date().timeIntervalSince(started)
        let verdict: String
        switch bound {
        case .activity(let date):
            verdict = "Arbeit vor \(Formatting.duration(now.timeIntervalSince(date)))"
        case .noActivitySince(let date):
            verdict = "nur Heartbeat seit mindestens "
                + Formatting.duration(now.timeIntervalSince(date))
        case .unknown:
            verdict = "unbekannt (schützt)"
        }
        print(
            "  \(name) — \(size / 1024) KiB"
                + (ignored ? ", ignoriert" : "")
                + ", mtime-Alter \(Formatting.duration(max(0, now.timeIntervalSince(modified))))"
                + " → \(verdict) [\(String(format: "%.1f", elapsed * 1000)) ms]")
    }
    exit(0)
}

/// `--probe` prints one reading as text and exits, without starting the menu bar app.
/// This is what you paste into a bug report, and it is how the reader gets verified from
/// a terminal against `ps -Ao stat | grep -c '^Z'`.
if CommandLine.arguments.contains("--probe") {
    do {
        let sampler = ZombieSampler()
        let snapshot = try sampler.sample()
        let thresholds = Preferences().thresholds

        print(
            "uid \(snapshot.uid): \(snapshot.totalProcesses) Prozesse "
                + "(\(snapshot.liveProcesses) live, \(snapshot.zombieCount) Zombies) "
                + "von \(snapshot.limit) — \(Formatting.percent(snapshot.usageFraction)) belegt, "
                + "\(snapshot.freeSlots) Slots frei")
        print("severity: \(snapshot.severity(thresholds: thresholds).title)")

        if snapshot.offenders.isEmpty {
            print("keine Zombie-Erzeuger")
        } else {
            print("Zombie-Erzeuger:")
            for offender in snapshot.offenders.prefix(10) {
                print(
                    "  pid \(offender.pid) \(offender.name) — \(offender.zombieCount) Zombies, "
                        + Formatting.age(offender.age())
                        + ", \(offender.liveChildCount) lebende Kinder"
                        + (offender.hasActiveSession
                            ? " (Sitzung: \(offender.sessionChildCount), idle "
                                + (offender.sessionIdleSeconds.map(Formatting.duration)
                                    ?? "unbekannt") + ")"
                            : " (keine Sitzung)")
                        + " — \(offender.executablePath ?? "Pfad unbekannt")")
            }
        }

        let policy = Preferences().cleanupPolicy
        let selection = ZombieReaper().selectTargets(in: snapshot, policy: policy)
        print(
            "geschützte PIDs (eigener Prozess + Vorfahren): "
                + snapshot.protectedPIDs.sorted().map(String.init).joined(separator: ", "))
        for skip in selection.skipped where skip.reason == .hasActiveSession {
            print("  \(skip.parent.pid) \(skip.parent.name) verschont: \(skip.reason.germanDescription)")
        }
        print(
            "Bereinigungs-Kandidaten: "
                + (selection.targets.isEmpty
                    ? "keine"
                    : selection.targets.map { "\($0.pid) (\($0.zombieCount))" }
                        .joined(separator: ", ")))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("probe failed: \(error)\n".utf8))
        exit(1)
    }
}

ZombrApp.main()
