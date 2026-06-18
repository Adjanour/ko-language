const vscode = require('vscode');

function activate(context) {
    console.log('Kō language support is now active!');

    // Register completion provider
    const completionProvider = vscode.languages.registerCompletionItemProvider('ko', {
        provideCompletionItems(document, position, token, context) {
            const items = [];

            // Keywords
            const keywords = ['fn', 'let', 'if', 'then', 'else', 'match', 'type', 'in', 'true', 'false'];
            keywords.forEach(keyword => {
                const item = new vscode.CompletionItem(keyword, vscode.CompletionItemKind.Keyword);
                items.push(item);
            });

            // Built-in functions
            const builtins = ['print', 'println', 'inspect', 'panic'];
            builtins.forEach(builtin => {
                const item = new vscode.CompletionItem(builtin, vscode.CompletionItemKind.Function);
                item.detail = 'Built-in function';
                items.push(item);
            });

            return items;
        }
    });

    // Register hover provider
    const hoverProvider = vscode.languages.registerHoverProvider('ko', {
        provideHover(document, position, token) {
            const word = document.getWordRangeAtPosition(position);
            if (!word) return null;

            const text = document.getText(word);

            // Provide hover info for keywords
            const keywordDocs = {
                'fn': 'Defines a function: `fn name param1 param2 = body`',
                'let': 'Bind a value: `let x = expr`',
                'if': 'Conditional: `if cond then expr else expr`',
                'match': 'Pattern matching: `match expr pattern -> body`',
                'type': 'Define algebraic data type: `type Name = Constructor * | ...`',
            };

            if (keywordDocs[text]) {
                return new vscode.Hover(keywordDocs[text]);
            }

            return null;
        }
    });

    context.subscriptions.push(completionProvider, hoverProvider);
}

function deactivate() {}

module.exports = { activate, deactivate };
