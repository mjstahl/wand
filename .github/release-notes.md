## 0.46.0 - 2026-08-24

A field may say what it holds when a construction leaves it out.

    type Conf(host : String, port : Port = :8080, retries : Int = 3)

    Conf(host = "example.com")   -- port :8080, retries 3

A default is a value written out: a literal, or a constructor applied to
literals. It reads with nothing in scope, so it says the same thing at every
site that omits the field, performs no effect for a construction to declare,
and prints back as written. A field with no default is still required.

A derived decoder reads them too, which is the wider half. A field the
document does not carry takes its default rather than failing, and a field it
does carry wins.

That is what made the second half possible. `Args` turns argv into a document
and a decoder reads it, so the flags are the fields -- but the line that tells
somebody what those flags are was a string written beside the type, free to
drift from it, which is half of what makes the shell version bad.

    type Flags(port : Port = :8080, timeout : Duration = 30s,
               verbose : Bool = false)

    Flags.usage   -- "[--port :8080] [--timeout 30s] [--verbose]"

`examples/ports/probe-args.wand` was the port that carried that string and
said so. Its flags are their own record now, so its decoder is derived as
well. What is left by hand is the positional host, which `Args` puts under
`_` with nothing in the type marking the field that reads it.

`Option` is a built-in type. Its name and its constructors need no import,
the way `Result` and `List` need none -- `Env.get` answers with one,
`Decode.optional` builds one, a derived decoder reads an absent field as one,
and both serialisers know what `Some` and `None` mean, yet
`type Opts(tag : Option String)` said "unknown type 'Option'". The module
keeps its functions. If you declare your own `type Option`, that is now an
error, as it already was for any other built-in name.

Two smaller things you may feel. A `Bool` field a document does not carry now
reads as `false`, so a `Bool` flag no longer needs a default to be usable at
all. And a constructor that declares one field name twice is refused, where
it used to be taken silently with the first winning.

`wand t --fix` inserts a missing import. The error already named the module;
now the line it is missing travels with it.
