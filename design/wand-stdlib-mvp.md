# Wand: Standard Library MVP Reference

Proposed module list and function signatures for the MVP. Conventions:

- Module names capitalized.
- Function names lowercase, snake_case where multi-word.
- Predicate functions end with `?` (e.g. `is_empty?`).
- Effect rows shown where present; pure functions show no row.
- `Path` is a token type (lexical literals like `/tmp/foo`). `FS` is the operations module that touches the actual filesystem.

---

## Path

Pure operations on path values. Nothing touches the filesystem.

```
Path.join          : Path -> Path -> Path             (* also written as `/` operator *)
Path.parent        : Path -> Option Path
Path.basename      : Path -> String
Path.dirname       : Path -> Path
Path.extension     : Path -> Option String
Path.with_extension : Path -> String -> Path
Path.is_absolute?  : Path -> Bool
Path.is_relative?  : Path -> Bool
Path.normalize     : Path -> Path                     (* resolves "." and ".." segments *)
Path.to_string     : Path -> String
Path.components    : Path -> List String              (* split into segments *)
```

## FS

Filesystem operations. All effectful.

```
FS.read_file       : Path -> <io, exn> String
FS.read_bytes      : Path -> <io, exn> Bytes
FS.write_file      : Path -> String -> <io, exn> ()
FS.write_bytes     : Path -> Bytes -> <io, exn> ()
FS.append          : Path -> String -> <io, exn> ()
FS.create_file     : Path -> <io, exn> ()             (* creates empty file *)
FS.mkdir           : Path -> <io, exn> ()
FS.mkdir_p         : Path -> <io, exn> ()             (* creates parents *)
FS.delete          : Path -> <io, exn> ()
FS.delete_dir      : Path -> <io, exn> ()             (* recursive *)
FS.rename          : Path -> Path -> <io, exn> ()
FS.copy            : Path -> Path -> <io, exn> ()
FS.exists?         : Path -> <io> Bool
FS.is_file?        : Path -> <io> Bool
FS.is_dir?         : Path -> <io> Bool
FS.list_dir        : Path -> <io, exn> List Path
FS.walk            : Path -> <io, exn> List Path      (* recursive *)
FS.mtime           : Path -> <io, exn> DateTime
FS.size            : Path -> <io, exn> Size
FS.cwd             : () -> <io> Path
FS.cd              : Path -> <io, exn> ()
FS.with_temp_file  : (Path -> <e> a) -> <io, e> a     (* auto-cleanup *)
FS.with_temp_dir   : (Path -> <e> a) -> <io, e> a     (* auto-cleanup *)
```

## Process

External program invocation.

```
Process.run        : String -> List String -> <process, exn> ProcessResult
Process.run_quiet  : String -> List String -> <process, exn> Int     (* just exit code *)
Process.shell      : String -> <process, exn> String                 (* runs through shell, returns stdout *)
Process.spawn      : String -> List String -> <process> ProcessHandle (* for backgrounded work *)
Process.wait       : ProcessHandle -> <process> ProcessResult
Process.pid        : () -> <process> Int                             (* current process *)
```

Where `ProcessResult` is:

```
type ProcessResult = {
  exit   : Int,
  stdout : String,
  stderr : String,
}
```

## Env

Environment variables and process environment.

```
Env.get            : String -> <env> Option String
Env.get!           : String -> <env, exn> String      (* raises if missing *)
Env.set            : String -> String -> <env> ()
Env.unset          : String -> <env> ()
Env.all            : () -> <env> Map String String
Env.args           : () -> <env> List String          (* command-line args *)
Env.home           : () -> <env> Path
Env.user           : () -> <env> String
```

## IO

Standard input/output.

```
IO.print           : String -> <io> ()                (* stdout, no newline *)
IO.println         : String -> <io> ()                (* stdout, with newline *)
IO.print_err       : String -> <io> ()                (* stderr, no newline *)
IO.println_err     : String -> <io> ()                (* stderr, with newline *)
IO.read_line       : () -> <io, exn> String
IO.read_all        : () -> <io, exn> String           (* read stdin to EOF *)
IO.eof?            : () -> <io> Bool
IO.flush           : () -> <io> ()
```

Top-level shortcuts (auto-imported, no module prefix needed):

```
print              : String -> <io> ()                (* alias for IO.println *)
print_err          : String -> <io> ()                (* alias for IO.println_err *)
read_line          : () -> <io, exn> String
args               : () -> <env> List String          (* alias for Env.args *)
exit               : Int -> <exit> a
```

## String

