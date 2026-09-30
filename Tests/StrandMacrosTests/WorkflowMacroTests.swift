import StrandMacrosPlugin
import Testing

@Suite struct WorkflowMacroTests {

    @Test func singleZeroParamSignal() {
        #expect(
            expand(
                """
                @Workflow
                struct OrderWorkflow {
                    @WorkflowSignal
                    mutating func pause() {}
                }
                """
            )
                == expand(
                    """
                    struct OrderWorkflow {
                        @WorkflowSignal
                        mutating func pause() {}
                        mutating func handleSignal(name: String, payload: ByteBuffer?) throws {
                            switch name {
                            case Pause.signalName:
                                Pause.apply(to: &self, input: ())
                            default:
                                break
                            }
                        }
                    }
                    extension OrderWorkflow: Workflow {}
                    """
                )
        )
    }

    @Test func multipleSignals() {
        #expect(
            expand(
                """
                @Workflow
                struct ShippingWorkflow {
                    @WorkflowSignal
                    mutating func pause() {}
                    @WorkflowSignal
                    mutating func resume() {}
                    @WorkflowSignal
                    mutating func setPriority(_ p: ShippingPriority) {}
                }
                """
            )
                == expand(
                    """
                    struct ShippingWorkflow {
                        @WorkflowSignal
                        mutating func pause() {}
                        @WorkflowSignal
                        mutating func resume() {}
                        @WorkflowSignal
                        mutating func setPriority(_ p: ShippingPriority) {}
                        mutating func handleSignal(name: String, payload: ByteBuffer?) throws {
                            switch name {
                            case Pause.signalName:
                                Pause.apply(to: &self, input: ())
                            case Resume.signalName:
                                Resume.apply(to: &self, input: ())
                            case SetPriority.signalName:
                                if let p = try decodeSignalPayload(ShippingPriority.self, from: payload) {
                                    SetPriority.apply(to: &self, input: p)
                                }
                            default:
                                break
                            }
                        }
                    }
                    extension ShippingWorkflow: Workflow {}
                    """
                )
        )
    }

    @Test func generatesInitWhenExplicitInitExists() {
        // An explicit init(input:) suppresses Swift's synthesised init().
        // @Workflow detects this and generates init() {} automatically.
        #expect(
            expand(
                """
                @Workflow
                struct OrderWorkflow {
                    var orderId: String = ""
                    init(input: String) { orderId = input }
                    @WorkflowSignal mutating func pause() {}
                }
                """
            )
                == expand(
                    """
                    struct OrderWorkflow {
                        var orderId: String = ""
                        init(input: String) { orderId = input }
                        @WorkflowSignal mutating func pause() {}
                        init() {}
                        mutating func handleSignal(name: String, payload: ByteBuffer?) throws {
                            switch name {
                            case Pause.signalName:
                                Pause.apply(to: &self, input: ())
                            default:
                                break
                            }
                        }
                    }
                    extension OrderWorkflow: Workflow {}
                    """
                )
        )
    }

    @Test func noSignalsAddsConformanceOnly() {
        #expect(
            expand(
                """
                @Workflow
                struct EmptyWorkflow {
                    mutating func run() {}
                }
                """
            )
                == expand(
                    """
                    struct EmptyWorkflow {
                        mutating func run() {}
                    }
                    extension EmptyWorkflow: Workflow {}
                    """
                )
        )
    }

    // MARK: - Type inference

    @Test func infersCodableOutputTypealias() {
        // @Workflow generates typealias Input / Output from the run() signature
        // when they are not already declared by the user.
        #expect(
            expand(
                """
                @Workflow
                struct OrderWorkflow {
                    mutating func run(context: WorkflowContext<Self>, input: OrderInput) async throws -> ShipResult {}
                }
                """
            )
                == expand(
                    """
                    struct OrderWorkflow {
                        mutating func run(context: WorkflowContext<Self>, input: OrderInput) async throws -> ShipResult {}
                        typealias Input = OrderInput
                        typealias Output = ShipResult
                    }
                    extension OrderWorkflow: Workflow {}
                    """
                )
        )
    }

    @Test func infersVoidOutputTypealias() {
        // A run() with no return type gets typealias Output = Void.
        // No StrandVoid wrapper is generated — Void satisfies Output: Sendable directly.
        #expect(
            expand(
                """
                @Workflow
                struct NotifyWorkflow {
                    mutating func run(context: WorkflowContext<Self>, input: String) async throws {}
                }
                """
            )
                == expand(
                    """
                    struct NotifyWorkflow {
                        mutating func run(context: WorkflowContext<Self>, input: String) async throws {}
                        typealias Input = String
                        typealias Output = Void
                    }
                    extension NotifyWorkflow: Workflow {}
                    """
                )
        )
    }

    @Test func skipsTypealiasWhenUserDeclaresExplicitly() {
        // If the user already declares typealias Input/Output, the macro must not
        // generate duplicates — that would cause a compile error.
        #expect(
            expand(
                """
                @Workflow
                struct OrderWorkflow {
                    typealias Input = OrderInput
                    typealias Output = ShipResult
                    mutating func run(context: WorkflowContext<Self>, input: OrderInput) async throws -> ShipResult {}
                }
                """
            )
                == expand(
                    """
                    struct OrderWorkflow {
                        typealias Input = OrderInput
                        typealias Output = ShipResult
                        mutating func run(context: WorkflowContext<Self>, input: OrderInput) async throws -> ShipResult {}
                    }
                    extension OrderWorkflow: Workflow {}
                    """
                )
        )
    }

    @Test func typeInferenceWithSignals() {
        // Type inference and signal dispatch can coexist.
        #expect(
            expand(
                """
                @Workflow
                struct OrderWorkflow {
                    @WorkflowSignal mutating func pause() {}
                    mutating func run(context: WorkflowContext<Self>, input: OrderInput) async throws -> ShipResult {}
                }
                """
            )
                == expand(
                    """
                    struct OrderWorkflow {
                        @WorkflowSignal mutating func pause() {}
                        mutating func run(context: WorkflowContext<Self>, input: OrderInput) async throws -> ShipResult {}
                        typealias Input = OrderInput
                        typealias Output = ShipResult
                        mutating func handleSignal(name: String, payload: ByteBuffer?) throws {
                            switch name {
                            case Pause.signalName:
                                Pause.apply(to: &self, input: ())
                            default:
                                break
                            }
                        }
                    }
                    extension OrderWorkflow: Workflow {}
                    """
                )
        )
    }
}
