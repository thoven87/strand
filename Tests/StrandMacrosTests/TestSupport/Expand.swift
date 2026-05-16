import StrandMacrosPlugin
import SwiftBasicFormat
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros

private let strandMacros: [String: any Macro.Type] = [
    "WorkflowSignal": WorkflowSignalMacro.self,
    "WorkflowUpdate": WorkflowUpdateMacro.self,
    "Workflow": WorkflowMacro.self,
    "ContainerActivity": ContainerActivityMacro.self,
    "ActivityContainer": ActivityContainerMacro.self,
    "Activity": ActivityMacro.self,
]

/// Expands all Strand macros in `source` and returns the result with all
/// whitespace stripped, making comparisons insensitive to formatter differences.
func expand(_ source: String) -> String {
    let syntax = Parser.parse(source: source)
    // A shared base context; each expansion node gets its own context that
    // carries the correct lexical context (enclosing struct, etc.) — required
    // for PeerMacros like @WorkflowSignal that query `context.lexicalContext`.
    let base = BasicMacroExpansionContext(
        lexicalContext: [],
        expansionDiscriminator: "",
        sourceFiles: [:]
    )
    let expanded = syntax.expand(macros: strandMacros) { node in
        BasicMacroExpansionContext(
            sharingWith: base,
            lexicalContext: node.allMacroLexicalContexts()
        )
    }
    return expanded.formatted(using: BasicFormat()).description
        .filter { !$0.isWhitespace }
}
