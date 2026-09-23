const vscode = require('vscode');
const path = require('path');
const fs = require('fs');
const { execSync } = require('child_process');
const { LanguageClient, TransportKind } = require('vscode-languageclient/node');

let client;
let outputChannel;

/** Resolve the ko-lsp binary: explicit setting first, then $PATH, then build tree. */
function resolveLspPath() {
    const configured = vscode.workspace.getConfiguration('ko').get('languageServer.path', '');
    if (configured && configured.trim() !== '') {
        return configured.trim();
    }
    try {
        const found = execSync('which ko-lsp', { encoding: 'utf-8' }).trim();
        if (found) return found;
    } catch {
        // fall through to dev-layout probe below
    }
    // Dev layout: <repo>/vscode-ko/ → <repo>/ko-zig/zig-out/bin/ko-lsp
    const devLsp = path.join(path.dirname(__dirname), 'ko-zig', 'zig-out', 'bin', 'ko-lsp');
    if (fs.existsSync(devLsp)) {
        return devLsp;
    }
    return 'ko-lsp';
}

function startClient(context) {
    const config = vscode.workspace.getConfiguration('ko');
    const lspPath = resolveLspPath();
    const lspArgs = config.get('languageServer.args', []);

    const serverOptions = {
        run: { command: lspPath, args: lspArgs, transport: TransportKind.stdio },
        debug: { command: lspPath, args: lspArgs, transport: TransportKind.stdio },
    };
    const clientOptions = {
        documentSelector: [{ scheme: 'file', language: 'ko' }],
        synchronize: {
            fileEvents: vscode.workspace.createFileSystemWatcher('**/*.ko'),
        },
        outputChannel,
    };

    client = new LanguageClient('koLanguage', 'Kō Language Server', serverOptions, clientOptions);
    client.start().then(
        () => outputChannel.appendLine(`Kō language server started: ${lspPath}`),
        (err) => {
            outputChannel.appendLine(`Failed to start Kō language server (${lspPath}): ${err && err.message ? err.message : err}`);
            vscode.window
                .showErrorMessage(
                    `Kō language server failed to start. Set "ko.languageServer.path" to your ko-lsp binary.`,
                    'Open Settings',
                    'Show Output'
                )
                .then((choice) => {
                    if (choice === 'Open Settings') {
                        vscode.commands.executeCommand('workbench.action.openSettings', 'ko.languageServer.path');
                    } else if (choice === 'Show Output') {
                        outputChannel.show();
                    }
                });
        }
    );
    context.subscriptions.push(client);
}

async function restartLanguageServer(context) {
    if (client) {
        await client.stop().then(
            () => {},
            () => {}
        );
        client = undefined;
    }
    startClient(context);
}

function runKoFile() {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.languageId !== 'ko') {
        vscode.window.showWarningMessage('Kō: open a .ko file first, then run it.');
        return;
    }
    const config = vscode.workspace.getConfiguration('ko');
    const koBin = config.get('compiler.path', 'ko') || 'ko';
    const filePath = editor.document.fileName;
    if (editor.document.isDirty) {
        editor.document.save();
    }
    let terminal = vscode.window.terminals.find((t) => t.name === 'Kō');
    if (!terminal || terminal.exitStatus !== undefined) {
        terminal = vscode.window.createTerminal('Kō');
    }
    terminal.show();
    // Quote the path; the shell handles the rest.
    terminal.sendText(`${koBin} "${filePath}"`, true);
}

function activate(context) {
    outputChannel = vscode.window.createOutputChannel('Kō Language Server');
    context.subscriptions.push(outputChannel);

    startClient(context);

    context.subscriptions.push(
        vscode.commands.registerCommand('ko.restartLanguageServer', () => restartLanguageServer(context)),
        vscode.commands.registerCommand('ko.runKoFile', runKoFile),
        vscode.workspace.onDidChangeConfiguration((e) => {
            if (e.affectsConfiguration('ko.languageServer')) {
                restartLanguageServer(context);
            }
        })
    );
}

function deactivate() {
    if (client) {
        return client.stop();
    }
    return undefined;
}

module.exports = { activate, deactivate };
