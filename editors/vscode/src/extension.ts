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
  LanguageClient, LanguageClientOptions,
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

const autoEdit = () =>
  workspace.getConfiguration('wand').get<boolean>('autoEdit', true);

// The server is the compiler, so a client that cannot spawn it has nothing
// to offer and the reason is almost always one of two things: no wand on
// PATH, or a `wand.path` pointing somewhere it is not. Said here, because
// the alternative is VS Code reporting that an extension failed to activate.
const start = async (): Promise<void> => {
  try {
    await client!.start();
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    const open = 'Open settings';
    const chosen = await window.showErrorMessage(
      `wand: cannot start the language server at '${wandPath()}' (${message}). `
      + 'Install wand, or set `wand.path` to the binary.', open);
    if (chosen === open) {
      await commands.executeCommand(
        'workbench.action.openSettings', 'wand.path');
    }
  }
};

export async function activate(context: ExtensionContext) {
  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ language: 'wand' }],
    // The server pushes an import and its manifest labels on a change that
    // completes a resolvable name -- the one thing it does to a buffer
    // without being asked, so it is a setting. Sent at startup, and again
    // whenever it changes, because the server holds it rather than asking.
    initializationOptions: { autoEdit: autoEdit() },
  };
  const build = () => new LanguageClient('wand', 'wand',
    { command: wandPath(), args: ['lsp'] }, clientOptions);
  client = build();

  context.subscriptions.push(
    workspace.onDidChangeConfiguration(async (e) => {
      if (e.affectsConfiguration('wand.autoEdit')) {
        client?.sendNotification('workspace/didChangeConfiguration',
          { settings: { wand: { autoEdit: autoEdit() } } });
      }
      // The path is read once, when the client is built, so a new one means
      // a new server. Without this the setting appeared to do nothing until
      // the window was reloaded -- and a reader who has just corrected the
      // path is the one person most in need of it taking effect.
      if (e.affectsConfiguration('wand.path')) {
        await client?.stop().catch(() => undefined);
        client = build();
        await start();
      }
    }));

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

  // The file name is an argument, never text a shell reads. It used to be
  // typed into a terminal with `JSON.stringify` around it, and a file named
  // `x$(cmd).wand` ran `cmd` the moment the lens was clicked: double quotes
  // do not stop a shell reading `$(...)`.
  //
  // The terminal spawns its process from an argv, so nothing here is parsed
  // as a command line. On a POSIX machine that process is `sh` running a
  // fixed script with the two paths after it -- `$0` and `$1` are positional
  // parameters, which a shell never reads back as source, so the script is a
  // constant with nothing to escape. The shell is there for the redirect
  // alone: stdin from /dev/null means a script that reads stdin
  // (`IO.stdin_lines`) rehearses against empty input instead of blocking on
  // the terminal. Windows has no /bin/sh and no /dev/null, so it spawns wand
  // itself and does without the redirect.
  const REHEARSE = 'wand rehearse';
  context.subscriptions.push(
    commands.registerCommand('wand.rehearse', (uri?: Uri) => {
      const file = uri?.fsPath ?? window.activeTextEditor?.document.uri.fsPath;
      if (!file) { return; }
      // A terminal that runs one command exits with it, so the last one is
      // replaced rather than reused.
      window.terminals.filter((t) => t.name === REHEARSE)
        .forEach((t) => t.dispose());
      const term = window.createTerminal(
        process.platform === 'win32'
          ? { name: REHEARSE, shellPath: wandPath(),
              shellArgs: ['--dry-run', file] }
          : { name: REHEARSE, shellPath: '/bin/sh',
              shellArgs: ['-c', 'exec "$0" --dry-run "$1" < /dev/null',
                          wandPath(), file] });
      term.show(true);
    }));

  await start();
}

export function deactivate(): Thenable<void> | undefined {
  // A client that never started has nothing to stop, and a window closing
  // is not the place to raise about it.
  return client?.stop().catch(() => undefined);
}
