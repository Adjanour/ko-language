const vscode = require('vscode');
const path = require('path');
const { LanguageClient, TransportKind } = require('vscode-languageclient/node');

let client;

function activate(context) {
    console.log('Kō language support is now active!');

    // Path to ko-lsp binary — look in PATH first, then fallback to dev layout
    const { execSync } = require('child_process');
    let lspPath;
    try {
        lspPath = execSync('which ko-lsp', { encoding: 'utf-8' }).trim();
    } catch {
        lspPath = path.join(
            path.dirname(__dirname),
            'ko-zig', 'zig-out', 'bin', 'ko-lsp'
        );
    }

    // Server options — run ko-lsp as a subprocess
    const serverOptions = {
        run: {
            command: lspPath,
            transport: TransportKind.stdio,
        },
        debug: {
            command: lspPath,
            transport: TransportKind.stdio,
        },
    };

    // Client options
    const clientOptions = {
        documentSelector: [{ scheme: 'file', language: 'ko' }],
        synchronize: {
            fileEvents: vscode.workspace.createFileSystemWatcher('**/*.ko'),
        },
    };

    // Create and start the language client
    client = new LanguageClient(
        'koLanguage',
        'Kō Language Server',
        serverOptions,
        clientOptions
    );

    client.start().catch(err => {
        console.error('Failed to start Kō language server:', err);
    });
}

function deactivate() {
    if (client) {
        return client.stop();
    }
    return undefined;
}

module.exports = { activate, deactivate };
