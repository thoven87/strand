import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - ContainerActivityMacro

/// PeerMacro applied to stored properties inside an `@ActivityContainer` struct.
///
/// This macro performs validation only — it verifies the declaration is a stored
/// property — and always returns `[]`. The `@ActivityContainer` extension macro
/// is what reads these annotations to build the `activities` array.
public struct ContainerActivityMacro: PeerMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        guard declaration.is(VariableDeclSyntax.self) else {
            throw MacroError(
                "@ContainerActivity can only be applied to stored properties"
            )
        }
        return []
    }
}

// MARK: - ActivityMacro

/// PeerMacro applied to functions inside an `@ActivityContainer` struct.
///
/// Validates that the declaration is a function with an `input:` first parameter,
/// then returns `[]` — it generates nothing on its own. The `@ActivityContainer`
/// extension macro reads this annotation to generate a nested `Activity`-conforming
/// struct that delegates to the annotated method.
public struct ActivityMacro: PeerMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        guard let funcDecl = declaration.as(FunctionDeclSyntax.self) else {
            throw MacroError("@Activity can only be applied to functions")
        }

        let params = Array(funcDecl.signature.parameterClause.parameters)

        guard !params.isEmpty, params[0].firstName.text == "input" else {
            throw MacroError(
                "@Activity function must have 'input:' as its first parameter"
            )
        }

        return []
    }
}

// MARK: - ActivityContainerMacro

/// ExtensionMacro applied to a struct that groups related activities.
///
/// Collects all `@ContainerActivity`-annotated stored properties and
/// `@Activity`-annotated functions, then synthesises `ActivityContainerProtocol`
/// conformance with nested `Activity`-conforming structs for every `@Activity`
/// method.
///
/// ```swift
/// @ActivityContainer
/// struct OllamaActivities {
///     let ollama: OllamaClient
///
///     @Activity
///     func classify(input: ClassifyInput, context: ActivityContext) async throws -> ClassifyOutput {
///         try await ollama.chatJSON(system: "...", user: "...", as: ClassifyOutput.self)
///     }
/// }
/// ```
/// expands to:
/// ```swift
/// extension OllamaActivities: ActivityContainerProtocol {
///     struct Classify: Activity {
///         typealias Input = ClassifyInput
///         typealias Output = ClassifyOutput
///         let _container: OllamaActivities
///         func run(input: ClassifyInput, context: ActivityContext) async throws -> ClassifyOutput {
///             try await _container.classify(input: input, context: context)
///         }
///     }
///     var activities: [any ActivityBox] {
///         [Classify(_container: self)]
///     }
/// }
/// ```
public struct ActivityContainerMacro: ExtensionMacro {

    // MARK: - Private helpers

    private struct ActivityMethodInfo {
        let structName: String
        let funcName: String
        let inputType: String
        let outputType: String
        let hasContextParam: Bool
        let isVoidReturn: Bool
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {

        // 1. Collect @ContainerActivity-annotated property names (existing behaviour).
        var propNames: [String] = []

        // 2. Collect @Activity-annotated function info (new behaviour).
        var activityMethods: [ActivityMethodInfo] = []

        for member in declaration.memberBlock.members {
            // @ContainerActivity var — extract property name
            if let varDecl = member.decl.as(VariableDeclSyntax.self),
                hasContainerActivityAttribute(varDecl)
            {
                for binding in varDecl.bindings {
                    if let ident = binding.pattern.as(IdentifierPatternSyntax.self) {
                        propNames.append(ident.identifier.text)
                    }
                }
            }

            // @Activity func — extract signature info
            if let funcDecl = member.decl.as(FunctionDeclSyntax.self),
                hasActivityAttribute(funcDecl)
            {
                let funcName = funcDecl.name.text
                let structName = funcName.prefix(1).uppercased() + funcName.dropFirst()
                let params = Array(funcDecl.signature.parameterClause.parameters)

                // First parameter labeled 'input:' provides the Input type.
                let inputType =
                    params.first(where: { $0.firstName.text == "input" })
                    .map { $0.type.trimmedDescription } ?? "StrandVoid"

                // Presence of a 'context:' parameter controls how we call the method.
                let hasContextParam = params.contains { $0.firstName.text == "context" }

                // Void return → StrandVoid
                let returnTypeStr = funcDecl.signature.returnClause?.type.trimmedDescription
                let isVoidReturn =
                    returnTypeStr == nil || returnTypeStr == "Void" || returnTypeStr == "()"
                let outputType = isVoidReturn ? "StrandVoid" : returnTypeStr!

                activityMethods.append(
                    ActivityMethodInfo(
                        structName: structName,
                        funcName: funcName,
                        inputType: inputType,
                        outputType: outputType,
                        hasContextParam: hasContextParam,
                        isVoidReturn: isVoidReturn
                    )
                )
            }
        }

        let typeName = type.trimmedDescription

        // 3. Build the inner content of the extension body as a plain string.
        //    Each struct declaration is indented with 4 spaces so it sits correctly
        //    inside `extension \(typeName): ActivityContainerProtocol { ... }`.
        var innerLines: [String] = []

        for method in activityMethods {
            innerLines.append("    struct \(method.structName): Activity {")
            innerLines.append("        typealias Input = \(method.inputType)")
            innerLines.append("        typealias Output = \(method.outputType)")
            innerLines.append("        let _container: \(typeName)")
            innerLines.append(
                "        func run(input: \(method.inputType), context: ActivityContext) async throws -> \(method.outputType) {"
            )

            if method.isVoidReturn {
                if method.hasContextParam {
                    innerLines.append(
                        "            try await _container.\(method.funcName)(input: input, context: context)"
                    )
                } else {
                    innerLines.append(
                        "            try await _container.\(method.funcName)(input: input)"
                    )
                }
                innerLines.append("            return StrandVoid()")
            } else {
                if method.hasContextParam {
                    innerLines.append(
                        "            try await _container.\(method.funcName)(input: input, context: context)"
                    )
                } else {
                    innerLines.append(
                        "            try await _container.\(method.funcName)(input: input)"
                    )
                }
            }

            innerLines.append("        }")
            innerLines.append("    }")
        }

        // Build the activities array: @ContainerActivity props come first (they
        // are already `ActivityBox`), followed by @Activity method structs.
        let allItems =
            (propNames + activityMethods.map { "\($0.structName)(_container: self)" })
            .joined(separator: ", ")

        innerLines.append("    var activities: [any ActivityBox] {")
        innerLines.append("        [\(allItems)]")
        innerLines.append("    }")

        let innerContent = innerLines.joined(separator: "\n")

        // 4. Emit the extension.
        let ext: DeclSyntax = """
            extension \(raw: typeName): ActivityContainerProtocol {
            \(raw: innerContent)
            }
            """

        guard let extDecl = ext.as(ExtensionDeclSyntax.self) else {
            return []
        }
        return [extDecl]
    }

    // MARK: - Attribute checkers

    private static func hasContainerActivityAttribute(_ varDecl: VariableDeclSyntax) -> Bool {
        varDecl.attributes.contains { attrElem in
            guard let attr = attrElem.as(AttributeSyntax.self) else { return false }
            return attr.attributeName.trimmedDescription == "ContainerActivity"
        }
    }

    private static func hasActivityAttribute(_ funcDecl: FunctionDeclSyntax) -> Bool {
        funcDecl.attributes.contains { attrElem in
            guard let attr = attrElem.as(AttributeSyntax.self) else { return false }
            return attr.attributeName.trimmedDescription == "Activity"
        }
    }
}
