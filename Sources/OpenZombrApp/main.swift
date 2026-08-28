import Foundation
import OpenZombrKit

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
                        + " — \(offender.executablePath ?? "Pfad unbekannt")")
            }
        }

        let policy = Preferences().cleanupPolicy
        let selection = ZombieReaper().selectTargets(in: snapshot, policy: policy)
        print(
            "geschützte PIDs (eigener Prozess + Vorfahren): "
                + snapshot.protectedPIDs.sorted().map(String.init).joined(separator: ", "))
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
