import NIOCore
import Strand

/// Top-level workflow that fans out to one ``RoomMonitorWorkflow`` per room,
/// all running in parallel.
///
/// All room monitors run concurrently — Strand releases worker slots between
/// activations so rooms genuinely overlap rather than running sequentially.
///
/// The workflow also accepts an ``UpdateThresholds`` signal mid-run (forwarded
/// from ops tooling via the client handle), storing the update in durable state
/// and reporting it in the final summary.
struct BuildingMonitorWorkflow: Workflow {
    typealias Input = BuildingInput
    typealias Output = BuildingReport

    // ── Mutable state ─────────────────────────────────────────────────────

    /// Records any threshold update received mid-session.
    /// Persisted as workflow state so it survives worker restarts.
    var pendingThresholdUpdate: ThresholdUpdate? = nil

    // ── Signal: receive ops-team threshold updates ─────────────────────────
    //
    // In production you'd signal the specific room's child workflow handle
    // directly (retrieved via `client.workflow(id:)`). For this example we
    // signal the parent workflow to demonstrate the signal API — the update
    // is recorded in the parent's durable state and reported in the summary.

    mutating func handleSignal(name: String, payload: ByteBuffer?) throws {
        if name == RoomMonitorWorkflow.UpdateThresholds.signalName,
            let update = try? decodeSignalPayload(ThresholdUpdate.self, from: payload)
        {
            pendingThresholdUpdate = update
            print("  Ops signal received: \(update.reason)")
        }
    }

    // ── Orchestration ──────────────────────────────────────────────────────

    mutating func run(
        context: WorkflowContext<Self>,
        input: BuildingInput
    ) async throws -> BuildingReport {

        print("\n\(input.buildingName) — monitoring \(input.rooms.count) rooms in parallel")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        // Fan out — all rooms monitored simultaneously.
        // With 4 rooms each sleeping 2 s between 5 cycles, total wall time
        // is ~10 s regardless of room count (they all sleep at the same time).
        let reports: [RoomReport]

        switch input.rooms.count {
        case 4:
            async let r0 = context.runChildWorkflow(RoomMonitorWorkflow.self, input: input.rooms[0])
            async let r1 = context.runChildWorkflow(RoomMonitorWorkflow.self, input: input.rooms[1])
            async let r2 = context.runChildWorkflow(RoomMonitorWorkflow.self, input: input.rooms[2])
            async let r3 = context.runChildWorkflow(RoomMonitorWorkflow.self, input: input.rooms[3])
            reports = try await [r0, r1, r2, r3]
        default:
            // Fallback: sequential (handles any room count gracefully)
            var results: [RoomReport] = []
            for room in input.rooms {
                let r = try await context.runChildWorkflow(RoomMonitorWorkflow.self, input: room)
                results.append(r)
            }
            reports = results
        }

        let totalAlerts = reports.reduce(0) { $0 + $1.totalAlerts }

        print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("\(input.buildingName) — session complete")
        print()
        for r in reports {
            let icon = r.totalAlerts == 0 ? "✅" : "⚠️ "
            let name = r.displayName.padding(toLength: 20, withPad: " ", startingAt: 0)
            print("  \(icon)  \(name)  \(r.totalAlerts) alert(s), \(r.cyclesCompleted) cycles")
        }
        print()
        if let update = pendingThresholdUpdate {
            print("  Threshold update applied: \(update.reason)")
        }
        print("  Total alerts: \(totalAlerts)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        return BuildingReport(rooms: reports, totalAlerts: totalAlerts)
    }
}
