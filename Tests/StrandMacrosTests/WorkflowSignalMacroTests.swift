import Testing

@Suite struct WorkflowSignalMacroTests {

    @Test func zeroParamSignal() {
        #expect(
            expand(
                """
                struct OrderWorkflow {
                    @WorkflowSignal
                    mutating func pause() {}
                }
                """
            )
                == expand(
                    """
                    struct OrderWorkflow {
                        mutating func pause() {}
                        struct Pause: WorkflowSignal {
                            typealias W = OrderWorkflow
                            typealias Input = StrandVoid
                            static var signalName: String { "pause" }
                            static func apply(to w: inout OrderWorkflow, input: StrandVoid) { w.pause() }
                        }
                    }
                    """
                )
        )
    }

    @Test func oneParamWildcardLabel() {
        #expect(
            expand(
                """
                struct ShippingWorkflow {
                    @WorkflowSignal
                    mutating func setPriority(_ p: ShippingPriority) {}
                }
                """
            )
                == expand(
                    """
                    struct ShippingWorkflow {
                        mutating func setPriority(_ p: ShippingPriority) {}
                        struct SetPriority: WorkflowSignal {
                            typealias W = ShippingWorkflow
                            typealias Input = ShippingPriority
                            static var signalName: String { "setPriority" }
                            static func apply(to w: inout ShippingWorkflow, input: ShippingPriority) { w.setPriority(input) }
                        }
                    }
                    """
                )
        )
    }

    @Test func customSignalName() {
        #expect(
            expand(
                """
                struct OrderWorkflow {
                    @WorkflowSignal(name: "prio")
                    mutating func setPriority(_ p: Priority) {}
                }
                """
            )
                == expand(
                    """
                    struct OrderWorkflow {
                        mutating func setPriority(_ p: Priority) {}
                        struct SetPriority: WorkflowSignal {
                            typealias W = OrderWorkflow
                            typealias Input = Priority
                            static var signalName: String { "prio" }
                            static func apply(to w: inout OrderWorkflow, input: Priority) { w.setPriority(input) }
                        }
                    }
                    """
                )
        )
    }

    @Test func labeledParam() {
        #expect(
            expand(
                """
                struct DataWorkflow {
                    @WorkflowSignal
                    mutating func setData(data: MyData) {}
                }
                """
            )
                == expand(
                    """
                    struct DataWorkflow {
                        mutating func setData(data: MyData) {}
                        struct SetData: WorkflowSignal {
                            typealias W = DataWorkflow
                            typealias Input = MyData
                            static var signalName: String { "setData" }
                            static func apply(to w: inout DataWorkflow, input: MyData) { w.setData(data: input) }
                        }
                    }
                    """
                )
        )
    }
}
