import Testing

@Suite struct ActivityContainerMacroTests {

    @Test func basicContainer() {
        #expect(
            expand(
                """
                @ActivityContainer
                struct PaymentActivities {
                    @ContainerActivity var charge: ChargeActivity
                    @ContainerActivity var refund: RefundActivity
                }
                """
            )
                == expand(
                    """
                    struct PaymentActivities {
                        var charge: ChargeActivity
                        var refund: RefundActivity
                    }
                    extension PaymentActivities: ActivityContainerProtocol {
                        var activities: [any Activity] { [charge, refund] }
                    }
                    """
                )
        )
    }

    @Test func dependencyExcluded() {
        #expect(
            expand(
                """
                @ActivityContainer
                struct PaymentActivities {
                    let stripe: StripeClient
                    @ContainerActivity var charge: ChargeActivity
                }
                """
            )
                == expand(
                    """
                    struct PaymentActivities {
                        let stripe: StripeClient
                        var charge: ChargeActivity
                    }
                    extension PaymentActivities: ActivityContainerProtocol {
                        var activities: [any Activity] { [charge] }
                    }
                    """
                )
        )
    }

    @Test func activityMethodWithContext() {
        #expect(
            expand(
                """
                @ActivityContainer
                struct OllamaActivities {
                    @Activity
                    func classify(input: ClassifyInput, context: ActivityContext) async throws -> ClassifyOutput {}
                }
                """
            )
                == expand(
                    """
                    struct OllamaActivities {
                        func classify(input: ClassifyInput, context: ActivityContext) async throws -> ClassifyOutput {}
                    }
                    extension OllamaActivities: ActivityContainerProtocol {
                        struct Classify: Activity {
                            typealias Input = ClassifyInput
                            typealias Output = ClassifyOutput
                            let _container: OllamaActivities
                            func run(input: ClassifyInput, context: ActivityContext) async throws -> ClassifyOutput {
                                try await _container.classify(input: input, context: context)
                            }
                        }
                        var activities: [any Activity] { [Classify(_container: self)] }
                    }
                    """
                )
        )
    }

    @Test func activityMethodWithoutContext() {
        #expect(
            expand(
                """
                @ActivityContainer
                struct SimpleActivities {
                    @Activity
                    func transform(input: String) async throws -> String {}
                }
                """
            )
                == expand(
                    """
                    struct SimpleActivities {
                        func transform(input: String) async throws -> String {}
                    }
                    extension SimpleActivities: ActivityContainerProtocol {
                        struct Transform: Activity {
                            typealias Input = String
                            typealias Output = String
                            let _container: SimpleActivities
                            func run(input: String, context: ActivityContext) async throws -> String {
                                try await _container.transform(input: input)
                            }
                        }
                        var activities: [any Activity] { [Transform(_container: self)] }
                    }
                    """
                )
        )
    }

    @Test func mixedVarAndMethodActivities() {
        #expect(
            expand(
                """
                @ActivityContainer
                struct MixedActivities {
                    @ContainerActivity var charge: ChargeActivity
                    @Activity
                    func notify(input: NotifyInput, context: ActivityContext) async throws -> NotifyOutput {}
                }
                """
            )
                == expand(
                    """
                    struct MixedActivities {
                        var charge: ChargeActivity
                        func notify(input: NotifyInput, context: ActivityContext) async throws -> NotifyOutput {}
                    }
                    extension MixedActivities: ActivityContainerProtocol {
                        struct Notify: Activity {
                            typealias Input = NotifyInput
                            typealias Output = NotifyOutput
                            let _container: MixedActivities
                            func run(input: NotifyInput, context: ActivityContext) async throws -> NotifyOutput {
                                try await _container.notify(input: input, context: context)
                            }
                        }
                        var activities: [any Activity] { [charge, Notify(_container: self)] }
                    }
                    """
                )
        )
    }
}
