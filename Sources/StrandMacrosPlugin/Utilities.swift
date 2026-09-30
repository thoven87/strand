import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - Shared macro helpers

/// Returns the leading access modifier with a trailing space (e.g. `"public "`, `"package "`)
/// or `""` (internal by default) when none is present.
///
/// `open` is mapped to `"public "` — nested types cannot be declared `open`.
func leadingAccessModifier(from modifiers: DeclModifierListSyntax) -> String {
    for modifier in modifiers {
        switch modifier.name.tokenKind {
        case .keyword(.public): return "public "
        case .keyword(.package): return "package "
        case .keyword(.internal): return "internal "
        case .keyword(.fileprivate): return "fileprivate "
        case .keyword(.private): return "private "
        case .keyword(.open): return "public "
        default: break
        }
    }
    return ""
}

/// Returns `true` when `structDecl` has an `@Workflow` attribute — used by peer macros
/// to confirm they are applied inside a `@Workflow`-annotated struct.
func hasWorkflowAttribute(_ structDecl: StructDeclSyntax) -> Bool {
    structDecl.attributes.contains { elem in
        guard let attr = elem.as(AttributeSyntax.self) else { return false }
        return attr.attributeName.trimmedDescription == "Workflow"
    }
}

/// Extracts the string-literal value for a named argument from an attribute node.
///
/// e.g. `@WorkflowSignal(name: "my-signal")` with `argName = "name"` → `"my-signal"`.
func stringLiteralArg(named argName: String, from node: AttributeSyntax) -> String? {
    guard let args = node.arguments, case .argumentList(let argList) = args else { return nil }
    for arg in argList where arg.label?.text == argName {
        if let strLit = arg.expression.as(StringLiteralExprSyntax.self),
            let segment = strLit.segments.first?.as(StringSegmentSyntax.self)
        {
            return segment.content.text
        }
    }
    return nil
}
