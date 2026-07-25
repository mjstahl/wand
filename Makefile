.PHONY: build test repl run fmt clean install

build:
	dune build

test:
	dune test

repl: build
	dune exec wand -- i

run: build
	dune exec wand

fmt:
	dune fmt

clean:
	dune clean

install:
	dune build @install
