.PHONY: package install clean

SHELL := /bin/bash

VERSION := $(shell node -p "require('./package.json').version")
VSIX     = wand-$(VERSION).vsix

# `code` when it is on PATH; otherwise the copy inside the macOS app bundle,
# for machines where "Shell Command: Install 'code' command" was never run.
CODE   := $(or $(shell command -v code), \
               /Applications/Visual\ Studio\ Code.app/Contents/Resources/app/bin/code)

package:
	npm install --no-audit --no-fund
	npm run compile
	npm run package

# The grep drops deprecation warnings that are VS Code's own (its CLI runs
# under Electron-as-Node and ignores NODE_OPTIONS), not anything the
# extension can fix. pipefail keeps a real install failure fatal, and it
# lives in the recipe because Apple's make (3.81) predates .SHELLFLAGS.
install: package
	@set -o pipefail; $(CODE) --install-extension $(VSIX) 2>&1 \
	  | grep -v -e DeprecationWarning -e trace-deprecation

clean:
	rm -rf node_modules out wand-*.vsix
