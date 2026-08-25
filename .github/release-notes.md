## 0.47.0 - 2026-08-24

A command line is flags and arguments. The flags are a record -- each has a
name and a type -- and what is written without a flag in front of it has no
name at all. So a type with one field whose type is a record, and one that is
not, describes the whole thing:

    type Flags(port : Port = :8080, timeout : Duration = 30s,
               verbose : Bool = false)

    type Opts(flags : Flags, host : String)

    Args.read Opts.spec Opts.reader (Env.args ())

    Opts.usage   -- "[--port :8080] [--timeout 30s] [--verbose] <host>"

Which field is which comes from the types rather than the names, so both are
yours to call anything. The nesting is what tells a repeatable flag from the
arguments: inside the record a `List` field collects, and outside it a `List`
field is what was written bare.

The argument field's type says how many there may be -- `String` exactly one,
`Option` one or none, `List` any number -- and each is read as its own type,
so a `Port` argument refuses `nope` where it stands. The refusals name the
field: `.host: expected one host, got 2`.

Two facts a command line cannot carry now come from the type instead of a
list written beside it. A `Bool` field is a switch, taking no value. A `List`
field collects, so `--tag a --tag b` is two tags where `--name a --name b` is
one name written twice, and a flag that collects holds a list however many
times it was written, including none.

`--` ends the flags. What follows is positional whatever it looks like, which
is the only way to pass an argument beginning with two dashes -- and which
`Args.parse raw ["--", "-x", "y"]` used to answer `Ok(["y"])`, having read
`--` as a flag with no name that ate the next argument. Note that
`wand script.wand -- ...` already spends one `--` handing the rest to the
script, so a script's own separator is the second one.

`--help` is not a flag a type declares. It is a question about the command
line rather than a value in it, and the answer is a usage line rather than a
record, so `Args.help?` answers it before the arguments are read. Printing
and exiting stay in the script, where the effects are declared.

`examples/ports/probe-args.wand` is 57 lines from 74. Its decoder, its usage
line, and its account of the flags all come from one declaration now.

Also: `V-IMP2` reports an import that binds nothing the file mentions, and
`wand t --fix` deletes the line. It found fourteen dead imports in this
repository, six of them `import Option` lines that died when `Option` became
built in last release.
