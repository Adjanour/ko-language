const vscode = require('vscode');
const path = require('path');
const { LanguageClient, TransportKind } = require('vscode-languageclient/node');

let client;

function activate(context) {
    console.log('Kō language support is now active!');

    // ===== Start LSP Server =====
    const serverModule = '/home/bernard/Learning/weird/lsp.py';
    const serverOptions = {
        command: 'python3',
        args: [serverModule],
        options: { cwd: path.join(context.extensionPath, '..', '..') },
        transport: TransportKind.stdio,
    };

    const clientOptions = {
        documentSelector: [{ scheme: 'file', language: 'ko' }],
    };

    client = new LanguageClient('ko', 'Kō Language Server', serverOptions, clientOptions);
    client.start();

    // ===== Folding Provider (not in LSP, kept local) =====
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

    context.subscriptions.push(foldingProvider);
}

function deactivate() {
    if (client) {
        return client.stop();
    }
}

module.exports = { activate, deactivate };
