const vscode = require('vscode');
const path = require('path');
const fs = require('fs');
const { LanguageClient, TransportKind } = require('vscode-languageclient/node');

let client;

function activate(context) {
    console.log('Kō language support is now active!');

    // ===== Start LSP Server =====
    const serverModule = findLsp();
    const serverOptions = {
        command: 'python3',
        args: [serverModule],
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

function findLsp() {
    // 1) env var override
    if (process.env.KO_LSP_PATH && fs.existsSync(process.env.KO_LSP_PATH)) {
        return process.env.KO_LSP_PATH;
    }
    // 2) relative to extension dir (bundled VSIX: lsp.py shipped alongside)
    let p = path.join(__dirname, 'lsp.py');
    if (fs.existsSync(p)) return p;
    // 3) walk up from __dirname looking for lsp.py (works for dev installs)
    p = __dirname;
    for (let i = 0; i < 6; i++) {
        const candidate = path.join(p, 'lsp.py');
        if (fs.existsSync(candidate)) return candidate;
        const parent = path.dirname(p);
        if (parent === p) break;
        p = parent;
    }
    // 4) relative to workspace root
    if (vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders.length > 0) {
        p = path.join(vscode.workspace.workspaceFolders[0].uri.fsPath, 'lsp.py');
        if (fs.existsSync(p)) return p;
    }
    throw new Error('Could not find lsp.py — set KO_LSP_PATH or open the ko-language workspace');
}

function deactivate() {
    if (client) {
        return client.stop();
    }
}

module.exports = { activate, deactivate };
