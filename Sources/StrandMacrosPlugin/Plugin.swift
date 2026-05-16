import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct StrandMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        WorkflowSignalMacro.self,
        WorkflowQueryMacro.self,
        WorkflowUpdateMacro.self,
        WorkflowMacro.self,
        ContainerActivityMacro.self,
        ActivityContainerMacro.self,
        ActivityMacro.self,
    ]
}
