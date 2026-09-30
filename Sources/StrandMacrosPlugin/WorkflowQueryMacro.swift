import SwiftSyntax
import SwiftSyntaxMacros

/// PeerMacro applied to a function or stored property inside a `@Workflow` struct.
///
/// **Function query** — `@WorkflowQuery func getStatus() -> OrderStatus`:
/// ```swift
/// struct GetStatus: WorkflowQuery {
///     typealias W = OwningWorkflow
///     typealias Output = OrderStatus
///     static func run(workflow: OwningWorkflow) throws -> OrderStatus {
///         workflow.getStatus()
///     }
/// }
/// ```
///
/// **Property query** — `@WorkflowQuery var status: OrderStatus`:
/// ```swift
/// struct Status: WorkflowQuery {
///     typealias W = OwningWorkflow
///     typealias Output = OrderStatus
///     static func run(workflow: OwningWorkflow) throws -> OrderStatus {
///         workflow.status
///     }
/// }
/// ```
///
/// The generated struct carries the same access modifier as the annotated declaration.
/// An optional `name:` argument overrides the query's wire name.
public struct WorkflowQueryMacro: PeerMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        // Find the enclosing struct to derive the parent type name.
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

        let customName = stringLiteralArg(named: "name", from: node)

        if let funcDecl = declaration.as(FunctionDeclSyntax.self) {
            return try expandFunction(
                node: node,
                funcDecl: funcDecl,
                parentName: parentName,
                customName: customName
            )
        } else if let varDecl = declaration.as(VariableDeclSyntax.self) {
            return try expandProperty(
                node: node,
                varDecl: varDecl,
                parentName: parentName,
                customName: customName
            )
        } else {
            throw MacroError(
                "@WorkflowQuery can only be applied to functions or stored properties"
            )
        }
    }

    // MARK: - Function query

    private static func expandFunction(
        node: AttributeSyntax,
        funcDecl: FunctionDeclSyntax,
        parentName: String,
        customName: String?
    ) throws -> [DeclSyntax] {
        guard let returnClause = funcDecl.signature.returnClause else {
            throw MacroError("@WorkflowQuery function must return a value")
        }
        let outputType = returnClause.type.trimmedDescription
        guard outputType != "Void" && outputType != "()" else {
            throw MacroError("@WorkflowQuery function must return a non-Void value")
        }

        let params = Array(funcDecl.signature.parameterClause.parameters)
        guard params.isEmpty else {
            throw MacroError("@WorkflowQuery function must have no parameters")
        }

        let funcName = funcDecl.name.text
        let structName =
            (customName ?? funcName).prefix(1).uppercased()
            + (customName ?? funcName).dropFirst()
        let wireName = customName ?? funcName
        let isThrows = funcDecl.signature.effectSpecifiers?.throwsClause != nil
        let callExpr = isThrows ? "try workflow.\(funcName)()" : "workflow.\(funcName)()"
        let access = leadingAccessModifier(from: funcDecl.modifiers)

        return [
            """
            \(raw: access)struct \(raw: structName): WorkflowQuery {
                \(raw: access)typealias W = \(raw: parentName)
                \(raw: access)typealias Output = \(raw: outputType)
                \(raw: access)static var queryName: String { \(literal: wireName) }
                \(raw: access)static func run(workflow: \(raw: parentName)) throws -> \(raw: outputType) {
                    \(raw: callExpr)
                }
            }
            """
        ]
    }

    // MARK: - Property query

    private static func expandProperty(
        node: AttributeSyntax,
        varDecl: VariableDeclSyntax,
        parentName: String,
        customName: String?
    ) throws -> [DeclSyntax] {
        guard let binding = varDecl.bindings.first,
            let identifier = binding.pattern.as(IdentifierPatternSyntax.self)
        else {
            throw MacroError("@WorkflowQuery property must have an identifier")
        }
        guard let typeAnnotation = binding.typeAnnotation else {
            throw MacroError(
                "@WorkflowQuery property must have an explicit type annotation"
            )
        }

        let propName = identifier.identifier.text
        let outputType = typeAnnotation.type.trimmedDescription
        let wireName = customName ?? propName
        let structName = wireName.prefix(1).uppercased() + wireName.dropFirst()
        let access = leadingAccessModifier(from: varDecl.modifiers)

        return [
            """
            \(raw: access)struct \(raw: structName): WorkflowQuery {
                \(raw: access)typealias W = \(raw: parentName)
                \(raw: access)typealias Output = \(raw: outputType)
                \(raw: access)static var queryName: String { \(literal: wireName) }
                \(raw: access)static func run(workflow: \(raw: parentName)) throws -> \(raw: outputType) {
                    workflow.\(raw: propName)
                }
            }
            """
        ]
    }
}
