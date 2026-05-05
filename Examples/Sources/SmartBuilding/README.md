# Smart Building Monitor

An IoT monitoring example that runs one long-lived `RoomMonitorWorkflow` per
room, all in parallel. The server room has a temperature spike mid-run that
triggers an alert; a signal then raises the threshold without restarting
the workflow.

---

## What it demonstrates

| Strand feature | Where |
|---|---|
| `context.sleep(for:)` | Between each sensor polling cycle — releases the worker slot |
| Per-entity child workflows | One `RoomMonitorWorkflow` per room, all `async let` in parallel |
| In-flight state update via signal | `UpdateThresholds` signal arrives mid-run, new limits apply next cycle |
| `WorkflowSignalDefinition` | Typed `handle.signal(name:payload:)` |
| Durability under crash | Kill mid-cycle; each room monitor resumes from its last completed cycle |

---

## Building layout

```
Strand HQ
├── Lobby           — baseline readings, no alerts
├── Open Office     — elevated CO₂ (occupancy effect)
├── Server Room     — high baseline temp; 87 °C spike on cycle 3 → alert fires
└── Conference Room — variable CO₂ and humidity
```

---

## Prerequisites

- PostgreSQL 15+ on `localhost:5499`

```bash
psql "postgresql://strand:strand@localhost:5499/strand_dev" -f ../../../strand.sql
```

---

## Quick start

```bash
cd Examples
swift run SmartBuilding
```

The demo runs 5 monitoring cycles per room (~20 s total). After cycle 3 the
server room spikes and an alert fires. A background task then sends an
`UpdateThresholds` signal to raise the server room ceiling, demonstrating
in-flight workflow state mutation.

---

## Sending a threshold update manually

If you have a typed `WorkflowHandle<RoomMonitorWorkflow>` (e.g. obtained when
you started the room monitor directly), use the type-safe API:

```swift
// Typed — compiler verifies the signal type and payload.
try await roomHandle.signal(
    RoomMonitorWorkflow.UpdateThresholds.self,
    payload: ThresholdUpdate(
        newThresholds: RoomThresholds(
            maxTemperatureCelsius: 90.0,
            maxCO2PPM: 800.0,
            minHumidityPercent: 35.0
        ),
        reason: "post-incident raise"
    )
)
```

In this demo the room monitors are child workflows started internally by
`BuildingMonitorWorkflow`, so only a `WorkflowHandle<BuildingMonitorWorkflow>`
is available in `main()`. When you need to signal a child from outside its
parent, look up the task by ID and use the typed client overload:

```swift
// Typed client overload — signal name and payload type derived from the definition.
try await client.signal(
    RoomMonitorWorkflow.UpdateThresholds.self,
    taskID: roomTaskID,
    payload: ThresholdUpdate(
        newThresholds: RoomThresholds(
            maxTemperatureCelsius: 90.0,
            maxCO2PPM: 800.0,
            minHumidityPercent: 35.0
        ),
        reason: "post-incident raise"
    )
)
```

Or from **Loom**: task detail → **Send Signal**:

| Field | Value |
|---|---|
| Signal name | `update-thresholds` |
| Payload | `{"newThresholds": {"maxTemperatureCelsius": 90, "maxCO2PPM": 800, "minHumidityPercent": 35}, "reason": "post-incident"}` |

---

## Crash recovery demo

Kill the process during any monitoring cycle (`Ctrl-C`). Restart with
`swift run SmartBuilding`. Each room monitor resumes from its last completed
cycle — the server room won't re-run cycles 1 and 2 if cycle 3 is where it
stopped.

---

## Extending this example

- **MQTT integration**: swap `ReadSensorsActivity` for real MQTT publish/subscribe
- **Alert escalation**: add a child `AlertEscalationWorkflow` that sleeps between
  escalation tiers and waits for an `Acknowledge` signal
- **Predictive maintenance**: track cumulative sensor readings and spawn a
  `MaintenanceWorkflow` when thresholds indicate wear
