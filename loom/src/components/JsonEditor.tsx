import CodeMirror from "@uiw/react-codemirror";
import { json } from "@codemirror/lang-json";
import { vscodeDark } from "@uiw/codemirror-theme-vscode";

interface JsonEditorProps {
    value: string;
    onChange: (value: string) => void;
    minHeight?: string;
    placeholder?: string;
    /** Whether the editor is in a read-only / disabled state. */
    readOnly?: boolean;
}

/**
 * Editable JSON field backed by CodeMirror 6.
 *
 * Features: JSON syntax highlighting, line numbers, bracket matching,
 * auto-indent, and the same vsDark colour scheme as JsonView.
 */
export function JsonEditor({
    value,
    onChange,
    minHeight = "140px",
    placeholder,
    readOnly = false,
}: JsonEditorProps) {
    return (
        <CodeMirror
            value={value}
            extensions={[json()]}
            theme={vscodeDark}
            onChange={onChange}
            minHeight={minHeight}
            placeholder={placeholder}
            readOnly={readOnly}
            className="rounded border border-border overflow-hidden text-xs font-mono"
            basicSetup={{
                lineNumbers: true,
                foldGutter: false,
                dropCursor: false,
                allowMultipleSelections: false,
                indentOnInput: true,
                bracketMatching: true,
                closeBrackets: true,
                autocompletion: false,
                highlightActiveLine: true,
                highlightSelectionMatches: false,
            }}
        />
    );
}
