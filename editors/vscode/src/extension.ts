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
import { existsSync } from 'fs';
import { homedir } from 'os';
import { delimiter, join } from 'path';

let client: LanguageClient | undefined;

// A GUI-launched VS Code does not carry the shell's PATH, so the bare
// default `wand` can be unspawnable even when the terminal finds it. When
// the setting is that default and PATH has no wand, fall back to the
// places installs land: install.sh's ~/.local/bin, then Homebrew's.
const wandPath = () => {
  const configured =
    workspace.getConfiguration('wand').get<string>('path', 'wand');
  if (configured !== 'wand') { return configured; }
  const onPath = (process.env.PATH ?? '').split(delimiter)
    .some((dir) => dir !== '' && existsSync(join(dir, 'wand')));
  if (onPath) { return configured; }
  for (const candidate of [
    join(homedir(), '.local', 'bin', 'wand'),
    '/usr/local/bin/wand',
    '/opt/homebrew/bin/wand',
  ]) {
    if (existsSync(candidate)) { return candidate; }
  }
  return configured;
};

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

  // The "Rehearse" lens sits on the manifest line when the file has one
  // (it is the first statement, so only the opening lines are scanned),
  // and on the first line otherwise -- every file can be rehearsed.
  context.subscriptions.push(
    languages.registerCodeLensProvider({ language: 'wand' }, {
      provideCodeLenses(doc: TextDocument): CodeLens[] {
        let anchor = 0;
        for (let line = 0; line < Math.min(doc.lineCount, 10); line++) {
          if (/^\s*uses\s*\{/.test(doc.lineAt(line).text)) {
            anchor = line;
            break;
          }
        }
        const text = doc.lineAt(anchor).text;
        return [new CodeLens(new Range(anchor, 0, anchor, text.length), {
          title: 'Rehearse (dry run)',
          command: 'wand.rehearse',
          arguments: [doc.uri],
        })];
      },
    }));

  context.subscriptions.push(
    commands.registerCommand('wand.rehearse', (uri?: Uri) => {
      const file = uri?.fsPath ?? window.activeTextEditor?.document.uri.fsPath;
      if (!file) { return; }
      const term = window.terminals.find((t) => t.name === 'wand rehearse')
        ?? window.createTerminal('wand rehearse');
      term.show(true);
      // stdin comes from /dev/null: a script that reads stdin (IO.stdin_lines)
      // rehearses against empty input instead of blocking on the terminal.
      term.sendText(`${wandPath()} --dry-run ${JSON.stringify(file)} < /dev/null`);
    }));

  await client.start();
}

export function deactivate(): Thenable<void> | undefined {
  return client?.stop();
}
