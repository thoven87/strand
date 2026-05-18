import Strand

/// End-to-end order-processing pipeline demonstrating Strand's core patterns:
///
/// **Sequential steps** (each depends on the previous):
///   1. `ProcessOrderActivities.ValidateOrder`    — catalog check, pricing
///   2. `ProcessOrderActivities.ReserveInventory ×N` — fan-out: one per SKU
///   3. `ProcessOrderActivities.ChargePayment`    — payment gateway
///
/// **Parallel fan-out** (both dispatched simultaneously):
///   4a. `ProcessOrderActivities.FulfillOrder`      — shipment + tracking number
///   4b. `ProcessOrderActivities.SendConfirmation`  — customer email
///
/// **Signals** — mutate workflow state while it is WAITING between activations:
///   • `cancel()` — sets `isCancelled = true`; checked before each major step
///
/// **Queries** — zero-activation reads of persisted workflow state:
///   • `currentStatus()` — returns the current `OrderStatus`
///
/// The `@Workflow` macro synthesises:
///   • `handleSignal` dispatch to all `@WorkflowSignal` methods
///   • `handleUpdate` dispatch to all `@WorkflowUpdate` methods
///   • `init() {}` (required when stored properties have defaults)
@Workflow
struct ProcessOrderWorkflow {
    typealias Input = OrderInput
    typealias Output = OrderResult

    // ── Persisted state — survives across activations ─────────────────────────
    var status: OrderStatus = .pending
    var isCancelled = false

    // ── Signal ────────────────────────────────────────────────────────────────
    /// Cancels the order gracefully.  The workflow exits early with `.cancelled`
    /// before the next activity is dispatched.
    @WorkflowSignal
    mutating func cancel() {
        isCancelled = true
        status = .cancelled
    }

    // ── Query ─────────────────────────────────────────────────────────────────
    /// Returns the current pipeline stage without activating the workflow.
    /// Typed return — callers receive `OrderStatus` directly:
    /// ```swift
    /// let s: OrderStatus = try await handle.query(ProcessOrderWorkflow.CurrentStatus.self)
    /// ```
    @WorkflowQuery
    func currentStatus() -> OrderStatus { status }

    // ── Handler ───────────────────────────────────────────────────────────────
    mutating func run(
        context: WorkflowContext<Self>,
        input: OrderInput
    ) async throws -> OrderResult {

        // ── 1. Validate order ─────────────────────────────────────────────────
        status = .validating
        let validation = try await context.runActivity(
            ProcessOrderActivities.ValidateOrder.self,
            input: .init(orderId: input.orderId, items: input.items),
            options: .init(maxAttempts: 3)
        )

        if isCancelled { return .cancelled(input) }

        // ── 2. Reserve inventory — fan-out, one activity per SKU ──────────────
        // `ReserveInventory ×N` groups neatly in the Run Timeline.
        status = .reservingInventory
        var primaryWarehouse = "WH-SEA"
        try await withThrowingTaskGroup(of: ReserveInventoryOutput.self) { group in
            for item in input.items {
                group.addTask {
                    try await context.runActivity(
                        ProcessOrderActivities.ReserveInventory.self,
                        input: .init(
                            orderId: input.orderId,
                            sku: item.sku,
                            quantity: item.quantity
                        ),
                        options: .init(
                            maxAttempts: 4,
                            retryStrategy: .backoff(
                                initial: .milliseconds(400),
                                multiplier: 1.5,
                                cap: .seconds(5)
                            )
                        )
                    )
                }
            }
            for try await reservation in group {
                primaryWarehouse = reservation.warehouseId
            }
        }

        if isCancelled { return .cancelled(input) }

        // ── 3. Charge payment ─────────────────────────────────────────────────
        status = .chargingPayment
        let warehouseId = primaryWarehouse  // let-bind before @Sendable capture
        let charge = try await context.runActivity(
            ProcessOrderActivities.ChargePayment.self,
            input: .init(
                orderId: input.orderId,
                customerId: input.customerId,
                amountCents: validation.totalCents
            ),
            options: .init(
                maxAttempts: 5,
                retryStrategy: .backoff(
                    initial: .milliseconds(500),
                    multiplier: 2.0,
                    cap: .seconds(10)
                )
            )
        )

        // ── 4. Fulfill + notify in parallel ───────────────────────────────────
        status = .fulfilling
        var trackingNumber = ""
        try await withThrowingTaskGroup(of: String?.self) { group in
            // 4a: create shipment → returns tracking number
            group.addTask {
                let shipment = try await context.runActivity(
                    ProcessOrderActivities.FulfillOrder.self,
                    input: .init(
                        orderId: input.orderId,
                        items: input.items,
                        shippingAddress: input.shippingAddress,
                        warehouseId: warehouseId
                    ),
                    options: .init(maxAttempts: 3)
                )
                return shipment.trackingNumber
            }
            // 4b: email customer — no useful return value
            group.addTask {
                try await context.runActivity(
                    ProcessOrderActivities.SendConfirmation.self,
                    input: .init(
                        orderId: input.orderId,
                        customerEmail: input.customerEmail,
                        amountCents: charge.amountCents,
                        trackingNumber: "PENDING"
                    ),
                    options: .init(maxAttempts: 4)
                )
                return nil
            }
            for try await result in group {
                if let tn = result { trackingNumber = tn }
            }
        }

        status = .completed
        return OrderResult(
            orderId: input.orderId,
            status: .completed,
            totalCents: charge.amountCents,
            trackingNumber: trackingNumber
        )
    }
}

// MARK: - Convenience

extension OrderResult {
    fileprivate static func cancelled(_ input: OrderInput) -> OrderResult {
        OrderResult(orderId: input.orderId, status: .cancelled, totalCents: 0, trackingNumber: "")
    }
}
