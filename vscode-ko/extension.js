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
                { name: 'print', sig: 'print value', doc: 'Print a value without newline' },
                { name: 'println', sig: 'println value', doc: 'Print a value with newline' },
                { name: 'inspect', sig: 'inspect value', doc: 'Print detailed type/value info for debugging' },
                { name: 'panic', sig: 'panic message', doc: 'Exit with error message' },
                // String ops
                { name: 'len', sig: 'len s', doc: 'Returns length of string' },
                { name: 'concat', sig: 'concat a b', doc: 'Concatenates two strings' },
                { name: 'char_at', sig: 'char_at s i', doc: 'Returns character at index' },
                { name: 'substring', sig: 'substring s start end', doc: 'Extracts substring' },
                { name: 'contains', sig: 'contains s sub', doc: 'Checks if string contains substring' },
                { name: 'to_upper', sig: 'to_upper s', doc: 'Converts to uppercase' },
                { name: 'to_lower', sig: 'to_lower s', doc: 'Converts to lowercase' },
                { name: 'trim', sig: 'trim s', doc: 'Removes leading/trailing whitespace' },
                { name: 'starts_with', sig: 'starts_with s prefix', doc: 'Checks if string starts with prefix' },
                { name: 'ends_with', sig: 'ends_with s suffix', doc: 'Checks if string ends with suffix' },
                { name: 'repeat', sig: 'repeat s n', doc: 'Repeats string n times' },
                // Math ops
                { name: 'abs', sig: 'abs n', doc: 'Returns absolute value' },
                { name: 'min', sig: 'min a b', doc: 'Returns smaller of two values' },
                { name: 'max', sig: 'max a b', doc: 'Returns larger of two values' },
                { name: 'pow', sig: 'pow base exp', doc: 'Raises base to power' },
                { name: 'sqrt', sig: 'sqrt n', doc: 'Returns square root' },
                { name: 'floor', sig: 'floor n', doc: 'Rounds down to integer' },
                { name: 'ceil', sig: 'ceil n', doc: 'Rounds up to integer' },
                { name: 'mod', sig: 'mod a b', doc: 'Returns remainder of division' },
                // Conversion
                { name: 'to_string', sig: 'to_string v', doc: 'Converts value to string' },
                { name: 'to_int', sig: 'to_int v', doc: 'Converts value to integer' },
                { name: 'to_float', sig: 'to_float v', doc: 'Converts value to float' },
                { name: 'type_of', sig: 'type_of v', doc: 'Returns type name as string' },
                { name: 'is_int', sig: 'is_int v', doc: 'Returns true if value is int' },
                { name: 'is_float', sig: 'is_float v', doc: 'Returns true if value is float' },
                { name: 'is_string', sig: 'is_string v', doc: 'Returns true if value is string' },
                { name: 'is_bool', sig: 'is_bool v', doc: 'Returns true if value is bool' },
                // I/O
                { name: 'read_line', sig: 'read_line prompt', doc: 'Reads a line from stdin' },
                { name: 'read_file', sig: 'read_file path', doc: 'Reads entire file as string' },
                { name: 'write_file', sig: 'write_file path content', doc: 'Writes string to file' },
                { name: 'append_file', sig: 'append_file path content', doc: 'Appends string to file' },
                { name: 'run', sig: 'run cmd', doc: 'Runs shell command, returns output' },
                { name: 'get_env', sig: 'get_env name', doc: 'Returns environment variable value' },
                { name: 'args_count', sig: 'args_count', doc: 'Returns number of command line arguments' },
                { name: 'args_get', sig: 'args_get i', doc: 'Returns command line argument at index' },
                { name: 'now', sig: 'now', doc: 'Returns milliseconds since program start' },
                { name: 'exit', sig: 'exit code', doc: 'Exits with given code' },
                // Random
                { name: 'random', sig: 'random seed min max', doc: 'Pure random — returns value' },
                { name: 'seed', sig: 'seed', doc: 'Returns next seed for chaining' },
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
                // Constructors
                'Just': { sig: '`Just value`', doc: 'Maybe constructor — wraps a value\n\n```kō\ntype Maybe = Just * | Nothing\nlet x = Just 42\n```' },
                'Nothing': { sig: '`Nothing`', doc: 'Maybe constructor — no value\n\n```kō\ntype Maybe = Just * | Nothing\nlet x = Nothing\n```' },
                'Cons': { sig: '`Cons head tail`', doc: 'List constructor — prepends element\n\n```kō\ntype List = Cons * * | Nil\nlet xs = Cons 1 (Cons 2 (Cons 3 Nil))\n```' },
                'Nil': { sig: '`Nil`', doc: 'List constructor — empty list\n\n```kō\ntype List = Cons * * | Nil\nlet xs = Nil\n```' },
                'Ok': { sig: '`Ok value`', doc: 'Result constructor — success\n\n```kō\ntype Result = Ok * | Err *\nlet r = Ok 42\n```' },
                'Err': { sig: '`Err message`', doc: 'Result constructor — error\n\n```kō\ntype Result = Ok * | Err *\nlet r = Err "failed"\n```' },
                // String operations
                'len': { sig: '`len value`', doc: 'Returns length of string\n\n```kō\nlen "hello" // 5\n```' },
                'concat': { sig: '`concat a b`', doc: 'Concatenates two strings\n\n```kō\nconcat "hello" " world" // "hello world"\n```' },
                'char_at': { sig: '`char_at s i`', doc: 'Returns character at index\n\n```kō\nchar_at "hello" 1 // \'e\'\n```' },
                'substring': { sig: '`substring s start end`', doc: 'Extracts substring\n\n```kō\nsubstring "hello" 0 3 // "hel"\n```' },
                'contains': { sig: '`contains s sub`', doc: 'Checks if string contains substring\n\n```kō\ncontains "hello" "ell" // true\n```' },
                'to_upper': { sig: '`to_upper s`', doc: 'Converts to uppercase' },
                'to_lower': { sig: '`to_lower s`', doc: 'Converts to lowercase' },
                'trim': { sig: '`trim s`', doc: 'Removes leading/trailing whitespace' },
                'starts_with': { sig: '`starts_with s prefix`', doc: 'Checks if string starts with prefix' },
                'ends_with': { sig: '`ends_with s suffix`', doc: 'Checks if string ends with suffix' },
                'repeat': { sig: '`repeat s n`', doc: 'Repeats string n times\n\n```kō\nrepeat "ha" 3 // "hahaha"\n```' },
                // Math operations
                'abs': { sig: '`abs n`', doc: 'Returns absolute value' },
                'min': { sig: '`min a b`', doc: 'Returns smaller of two values' },
                'max': { sig: '`max a b`', doc: 'Returns larger of two values' },
                'pow': { sig: '`pow base exp`', doc: 'Raises base to power\n\n```kō\npow 2 10 // 1024\n```' },
                'sqrt': { sig: '`sqrt n`', doc: 'Returns square root' },
                'floor': { sig: '`floor n`', doc: 'Rounds down to integer' },
                'ceil': { sig: '`ceil n`', doc: 'Rounds up to integer' },
                'mod': { sig: '`mod a b`', doc: 'Returns remainder of division' },
                // Conversion
                'to_string': { sig: '`to_string v`', doc: 'Converts value to string' },
                'to_int': { sig: '`to_int v`', doc: 'Converts value to integer' },
                'to_float': { sig: '`to_float v`', doc: 'Converts value to float' },
                'type_of': { sig: '`type_of v`', doc: 'Returns type name as string\n\n```kō\ntype_of 42 // "int"\n```' },
                'is_int': { sig: '`is_int v`', doc: 'Returns true if value is int' },
                'is_float': { sig: '`is_float v`', doc: 'Returns true if value is float' },
                'is_string': { sig: '`is_string v`', doc: 'Returns true if value is string' },
                'is_bool': { sig: '`is_bool v`', doc: 'Returns true if value is bool' },
                // I/O
                'read_line': { sig: '`read_line prompt`', doc: 'Reads a line from stdin\n\n```kō\nlet name = read_line "name: "\n```' },
                'read_file': { sig: '`read_file path`', doc: 'Reads entire file as string' },
                'write_file': { sig: '`write_file path content`', doc: 'Writes string to file, returns true on success' },
                'append_file': { sig: '`append_file path content`', doc: 'Appends string to file' },
                'run': { sig: '`run cmd`', doc: 'Runs shell command, returns output\n\n```kō\nlet out = run "ls -la"\n```' },
                'get_env': { sig: '`get_env name`', doc: 'Returns environment variable value' },
                'args_count': { sig: '`args_count`', doc: 'Returns number of command line arguments' },
                'args_get': { sig: '`args_get i`', doc: 'Returns command line argument at index' },
                'now': { sig: '`now`', doc: 'Returns milliseconds since program start' },
                'exit': { sig: '`exit code`', doc: 'Exits with given code' },
                // Random
                'random': { sig: '`random seed min max`', doc: 'Pure random — returns value, use seed for next' },
                'seed': { sig: '`seed`', doc: 'Returns next seed for chaining random calls' },
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
