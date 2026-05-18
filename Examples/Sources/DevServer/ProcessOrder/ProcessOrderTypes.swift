import Strand

// MARK: - Workflow input / output

/// Top-level order placed by a customer.
struct OrderInput: Codable, Sendable {
    let orderId: String
    let customerId: String
    let customerEmail: String
    let items: [OrderLineItem]
    let shippingAddress: String

    var totalCents: Int { items.reduce(0) { $0 + $1.subtotalCents } }
}

struct OrderLineItem: Codable, Sendable {
    let sku: String
    let name: String
    let quantity: Int
    let unitPriceCents: Int

    var subtotalCents: Int { unitPriceCents * quantity }
}

struct OrderResult: Codable, Sendable {
    let orderId: String
    let status: OrderStatus
    let totalCents: Int
    let trackingNumber: String
}

/// Mutable status tracked inside the workflow — readable via @WorkflowQuery.
enum OrderStatus: String, Codable, Sendable {
    case pending
    case validating
    case reservingInventory = "reserving_inventory"
    case chargingPayment = "charging_payment"
    case fulfilling
    case completed
    case cancelled
}

// MARK: - Activity I/O

struct ValidateOrderInput: Codable, Sendable {
    let orderId: String
    let items: [OrderLineItem]
}
struct ValidateOrderOutput: Codable, Sendable {
    let orderId: String
    let totalCents: Int
}

struct ReserveInventoryInput: Codable, Sendable {
    let orderId: String
    let sku: String
    let quantity: Int
}
struct ReserveInventoryOutput: Codable, Sendable {
    let sku: String
    let reservedQty: Int
    let warehouseId: String
}

struct ChargePaymentInput: Codable, Sendable {
    let orderId: String
    let customerId: String
    let amountCents: Int
}
struct ChargePaymentOutput: Codable, Sendable {
    let chargeId: String
    let amountCents: Int
}

struct FulfillOrderInput: Codable, Sendable {
    let orderId: String
    let items: [OrderLineItem]
    let shippingAddress: String
    let warehouseId: String
}
struct FulfillOrderOutput: Codable, Sendable {
    let trackingNumber: String
    let carrier: String
    let estimatedDelivery: String
}

struct SendConfirmationInput: Codable, Sendable {
    let orderId: String
    let customerEmail: String
    let amountCents: Int
    let trackingNumber: String
}
