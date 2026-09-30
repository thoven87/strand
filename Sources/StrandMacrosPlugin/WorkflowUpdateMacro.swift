import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - WorkflowUpdateMacro

/// PeerMacro applied to a `mutating func(input:) -> Output` inside a `@Workflow` struct.
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
///
/// Void-returning functions are allowed; the generated Output is `Void`.
/// The generated struct carries the same access modifier as the annotated function.
public struct WorkflowUpdateMacro: PeerMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        guard let funcDecl = declaration.as(FunctionDeclSyntax.self) else {
            throw MacroError("@WorkflowUpdate can only be applied to mutating functions")
        }

        // Find the enclosing struct to derive the parent type name.
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

        // Validate: exactly one parameter labelled 'input:'.
        let params = Array(funcDecl.signature.parameterClause.parameters)
        guard params.count == 1, params[0].firstName.text == "input" else {
            throw MacroError(
                "@WorkflowUpdate function must have exactly one parameter labelled 'input:'"
            )
        }
        let inputType = params[0].type.trimmedDescription

        // Determine return type — Void is allowed.
        let returnTypeStr = funcDecl.signature.returnClause?.type.trimmedDescription
        let isVoidReturn =
            returnTypeStr == nil || returnTypeStr == "Void" || returnTypeStr == "()"
        let outputType = isVoidReturn ? "Void" : returnTypeStr!

        let funcName = funcDecl.name.text
        let structName = funcName.prefix(1).uppercased() + funcName.dropFirst()
        let isThrows = funcDecl.signature.effectSpecifiers?.throwsClause != nil
        let access = leadingAccessModifier(from: funcDecl.modifiers)

        // Build the apply body.
        let tryPrefix = isThrows ? "try " : ""
        let callExpr = "\(tryPrefix)workflow.\(funcName)(input: input)"

        let applyBody: String
        if isVoidReturn {
            applyBody = callExpr  // Void function — no return statement needed
        } else {
            applyBody = "return \(callExpr)"
        }

        return [
            """
            \(raw: access)struct \(raw: structName): WorkflowUpdateDefinition {
                \(raw: access)typealias W = \(raw: parentName)
                \(raw: access)typealias Input = \(raw: inputType)
                \(raw: access)typealias Output = \(raw: outputType)
                \(raw: access)static var updateName: String { \(literal: funcName) }
                \(raw: access)static func apply(to workflow: inout \(raw: parentName), input: \(raw: inputType)) throws -> \(raw: outputType) {
                    \(raw: applyBody)
                }
            }
            """
        ]
    }
}
