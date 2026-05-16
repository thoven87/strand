import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - WorkflowUpdateMacro

/// PeerMacro applied to a `mutating func(input:) -> Output` inside a workflow struct.
///
/// For `@WorkflowUpdate mutating func setPriority(input: String) throws -> String`
/// it generates:
/// ```swift
/// struct SetPriority: WorkflowUpdateDefinition {
///     typealias W = OwningWorkflow
///     typealias Input = String
///     typealias Output = String
///     static var updateName: String { "setPriority" }
///     static func apply(to workflow: inout OwningWorkflow, input: String) throws -> String {
///         try workflow.setPriority(input: input)
///     }
/// }
/// ```
public struct WorkflowUpdateMacro: PeerMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        // --- Validate: must be a function declaration ---
        guard let funcDecl = declaration.as(FunctionDeclSyntax.self) else {
            throw MacroError("@WorkflowUpdate can only be applied to mutating functions")
        }

        // --- Validate: must have a non-Void return type ---
        guard let returnClause = funcDecl.signature.returnClause else {
            throw MacroError("@WorkflowUpdate function must return a value")
        }
        let outputType = returnClause.type.trimmedDescription
        if outputType == "Void" || outputType == "()" {
            throw MacroError("@WorkflowUpdate function must return a non-Void value")
        }

        // --- Validate: exactly one parameter labelled 'input:' ---
        let params = Array(funcDecl.signature.parameterClause.parameters)
        guard params.count == 1, params[0].firstName.text == "input" else {
            throw MacroError(
                "@WorkflowUpdate function must have exactly one parameter labelled 'input:'"
            )
        }
        let inputType = params[0].type.trimmedDescription

        // --- Find enclosing struct name ---
        var parentName: String? = nil
        for contextNode in context.lexicalContext {
            if let structDecl = contextNode.as(StructDeclSyntax.self) {
                parentName = structDecl.name.text
                break
            }
        }
        guard let parentName else {
            throw MacroError("@WorkflowUpdate must be used inside a workflow struct")
        }

        let funcName = funcDecl.name.text
        let structName = funcName.prefix(1).uppercased() + funcName.dropFirst()
        let isThrows = funcDecl.signature.effectSpecifiers?.throwsClause != nil
        let callExpr =
            isThrows
            ? "try workflow.\(funcName)(input: input)"
            : "workflow.\(funcName)(input: input)"

        return [
            """
            struct \(raw: structName): WorkflowUpdateDefinition {
                typealias W = \(raw: parentName)
                typealias Input = \(raw: inputType)
                typealias Output = \(raw: outputType)
                static var updateName: String { \(literal: funcName) }
                static func apply(to workflow: inout \(raw: parentName), input: \(raw: inputType)) throws -> \(raw: outputType) {
                    \(raw: callExpr)
                }
            }
            """
        ]
    }
}
