import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - WorkflowSignalMacro

/// PeerMacro: applied to a `mutating func` inside a `@Workflow` struct.
///
/// For a 0-parameter signal `@WorkflowSignal mutating func pause()` it generates:
/// ```swift
/// struct Pause: WorkflowSignal {
///     typealias W = OwningWorkflow
///     typealias Input = Void
///     static var signalName: String { "pause" }
///     static func apply(to w: inout OwningWorkflow, input: Void) {
///         w.pause()
///     }
/// }
/// ```
///
/// For a 1-parameter signal `@WorkflowSignal mutating func setPriority(_ p: Priority)`:
/// ```swift
/// struct SetPriority: WorkflowSignal {
///     typealias W = OwningWorkflow
///     typealias Input = Priority
///     static var signalName: String { "setPriority" }
///     static func apply(to w: inout OwningWorkflow, input: Priority) {
///         w.setPriority(input)
///     }
/// }
/// ```
///
/// The generated struct carries the same access modifier as the annotated function.
public struct WorkflowSignalMacro: PeerMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        guard let funcDecl = declaration.as(FunctionDeclSyntax.self) else {
            throw MacroError("@WorkflowSignal must be applied to a mutating func, not \(declaration.kind)")
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
            throw MacroError("@WorkflowSignal must be used inside a struct that conforms to Workflow")
        }

        let funcName = funcDecl.name.text
        let structName = funcName.prefix(1).uppercased() + funcName.dropFirst()
        let params = Array(funcDecl.signature.parameterClause.parameters)

        guard params.count <= 1 else {
            throw MacroError(
                "@WorkflowSignal function must have 0 or 1 parameters, got \(params.count)"
            )
        }

        let customSignalName = stringLiteralArg(named: "name", from: node)
        let access = leadingAccessModifier(from: funcDecl.modifiers)

        return [
            generateStruct(
                structName: structName,
                parentName: parentName,
                funcName: funcName,
                params: params,
                customSignalName: customSignalName,
                access: access
            )
        ]
    }

    // MARK: - Code generation

    private static func generateStruct(
        structName: String,
        parentName: String,
        funcName: String,
        params: [FunctionParameterSyntax],
        customSignalName: String?,
        access: String
    ) -> DeclSyntax {
        let wireName = customSignalName ?? funcName

        if params.isEmpty {
            return """
                \(raw: access)struct \(raw: structName): WorkflowSignal {
                    \(raw: access)typealias W = \(raw: parentName)
                    \(raw: access)typealias Input = Void
                    \(raw: access)static var signalName: String { \(literal: wireName) }
                    \(raw: access)static func apply(to w: inout \(raw: parentName), input: Void) {
                        w.\(raw: funcName)()
                    }
                }
                """
        } else {
            let param = params[0]
            let paramType = param.type.trimmedDescription
            let firstName = param.firstName.text
            let callSite =
                firstName == "_"
                ? "w.\(funcName)(input)"
                : "w.\(funcName)(\(firstName): input)"

            return """
                \(raw: access)struct \(raw: structName): WorkflowSignal {
                    \(raw: access)typealias W = \(raw: parentName)
                    \(raw: access)typealias Input = \(raw: paramType)
                    \(raw: access)static var signalName: String { \(literal: wireName) }
                    \(raw: access)static func apply(to w: inout \(raw: parentName), input: \(raw: paramType)) {
                        \(raw: callSite)
                    }
                }
                """
        }
    }
}

// MARK: - Shared error type

struct MacroError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