```
String.length      : String -> Int
String.is_empty?   : String -> Bool
String.upper       : String -> String
String.lower       : String -> String
String.trim        : String -> String
String.trim_left   : String -> String
String.trim_right  : String -> String
String.split       : String -> String -> List String  (* delim, input *)
String.join        : String -> List String -> String  (* delim, parts *)
String.lines       : String -> List String
String.contains?   : String -> String -> Bool         (* substring, input *)
String.starts_with? : String -> String -> Bool        (* prefix, input *)
String.ends_with?  : String -> String -> Bool         (* suffix, input *)
String.replace     : String -> String -> String -> String  (* from, to, input *)
String.repeat      : Int -> String -> String
String.reverse     : String -> String
String.chars       : String -> List Char
String.from_chars  : List Char -> String
String.to_int      : String -> Option Int
String.to_float    : String -> Option Float
```

## List

```
List.length        : List a -> Int
List.is_empty?     : List a -> Bool
List.head          : List a -> Option a
List.tail          : List a -> Option (List a)
List.last          : List a -> Option a
List.nth           : Int -> List a -> Option a
List.map           : (a -> b) -> List a -> List b
List.filter        : (a -> Bool) -> List a -> List a
List.filter_map    : (a -> Option b) -> List a -> List b
List.fold          : (b -> a -> b) -> b -> List a -> b
List.reduce        : (a -> a -> a) -> List a -> Option a
List.take          : Int -> List a -> List a
List.drop          : Int -> List a -> List a
List.reverse       : List a -> List a
List.sort          : List a -> List a                 (* requires Ord a *)
List.sort_by       : (a -> a -> Ordering) -> List a -> List a
List.sort_with     : (a -> b) -> List a -> List a     (* requires Ord b *)
List.unique        : List a -> List a                 (* requires Eq a *)
List.group_by      : (a -> b) -> List a -> Map b (List a)
List.flatten       : List (List a) -> List a
List.concat        : List a -> List a -> List a
List.zip           : List a -> List b -> List (a, b)
List.unzip         : List (a, b) -> (List a, List b)
List.contains?     : a -> List a -> Bool              (* requires Eq a *)
List.any?          : (a -> Bool) -> List a -> Bool
List.all?          : (a -> Bool) -> List a -> Bool
List.find          : (a -> Bool) -> List a -> Option a
List.count         : (a -> Bool) -> List a -> Int
List.range         : Int -> Int -> List Int
List.iter          : (a -> <e> ()) -> List a -> <e> ()
```

## Map

Key-value collections. Keys must implement `Ord`.

```
Map.empty          : Map k v
Map.from_list      : List (k, v) -> Map k v
Map.to_list        : Map k v -> List (k, v)
Map.get            : k -> Map k v -> Option v
Map.get!           : k -> Map k v -> v                (* raises if missing *)
Map.set            : k -> v -> Map k v -> Map k v
Map.delete         : k -> Map k v -> Map k v
Map.contains?      : k -> Map k v -> Bool
Map.size           : Map k v -> Int
Map.is_empty?      : Map k v -> Bool
Map.keys           : Map k v -> List k
Map.values         : Map k v -> List v
Map.map            : (v -> w) -> Map k v -> Map k w
Map.filter         : (k -> v -> Bool) -> Map k v -> Map k v
Map.merge          : Map k v -> Map k v -> Map k v    (* right wins on conflict *)
Map.iter           : (k -> v -> <e> ()) -> Map k v -> <e> ()
```

## Option

```
Option.is_some?    : Option a -> Bool
Option.is_none?    : Option a -> Bool
Option.map         : (a -> b) -> Option a -> Option b
Option.and_then    : (a -> Option b) -> Option a -> Option b
Option.or_else     : (() -> Option a) -> Option a -> Option a
Option.default     : a -> Option a -> a
Option.get!        : Option a -> a                    (* raises if None *)
Option.to_result   : e -> Option a -> Result e a
```

## Result

```
Result.is_ok?      : Result e a -> Bool
Result.is_err?     : Result e a -> Bool
Result.map         : (a -> b) -> Result e a -> Result e b
Result.map_error   : (e -> f) -> Result e a -> Result f a
Result.and_then    : (a -> Result e b) -> Result e a -> Result e b
Result.or_else     : (e -> Result f a) -> Result e a -> Result f a
Result.default     : a -> Result e a -> a
Result.get!        : Result e a -> a                  (* raises if Err *)
Result.to_option   : Result e a -> Option a
```

## JSON

```
type JSON =
  | JNull
  | JBool Bool
  | JNumber Float
  | JString String
  | JArray (List JSON)
  | JObject (Map String JSON)

JSON.parse         : String -> Result String JSON
JSON.encode        : JSON -> String
JSON.encode_pretty : JSON -> String
JSON.read_file     : Path -> <io, exn> JSON
JSON.write_file    : Path -> JSON -> <io, exn> ()

(* Accessor helpers *)
JSON.get_field     : String -> JSON -> Option JSON
JSON.as_string     : JSON -> Option String
JSON.as_int        : JSON -> Option Int
JSON.as_float      : JSON -> Option Float
JSON.as_bool       : JSON -> Option Bool
JSON.as_array      : JSON -> Option (List JSON)
JSON.as_object     : JSON -> Option (Map String JSON)
```

