import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - WorkflowMacro

/// MemberMacro: applied to a workflow struct.
///
/// Scans all members for `@WorkflowSignal`-annotated `mutating func` declarations
/// and synthesises `handleSignal(name:payload:)`:
///
/// ```swift
/// @Workflow
/// struct OrderWorkflow {
///     @WorkflowSignal mutating func pause() {}
///     @WorkflowSignal(name: "set-priority") mutating func setPriority(_ p: Priority) {}
/// }
/// ```
/// expands to:
/// ```swift
/// struct OrderWorkflow {
///     mutating func pause() {}
///     mutating func setPriority(_ p: Priority) {}
///     mutating func handleSignal(name: String, payload: ByteBuffer?) throws {
///         switch name {
///         case Pause.signalName:
///             Pause.apply(to: &self, input: .done)
///         case SetPriority.signalName:
///             if let p = try decodeSignalPayload(Priority.self, from: payload) {
///                 SetPriority.apply(to: &self, input: p)
///             }
///         default:
///             break
///         }
///     }
/// }
/// ```
public struct WorkflowMacro: MemberMacro, ExtensionMacro {

    // MARK: - ExtensionMacro: add Workflow conformance

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let ext: DeclSyntax = "extension \(raw: type.trimmedDescription): Workflow {}"
        guard let extDecl = ext.as(ExtensionDeclSyntax.self) else { return [] }
        return [extDecl]
    }

    // MARK: - MemberMacro: generate handleSignal and/or handleUpdate

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        var result: [DeclSyntax] = []

        // Generate init() {} when the struct has explicit initialisers but no init().
        // Any explicit initialiser suppresses Swift's synthesised memberwise init(),
        // breaking the Workflow.init() protocol requirement. The @Workflow macro
        // fills the gap automatically.
        let hasExplicitInits = declaration.memberBlock.members.contains {
            $0.decl.is(InitializerDeclSyntax.self)
        }
        let hasNoArgInit = declaration.memberBlock.members.contains { member in
            guard let initDecl = member.decl.as(InitializerDeclSyntax.self) else { return false }
            return initDecl.signature.parameterClause.parameters.isEmpty
        }
        if hasExplicitInits && !hasNoArgInit {
            result.append(DeclSyntax(stringLiteral: "init() {}"))
        }

        // Collect @WorkflowSignal-annotated functions from the struct/class/actor.
        let signals = declaration.memberBlock.members.compactMap { member -> SignalInfo? in
            guard
                let funcDecl = member.decl.as(FunctionDeclSyntax.self),
                hasWorkflowSignalAttribute(funcDecl)
            else { return nil }

            let funcName = funcDecl.name.text
            let structName = funcName.prefix(1).uppercased() + funcName.dropFirst()
            let params = Array(funcDecl.signature.parameterClause.parameters)
            let paramType = params.first.map { $0.type.trimmedDescription }

            return SignalInfo(
                structName: structName,
                paramCount: params.count,
                paramType: paramType
            )
        }

        // Collect @WorkflowUpdate-annotated functions from the struct/class/actor.
        let updates = declaration.memberBlock.members.compactMap { member -> UpdateInfo? in
            guard
                let funcDecl = member.decl.as(FunctionDeclSyntax.self),
                hasWorkflowUpdateAttribute(funcDecl)
            else { return nil }

            let funcName = funcDecl.name.text
            let structName = funcName.prefix(1).uppercased() + funcName.dropFirst()
            let params = Array(funcDecl.signature.parameterClause.parameters)
            let inputType = params.first.map { $0.type.trimmedDescription } ?? "StrandVoid"

            return UpdateInfo(structName: structName, inputType: inputType)
        }

        // Nothing more to generate if neither signals nor updates are found.
        guard !signals.isEmpty || !updates.isEmpty else { return result }

        // Generate handleSignal when signals are present.
        // Build the function source line-by-line at column 0. The MemberMacro
        // expansion context re-indents the whole DeclSyntax by indentationWidth
        // (4 spaces) when it inserts it as a struct member.
        if !signals.isEmpty {
            var lines: [String] = [
                "mutating func handleSignal(name: String, payload: ByteBuffer?) throws {",
                "    switch name {",
            ]
            for signal in signals {
                if signal.paramCount == 0 {
                    lines.append("    case \(signal.structName).signalName:")
                    lines.append("        \(signal.structName).apply(to: &self, input: .done)")
                } else {
                    let paramType = signal.paramType!
                    lines.append("    case \(signal.structName).signalName:")
                    lines.append("        if let p = try decodeSignalPayload(\(paramType).self, from: payload) {")
                    lines.append("            \(signal.structName).apply(to: &self, input: p)")
                    lines.append("        }")
                }
            }
            lines.append("    default:")
            lines.append("        break")
            lines.append("    }")
            lines.append("}")
            result.append(DeclSyntax(stringLiteral: lines.joined(separator: "\n")))
        }

        // Generate handleUpdate when updates are present.
        if !updates.isEmpty {
            var lines: [String] = [
                "mutating func handleUpdate(name: String, correlationID: String, payload: ByteBuffer?) throws -> ByteBuffer? {",
                "    switch name {",
            ]
            for update in updates {
                lines.append("    case \(update.structName).updateName:")
                lines.append("        if let inputBuf = payload {")
                lines.append("            let input = try _StrandCoder.decode(\(update.inputType).self, from: inputBuf)")
                lines.append("            let result = try \(update.structName).apply(to: &self, input: input)")
                lines.append("            return try _StrandCoder.encode(result)")
                lines.append("        }")
                lines.append("        return nil")
            }
            lines.append("    default:")
            lines.append("        return nil")
            lines.append("    }")
            lines.append("}")
            result.append(DeclSyntax(stringLiteral: lines.joined(separator: "\n")))
        }

        return result
    }

    // MARK: - Helpers

    private struct SignalInfo {
        let structName: String
        let paramCount: Int
        let paramType: String?
    }

    private struct UpdateInfo {
        let structName: String
        let inputType: String
    }

    /// Returns `true` when the function has an `@WorkflowSignal` attribute.
    private static func hasWorkflowSignalAttribute(_ funcDecl: FunctionDeclSyntax) -> Bool {
        funcDecl.attributes.contains { attrElem in
            guard let attr = attrElem.as(AttributeSyntax.self) else { return false }
            // Handles both @WorkflowSignal and @WorkflowSignal(name: "…")
            return attr.attributeName.trimmedDescription == "WorkflowSignal"
        }
    }

    /// Returns `true` when the function has an `@WorkflowUpdate` attribute.
    private static func hasWorkflowUpdateAttribute(_ funcDecl: FunctionDeclSyntax) -> Bool {
        funcDecl.attributes.contains { attrElem in
            guard let attr = attrElem.as(AttributeSyntax.self) else { return false }
            return attr.attributeName.trimmedDescription == "WorkflowUpdate"
        }
    }
}
