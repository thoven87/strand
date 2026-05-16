import SwiftSyntax
import SwiftSyntaxMacros

/// PeerMacro applied to a function inside a `@Workflow` struct.
///
/// For `@WorkflowQuery func getStatus() -> OrderStatus` it generates:
/// ```swift
/// struct GetStatus: WorkflowQuery {
///     typealias W = OwningWorkflow
///     typealias Output = OrderStatus
///     static func run(workflow: OwningWorkflow) throws -> OrderStatus {
///         workflow.getStatus()
///     }
/// }
/// ```
public struct WorkflowQueryMacro: PeerMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        guard let funcDecl = declaration.as(FunctionDeclSyntax.self) else {
            throw MacroError("@WorkflowQuery can only be applied to functions")
        }

        guard let returnClause = funcDecl.signature.returnClause else {
            throw MacroError("@WorkflowQuery function must return a value")
        }
        let outputType = returnClause.type.trimmedDescription
        if outputType == "Void" || outputType == "()" {
            throw MacroError("@WorkflowQuery function must return a non-Void value")
        }

        let params = Array(funcDecl.signature.parameterClause.parameters)
        guard params.isEmpty else {
            throw MacroError("@WorkflowQuery function must have no parameters")
        }

        var parentName: String? = nil
        for contextNode in context.lexicalContext {
            if let structDecl = contextNode.as(StructDeclSyntax.self) {
                parentName = structDecl.name.text
                break
            }
        }
        guard let parentName else {
            throw MacroError("@WorkflowQuery must be used inside a workflow struct")
        }

        let funcName = funcDecl.name.text
        let structName = funcName.prefix(1).uppercased() + funcName.dropFirst()
        let isThrows = funcDecl.signature.effectSpecifiers?.throwsClause != nil
        let callExpr = isThrows ? "try workflow.\(funcName)()" : "workflow.\(funcName)()"

        return [
            """
            struct \(raw: structName): WorkflowQuery {
                typealias W = \(raw: parentName)
                typealias Output = \(raw: outputType)
                static func run(workflow: \(raw: parentName)) throws -> \(raw: outputType) {
                    \(raw: callExpr)
                }
            }
            """
        ]
    }
}
