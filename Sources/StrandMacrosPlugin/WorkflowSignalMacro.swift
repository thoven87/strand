import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - WorkflowSignalMacro

/// PeerMacro: applied to a `mutating func` inside a workflow struct.
///
/// For a 0-parameter signal `@WorkflowSignal mutating func pause()` it generates:
/// ```swift
/// struct Pause: WorkflowSignal {
///     typealias W = OwningWorkflow
///     typealias Input = StrandVoid
///     static func apply(to w: inout OwningWorkflow, input: StrandVoid) {
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
///     static func apply(to w: inout OwningWorkflow, input: Priority) {
///         w.setPriority(input)
///     }
/// }
/// ```
public struct WorkflowSignalMacro: PeerMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        // --- Validate: must be a function declaration ---
        guard let funcDecl = declaration.as(FunctionDeclSyntax.self) else {
            throw MacroError("@WorkflowSignal must be applied to a mutating func, not \(declaration.kind)")
        }

        // --- Find enclosing struct name ---
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

        // --- Validate: 0 or 1 parameter only ---
        if params.count > 1 {
            throw MacroError(
                "@WorkflowSignal function must have 0 or 1 parameters, got \(params.count)"
            )
        }

        // --- Extract optional custom signal name: @WorkflowSignal(name: "my-name") ---
        var customSignalName: String? = nil
        if let arguments = node.arguments,
            case .argumentList(let argList) = arguments
        {
            for arg in argList {
                if arg.label?.text == "name",
                    let strLit = arg.expression.as(StringLiteralExprSyntax.self),
                    let segment = strLit.segments.first?.as(StringSegmentSyntax.self)
                {
                    customSignalName = segment.content.text
                }
            }
        }

        // --- Generate the nested struct ---
        return [
            generateStruct(
                structName: structName,
                parentName: parentName,
                funcName: funcName,
                params: params,
                customSignalName: customSignalName
            )
        ]
    }

    // MARK: - Code generation helpers

    private static func generateStruct(
        structName: String,
        parentName: String,
        funcName: String,
        params: [FunctionParameterSyntax],
        customSignalName: String?
    ) -> DeclSyntax {
        // The wire name: explicit @WorkflowSignal(name:) wins; otherwise the
        // function name (camelCase) is used — e.g. `func setPriority` → "setPriority".
        // Callers never need (name:) to get a readable wire name.
        let wireName = customSignalName ?? funcName

        if params.isEmpty {
            // 0-parameter signal — Input = StrandVoid
            return """
                struct \(raw: structName): WorkflowSignal {
                    typealias W = \(raw: parentName)
                    typealias Input = StrandVoid
                    static var signalName: String { \(literal: wireName) }
                    static func apply(to w: inout \(raw: parentName), input: StrandVoid) {
                        w.\(raw: funcName)()
                    }
                }
                """
        } else {
            // 1-parameter signal — Input = first parameter's type
            let param = params[0]
            let paramType = param.type.trimmedDescription
            let firstName = param.firstName.text

            // Determine the call-site label:
            //   _ p: T  → w.func(input)
            //   label p: T → w.func(label: input)
            let callSite: String
            if firstName == "_" {
                callSite = "w.\(funcName)(input)"
            } else {
                callSite = "w.\(funcName)(\(firstName): input)"
            }

            return """
                struct \(raw: structName): WorkflowSignal {
                    typealias W = \(raw: parentName)
                    typealias Input = \(raw: paramType)
                    static var signalName: String { \(literal: wireName) }
                    static func apply(to w: inout \(raw: parentName), input: \(raw: paramType)) {
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