## CSV

```
type CSVOptions = {
  delimiter : Char,           (* default ',' *)
  has_header : Bool,          (* default true *)
}

CSV.parse          : String -> Result String (List (List String))
CSV.parse_with     : CSVOptions -> String -> Result String (List (List String))
CSV.encode         : List (List String) -> String
CSV.read_file      : Path -> <io, exn> List (List String)
CSV.write_file     : Path -> List (List String) -> <io, exn> ()
```

## Regex

The `Regex` value type itself is a token (literals like `/pattern/`). This module provides operations.

```
Regex.match        : Regex -> String -> Option (List String)   (* full match + captures *)
Regex.match_all    : Regex -> String -> List (List String)     (* all matches *)
Regex.replace      : Regex -> String -> String -> String       (* pattern, replacement, input *)
Regex.replace_all  : Regex -> String -> String -> String
Regex.split        : Regex -> String -> List String
Regex.matches?     : Regex -> String -> Bool
```

## Date

Operations on the `Date` token.

```
Date.today         : () -> <io> Date
Date.year          : Date -> Int
Date.month         : Date -> Int
Date.day           : Date -> Int
Date.day_of_week   : Date -> Int                      (* 0 = Sunday *)
Date.add_days      : Int -> Date -> Date
Date.diff_days     : Date -> Date -> Int
Date.is_before?    : Date -> Date -> Bool
Date.is_after?     : Date -> Date -> Bool
Date.format        : String -> Date -> String         (* strftime-style *)
Date.parse         : String -> Result String Date
```

## Time

```
Time.now           : () -> <io> Time
Time.hour          : Time -> Int
Time.minute        : Time -> Int
Time.second        : Time -> Int
Time.format        : String -> Time -> String
Time.parse         : String -> Result String Time
```

## DateTime

```
DateTime.now       : () -> <io> DateTime
DateTime.utc_now   : () -> <io> DateTime
DateTime.date      : DateTime -> Date
DateTime.time      : DateTime -> Time
DateTime.add       : Duration -> DateTime -> DateTime
DateTime.diff      : DateTime -> DateTime -> Duration
DateTime.is_before? : DateTime -> DateTime -> Bool
DateTime.is_after? : DateTime -> DateTime -> Bool
DateTime.format    : String -> DateTime -> String
DateTime.parse     : String -> Result String DateTime
```

## Duration

```
Duration.zero      : Duration
Duration.seconds   : Duration -> Int
Duration.minutes   : Duration -> Int
Duration.hours     : Duration -> Int
Duration.days      : Duration -> Int
Duration.add       : Duration -> Duration -> Duration  (* also `+` operator *)
Duration.sub       : Duration -> Duration -> Duration  (* also `-` operator *)
Duration.scale     : Int -> Duration -> Duration
Duration.format    : Duration -> String                (* "1h30m" *)
```

## URL

Operations on the `URL` token.

```
URL.scheme         : URL -> String
URL.host           : URL -> String
URL.port           : URL -> Option Int
URL.path           : URL -> String
URL.query          : URL -> Map String String
URL.fragment       : URL -> Option String
URL.with_path      : String -> URL -> URL
URL.with_query     : Map String String -> URL -> URL
URL.parse          : String -> Result String URL
```

## HTTP

Minimal HTTP client. Sufficient for scripts that need to fetch data or call APIs.

```
type HTTPResponse = {
  status  : Int,
  headers : Map String String,
  body    : String,
}

HTTP.get           : URL -> <io, exn> HTTPResponse
HTTP.post          : URL -> String -> <io, exn> HTTPResponse
HTTP.put           : URL -> String -> <io, exn> HTTPResponse
HTTP.delete        : URL -> <io, exn> HTTPResponse
HTTP.request       : HTTPRequest -> <io, exn> HTTPResponse   (* full control *)

type HTTPRequest = {
  method  : String,
  url     : URL,
  headers : Map String String,
  body    : Option String,
  timeout : Option Duration,
}
```

---

## Notes on scope

This is *MVP*, not complete. Things deliberately omitted:

- Logging module (scripts can use `print_err`; structured logging is Phase 2)
- Database drivers (Phase 2; for now use `Process.run` to invoke `sqlite3` or similar)
- Concurrency primitives (deferred; use OS process model)
- Compression, encryption, hashing (Phase 2; use `Process.run` with system tools)
- Templating (Phase 2; string interpolation covers most cases)
- Sockets (Phase 2; HTTP covers most network needs)

If the MVP proves out and scripts start consistently reaching for these, they get added.
