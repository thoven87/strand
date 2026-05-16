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
                                Pause.apply(to: &self, input: .done)
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
                                Pause.apply(to: &self, input: .done)
                            case Resume.signalName:
                                Resume.apply(to: &self, input: .done)
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
                                Pause.apply(to: &self, input: .done)
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
}
