import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// All five order-processing activities grouped into one container.
///
/// `@ActivityContainer` synthesises `ActivityContainerProtocol` conformance and
/// generates a nested `Activity`-conforming struct for every `@Activity` method —
/// named after the method with the first letter capitalised.
///
/// In a real service these methods would share injected clients:
/// ```swift
/// let inventory: InventoryServiceClient
/// let payments:  PaymentGatewayClient
/// let email:     EmailServiceClient
/// ```
/// Every `@Activity` below has access to those fields without any per-activity
/// constructor boilerplate.  Registering the whole pipeline requires only:
/// ```swift
/// activityContainers: [ProcessOrderActivities()]
/// ```
@ActivityContainer
struct ProcessOrderActivities {

    // ── @Activity methods ─────────────────────────────────────────────────────
    // The @ActivityContainer macro generates a nested `Activity`-conforming struct
    // for each method:
    //   validateOrder   → ProcessOrderActivities.ValidateOrder
    //   reserveInventory → ProcessOrderActivities.ReserveInventory
    //   chargePayment   → ProcessOrderActivities.ChargePayment
    //   fulfillOrder    → ProcessOrderActivities.FulfillOrder
    //   sendConfirmation → ProcessOrderActivities.SendConfirmation

    /// Validates the order against the product catalog and confirms pricing.
    /// 5 % transient failure rate — shows up as retries in the dashboard.
    @Activity
    func validateOrder(
        input: ValidateOrderInput,
        context: ActivityContext
    ) async throws -> ValidateOrderOutput {
        try await Task.sleep(for: .milliseconds(Int.random(in: 300...800)))
        if Double.random(in: 0...1) < 0.05 {
            struct Err: Error, CustomStringConvertible {
                var description: String { "catalog service temporarily unavailable" }
            }
            throw Err()
        }
        let total = input.items.reduce(0) { $0 + $1.subtotalCents }
        return ValidateOrderOutput(orderId: input.orderId, totalCents: total)
    }

    /// Reserves stock for a single SKU in the warehouse.
    /// Called in parallel for each item — the Run Timeline shows
    /// `ReserveInventory ×N` for clear fan-out visibility.
    /// 10 % transient out-of-stock failure rate.
    @Activity
    func reserveInventory(
        input: ReserveInventoryInput,
        context: ActivityContext
    ) async throws -> ReserveInventoryOutput {
        try await Task.sleep(for: .milliseconds(Int.random(in: 200...600)))
        if Double.random(in: 0...1) < 0.10 {
            struct Err: Error, CustomStringConvertible {
                let sku: String
                var description: String { "SKU \(sku) temporarily out of stock" }
            }
            throw Err(sku: input.sku)
        }
        let warehouses = ["WH-SEA", "WH-LAX", "WH-ORD", "WH-JFK"]
        return ReserveInventoryOutput(
            sku: input.sku,
            reservedQty: input.quantity,
            warehouseId: warehouses.randomElement()!
        )
    }

    /// Processes the payment via the gateway.
    /// Highest failure rate (20 %) — makes retry/backoff clearly visible in
    /// the dashboard run timeline.
    @Activity
    func chargePayment(
        input: ChargePaymentInput,
        context: ActivityContext
    ) async throws -> ChargePaymentOutput {
        try await Task.sleep(for: .milliseconds(Int.random(in: 500...1_500)))
        if Double.random(in: 0...1) < 0.20 {
            struct Err: Error, CustomStringConvertible {
                let attempt: Int
                var description: String { "payment gateway timeout (attempt \(attempt))" }
            }
            throw Err(attempt: context.attempt)
        }
        let chargeId = "ch_\(input.orderId.prefix(6))_\(Int.random(in: 10_000...99_999))"
        return ChargePaymentOutput(chargeId: chargeId, amountCents: input.amountCents)
    }

    /// Creates a shipment and returns a tracking number.
    /// Runs in parallel with `sendConfirmation` — the two-activity fan-out is
    /// visible in the Run Timeline at the fulfilling stage.
    @Activity
    func fulfillOrder(
        input: FulfillOrderInput,
        context: ActivityContext
    ) async throws -> FulfillOrderOutput {
        try await Task.sleep(for: .milliseconds(Int.random(in: 800...2_000)))
        if Double.random(in: 0...1) < 0.05 {
            struct Err: Error, CustomStringConvertible {
                var description: String { "fulfillment service unavailable" }
            }
            throw Err()
        }
        let carriers = ["UPS", "FedEx", "USPS", "DHL"]
        let carrier = carriers.randomElement()!
        let tracking = "\(carrier.prefix(3))-\(Int.random(in: 1_000_000...9_999_999))"
        let days = Int.random(in: 2...5)
        let eta = Calendar.current.date(byAdding: .day, value: days, to: Date())!
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return FulfillOrderOutput(
            trackingNumber: tracking,
            carrier: carrier,
            estimatedDelivery: formatter.string(from: eta)
        )
    }

    /// Sends an order-confirmation email to the customer.
    /// Runs in parallel with `fulfillOrder`. 8 % transient failure rate.
    @Activity
    func sendConfirmation(
        input: SendConfirmationInput,
        context: ActivityContext
    ) async throws -> StrandVoid {
        try await Task.sleep(for: .milliseconds(Int.random(in: 300...700)))
        if Double.random(in: 0...1) < 0.08 {
            struct Err: Error, CustomStringConvertible {
                let to: String
                var description: String { "email delivery failed for \(to)" }
            }
            throw Err(to: input.customerEmail)
        }
        return StrandVoid()
    }
}
