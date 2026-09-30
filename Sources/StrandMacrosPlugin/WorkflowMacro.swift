import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - WorkflowMacro

/// MemberMacro + ExtensionMacro applied to a workflow struct.
///
/// Generates:
/// - `extension MyWorkflow: Workflow {}` (plus `workflowName` override when `name:` is given)
/// - `handleSignal(name:payload:)` dispatch from every `@WorkflowSignal` method
/// - `handleUpdate(name:correlationID:payload:)` dispatch from every `@WorkflowUpdate` method
/// - `init() {}` when the struct has explicit inits but none with zero parameters
public struct WorkflowMacro: MemberMacro, ExtensionMacro {

    // MARK: - ExtensionMacro: Workflow conformance (+ optional workflowName override)

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let access =
            (declaration.as(StructDeclSyntax.self)?.modifiers)
            .map { leadingAccessModifier(from: $0) } ?? ""

        if let customName = stringLiteralArg(named: "name", from: node) {
            // Custom workflow task name — generate workflowName override in the extension.
            let ext: DeclSyntax = """
                extension \(raw: type.trimmedDescription): Workflow {
                    \(raw: access)static var workflowName: String { \(literal: customName) }
                }
                """
            guard let extDecl = ext.as(ExtensionDeclSyntax.self) else { return [] }
            return [extDecl]
        } else {
            let ext: DeclSyntax = "extension \(raw: type.trimmedDescription): Workflow {}"
            guard let extDecl = ext.as(ExtensionDeclSyntax.self) else { return [] }
            return [extDecl]
        }
    }

    // MARK: - MemberMacro: handleSignal, handleUpdate, init()

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        var result: [DeclSyntax] = []

        // Synthesise init() {} when the struct has explicit initialisers but no no-arg one.
        // Any explicit initialiser suppresses Swift's memberwise init(), breaking the
        // Workflow.init() protocol requirement.
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

        // ── Infer typealias Input / Output from run(context:input:) ─────────────
        //
        // When the user omits explicit typealias declarations the macro derives
        // them from the run() signature, eliminating the boilerplate entirely:
        //
        //   @Workflow struct Order {
        //       mutating func run(context: WorkflowContext<Self>, input: OrderInput) async throws -> ShipResult { … }
        //   }
        //   // macro generates: typealias Input = OrderInput
        //   //                  typealias Output = ShipResult
        //
        // For Void-returning run() the macro generates `typealias Output = Void`.
        // With Output: Sendable (the protocol constraint), Void satisfies the
        // requirement directly — no StrandVoid forwarding wrapper is needed.
        if let runInfo = findRunMethod(in: declaration) {
            if !hasTypealias("Input", in: declaration) {
                result.append(DeclSyntax(stringLiteral: "typealias Input = \(runInfo.inputType)"))
            }
            if !hasTypealias("Output", in: declaration) {
                // outputType is nil when run() returns Void / has no return clause.
                // We emit `Void` explicitly so the associated type is unambiguous;
                // the protocol's Output: Sendable constraint accepts it directly.
                let outputTypeText = runInfo.outputType ?? "Void"
                result.append(DeclSyntax(stringLiteral: "typealias Output = \(outputTypeText)"))
            }
        }

        // Collect @WorkflowSignal-annotated functions.
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

        // Collect @WorkflowUpdate-annotated functions.
        let updates = declaration.memberBlock.members.compactMap { member -> UpdateInfo? in
            guard
                let funcDecl = member.decl.as(FunctionDeclSyntax.self),
                hasWorkflowUpdateAttribute(funcDecl)
            else { return nil }

            let funcName = funcDecl.name.text
            let structName = funcName.prefix(1).uppercased() + funcName.dropFirst()
            let params = Array(funcDecl.signature.parameterClause.parameters)
            let inputType = params.first.map { $0.type.trimmedDescription } ?? "Void"

            let returnTypeStr = funcDecl.signature.returnClause?.type.trimmedDescription
            let isVoidReturn =
                returnTypeStr == nil || returnTypeStr == "Void" || returnTypeStr == "()"

            return UpdateInfo(structName: structName, inputType: inputType, isVoidReturn: isVoidReturn)
        }

        guard !signals.isEmpty || !updates.isEmpty else { return result }

        // Generate handleSignal when signals are present.
        if !signals.isEmpty {
            var lines: [String] = [
                "mutating func handleSignal(name: String, payload: ByteBuffer?) throws {",
                "    switch name {",
            ]
            for signal in signals {
                if signal.paramCount == 0 {
                    lines.append("    case \(signal.structName).signalName:")
                    lines.append("        \(signal.structName).apply(to: &self, input: ())")
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
                if update.isVoidReturn {
                    // Void update: call apply, discard Void result, return nil to the caller.
                    lines.append("            _ = try \(update.structName).apply(to: &self, input: input)")
                } else {
                    lines.append("            let result = try \(update.structName).apply(to: &self, input: input)")
                    lines.append("            return try _StrandCoder.encode(result)")
                }
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

    // MARK: - run() type inference helpers

    /// Captures the Input and Output types inferred from the workflow's `run(context:input:)` method.
    private struct RunMethodInfo {
        /// Text of the `input:` parameter type (e.g. `"OrderInput"`).
        let inputType: String
        /// Text of the return type, or `nil` when the return is `Void` / omitted.
        let outputType: String?
    }

    /// Scans the struct body for `mutating func run(context:input:)` and extracts its
    /// `input:` parameter type and return type. Returns `nil` when not found (e.g. `run`
    /// is defined in an extension rather than the struct body).
    private static func findRunMethod(in declaration: some DeclGroupSyntax) -> RunMethodInfo? {
        for member in declaration.memberBlock.members {
            guard let funcDecl = member.decl.as(FunctionDeclSyntax.self),
                funcDecl.name.text == "run"
            else { continue }
            let params = Array(funcDecl.signature.parameterClause.parameters)
            guard params.count == 2,
                params[0].firstName.text == "context",
                params[1].firstName.text == "input"
            else { continue }
            let inputType = params[1].type.trimmedDescription
            let returnType = funcDecl.signature.returnClause?.type.trimmedDescription
            let isVoid = returnType == nil || returnType == "Void" || returnType == "()"
            return RunMethodInfo(inputType: inputType, outputType: isVoid ? nil : returnType)
        }
        return nil
    }

    /// Returns `true` when the struct already contains a `typealias <name> = …` declaration.
    private static func hasTypealias(_ name: String, in declaration: some DeclGroupSyntax) -> Bool {
        declaration.memberBlock.members.contains { member in
            guard let alias = member.decl.as(TypeAliasDeclSyntax.self) else { return false }
            return alias.name.text == name
        }
    }

    // MARK: - Existing helpers

    private struct SignalInfo {
        let structName: String
        let paramCount: Int
        let paramType: String?
    }

    private struct UpdateInfo {
        let structName: String
        let inputType: String
        let isVoidReturn: Bool
    }

    private static func hasWorkflowSignalAttribute(_ funcDecl: FunctionDeclSyntax) -> Bool {
        funcDecl.attributes.contains { attrElem in
            guard let attr = attrElem.as(AttributeSyntax.self) else { return false }
            return attr.attributeName.trimmedDescription == "WorkflowSignal"
        }
    }

    private static func hasWorkflowUpdateAttribute(_ funcDecl: FunctionDeclSyntax) -> Bool {
        funcDecl.attributes.contains { attrElem in
            guard let attr = attrElem.as(AttributeSyntax.self) else { return false }
            return attr.attributeName.trimmedDescription == "WorkflowUpdate"
        }
    }
}
