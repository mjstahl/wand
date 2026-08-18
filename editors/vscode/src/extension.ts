// The wand client: ~60 lines over vscode-languageclient. The server is
// `wand lsp` on the compiler binary itself, so the extension carries no
// language knowledge of its own -- it spawns the binary, registers the
// stdlib virtual documents definition jumps land in, and puts the
// language's headline feature (`wand --dry-run`) one click from every
// manifest line.

import {
  CodeLens, ExtensionContext, Range, TextDocument, Uri,
  commands, languages, window, workspace,
} from 'vscode';
import {
  LanguageClient, LanguageClientOptions, ServerOptions,
} from 'vscode-languageclient/node';

let client: LanguageClient | undefined;

const wandPath = () =>
  workspace.getConfiguration('wand').get<string>('path', 'wand');

export async function activate(context: ExtensionContext) {
  const serverOptions: ServerOptions = { command: wandPath(), args: ['lsp'] };
  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ language: 'wand' }],
  };
  client = new LanguageClient('wand', 'wand', serverOptions, clientOptions);

  // Standard library sources live inside the binary, not on disk; a
  // definition jump into one answers a wand-stdlib:/ URI, and this
  // provider fills it by asking the server for the embedded text.
  context.subscriptions.push(
    workspace.registerTextDocumentContentProvider('wand-stdlib', {
      async provideTextDocumentContent(uri: Uri): Promise<string> {
        const src = await client!.sendRequest<string | null>(
          'wand/stdlibSource', { uri: uri.toString() });
        return src ?? '';
      },
    }));

  // The "Rehearse" lens on the manifest line. The manifest is the first
  // statement of a file, so only the opening lines are scanned.
  context.subscriptions.push(
    languages.registerCodeLensProvider({ language: 'wand' }, {
      provideCodeLenses(doc: TextDocument): CodeLens[] {
        for (let line = 0; line < Math.min(doc.lineCount, 10); line++) {
          const text = doc.lineAt(line).text;
          if (/^\s*uses\s*\{/.test(text)) {
            return [new CodeLens(new Range(line, 0, line, text.length), {
              title: 'Rehearse (dry run)',
              command: 'wand.rehearse',
              arguments: [doc.uri],
            })];
          }
        }
        return [];
      },
    }));

  context.subscriptions.push(
    commands.registerCommand('wand.rehearse', (uri?: Uri) => {
      const file = uri?.fsPath ?? window.activeTextEditor?.document.uri.fsPath;
      if (!file) { return; }
      const term = window.terminals.find((t) => t.name === 'wand rehearse')
        ?? window.createTerminal('wand rehearse');
      term.show(true);
      term.sendText(`${wandPath()} --dry-run ${JSON.stringify(file)}`);
    }));

  await client.start();
}

export function deactivate(): Thenable<void> | undefined {
  return client?.stop();
}
