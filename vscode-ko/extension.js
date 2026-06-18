const vscode = require('vscode');

function activate(context) {
    console.log('Kō language support is now active!');

    // ===== Completion Provider =====
    const completionProvider = vscode.languages.registerCompletionItemProvider('ko', {
        provideCompletionItems(document, position, token, context) {
            const items = [];

            // Keywords with snippets
            const keywords = [
                { name: 'fn', snippet: 'fn ${1:name} ${2:params} = ${3:body}', doc: 'Define a function' },
                { name: 'let', snippet: 'let ${1:name} = ${2:expr}', doc: 'Bind a value (immutable)' },
                { name: 'if', snippet: 'if ${1:cond} then ${2:expr}', doc: 'Conditional expression' },
                { name: 'else', snippet: 'else ${1:expr}', doc: 'Else branch' },
                { name: 'then', snippet: 'then ${1:expr}', doc: 'Then branch' },
                { name: 'match', snippet: 'match ${1:expr}\n  ${2:pattern} -> ${3:body}', doc: 'Pattern matching' },
                { name: 'type', snippet: 'type ${1:Name} = ${2:Constructor} ${3:*} | ${4:Other}', doc: 'Define algebraic data type' },
                { name: 'in', snippet: 'in ${1:expr}', doc: 'Body of let expression' },
            ];
            keywords.forEach(kw => {
                const item = new vscode.CompletionItem(kw.name, vscode.CompletionItemKind.Keyword);
                item.insertText = new vscode.SnippetString(kw.snippet);
                item.documentation = kw.doc;
                items.push(item);
            });

            // Built-in functions with docs
            const builtins = [
                { name: 'print', sig: 'print value', doc: 'Print a value without newline\n\n```kō\nprint 42       // prints: 42\nprint "hello"  // prints: hello\n```' },
                { name: 'println', sig: 'println value', doc: 'Print a value with newline\n\n```kō\nprintln 42     // prints: 42\\n\n```' },
                { name: 'inspect', sig: 'inspect value', doc: 'Print detailed type/value info for debugging\n\n```kō\ninspect 42\n// Value{type=Int, value=42, addr=0x7fff...}\n\ninspect (Just 5)\n// Value{type=Constructor(tag=0, name=Just, arity=1), addr=...}\n```' },
                { name: 'panic', sig: 'panic message', doc: 'Exit with error message\n\n```kō\npanic "something went wrong"\n```' },
            ];
            builtins.forEach(fn => {
                const item = new vscode.CompletionItem(fn.name, vscode.CompletionItemKind.Function);
                item.detail = fn.sig;
                item.documentation = new vscode.MarkdownString(fn.doc);
                items.push(item);
            });

            // Common patterns as snippets
            const patterns = [
                { name: 'match-maybe', snippet: 'match ${1:mx}\n  Just ${2:x} -> ${3:value}\n  Nothing -> ${4:default}', doc: 'Pattern match on Maybe' },
                { name: 'match-list', snippet: 'match ${1:xs}\n  Cons ${2:x} ${3:rest} -> ${4:body}\n  Nil -> ${5:empty}', doc: 'Pattern match on List' },
                { name: 'match-result', snippet: 'match ${1:r}\n  Ok ${2:v} -> ${3:body}\n  Err ${4:msg} -> ${5:error}', doc: 'Pattern match on Result' },
                { name: 'type-maybe', snippet: 'type Maybe = Just * | Nothing', doc: 'Maybe ADT definition' },
                { name: 'type-list', snippet: 'type List = Cons * * | Nil', doc: 'List ADT definition' },
                { name: 'type-result', snippet: 'type Result = Ok * | Err *', doc: 'Result ADT definition' },
            ];
            patterns.forEach(p => {
                const item = new vscode.CompletionItem(p.name, vscode.CompletionItemKind.Snippet);
                item.insertText = new vscode.SnippetString(p.snippet);
                item.documentation = p.doc;
                items.push(item);
            });

            return items;
        }
    });

    // ===== Hover Provider =====
    const hoverProvider = vscode.languages.registerHoverProvider('ko', {
        provideHover(document, position, token) {
            const word = document.getWordRangeAtPosition(position);
            if (!word) return null;
            const text = document.getText(word);

            const docs = {
                'fn': {
                    sig: '`fn name param1 param2 = body`',
                    doc: 'Defines a function. Functions are first-class.\n\n```kō\nfn add a b = a + b\nfn factorial n =\n  if n == 0 then 1\n  else n * factorial (n - 1)\n```'
                },
                'let': {
                    sig: '`let name = expr`',
                    doc: 'Binds a value to a name. Immutable — cannot be reassigned.\n\n```kō\nlet x = 42\nlet xs = Cons 1 (Cons 2 Nil)\n```'
                },
                'if': {
                    sig: '`if cond then expr else expr`',
                    doc: 'Conditional expression. Both branches must return the same type.\n\n```kō\nif x > 0 then "positive" else "negative"\n```'
                },
                'match': {
                    sig: '`match expr pattern -> body`',
                    doc: 'Pattern matching on algebraic data types.\n\n```kō\nmatch mx\n  Just x -> x\n  Nothing -> 0\n```'
                },
                'type': {
                    sig: '`type Name = Constructor * | Other`',
                    doc: 'Defines an algebraic data type. `*` marks type slots.\n\n```kō\ntype Maybe = Just * | Nothing\ntype List = Cons * * | Nil\ntype Expr = Add * * | Lit *\n```'
                },
                'true': { sig: '`true`', doc: 'Boolean literal' },
                'false': { sig: '`false`', doc: 'Boolean literal' },
                'print': { sig: '`print value`', doc: 'Prints value without newline' },
                'println': { sig: '`println value`', doc: 'Prints value with newline' },
                'inspect': { sig: '`inspect value`', doc: 'Prints detailed type/value info for debugging' },
                'panic': { sig: '`panic message`', doc: 'Exits with error message' },
                'Just': { sig: '`Just value`', doc: 'Maybe constructor — wraps a value\n\n```kō\ntype Maybe = Just * | Nothing\nlet x = Just 42\n```' },
                'Nothing': { sig: '`Nothing`', doc: 'Maybe constructor — no value\n\n```kō\ntype Maybe = Just * | Nothing\nlet x = Nothing\n```' },
                'Cons': { sig: '`Cons head tail`', doc: 'List constructor — prepends element\n\n```kō\ntype List = Cons * * | Nil\nlet xs = Cons 1 (Cons 2 (Cons 3 Nil))\n```' },
                'Nil': { sig: '`Nil`', doc: 'List constructor — empty list\n\n```kō\ntype List = Cons * * | Nil\nlet xs = Nil\n```' },
                'Ok': { sig: '`Ok value`', doc: 'Result constructor — success\n\n```kō\ntype Result = Ok * | Err *\nlet r = Ok 42\n```' },
                'Err': { sig: '`Err message`', doc: 'Result constructor — error\n\n```kō\ntype Result = Ok * | Err *\nlet r = Err "failed"\n```' },
            };

            if (docs[text]) {
                const d = docs[text];
                return new vscode.Hover([`**${d.sig}**`, '', d.doc]);
            }

            return null;
        }
    });

    // ===== Document Symbol Provider (Outline) =====
    const symbolProvider = vscode.languages.registerDocumentSymbolProvider('ko', {
        provideDocumentSymbols(document, token) {
            const symbols = [];
            const lines = document.getText().split('\n');

            for (let i = 0; i < lines.length; i++) {
                const line = lines[i];
                const fnMatch = line.match(/^fn\s+(\S+)/);
                const typeMatch = line.match(/^type\s+(\S+)/);
                const letMatch = line.match(/^let\s+(\S+)/);

                if (fnMatch) {
                    symbols.push(new vscode.DocumentSymbol(
                        fnMatch[1], 'function', vscode.SymbolKind.Function,
                        new vscode.Range(i, 0, i, line.length),
                        new vscode.Range(i, 3, i, 3 + fnMatch[1].length)
                    ));
                } else if (typeMatch) {
                    symbols.push(new vscode.DocumentSymbol(
                        typeMatch[1], 'type', vscode.SymbolKind.Enum,
                        new vscode.Range(i, 0, i, line.length),
                        new vscode.Range(i, 5, i, 5 + typeMatch[1].length)
                    ));
                } else if (letMatch) {
                    symbols.push(new vscode.DocumentSymbol(
                        letMatch[1], 'variable', vscode.SymbolKind.Variable,
                        new vscode.Range(i, 0, i, line.length),
                        new vscode.Range(i, 4, i, 4 + letMatch[1].length)
                    ));
                }
            }
            return symbols;
        }
    });

    // ===== Folding Provider =====
    const foldingProvider = vscode.languages.registerFoldingRangeProvider('ko', {
        provideFoldingRanges(document, token) {
            const ranges = [];
            const lines = document.getText().split('\n');
            let indentStack = [];

            for (let i = 0; i < lines.length; i++) {
                const line = lines[i];
                const indent = line.search(/\S/);

                if (indent >= 0) {
                    while (indentStack.length > 0 && indent <= indentStack[indentStack.length - 1].indent) {
                        const start = indentStack.pop();
                        if (i - start.line > 1) {
                            ranges.push(new vscode.FoldingRange(start.line, i - 1));
                        }
                    }
                    indentStack.push({ indent, line: i });
                }
            }
            return ranges;
        }
    });

    // ===== Brace Matching =====
    const bracketHandler = vscode.languages.registerBracketMatchingProvider('ko', {
        provideDocumentMatchingBrackets(document, position, token) {
            // Simple bracket matching
            const char = document.getText(new vscode.Range(position, position.translate(0, 1)));
            const brackets = { '(': ')', ')': '(', '[': ']', ']': '[', '{': '}', '}': '{' };
            if (!brackets[char]) return [];

            const other = brackets[char];
            const text = document.getText();
            let depth = 0;
            const startChar = char === '(' || char === '[' || char === '{';

            for (let i = 0; i < text.length; i++) {
                if (text[i] === char) depth++;
                else if (text[i] === other) depth--;
                if (depth === 0 && i !== position.character) {
                    return [new vscode.DocumentLink(new vscode.Range(position, position.translate(0, 1)), undefined)];
                }
            }
            return [];
        }
    });

    context.subscriptions.push(
        completionProvider,
        hoverProvider,
        symbolProvider,
        foldingProvider,
        bracketHandler
    );
}

function deactivate() {}

module.exports = { activate, deactivate };
