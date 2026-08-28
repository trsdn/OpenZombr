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
