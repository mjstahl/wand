open Ast

(* ── Constructor field name registry ─────────────────────────────────────── *)

let constr_fields : (Ctor.t, string option list) Hashtbl.t = Hashtbl.create 16

(* The defaults a constructor declares, by field name. A construction that
   leaves a field out takes its value from here, and so does a derived
   decoder reading a document with nothing under that name. *)
let constr_defaults : (Ctor.t, (string * Ast.expr) list) Hashtbl.t =
  Hashtbl.create 16

(* A pattern still carries a bare name, so a match has a name where the value
   has an identity. This says which identity a name means. Until a module can
   own a constructor, one name means one identity, and this is a lookup
   rather than a choice. *)
let ctor_of_name : (string, Ctor.t) Hashtbl.t = Hashtbl.create 16

let register_ctor c = Hashtbl.replace ctor_of_name (Ctor.name c) c

let ctor_named name =
  match Hashtbl.find_opt ctor_of_name name with
  | Some c -> c
  | None -> Ctor.Local name

(* Where a constructor stands in its declaration. `List.sort` ordered a
   variant by constructor name, so `type S = Zulu | Alpha` sorted to
   `[Alpha, Zulu]` and renaming a constructor moved values around. The
   declaration is what decides everything else about a type, and it decides
   this too. *)
let constr_index : (Ctor.t, int) Hashtbl.t = Hashtbl.create 16

let () =
  (* The built-in pairs declare their absent and failed cases first, which
     is the order they already sorted in. *)
  List.iter (fun (n, i) -> Hashtbl.replace constr_index (Ctor.Builtin n) i)
    ["None", 0; "Some", 1; "Error", 0; "Ok", 1; "ShellResult", 0];
  Hashtbl.add constr_fields (Ctor.Builtin "ShellResult")
    [Some "stdout"; Some "stderr"; Some "code"];
  (* Built in, so they are known before any file is read. *)
  Hashtbl.add constr_fields (Ctor.Builtin "Some") [None];
  Hashtbl.add constr_fields (Ctor.Builtin "None") [];
  List.iter (fun n -> Hashtbl.replace ctor_of_name n (Ctor.Builtin n))
    ["ShellResult"; "Some"; "None"; "Ok"; "Error"]

let defaults_of name =
  match Hashtbl.find_opt constr_defaults name with
  | Some ds -> ds
  | None -> []

(* Type definitions, kept for derivation.
   A decoder derived from a type has to find the decoders of the types its
   fields mention, and a type may mention itself. Those are looked up when a
   field is decoded rather than when the decoder is built, which is what lets
   `type Node (label : String, children : List Node)` have a decoder at all
   -- built eagerly, deriving one would not terminate. *)
let derivable :
  (string, string * string list * (string option * type_expr) list) Hashtbl.t =
  Hashtbl.create 16

(* A Map holds a key once.

   Two entries with one key means one of them is unreachable: `Map.get` finds
   a single value, while `size`, `keys` and any fold see both. A document
   read in, edited and written back would carry the ghost along.

   The rule is the one an assignment already implies: the last value given
   wins, and it sits where the key first appeared. Position matters because
   a Map is written back out in the order it holds -- a config that reorders
   itself on every edit makes a diff nobody can read. *)
let map_put kvs key v =
  let rec go seen = function
    | [] -> if seen then [] else [(key, v)]
    | (k, _) :: rest when String.equal k key ->
      if seen then go seen rest else (key, v) :: go true rest
    | pair :: rest -> pair :: go seen rest
  in
  go false kvs

let map_of_pairs pairs = List.fold_left (fun acc (k, v) -> map_put acc k v) [] pairs

(* Reading a key out of a document that names it twice. The later one, for
   the same reason a Map keeps the later value: it is what an assignment
   means, and it is what the parsers everything else in the world uses do.
   Every reader here agrees on it -- `JSON.field`, a decoder, and the Map
   `get_object` hands back -- so a document cannot say different things to
   two readers of the same program. *)
let assoc_last key kvs =
  List.fold_left (fun found (k, v) -> if String.equal k key then Some v else found) None kvs

let find_field_index names label =
  let rec go i = function
    | [] -> None
    | Some n :: _ when n = label -> Some i
    | _ :: rest -> go (i + 1) rest
  in go 0 names

(* ── Values ───────────────────────────────────────────────────────────────── *)

type value =
  | VInt      of int
  | VFloat    of float
  | VString   of string
  | VBool     of bool
  | VUnit
  | VPath     of string
  | VGlob     of string
  | VDateTime of string
  | VDuration of string
  | VURL      of string
  | VIPv4     of string
  | VCIDR     of string
  | VPort     of int
  | VVersion  of string
  | VSize     of string
  | VRegex         of Re.re
  | VJson          of Yojson.Basic.t
  | VToml          of Toml.Types.value
  | VTuple         of value list
  | VList          of value list
  | VMap           of (string * value) list
  | VRecord        of (string * value) list  (* used for module namespaces *)
  | VFun           of env * pat list * expr
  (* Which constructor, and whose. `Ctor.t` rather than the bare name: two
     modules may each declare one called `Status`, and a pattern from one
     file must not match a value from the other. *)
  | VConstr        of Ctor.t * value list
  | VPartialConstr of Ctor.t * int * value list
  | VFix           of string * env * pat list * expr
  | VFixGroup      of (string * pat list * expr) list * env * string
      (* mutually-recursive function group; last string is which member
         this particular value represents *)
  | VBuiltin       of (value -> value)
  (* A resource: how to acquire, and how to give back. A description, not
     something already open -- which is what lets one be named, passed, and
     used twice. `with` is the only thing that runs it. *)
  | VResource      of value * value
  (* A stream: an inert description of a source and its stages, run only
     by a terminal operation, which opens, pulls each line through the
     stages, and closes on the way out. Like a Resource, it describes; it
     is never the open thing, which is what lets one be named, passed,
     and folded twice (each fold reads the source afresh). *)
  | VStream        of stream_desc
  (* The answer a `FS!stream_lines`-family effect resumes with: the default
     handler wraps the real channel; a mock answers with a plain list and
     never sees this constructor. Runtime-internal -- it goes straight back
     to the terminal loop and no wand code ever holds one. *)
  | VLineSource    of in_channel
  (* A decoder: how to read a value out of data that arrived untyped. It is
     handed the data and the path it stands at, so a failure can name the
     field that failed rather than only the type that did not fit. Every
     backend presents its input in JSON's shape, so one set of combinators
     serves all of them. *)
  | VDecoder       of (Yojson.Basic.t -> string list -> (value, string) result)
  (* An index over the entries behind it. An environment is a list because
     that is what binding is -- push a name in front of what was there -- and
     lookup walks it, which is fine for the handful a script defines and not
     fine for the couple of hundred builtins they all sit in front of. The
     index is dropped in front of that fixed part, so a name in it is found
     in one step instead of two hundred.

     It is a hint, not an authority: a miss keeps walking. That way an
     environment can be appended to, sliced, or carry several indexes without
     any of it having to know. *)
  | VEnvIndex      of (string, value) Hashtbl.t

and env = (string * value) list

and stream_desc = { s_source : stream_source; s_stages : stream_stage list }

and stream_source =
  | SFile  of string
  | SStdin
  | SVals  of value list
  (* An injected puller, reachable only from OCaml -- how the tests prove
     that `take` stops pulling, which no wand-level mock can observe under
     open-granularity effects. *)
  | SPull  of (unit -> value option)

and stream_stage =
  | StMap    of value
  | StFilter of value
  | StTake   of int

(* The key an index entry is filed under. Not a legal identifier, so no
   program can name it and no lookup can collide with it. *)
(* A default is a value written out, so the only names it can hold are
   constructors. This is those, as an environment to read one in: rebuilt
   when a declaration is registered rather than at each use, since a default
   is read every time a construction leaves its field out. *)
let ctor_env_cache : (string * value) list option ref = ref None

let forget_ctor_env () = ctor_env_cache := None

let ctor_env () =
  match !ctor_env_cache with
  | Some e -> e
  | None ->
    let e =
      Hashtbl.fold (fun c fields acc ->
        let v = match fields with
          | [] -> VConstr (c, [])
          | fs -> VPartialConstr (c, List.length fs, [])
        in
        (* Keyed by the name a default writes, which is the bare one. *)
        (Ctor.name c, v) :: acc) constr_fields []
    in
    ctor_env_cache := Some e; e

let env_index_key = "\000index"

let index_env (base : env) : env =
  let tbl = Hashtbl.create (List.length base * 2 + 16) in
  (* First binding wins, as walking the list would. *)
  List.iter (fun (k, v) -> if not (Hashtbl.mem tbl k) then Hashtbl.add tbl k v) base;
  (env_index_key, VEnvIndex tbl) :: base

(* Every name an environment can reach, for a "did you mean" hint. *)
let rec env_names (e : env) =
  match e with
  | [] -> []
  | (k, VEnvIndex tbl) :: rest when k = env_index_key ->
    Hashtbl.fold (fun k _ acc -> k :: acc) tbl [] @ env_names rest
  | (k, _) :: rest -> k :: env_names rest

(* Re-index as a file's own definitions pile up, so a lookup never walks more
   than this many before reaching one. An index is a hint, so adding another
   in front of an older one is always safe -- the newer one simply covers
   more. *)
let index_every = 32

let rec lookup_var name (e : env) =
  match e with
  | [] -> None
  | (k, VEnvIndex tbl) :: rest when k = env_index_key ->
    (match Hashtbl.find_opt tbl name with
     | Some _ as found -> found
     | None -> lookup_var name rest)
  | (k, v) :: rest -> if String.equal k name then Some v else lookup_var name rest

(* ── Instants ───────────────────────────────────────────────────────────── *)

(* Days from 1970-01-01 to a civil date, by Howard Hinnant's algorithm. It
   is exact for every proleptic Gregorian date and needs no table. *)
let days_from_civil y m d =
  let y = if m <= 2 then y - 1 else y in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - era * 400 in
  let mp = (m + 9) mod 12 in
  let doy = (153 * mp + 2) / 5 + d - 1 in
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy in
  era * 146097 + doe - 719468

(* A DateTime as seconds from the epoch, so that two spellings of one
   instant compare equal: `2024-01-15T20:00:00+05:30` and
   `2024-01-15T14:30:00Z` are the same moment.

   The lexer has already fixed the shape -- `YYYY-MM-DDTHH:MM:SS`, then
   `Z`, `+HH:MM`, `-HH:MM`, or nothing -- so the digits are where this
   expects them. A value with no offset is read as UTC. Reading it as local
   time would make one script answer differently on two machines. *)
let datetime_epoch s =
  let num at len = int_of_string (String.sub s at len) in
  let days = days_from_civil (num 0 4) (num 5 2) (num 8 2) in
  (* A bare day is that day at midnight. The lexer keeps the short
     spelling, so this is where the two forms become one meaning. *)
  if String.length s = 10 then days * 86400
  else
  let secs = days * 86400 + num 11 2 * 3600 + num 14 2 * 60 + num 17 2 in
  if String.length s <= 19 then secs
  else
    match s.[19] with
    | 'Z' -> secs
    | '+' -> secs - (num 20 2 * 3600 + num 23 2 * 60)
    | '-' -> secs + (num 20 2 * 3600 + num 23 2 * 60)
    | _   -> secs

(* The inverse: an instant written back as a `DateTime` in UTC. Every
   instant wand produces is written this way -- `Z`, whole seconds -- so a
   value that came from `Clock.now` reads like a value that was written by
   hand. The algorithm is the one `days_from_civil` reverses, from the same
   note by Howard Hinnant. *)
let civil_from_days z =
  let z = z + 719468 in
  let era = (if z >= 0 then z else z - 146096) / 146097 in
  let doe = z - era * 146097 in
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 in
  let y = yoe + era * 400 in
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100) in
  let mp = (5 * doy + 2) / 153 in
  let d = doy - (153 * mp + 2) / 5 + 1 in
  let m = if mp < 10 then mp + 3 else mp - 9 in
  ((if m <= 2 then y + 1 else y), m, d)

(* Whole days since the epoch, flooring so that an instant before 1970
   lands in the day it belongs to rather than the one after. *)
let epoch_days secs = if secs >= 0 then secs / 86400 else (secs - 86399) / 86400

let seconds_into_day secs = secs - epoch_days secs * 86400

(* A day at midnight UTC, or why it is not a day. `days_from_civil` maps
   any three numbers to some day, so `2026-02-30` would come back as March
   the 2nd; converting back and comparing is what refuses it. *)
let day_at y m d =
  if m < 1 || m > 12 || d < 1 || d > 31 then
    Error (Printf.sprintf "%04d-%02d-%02d is not a day" y m d)
  else
    let days = days_from_civil y m d in
    let (y', m', d') = civil_from_days days in
    if y' = y && m' = m && d' = d then Ok days
    else Error (Printf.sprintf "%04d-%02d-%02d is not a day" y m d)

let datetime_of_epoch secs =
  let days = if secs >= 0 then secs / 86400 else (secs - 86399) / 86400 in
  let rest = secs - days * 86400 in
  let (y, m, d) = civil_from_days days in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    y m d (rest / 3600) (rest mod 3600 / 60) (rest mod 60)

(* ── Display ──────────────────────────────────────────────────────────────── *)

(* Two ways to write a value down.

   `to_text` is the value as text -- what `IO.println` writes, what `%{...}`
   splices, what goes down a command's stdin, what a CSV cell holds. A
   string is its own characters there, because that is the whole point of
   writing it out.

   `show_value` is the value as someone reads it back: the answer the REPL
   echoes, the value an error message names. A string is quoted there, at
   any depth, because without quotes the display does not say what the value
   was -- `["a, b"]` is one element and `["a", "b"]` is two, and both print
   as `[a, b]`. Quoted, what is shown is wand source again, and the escapes
   are the ones the lexer reads back. *)

(* A TOML array holds one type, so the library keeps it as a list of that
   type rather than a list of values. This puts the values back. *)
let toml_array_values (arr : Toml.Types.array) : Toml.Types.value list =
  match arr with
  | Toml.Types.NodeBool bs   -> List.map (fun b -> Toml.Types.TBool b) bs
  | Toml.Types.NodeInt ns    -> List.map (fun n -> Toml.Types.TInt n) ns
  | Toml.Types.NodeFloat fs  -> List.map (fun f -> Toml.Types.TFloat f) fs
  | Toml.Types.NodeString ss -> List.map (fun s -> Toml.Types.TString s) ss
  | Toml.Types.NodeDate ds   -> List.map (fun d -> Toml.Types.TDate d) ds
  | Toml.Types.NodeTable ts  -> List.map (fun t -> Toml.Types.TTable t) ts
  | Toml.Types.NodeArray ars -> List.map (fun a -> Toml.Types.TArray a) ars
  | Toml.Types.NodeEmpty     -> []

let quoted s =
  let buf = Buffer.create (String.length s + 2) in
  Buffer.add_char buf '"';
  String.iter (fun c ->
    match c with
    | '"'  -> Buffer.add_string buf "\\\""
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\n' -> Buffer.add_string buf "\\n"
    | '\t' -> Buffer.add_string buf "\\t"
    | '\r' -> Buffer.add_string buf "\\r"
    | c    -> Buffer.add_char buf c) s;
  Buffer.add_char buf '"';
  Buffer.contents buf

let rec render ~quote v =
  let sub = render ~quote in
  match v with
  | VInt n      -> string_of_int n
  | VFloat f    -> Printf.sprintf "%g" f
  | VString s   -> if quote then quoted s else s
  | VBool b     -> string_of_bool b
  | VUnit       -> "()"
  | VPath s     -> s
  | VGlob s     -> s
  (* An instant shows as the moment it names, in UTC and in full, whichever
     of its spellings was written. A bare day is that day at midnight, and
     an offset resolves; the source keeps whatever it wrote, which is the
     formatter's business rather than this one's. *)
  | VDateTime s -> datetime_of_epoch (datetime_epoch s)
  | VDuration s -> s
  | VURL s      -> s
  | VIPv4 s     -> s
  | VCIDR s     -> s
  | VPort n     -> Printf.sprintf ":%d" n
  | VVersion s  -> s
  | VSize s     -> s
  | VRegex _    -> "<regex>"
  | VJson j     -> Yojson.Basic.to_string j
  (* A TOML value shows the way the rest of the language shows the same
     shapes: a table like a map, an array like a list. What it does not show
     as is a TOML document -- that is the text of the value rather than a
     look at it, so it belongs to `to_text` and to `TOML.stringify`. A
     document has newlines in it, and a display with newlines in it stops
     being one as soon as it is inside anything: a list of two tables came
     out over four lines, and the `: TOML` that says what it is landed
     after a blank. *)
  | VToml v -> render_toml ~quote v
  | VFun _ | VFix _ | VFixGroup _ | VBuiltin _ -> "<fn>"
  | VResource _ -> "<resource>"
  | VStream _ -> "<stream>"
  | VLineSource _ -> "<line source>"
  | VDecoder _  -> "<decoder>"
  | VEnvIndex _ -> "<env index>"
  | VPartialConstr (n, _, _) -> Printf.sprintf "<%s>" (Ctor.name n)
  | VConstr (name, []) -> (Ctor.name name)
  | VConstr (name, vs) ->
    (Ctor.name name) ^ "(" ^ String.concat ", " (List.map sub vs) ^ ")"
  | VTuple vs   ->
    "(" ^ String.concat ", " (List.map sub vs) ^ ")"
  | VList vs    ->
    "[" ^ String.concat ", " (List.map sub vs) ^ "]"
  | VMap kvs    ->
    "{" ^ String.concat ", " (List.map (fun (k, v) -> k ^ " = " ^ sub v) kvs) ^ "}"
  | VRecord kvs ->
    "{ " ^ String.concat ", " (List.map (fun (k, v) ->
      k ^ " = " ^ sub v) kvs) ^ " }"

and render_toml ~quote (v : Toml.Types.value) =
  let sub = render_toml ~quote in
  match v with
  | Toml.Types.TBool b   -> string_of_bool b
  | Toml.Types.TInt n    -> string_of_int n
  | Toml.Types.TFloat f  -> Printf.sprintf "%g" f
  | Toml.Types.TString s -> if quote then quoted s else s
  | Toml.Types.TTable tbl ->
    "{" ^ String.concat ", "
      (List.map (fun (k, v) ->
         Toml.Types.Table.Key.to_string k ^ " = " ^ sub v)
         (Toml.Types.Table.to_list tbl)) ^ "}"
  | Toml.Types.TArray arr ->
    (* An array showed as `<toml-array>`, which is a display that says
       nothing about the value: the one thing a reader wants from an array
       is what is in it. *)
    "[" ^ String.concat ", " (List.map sub (toml_array_values arr)) ^ "]"
  | Toml.Types.TDate _   -> "<toml-date>"

let show_value v = render ~quote:true v

(* Writing a value out is only unquoted where the value is the text: a
   string is its characters. A list of strings is not text -- the brackets
   and commas are already a display, and one that does not say where an
   element ends is no more use inside `%{...}` than it is in the REPL. *)
let to_text v =
  match v with
  | VString s                    -> s
  | VToml (Toml.Types.TString s) -> s
  (* The text of a TOML table is the document it stands for, newlines and
     all. `IO.println` of one writes real TOML; showing one does not. *)
  | VToml (Toml.Types.TTable tbl) -> Toml.Printer.string_of_table tbl
  | v                            -> show_value v

(* ── Runtime error ────────────────────────────────────────────────────────── *)

exception EvalError of string

(* ── Checked Int arithmetic ───────────────────────────────────────────────── *)

(* Int is a machine word, 63 bits on a 64-bit platform, and wrapping past its
   range produced a plausible-looking wrong number rather than a complaint:
   the linear `fib 91` came back negative and every later term stayed wrong
   without anything saying so. Arithmetic whose result Int cannot represent
   now fails the way `1 / 0` does.

   A runtime error, not the Raise effect. Overflow is possible in any `+`, so
   making it an effect would put Raise on every function that adds
   two numbers, which says nothing about that function -- the same reason
   division by zero is a runtime error today. *)
let overflow op =
  raise (EvalError (Printf.sprintf
    "integer overflow in '%s': Int holds %d to %d" op min_int max_int))

(* Two operands of one sign whose result has the other went past the end. *)
let add_ovf x y =
  let s = x + y in
  if (x >= 0) = (y >= 0) && (s >= 0) <> (x >= 0) then overflow "+" else s

let sub_ovf x y =
  let d = x - y in
  if (x >= 0) <> (y >= 0) && (d >= 0) <> (x >= 0) then overflow "-" else d

(* Dividing the product back gives a different operand when it wrapped.
   `-1 * min_int` is the exception: it wraps to min_int, and dividing that
   by -1 wraps straight back, so the check has to name it. *)
let mul_ovf x y =
  let p = x * y in
  if x <> 0 && (p / x <> y || (x = -1 && y = min_int)) then overflow "*"
  else p

(* min_int / -1 is the one quotient with no representation. *)
let div_ovf x y = if x = min_int && y = -1 then overflow "/" else x / y

let neg_ovf x = if x = min_int then overflow "-" else -x

(* ── Algebraic effects ────────────────────────────────────────────────────── *)

type _ Effect.t += WandEffect : string * value -> value Effect.t

(* The Shell allowlist of the $()/$?() site currently being performed --
   the manifest bound of the file the site was written in, carried to the
   default handler out of band so the effect payload wand handlers match on
   stays a plain command string. Domain-local: it is set for the dynamic
   extent of one perform, and a perform is handled on the domain it was
   made on (Par's cross-domain forwarding re-threads it explicitly). None
   means the site is unbounded and nothing is checked at spawn. *)
let ambient_shell_allow : string list option Domain.DLS.key =
  Domain.DLS.new_key (fun () -> None)

(* How long a command may run, in milliseconds, or None for as long as it
   takes. `Shell.timeout` sets it for the extent of the thunk it is given,
   and the default handler reads it when it waits for a child.

   Domain-local for the same reason the shell bound is: it belongs to the
   code that is running, not to the program. A `Par` worker that inherits
   nothing here waits without a deadline, which is the honest default --
   the worker was not the code the timeout was written around. *)
let shell_deadline : int option Domain.DLS.key =
  Domain.DLS.new_key (fun () -> None)

(* A timed-out command raises like any other failure, and `Shell.timeout`
   picks its own out of the raises it may catch by this prefix. Nothing
   else produces it, because nothing else sets a deadline. *)
let timeout_prefix = "wand:timeout"

let starts_with prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

let drop_prefix prefix s =
  let n = String.length prefix + 2 in   (* the prefix, then ": " *)
  if String.length s > n then String.sub s n (String.length s - n) else s

let perform_shell name allow payload =
  let saved = Domain.DLS.get ambient_shell_allow in
  Domain.DLS.set ambient_shell_allow allow;
  Fun.protect
    ~finally:(fun () -> Domain.DLS.set ambient_shell_allow saved)
    (fun () -> Effect.perform (WandEffect (name, payload)))

(* Raised into a handled body that a handler case answered without resuming,
   so the body unwinds and releases whatever it was holding. Private, and
   caught by the case that raised it: it is a way of running cleanup, not a
   failure anyone can see or catch. `try` re-raises what it does not
   recognise, so an abandoned region cannot be caught mid-unwind. *)
exception Abandoned

(* An abandoned region unwinds by raising `Abandoned` where the operation was
   performed. When that point is inside a `with`'s release -- a scratch
   directory removing its tree, say -- the release is running as
   `Fun.protect`'s finally, and OCaml wraps whatever the finally raises in
   `Fun.Finally_raised`. One wrapper per bracket the unwind passes through,
   so the question is what is at the bottom rather than what is on top.
   Without this a handler that declined to resume such an operation reached
   the top level as a fatal error instead of unwinding. *)
let rec is_abandoned = function
  | Abandoned -> true
  | Fun.Finally_raised e -> is_abandoned e
  | _ -> false

(* The script is stopping, carrying the code it will stop with. Raised by
   `exit` and by a signal, so that stopping unwinds the stack like anything
   else and every `with` on it releases what it holds.

   Not an EvalError, deliberately: `try` re-raises what it does not
   recognise, so a script cannot catch its own cancellation and carry on.
   The only thing that skips cleanup is a process that is destroyed rather
   than stopped -- SIGKILL, or the machine going away. *)
exception Interrupted of int

(* Set by a signal handler; read by the evaluator between steps. A signal
   handler cannot raise usefully here -- it runs wherever the program
   happens to be, which may be inside an effect handler carrying out a
   command, and an exception raised there abandons the body instead of
   unwinding it. Recording the request and raising from the evaluator's own
   stack puts the unwinding where the `with` frames are. *)
let interrupt_requested = Atomic.make 0

let request_interrupt code = Atomic.set interrupt_requested code

(* The request stands until the process ends, because every domain has to
   see it: a Par worker runs its own evaluation loop, and one that missed
   the request would keep working while the rest of the program unwound.

   Each domain raises it exactly once, recorded in domain-local state.
   Raising once is what lets cleanup run: a release is ordinary evaluation,
   and would re-raise on its first step against a request that still stood
   for this domain. A second signal is dealt with by the signal handler
   itself, which stops the process outright. *)
(* Where evaluation stands, for stamping a runtime error with a position.

   The position used to come from an exception handler wrapped around every
   `Located` node, which is the obvious way to do it and the one that costs
   the most: a handler is a stack frame, and a `Located` sits on every
   function body and every match arm, so a frame stayed behind on each one.
   Frames on the tail path never come back, so the stack grew with the call
   chain rather than with the nesting -- and every minor collection rescans
   that whole stack as roots, which makes a long recursion quadratic in its
   own depth. Recording the position instead of catching at it costs two
   stores and leaves the tail call a tail call.

   Two integers rather than the `Token.loc` they came from, because this is
   written on the way into every function body and arm: a record would be a
   pointer store, which is a write barrier, and wrapping it to say "none" is
   an allocation. Line 0 is what nowhere-in-particular is spelled as.

   Per-domain because Par's workers each evaluate their own program.

   Read only when an error is being reported. Until then it is written and
   never looked at. *)
type loc_cell = { mutable at_line : int; mutable at_col : int }

let current_loc : loc_cell Domain.DLS.key =
  Domain.DLS.new_key (fun () -> { at_line = 0; at_col = 0 })

(* The position an error is reported at is the innermost `Located` still
   being evaluated. That is what the cell holds, provided every construct
   that carries on after a subexpression finishes puts back what it found --
   otherwise a call that has already returned leaves its own body's position
   behind, and the next failure is reported against a line in whichever file
   that body came from. Tail positions are exempt: nothing carries on after
   them, so there is nothing to put back, which is the whole point. *)
let loc_cell () = Domain.DLS.get current_loc

let mark_loc (c : loc_cell) (l : Token.loc) =
  c.at_line <- l.Token.line;
  c.at_col  <- l.Token.col

(* Prefix a runtime error with where it was raised, unless it says already. *)
let stamp_loc msg =
  let c = loc_cell () in
  if c.at_line = 0 || Util.has_loc_prefix msg then msg
  else Printf.sprintf "%d:%d: %s" c.at_line c.at_col msg

(* Forget the position between runs. A session evaluates one statement after
   another, and an error raised before the next one reaches a `Located` --
   while an import is being resolved, say -- would otherwise be reported
   against the statement before it. *)
let forget_loc () =
  let c = loc_cell () in
  c.at_line <- 0;
  c.at_col <- 0

let interrupt_taken = Domain.DLS.new_key (fun () -> ref false)

(* Stretches where this domain must not unwind, however urgently the program
   is stopping, because something else depends on it reaching the end. Par's
   calling domain is the case: it is answering its workers' effects, and
   unwinding out of that leaves them blocked on a reply that never comes and
   never released. It takes the interrupt after they are joined. *)
let interrupts_deferred = Domain.DLS.new_key (fun () -> ref 0)

let defer_interrupts f =
  let d = Domain.DLS.get interrupts_deferred in
  incr d;
  Fun.protect ~finally:(fun () -> decr d) f

(* Forget a request that has been dealt with, for a session that carries on
   afterwards -- including this domain's record of having taken it, or the
   next request would be ignored here. A script has nothing to carry on to
   and never calls this. *)
let clear_interrupt () =
  Atomic.set interrupt_requested 0;
  Domain.DLS.get interrupt_taken := false

(* A worker that lost a race. `Par.race` sets this on the domains it is no
   longer waiting on, and the worker raises at its next checkpoint, so it
   releases what it holds on the way out.

   Domain-local and separate from the program-wide interrupt: one lost race
   is not the program stopping, and a loser must not look like Ctrl-C to
   anything else. *)
let cancelled : bool ref Domain.DLS.key = Domain.DLS.new_key (fun () -> ref false)

let cancel_this_domain flag = Domain.DLS.set cancelled flag

(* Races currently running. Nothing but a race cancels a domain, and it can
   only cancel one it is still waiting on, so while this is zero no domain
   is carrying a cancellation and there is nothing for the check below to
   find. Counted rather than flagged, because a thunk in a race may itself
   race. *)
let races_running = Atomic.make 0

let with_race_running f =
  Atomic.incr races_running;
  Fun.protect ~finally:(fun () -> Atomic.decr races_running) f

let check_interrupt_now () =
  (* Raised once, then cleared, for the reason the program-wide interrupt is
     taken once: a release is ordinary evaluation, and a flag that still
     stood would raise again on the first step of the cleanup, so nothing
     the loser held would be given back. *)
  let cancel = Domain.DLS.get cancelled in
  if !cancel then begin cancel := false; raise (Interrupted 0) end;
  let code = Atomic.get interrupt_requested in
  if code <> 0 && !(Domain.DLS.get interrupts_deferred) = 0 then begin
    let taken = Domain.DLS.get interrupt_taken in
    if not !taken then begin taken := true; raise (Interrupted code) end
  end

(* Every step of evaluation asks whether it should stop, and almost every
   time the answer is no. What that answer used to cost was two reads of
   domain-local state, which is a call and an indirection each -- more, on
   the shapes a script actually runs, than resolving all its names.

   Both reasons to stop are announced globally before any domain can see
   them, so two atomic loads decide it. Whatever they cannot rule out is
   left to the full check, which is unchanged. *)
let check_interrupt () =
  if Atomic.get interrupt_requested <> 0 || Atomic.get races_running <> 0 then
    check_interrupt_now ()

(* Structural comparison that a script can catch. OCaml's `=` and `compare`
   raise Invalid_argument when they reach a closure, and a value may carry one
   -- a function, a builtin, a compiled regex or a decoder, directly or inside
   a list, tuple, Map or constructor. That exception is not an EvalError, so
   `try` re-raises it and the interpreter dies with a fatal error on code that
   typechecked: `==`, `!=` and `List.sort` all admit function-typed operands.
   Turning it into an EvalError makes it a value the language can see. *)
let parse_dur_ms s =
  let n = String.length s in
  let i = ref 0 in
  let total = ref 0 in
  let at i prefix =
    let plen = String.length prefix in
    n >= i + plen && String.sub s i plen = prefix
  in
  (try
    while !i < n do
      let j = ref !i in
      while !j < n && s.[!j] >= '0' && s.[!j] <= '9' do incr j done;
      if !j = !i then raise Exit;
      (* A number past what an Int holds is not malformed, it is too big --
         and saying which is the difference between a reader checking their
         spelling and a reader checking their arithmetic. It used to escape
         as OCaml's own "int_of_string" and say neither. *)
      let digits = String.sub s !i (!j - !i) in
      let num =
        match int_of_string_opt digits with
        | Some v -> v
        | None ->
          raise (EvalError (Printf.sprintf
            "duration %S is too large: %s does not fit in an Int" s digits))
      in
      i := !j;
      (* Each unit's contribution and the running sum go through the checked
         arithmetic the rest of the evaluator uses. A duration whose total
         milliseconds overflow an Int used to wrap silently to a negative
         number that looked like an answer -- `9999999999999w` came back
         positive-looking nonsense. It is too big, not malformed, and says so.
         The factors are constants, so only `num * factor` and the sum can
         overflow; both are checked. *)
      let add_unit factor width =
        total := add_ovf !total (mul_ovf num factor); i := !i + width
      in
      if      at !i "min" then add_unit 60000 3
      else if at !i "ms"  then add_unit 1 2
      else if at !i "w"   then add_unit (7 * 24 * 3600000) 1
      else if at !i "d"   then add_unit (24 * 3600000) 1
      else if at !i "h"   then add_unit 3600000 1
      else if at !i "m"   then add_unit 60000 1
      else if at !i "s"   then add_unit 1000 1
      else raise Exit
    done
  with Exit -> raise (EvalError (Printf.sprintf "invalid duration: %S" s)));
  !total

(* ── The order wand gives a value ─────────────────────────────────────── *)

(* A size in bytes. A `KB` is 1000 bytes, not 1024: the spelling is the SI
   one, and SI says 1000. Reading it as 1024 would be lying about the unit
   the author wrote. Binary units would be `KiB`, which wand does not lex.

   A literal may carry a decimal (`1.5GB`), so the product is rounded to
   the nearest byte. `Int` holds 4.6 exabytes, and the largest literal the
   lexer accepts is far below that. *)
let size_bytes s =
  let n = String.length s in
  let i = ref 0 in
  while !i < n && (let c = s.[!i] in (c >= '0' && c <= '9') || c = '.') do incr i done;
  let number = float_of_string (String.sub s 0 !i) in
  let unit = String.sub s !i (n - !i) in
  let factor =
    match unit with
    | "B"  -> 1.0
    | "KB" -> 1e3
    | "MB" -> 1e6
    | "GB" -> 1e9
    | "TB" -> 1e12
    | "PB" -> 1e15
    | _ -> raise (EvalError (Printf.sprintf "invalid size: %S" s))
  in
  int_of_float (Float.round (number *. factor))

(* The readable spelling of a byte count: the largest unit that leaves at
   least one of it, to a tenth. `Size.of_bytes` answers exact bytes, so a
   sum of file sizes is a number nobody wants to read until it comes
   through here. Rounding can fill the unit -- 999_999 bytes is 1000.0KB --
   and that steps up rather than printing a thousand of something. A byte
   count below zero has no size to name, so it reads as `0B`. *)
let format_size_bytes n =
  let units = [| "B"; "KB"; "MB"; "GB"; "TB"; "PB" |] in
  let last = Array.length units - 1 in
  let rec pick i v = if i < last && v >= 1000.0 then pick (i + 1) (v /. 1000.0) else (i, v) in
  let i, v = pick 0 (float_of_int (max 0 n)) in
  let v = Float.round (v *. 10.0) /. 10.0 in
  let i, v = if i < last && v >= 1000.0 then (i + 1, v /. 1000.0) else (i, v) in
  let body =
    if Float.abs (v -. Float.round v) < 1e-9 then string_of_int (int_of_float (Float.round v))
    else Printf.sprintf "%.1f" v
  in
  body ^ units.(i)

let format_dur_ms ms =
  if ms = 0 then "0s"
  else
    let ms = abs ms in
    let buf = Buffer.create 16 in
    let add n unit =
      if n > 0 then (Buffer.add_string buf (string_of_int n); Buffer.add_string buf unit)
    in
    let rem = ref ms in
    let wk = !rem / (7*24*3600000) in rem := !rem mod (7*24*3600000);
    let dy = !rem / (24*3600000)   in rem := !rem mod (24*3600000);
    let hr = !rem / 3600000        in rem := !rem mod 3600000;
    let mn = !rem / 60000          in rem := !rem mod 60000;
    let sc = !rem / 1000           in rem := !rem mod 1000;
    let ml = !rem in
    add wk "w"; add dy "d"; add hr "h"; add mn "m"; add sc "s"; add ml "ms";
    Buffer.contents buf

(* An address as the 32-bit number it is, so `10.0.0.9` is below
   `10.0.0.10`. Text order says otherwise, which is the answer nobody
   wants. The lexer has already refused an octet above 255. *)
let ipv4_key s =
  List.fold_left (fun acc part -> acc * 256 + int_of_string part) 0
    (String.split_on_char '.' s)

(* A network, keyed by where it starts and then how far it reaches. Compared
   as text, `10.0.0.0/8` sorted below `9.0.0.0/8` -- the same two addresses
   the other way round from what `IPv4` answers, which reads them as
   numbers. *)
let cidr_key s =
  match String.split_on_char '/' s with
  | [addr; bits] -> (ipv4_key addr, int_of_string bits)
  | _ -> raise (EvalError (Printf.sprintf "invalid CIDR: %S" s))

(* Semver precedence. Numbers compare as numbers, so `1.10.0` is above
   `1.9.0`. A version with a prerelease is below the same version without
   one, and two prereleases compare identifier by identifier: a number
   against a number numerically, a number below a word, two words by their
   text, and if all of them match, the longer list wins.

   wand's literal accepts two spellings semver does not, and both fall out
   of the rule rather than needing an exception: a leading zero reads as
   the number it is, and an empty prerelease is one empty identifier, below
   every other. *)
let version_parts s =
  match String.index_opt s '-' with
  | None -> (s, None)
  | Some i -> (String.sub s 0 i,
               Some (String.sub s (i + 1) (String.length s - i - 1)))

let compare_prerelease a b =
  let ids t = String.split_on_char '.' t in
  let numeric t = t <> "" && String.for_all (fun c -> c >= '0' && c <= '9') t in
  let rec go xs ys =
    match xs, ys with
    | [], [] -> 0
    | [], _  -> -1          (* fewer identifiers is lower *)
    | _, []  -> 1
    | x :: xs, y :: ys ->
      let c =
        match numeric x, numeric y with
        | true, true   -> compare (int_of_string x) (int_of_string y)
        | true, false  -> -1
        | false, true  -> 1
        | false, false -> compare x y
      in
      if c <> 0 then c else go xs ys
  in
  go (ids a) (ids b)

let compare_versions a b =
  let (na, pa) = version_parts a and (nb, pb) = version_parts b in
  let nums t = List.map int_of_string (String.split_on_char '.' t) in
  let c = compare (nums na) (nums nb) in
  if c <> 0 then c
  else
    match pa, pb with
    | None,   None   -> 0
    | Some _, None   -> -1      (* a prerelease is below the release *)
    | None,   Some _ -> 1
    | Some x, Some y -> compare_prerelease x y

(* Comparing normalized values is the whole point: `90s` against `1min`, or
   one instant written two ways. `Date` and `Time` are fixed-width and
   zero-padded, so for those two the text order is already the right order.

   The `Ord` constraint refuses every other type, so the last case says
   what cannot arrive here rather than what to do about it. *)
let wand_order a b =
  match a, b with
  | VInt x,      VInt y      -> compare x y
  | VFloat x,    VFloat y    -> compare x y
  | VString x,   VString y   -> compare x y
  | VDuration x, VDuration y -> compare (parse_dur_ms x) (parse_dur_ms y)
  | VDateTime x, VDateTime y -> compare (datetime_epoch x) (datetime_epoch y)
  | VSize x,     VSize y     -> compare (size_bytes x) (size_bytes y)
  | VVersion x,  VVersion y  -> compare_versions x y
  | VPort x,     VPort y     -> compare x y
  | VIPv4 x,     VIPv4 y     -> compare (ipv4_key x) (ipv4_key y)
  | VCIDR x,     VCIDR y     -> compare (cidr_key x) (cidr_key y)
  | _ -> raise (EvalError "these values have no order")

(* Equality normalizes wherever ordering does, so the three relations agree.
   It compared the stored text before, which made `60s == 1min` false while
   `60s < 1min` and `60s > 1min` were both false as well: three answers that
   no reader can hold at once. *)
(* The types whose text is not their value, so equality and sorting have to
   read them rather than compare their spelling. `Port` is not here: it
   holds the number already. *)
let normalized = function
  | VDuration _ | VDateTime _ | VSize _ | VVersion _ | VIPv4 _ | VCIDR _ -> true
  | _ -> false

(* A value that holds code. Two of these cannot be compared, and the walk
   has to say so itself: OCaml's `compare` raises only when it reaches the
   function inside, and two closures whose bodies already differ answer
   before it gets there. *)
let functional = function
  | VFun _ | VFix _ | VFixGroup _ | VBuiltin _ -> true
  | _ -> false

let rec wand_equal a b =
  match a, b with
  | _ when functional a || functional b ->
    raise (EvalError "cannot compare functions for equality")
  | _ when normalized a && normalized b ->
    (try wand_order a b = 0 with EvalError _ -> false)
  (* A value that normalizes can sit inside another value, so the walk goes
     in rather than stopping at the outside: `[60s] == [1min]` is the same
     question as `60s == 1min`. *)
  | VTuple xs, VTuple ys | VList xs, VList ys ->
    List.length xs = List.length ys && List.for_all2 wand_equal xs ys
  | VConstr (n1, xs), VConstr (n2, ys) ->
    n1 = n2 && List.length xs = List.length ys && List.for_all2 wand_equal xs ys
  | VMap kvs1, VMap kvs2 | VRecord kvs1, VRecord kvs2 ->
    List.length kvs1 = List.length kvs2
    && List.for_all2 (fun (k1, v1) (k2, v2) -> k1 = k2 && wand_equal v1 v2)
         kvs1 kvs2
  | _ ->
    (try a = b
     with Invalid_argument _ ->
       raise (EvalError "cannot compare functions for equality"))

(* A key that agrees with `wand_equal`: two values it calls equal always
   produce the same key. The reverse need not hold -- values that share a
   key are settled by `wand_equal` itself -- so a type whose equality is
   subtler than any cheap key can be (a `Version` and its prerelease) keys
   coarsely and still answers correctly.

   This is what keeps a membership test a hash lookup. Comparing each value
   against everything already seen would agree too, and would cost the
   square of the length. *)
let rec eq_key v =
  match v with
  (* Equality on a function is an error, but only once there is something to
     compare it against: a list of one is still a list of one. One key for
     all of them puts any two in the same bucket, so `wand_equal` is reached
     and raises whichever two they are -- rather than the answer depending
     on which values happened to share a bucket. A list holds one type, so
     nothing else can land here beside them. *)
  | VFun _ | VFix _ | VFixGroup _ | VBuiltin _ -> VUnit
  (* The types whose text is not their value, keyed by the value. *)
  | VDuration s -> VInt (parse_dur_ms s)
  | VDateTime s -> VInt (datetime_epoch s)
  | VIPv4 s     -> VInt (ipv4_key s)
  | VSize s     -> VInt (size_bytes s)
  (* The numbers only. Two equal versions have equal numbers, so this is a
     sound key; the prerelease is left for `wand_equal` to settle. *)
  | VVersion s ->
    (match String.split_on_char '.' (fst (version_parts s)) with
     | parts -> (try VList (List.map (fun p -> VInt (int_of_string p)) parts)
                 with Failure _ -> VString s))
  (* A value that normalizes can sit inside another one, so the walk goes
     in, exactly as `wand_equal` does. *)
  | VList xs        -> VList (List.map eq_key xs)
  | VTuple xs       -> VTuple (List.map eq_key xs)
  | VConstr (n, xs) -> VConstr (n, List.map eq_key xs)
  | VRecord kvs     -> VRecord (List.map (fun (k, x) -> (k, eq_key x)) kvs)
  | VMap kvs        -> VMap (List.map (fun (k, x) -> (k, eq_key x)) kvs)
  | v -> v


(* Two constructors of one type, by where they were declared. Falling back
   to the name covers a constructor that reached here without a declaration
   being read; within one list both come from one type, so the two never
   mix. *)
let compare_ctor c1 c2 =
  match Hashtbl.find_opt constr_index c1, Hashtbl.find_opt constr_index c2 with
  | Some i, Some j -> compare i j
  | _ -> compare (Ctor.name c1) (Ctor.name c2)

(* `List.sort` takes a list of any type, including types wand does not
   order, so it keeps structural comparison and reaches for `wand_order`
   only where wand defines one.

   The walk is written out rather than left to the runtime's own compare,
   which reads a constructor's name. It has to go all the way in: a
   constructor inside a tuple inside a list is still a constructor, and
   ordering it by name there would be the same defect one level down. *)
let rec wand_compare a b =
  match a, b with
  | _ when functional a || functional b ->
    raise (EvalError "cannot order functions")
  | _ when normalized a && normalized b -> wand_order a b
  | VConstr (c1, xs1), VConstr (c2, xs2) ->
    let c = compare_ctor c1 c2 in
    if c <> 0 then c else compare_each xs1 xs2
  | VList xs, VList ys | VTuple xs, VTuple ys -> compare_each xs ys
  | VRecord kvs1, VRecord kvs2 | VMap kvs1, VMap kvs2 ->
    compare_pairs kvs1 kvs2
  | _ ->
    (try compare a b
     with Invalid_argument _ -> raise (EvalError "cannot order functions"))

(* Element by element, and a list that runs out first is the lesser -- the
   order the runtime's own compare gives a list, kept. *)
and compare_each xs ys =
  match xs, ys with
  | [], []             -> 0
  | [], _              -> -1
  | _, []              -> 1
  | x :: xs, y :: ys   ->
    let c = wand_compare x y in
    if c <> 0 then c else compare_each xs ys

and compare_pairs kvs1 kvs2 =
  match kvs1, kvs2 with
  | [], []                        -> 0
  | [], _                         -> -1
  | _, []                         -> 1
  | (k1, v1) :: r1, (k2, v2) :: r2 ->
    let c = compare k1 k2 in
    if c <> 0 then c
    else
      let c = wand_compare v1 v2 in
      if c <> 0 then c else compare_pairs r1 r2

(* ── Pattern matching ─────────────────────────────────────────────────────── *)

(* Whether a pattern list and a value list have the same length, decided by
   walking them together rather than measuring each. Measuring meant that
   testing `[]` against a list looked at every element of it, so each step of
   a recursive list function cost the length of what remained and traversing
   a list of n elements cost O(n^2). *)
let rec same_length ps vs =
  match ps, vs with
  | [], []           -> true
  | _ :: ps, _ :: vs -> same_length ps vs
  | _                -> false

(* How many observers are watching effects: user handlers currently in scope,
   plus one while a rehearsal or trace is running. Par consults this to decide
   whether a worker may perform its own effects. *)
let observers = Atomic.make 0

let observed f =
  ignore (Atomic.fetch_and_add observers 1);
  Fun.protect ~finally:(fun () -> ignore (Atomic.fetch_and_add observers (-1))) f

(* The observers that are a `handle` written in wand, which is the subset a
   rehearsal and a trace are not. `Par.timeout` consults this: a rehearsal
   collapsing a race still reports what the work would do, where a handler
   collapsing it takes the deadline away and says nothing. *)
let handlers = Atomic.make 0

let handled f =
  ignore (Atomic.fetch_and_add handlers 1);
  Fun.protect ~finally:(fun () -> ignore (Atomic.fetch_and_add handlers (-1))) f

(* Installs the runtime's own handlers. Set by the runner, which owns them. *)
let with_default_handler : ((unit -> value) -> value) ref = ref (fun f -> f ())

(* In a match arm, a list pattern states the whole shape: `[a, b]` is a
   two-element list and nothing else, because the arms discriminate and a
   longer list belongs to another arm. A destructuring `let` has no other
   arm -- it only binds -- so there `[a, b]` names the leading elements and
   whatever follows is ignored, the way a map pattern binds the keys it
   names and ignores the rest. [prefix] selects the binding reading. *)
(* The constructor a pattern names, whatever form it takes. *)
let pat_ctor_name (p : pat) =
  match p with
  | PConstr (n, _) | PConstrNamed (n, _) | PConstrBare (n, _) -> n
  | _ -> ""

(* Which constructor a name means here. A name bound in scope wins: that is
   how a renamed import, and a type's own name where it has one constructor,
   reach the constructor they stand for. *)
let ctor_in_scope env name =
  match lookup_var name env with
  | Some (VConstr (c, _)) | Some (VPartialConstr (c, _, _)) -> c
  | _ -> ctor_named name

let rec try_match ?(prefix = false) (p : pat) v (env : env) : env option =
  match p, v with
  | PVar name, v          -> Some ((name, v) :: env)
  | Wild, _               -> Some env
  | Int n,    VInt m      when n = m -> Some env
  | Float f,  VFloat g    when f = g -> Some env
  | String s, VString t   when s = t -> Some env
  | Bool b,   VBool c     when b = c -> Some env
  | Unit,     VUnit                  -> Some env
  | PTuple ps, VTuple vs when same_length ps vs ->
    List.fold_left2
      (fun acc p v -> match acc with
        | None     -> None
        | Some env -> try_match ~prefix p v env)
      (Some env) ps vs
  | PList ps, VList vs ->
    let rec go acc ps vs =
      match acc, ps, vs with
      | None, _, _                 -> None
      | Some env, [], []           -> Some env
      | Some env, [], _ :: _       -> if prefix then Some env else None
      | Some _, _ :: _, []         -> None
      | Some env, p :: ps, v :: vs -> go (try_match ~prefix p v env) ps vs
    in
    go (Some env) ps vs
  (* A type annotation says nothing about which values match: it is checked
     before the program runs, and the pattern under it does the matching. *)
  | PAnnot (p, _), v -> try_match ~prefix p v env
  | PCons (hp, tp), VList (v :: vs) ->
    (match try_match ~prefix hp v env with
     | None      -> None
     | Some env' -> try_match ~prefix tp (VList vs) env')
  | PCons _, VList [] -> None
  | PTuple ps, VConstr (_, vals) when same_length ps vals ->
    List.fold_left2
      (fun acc p v -> match acc with
        | None     -> None
        | Some env -> try_match ~prefix p v env)
      (Some env) ps vals
  | PConstr (name, pats), VConstr (vname, vals)
    when Ctor.equal (ctor_in_scope env name) vname && same_length pats vals ->
    List.fold_left2
      (fun acc p v -> match acc with
        | None     -> None
        | Some env -> try_match ~prefix p v env)
      (Some env) pats vals
  (* The declaration decides which of the two readings this is, exactly as
     it does when the pattern is checked. *)
  (* `one.Live`: the module's namespace holds the constructor, so its
     identity comes from there. The pattern under the qualifier then matches
     the value as any other would. *)
  (* `one.Live`: the module's namespace holds the constructor, so its identity
     comes from there. What is under the qualifier is matched against the
     value's fields directly -- resolving its bare name again would consult
     the index, where one name holds one constructor and another module may
     have registered it. *)
  | PQualified (m, inner), VConstr (vc, vals) ->
    let owner =
      match lookup_var m env with
      | Some (VRecord kvs) ->
        (match List.assoc_opt (pat_ctor_name inner) kvs with
         | Some (VConstr (c, _)) | Some (VPartialConstr (c, _, _)) -> Some c
         | _ -> None)
      | _ -> None
    in
    (match owner with
     | Some c when Ctor.equal c vc ->
       let fields () = match Hashtbl.find_opt constr_fields vc with
         | Some names -> names
         | None -> []
       in
       let named bindings =
         List.fold_left (fun acc (fname, p) ->
           match acc with
           | None -> None
           | Some env ->
             (match find_field_index (fields ()) fname with
              | None -> None
              | Some i ->
                (match List.nth_opt vals i with
                 | None -> None
                 | Some v -> try_match ~prefix p v env))) (Some env) bindings
       in
       (match inner with
        | PConstr (_, pats) when same_length pats vals ->
          List.fold_left2 (fun acc p v ->
            match acc with
            | None -> None
            | Some env -> try_match ~prefix p v env) (Some env) pats vals
        | PConstr (_, _) -> None
        | PConstrNamed (_, bindings) -> named bindings
        | PConstrBare (_, ids) ->
          let named_fields = List.exists (fun dn -> dn <> None) (fields ()) in
          (match Ast.constr_bare_reading ~named_fields "" ids with
           | PConstrNamed (_, bindings) -> named bindings
           | PConstr (_, pats) when same_length pats vals ->
             List.fold_left2 (fun acc p v ->
               match acc with
               | None -> None
               | Some env -> try_match ~prefix p v env) (Some env) pats vals
           | _ -> None)
        | _ -> None)
     | _ -> None)
  | PQualified (_, _), _ -> None
  | PConstrBare (name, ids), _ ->
    let named_fields =
      match Hashtbl.find_opt constr_fields (ctor_in_scope env name) with
      | Some fields -> List.exists (fun dn -> dn <> None) fields
      | None -> false
    in
    try_match ~prefix (Ast.constr_bare_reading ~named_fields name ids) v env
  | PConstrNamed (name, bindings), VConstr (vname, vals)
    when Ctor.equal (ctor_in_scope env name) vname ->
    (match Hashtbl.find_opt constr_fields vname with
     | None -> None
     | Some field_names ->
       List.fold_left (fun acc (fname, p) ->
         match acc with
         | None -> None
         | Some env ->
           (match find_field_index field_names fname with
            | None -> None
            | Some i ->
              (match List.nth_opt vals i with
               | None -> None
               | Some v -> try_match ~prefix p v env))
       ) (Some env) bindings)
  | PMap bindings, (VMap kvs | VRecord kvs) ->
    List.fold_left (fun acc (key, p) ->
      match acc with
      | None -> None
      | Some env ->
        (match List.assoc_opt key kvs with
         | None   -> None
         | Some v -> try_match ~prefix p v env)
    ) (Some env) bindings
  | _ -> None

(* ── Evaluation ───────────────────────────────────────────────────────────── *)

(* One shell argument, whatever the value contains.

   Single quotes are the only quoting `sh` treats as absolutely literal:
   inside them a space does not split, a `*` does not expand, and `;`, `|`,
   backticks and `$(...)` are text. The one character they cannot carry is
   `'` itself, which is closed, escaped and reopened -- the standard
   `'\''` dance.

   An empty value becomes `''`, which is one empty argument rather than no
   argument at all. That is the difference between `rm ''` and `rm`. *)
let shell_quote v =
  let buf = Buffer.create (String.length v + 2) in
  Buffer.add_char buf '\'';
  String.iter
    (fun c -> if c = '\'' then Buffer.add_string buf "'\\''" else Buffer.add_char buf c)
    v;
  Buffer.add_char buf '\'';
  Buffer.contents buf

(* The same value where the author already opened a quote of their own.
   Wrapping it in single quotes there would quote nothing -- inside `"..."`
   a single quote is an ordinary character, so `$(echo "hi %{name}")` put
   the value straight into text the shell still expands, and a name holding
   `$(...)` ran. The value is escaped for the quote it lands in instead,
   which keeps the author's word one word and leaves nothing for the shell
   to read.

   Inside single quotes only the quote itself can end the span: it is closed,
   the character escaped outside, and the span reopened. Inside double
   quotes the four the shell still reads there take a backslash. *)
let quote_within q v =
  let buf = Buffer.create (String.length v + 8) in
  String.iter (fun c ->
    if q = '\'' then
      (if c = '\'' then Buffer.add_string buf "'\\''" else Buffer.add_char buf c)
    else begin
      if c = '"' || c = '\\' || c = '$' || c = '`' then Buffer.add_char buf '\\';
      Buffer.add_char buf c
    end) v;
  Buffer.contents buf

(* Deriving a decoder needs the decoding machinery, which is defined further
   down the file; `eval` only has to be able to reach it. *)
let derive_decoder : (string -> value) ref =
  ref (fun _ -> raise (EvalError "decoder derivation is not wired up"))

let derive_encoder : (string -> value) ref =
  ref (fun _ -> raise (EvalError "encoder derivation is not wired up"))

let derive_usage : (string -> value) ref =
  ref (fun _ -> raise (EvalError "usage derivation is not wired up"))

let derive_spec : (string -> value) ref =
  ref (fun _ -> raise (EvalError "spec derivation is not wired up"))

let derive_reader : (string -> value) ref =
  ref (fun _ -> raise (EvalError "reader derivation is not wired up"))

let rec eval (env : env) (e : expr) : value = eval_at false env e

(* Evaluate in tail position: the value of `e` is the value of whatever
   called us, so no frame here has any work left to do. *)
and eval_tail (env : env) (e : expr) : value = eval_at true env e

and eval_at (tail : bool) (env : env) (e : expr) : value =
  check_interrupt ();
  match e with
  | Int n      -> VInt n
  | Float f    -> VFloat f
  | String s   -> VString s
  | Bool b     -> VBool b
  | Unit       -> VUnit
  | Path s     -> VPath s
  | Glob s     -> VGlob s
  | DateTime s -> VDateTime s
  | Duration s -> VDuration s
  | URL s      -> VURL s
  | IPv4 s     -> VIPv4 s
  | CIDR s     -> VCIDR s
  | Port n     -> VPort n
  | Version s  -> VVersion s
  | Size s     -> VSize s
  | Var name ->
    (match lookup_var name env with
     | Some v -> v
     | None   ->
       raise (EvalError (Printf.sprintf "unbound variable '%s'%s"
         name (Util.hint name (env_names env)))))
  | Constr name ->
    (match lookup_var name env with
     | Some v -> v
     | None   ->
       raise (EvalError (Printf.sprintf "unknown constructor '%s'%s"
         name (Util.hint name (env_names env)))))
  | EnvVar name ->
    (match Sys.getenv_opt name with
     | Some v -> VString v
     | None   -> raise (EvalError (Printf.sprintf
         "environment variable '%s' is not set" name)))
  | Hole ->
    raise (EvalError "cannot evaluate a hole")
  | UnOp ("-", e) ->
    (match eval env e with
     | VInt n   -> VInt (neg_ovf n)
     | VFloat f -> VFloat (-.f)
     | _        -> raise (EvalError "'-' requires a number"))
  | UnOp ("!", e) ->
    (match eval env e with
     | VBool b -> VBool (not b)
     | _       -> raise (EvalError "'!' requires a bool"))
  | UnOp (op, _) ->
    raise (EvalError (Printf.sprintf "unknown operator '%s'" op))
  | BinOp (op, a, b) -> eval_binop env op a b
  | Fn (params, body) -> VFun (env, params, body)
  | App (f, x) ->
    let vf = eval env f in
    let vx = eval env x in
    if tail then apply_tail vf vx else apply vf vx
  | Let (p, e1, e2, _) ->
    let v1 = eval env e1 in
    let v1 = match p, v1 with
      | PVar name, VFun (fenv, params, body) ->
        VFix (name, fenv, params, body)
      | _ -> v1
    in
    eval_at tail (bind_pat ~prefix:true p v1 env) e2
  | LetRec (bindings, e2, _) ->
    let env' = List.fold_left (fun acc (name, _, _) ->
      (name, VFixGroup (bindings, env, name)) :: acc) env bindings in
    eval_at tail env' e2
  | If (cond, then_, else_) ->
    (match eval env cond with
     | VBool true  -> eval_at tail env then_
     | VBool false -> eval_at tail env else_
     | _           -> raise (EvalError "if condition must be a bool"))
  | Match (scrutinee, cases) ->
    let sv = eval env scrutinee in
    eval_match tail env sv cases
  | Tuple es  -> VTuple (List.map (eval env) es)
  | List es   -> VList  (List.map (eval env) es)
  (* `Foo.Live`: the module's namespace holds its constructors, so the
     identity comes from there rather than from the bare-name index. *)
  | Qualified (m, inner) ->
    let from_module name =
      match lookup_var m env with
      | Some (VRecord kvs) ->
        (match List.assoc_opt name kvs with
         | Some (VConstr (c, _)) | Some (VPartialConstr (c, _, _)) -> Some c
         | _ -> None)
      | _ -> None
    in
    let with_ident name k =
      match from_module name with
      | Some c -> k c
      | None ->
        raise (EvalError (Printf.sprintf
          "'%s' has no constructor '%s'" m name))
    in
    (match inner with
     | Constr name -> with_ident name (fun c ->
         match Hashtbl.find_opt constr_fields c with
         | Some (_ :: _ as fs) -> VPartialConstr (c, List.length fs, [])
         | _ -> VConstr (c, []))
     | ConstrApp (name, fields) ->
       with_ident name (fun c -> eval_constr_app env c fields)
     | ConstrBare (name, ids) ->
       with_ident name (fun c ->
         let named_fields =
           match Hashtbl.find_opt constr_fields c with
           | Some fields -> List.exists (fun dn -> dn <> None) fields
           | None -> false
         in
         match Ast.constr_bare_construction ~named_fields name ids with
         | ConstrApp (_, fields) -> eval_constr_app env c fields
         | other -> eval env other)
     | App (f, arg) ->
       (* `Foo.Some 3`: the constructor, then what it is applied to. *)
       apply (eval env (Qualified (m, f))) (eval env arg)
     | other -> eval env other)
  | ConstrBare (name, ids) ->
    let named_fields =
      match Hashtbl.find_opt constr_fields (ctor_named name) with
      | Some fields -> List.exists (fun dn -> dn <> None) fields
      | None -> false
    in
    eval env (Ast.constr_bare_construction ~named_fields name ids)
  | ConstrApp (name, fields) -> eval_constr_app env (ctor_in_scope env name) fields
  | ConstrUpdate (name, base, fields) ->
    let replacements = List.map (fun (fname, e) -> (fname, eval env e)) fields in
    (match eval env base, Hashtbl.find_opt constr_fields (ctor_named name) with
     | VConstr (_, values), Some field_names ->
       VConstr ((ctor_named name), List.map2 (fun fname_opt v ->
         match fname_opt with
         | Some fn -> (match List.assoc_opt fn replacements with
                       | Some v' -> v'
                       | None -> v)
         | None -> v) field_names values)
     | _ -> raise (EvalError (Printf.sprintf
         "'%s' cannot be updated: it has no named fields" name)))
  | MapLit kvs ->
    VMap (map_of_pairs (List.map (fun (k, e) -> (k, eval env e)) kvs))
  | Field (e, label) ->
    (* A type's derived decoder: `Pod.decoder`. Resolved from the type's own
       definition rather than bound as a value, so it costs nothing until it
       is named and a recursive type can still have one. *)
    (match strip_located e, label with
     | Constr tname, "decoder" when Hashtbl.mem derivable tname ->
       !derive_decoder tname
     | Constr tname, "encoder" when Hashtbl.mem derivable tname ->
       !derive_encoder tname
     | Constr tname, "usage" when Hashtbl.mem derivable tname ->
       !derive_usage tname
     | Constr tname, "spec" when Hashtbl.mem derivable tname ->
       !derive_spec tname
     | Constr tname, "reader" when Hashtbl.mem derivable tname ->
       !derive_reader tname
     | _ ->
    (* No VMap case: dot access on a Map is rejected by the typechecker.
       VRecord is how imported module namespaces are reached (FS.cwd). *)
    (match eval env e with
     | VRecord kvs ->
       (match List.assoc_opt label kvs with
        | Some v -> v
        | None   ->
          raise (EvalError (Printf.sprintf "no field '%s'%s"
            label (Util.hint label (List.map fst kvs)))))
     | VConstr (name, vals) ->
       (match Hashtbl.find_opt constr_fields name with
        | Some names ->
          (match find_field_index names label with
           | Some i ->
             (match List.nth_opt vals i with
              | Some v -> v
              | None   -> raise (EvalError (Printf.sprintf
                  "constructor '%s' is not fully applied" (Ctor.name name))))
           | None -> raise (EvalError (Printf.sprintf
               "constructor '%s' has no field named '%s'" (Ctor.name name) label)))
        | None -> raise (EvalError (Printf.sprintf
            "constructor '%s' has no named fields" (Ctor.name name))))
     | _ -> raise (EvalError "field access on non-record")))
  | Seq (a, b) ->
    ignore (eval env a); eval_at tail env b
  | ImportExpr _ ->
    raise (EvalError "import expressions must be handled by the runner")
  | RegexLit (pat, flags) ->
    let opts = String.to_seq flags |> Seq.flat_map (function
      | 'i' -> List.to_seq [`CASELESS]
      | 'm' -> List.to_seq [`MULTILINE]
      | 's' -> List.to_seq [`DOTALL]
      | _   -> List.to_seq []) |> List.of_seq
    in
    (try VRegex (Re.compile (Re.Pcre.re ~flags:opts pat))
     with Re.Pcre.Parse_error ->
       raise (EvalError (Printf.sprintf "invalid regex: r/%s/%s" pat flags)))
  | RunCmd (e, allow) ->
    let cmd = match eval env e with
      | VString s -> s
      | _ -> raise (EvalError "$(…) requires a string")
    in
    perform_shell "Shell!run" allow (VString cmd)
  | RunQuery (e, allow) ->
    let cmd = match eval env e with
      | VString s -> s
      | _ -> raise (EvalError "$?(…) requires a string")
    in
    perform_shell "Shell!capture" allow (VString cmd)
  | Handle (body_expr, cases) ->
    let effect_cases = List.filter_map (function
      | Ast.EffectCase (n, p, k, b) -> Some (n, p, k, b)
      | _ -> None) cases in
    let return_case = List.find_opt (function
      | Ast.ReturnCase _ -> true | _ -> false) cases in
    let apply_return v =
      match return_case with
      | None -> v
      | Some (Ast.ReturnCase (p, b)) -> eval (bind_pat p v env) b
      | Some (Ast.EffectCase _) -> assert false
    in
    observed (fun () -> handled (fun () ->
    Effect.Deep.match_with (fun () -> eval env body_expr) ()
      { Effect.Deep.
          retc = apply_return;
          exnc = raise;
          effc = fun (type a) (eff : a Effect.t) ->
            match eff with
            | WandEffect (op, arg) ->
              let rec try_cases = function
                | [] -> (None : ((a, value) Effect.Deep.continuation -> value) option)
                | (name, arg_pat, cont_name, case_body) :: rest ->
                  if name <> op then try_cases rest
                  else
                    match try_match arg_pat arg env with
                    | None -> try_cases rest
                    | Some env' ->
                      Some (fun (k : (a, value) Effect.Deep.continuation) ->
                        (* An case that answers without resuming ends the body
                           it was handling. The body may be holding something
                           that has to be given back -- a lock, a temp file --
                           and a continuation that is simply dropped runs no
                           cleanup at all, not even when it is collected. So
                           the abandoned region is unwound deliberately.

                           Cleanup runs here, inside this case, which is what
                           makes it visible: a release that performs an effect
                           of its own reaches the same handlers the acquiring
                           code saw, rather than whatever happens to be
                           installed later. Discontinuing returns the value
                           the unwinding produced; it is discarded, and the
                           case answers with its own. *)
                        let resumed = ref false in
                        let cont =
                          VBuiltin (fun v ->
                            resumed := true;
                            Effect.Deep.continue k v)
                        in
                        let answer = eval ((cont_name, cont) :: env') case_body in
                        (* Resuming consumes the continuation, so only an case
                           that never did has one left to discontinue.

                           Measured against OCaml itself, four ways, because
                           the obvious one is wrong: an case that *resumes*
                           runs cleanup and keeps its value; one that *drops*
                           the continuation runs no cleanup at all, not even
                           after a full GC; one that *discontinues* runs
                           cleanup but unwinds past the case, losing its
                           value; and one that discontinues and catches --
                           this -- gets both, because `discontinue` returns
                           to the case rather than transferring away from
                           it. *)
                        if not !resumed then
                          (try ignore (Effect.Deep.discontinue k Abandoned)
                           with e when is_abandoned e -> ());
                        answer)
              in
              try_cases effect_cases
            | _ -> None
      }))
  | RawString s -> VString s
  | Interp (parts, tail) | RawInterp (parts, tail) ->
    let buf = Buffer.create 32 in
    List.iter (fun (lit, e) ->
      Buffer.add_string buf lit;
      Buffer.add_string buf (to_text (eval env e))
    ) parts;
    Buffer.add_string buf tail;
    VString (Buffer.contents buf)
  | CmdInterp (parts, tail) ->
    let buf = Buffer.create 32 in
    List.iter (fun (lit, e, h) ->
      Buffer.add_string buf lit;
      let v = to_text (eval env e) in
      Buffer.add_string buf
        (match (h : Token.hole) with
         | Token.Source    -> v
         | Token.Arg       -> shell_quote v
         | Token.Inside q  -> quote_within q v)
    ) parts;
    Buffer.add_string buf tail;
    VString (Buffer.contents buf)
  | Contract (reqs, ens, body) ->
    List.iter (fun req ->
      match eval env req with
      | VBool true  -> ()
      | VBool false -> raise (EvalError (Printf.sprintf
          "precondition failed: %s" (Ast.show req)))
      | _ -> assert false
    ) reqs;
    let v = eval env body in
    List.iter (fun e ->
      let env' = ("result", v) :: env in
      match eval env' e with
      | VBool true  -> ()
      | VBool false -> raise (EvalError (Printf.sprintf
          "postcondition failed: %s" (Ast.show e)))
      | _ -> assert false
    ) ens;
    v
  | Try e ->
    let c = loc_cell () in
    let line = c.at_line and col = c.at_col in
    let restore v = c.at_line <- line; c.at_col <- col; v in
    restore @@
    Effect.Deep.match_with (fun () -> eval env e) ()
      { Effect.Deep.
          retc = (fun v -> VConstr (Ctor.Builtin "Ok", [v]));
          exnc = (function
            | EvalError msg -> VConstr (Ctor.Builtin "Error", [VString (Util.strip_loc_prefix msg)])
            | Failure  msg  -> VConstr (Ctor.Builtin "Error", [VString (Util.strip_loc_prefix msg)])
            | exn           -> raise exn);
          effc = fun (type a) (_ : a Effect.t) ->
            (None : ((a, value) Effect.Deep.continuation -> value) option) }
  | With (resource, p, body) ->
    (* Acquire, run, release -- and release however the body leaves: a
       value, a raise, or a handler that answered without resuming and
       unwound it. Fun.protect covers all three, the last because an
       abandoned region is torn down deliberately rather than dropped. *)
    (match eval env resource with
     | VResource (acquire, release) ->
       (* An acquire runs to the end for the same reason a release does. The
          resource becomes real partway through it -- the file exists, the
          lock is taken -- and only the value it returns lets the release
          reach that resource. An interrupt taken between those two points
          leaves something held that nothing can now give back, which is the
          leak this bracket exists to prevent. Deferred, the interrupt is
          taken on the first step of the body instead, with the release
          already installed. *)
       let held = defer_interrupts (fun () -> apply acquire VUnit) in
       Fun.protect
         (* A release runs to the end even while the program is stopping.
            It is ordinary evaluation, so without this the interrupt would
            land in the middle of the cleanup it triggered and leave the
            resource half-released -- which is worse than not having tried.
            Someone who asks twice gets an immediate stop from the signal
            handler; that is the way out of a release that hangs. *)
         ~finally:(fun () -> defer_interrupts (fun () -> ignore (apply release held)))
         (fun () -> eval (bind_pat p held env) body)
     | other ->
       raise (EvalError (Printf.sprintf
         "with expects a resource, got %s" (show_value other))))
  | Annot (_, e) -> eval_at tail env e
  | Located (loc, e) ->
    let c = loc_cell () in
    if tail then (mark_loc c loc; eval_tail env e)
    else begin
      let line = c.at_line and col = c.at_col in
      mark_loc c loc;
      let v = eval env e in
      (* Only on the way out through a value. An error on its way past wants
         the position it was raised at, not the one being returned to. *)
      c.at_line <- line;
      c.at_col <- col;
      v
    end

(* Build a record constructor's value from the fields a construction names.
   Takes the identity rather than the name, so a qualified construction can
   say which module's constructor it means. *)
and eval_constr_app env c fields =
  let name = Ctor.name c in
  let provided = List.filter_map (fun (fname_opt, e) ->
    match fname_opt with
    | Some fname -> Some (fname, eval env e)
    | None -> None
  ) fields in
  (match Hashtbl.find_opt constr_fields c with
   | None -> raise (EvalError (Printf.sprintf "unknown constructor '%s'%s"
       name (Util.hint name (List.map fst env))))
   | Some field_names ->
     let ordered = List.map (fun fname_opt ->
       match fname_opt with
       | None -> raise (EvalError (Printf.sprintf
           "constructor '%s' has an unnamed field" name))
       | Some fn ->
         (match List.assoc_opt fn provided with
          | Some v -> v
          | None ->
            (* Left out, so the declaration says what it holds. A default is
               a value written out, so it reads in an empty environment and
               the same way at every site that omits the field. *)
            (match List.assoc_opt fn (defaults_of c) with
             | Some d -> eval (ctor_env ()) d
             | None -> raise (EvalError (Printf.sprintf
                 "constructor '%s' missing field '%s'" name fn))))
     ) field_names in
     VConstr (c, ordered))

and apply vf vx =
  (* The call is left with work to do after this returns -- it is a builtin
     applying a function it was handed, or a caller evaluating the rest of
     an expression -- so the callee's position goes back where it was found.
     `apply_tail` is the same call with nothing to come back to. *)
  let c = loc_cell () in
  let line = c.at_line and col = c.at_col in
  let v = apply_tail vf vx in
  c.at_line <- line;
  c.at_col  <- col;
  v

and apply_tail vf vx =
  match vf with
  | VBuiltin f -> f vx
  | VFun (fenv, params, body) ->
    (match params with
     | []      -> raise (EvalError "function with no parameters")
     | [p]     -> eval_tail (bind_pat p vx fenv) body
     | p :: rest ->
       let env' = bind_pat p vx fenv in
       VFun (env', rest, body))
  | VFix (name, fenv, params, body) ->
    (* `vf` is the value being bound, so binding it costs nothing to build.
       Rebuilding it made a second copy of the same closure on every call,
       and going back through `apply_tail` made a `VFun` to carry it there.
       Neither outlived the call. *)
    let fenv' = (name, vf) :: fenv in
    (match params with
     | []        -> raise (EvalError "function with no parameters")
     | [p]       -> eval_tail (bind_pat p vx fenv') body
     | p :: rest -> VFun (bind_pat p vx fenv', rest, body))
  | VFixGroup (bindings, fenv, my_name) ->
    let fenv' = List.fold_left (fun acc (n, _, _) ->
      (n, VFixGroup (bindings, fenv, n)) :: acc) fenv bindings in
    let (_, params, body) = List.find (fun (n, _, _) -> n = my_name) bindings in
    apply_tail (VFun (fenv', params, body)) vx
  | VPartialConstr (name, 1, args) -> VConstr (name, args @ [vx])
  | VPartialConstr (name, n, args) -> VPartialConstr (name, n - 1, args @ [vx])
  | _ -> raise (EvalError "cannot apply a non-function")

and bind_pat ?(prefix = false) (p : pat) v (env : env) : env =
  match try_match ~prefix p v env with
  | Some env' -> env'
  | None      -> raise (EvalError "pattern match failure")

and eval_match (tail : bool) (env : env) sv cases =
  match cases with
  | [] -> raise (EvalError "non-exhaustive match")
  | (p, guard, body) :: rest ->
    (match try_match p sv env with
     | None      -> eval_match tail env sv rest
     | Some env' ->
       let passes = match guard with
         | None   -> true
         | Some g ->
           (match eval env' g with
            | VBool b -> b
            | _       -> raise (EvalError "guard must evaluate to a bool"))
       in
       if passes then eval_at tail env' body
       else eval_match tail env sv rest)

and eval_binop (env : env) op a b : value =
  match op with
  (* A sum of sizes is written in bytes, because a size holds one unit and
     `100MB + 4KB` fills two. `Size.format` is the readable spelling.

     Neither a size nor a duration has a value below zero, so a subtraction
     that would go under floors there -- the same answer `Duration.sub` and
     `Size.of_bytes` already give. *)
  | "+"  ->
    (match eval env a, eval env b with
     | VInt x,   VInt y   -> VInt (add_ovf x y)
     | VFloat x, VFloat y -> VFloat (x +. y)
     | VSize x,  VSize y  -> VSize (Printf.sprintf "%dB" (size_bytes x + size_bytes y))
     | VDuration x, VDuration y -> VDuration (format_dur_ms (parse_dur_ms x + parse_dur_ms y))
     (* A Duration moves an instant, from either side. The instant carries
        whole seconds, so a duration below a second moves it nowhere. *)
     | VDateTime x, VDuration d | VDuration d, VDateTime x ->
       VDateTime (datetime_of_epoch (datetime_epoch x + parse_dur_ms d / 1000))
     | _ -> raise (EvalError "'+' requires matching types"))
  | "-"  ->
    (match eval env a, eval env b with
     | VInt x,   VInt y   -> VInt (sub_ovf x y)
     | VFloat x, VFloat y -> VFloat (x -. y)
     | VSize x,  VSize y  ->
       VSize (Printf.sprintf "%dB" (max 0 (size_bytes x - size_bytes y)))
     | VDuration x, VDuration y ->
       VDuration (format_dur_ms (max 0 (parse_dur_ms x - parse_dur_ms y)))
     | VDateTime x, VDuration d ->
       VDateTime (datetime_of_epoch (datetime_epoch x - parse_dur_ms d / 1000))
     (* The length between two instants. It floors at zero like every other
        Duration subtraction, so a file stamped in the future reads as no
        age rather than a negative one. *)
     | VDateTime x, VDateTime y ->
       VDuration (format_dur_ms (max 0 ((datetime_epoch x - datetime_epoch y) * 1000)))
     | _ -> raise (EvalError "'-' requires matching types"))
  | "*"  ->
    (match eval env a, eval env b with
     | VInt x,   VInt y   -> VInt (mul_ovf x y)
     | VFloat x, VFloat y -> VFloat (x *. y)
     | _ -> raise (EvalError "'*' requires matching numeric types"))
  | "/"  ->
    (match eval env a, eval env b with
     | VInt _,   VInt 0   -> raise (EvalError "division by zero")
     | VInt x,   VInt y   -> VInt (div_ovf x y)
     | VFloat x, VFloat y -> VFloat (x /. y)
     | _ -> raise (EvalError "'/' requires matching numeric types"))
  | "%"  ->
    (match eval env a, eval env b with
     | VInt _,   VInt 0   -> raise (EvalError "modulo by zero")
     | VInt x,   VInt y   -> VInt (x mod y)
     | _ -> raise (EvalError "'%' requires Int operands"))
  | "++" ->
    (match eval env a, eval env b with
     | VString s1, VString s2 -> VString (s1 ^ s2)
     | _ -> raise (EvalError "'++' requires strings"))
  | "::" ->
    let vh = eval env a in
    (match eval env b with
     | VList vs -> VList (vh :: vs)
     | _        -> raise (EvalError "':' right side must be a list"))
  | "==" -> VBool (wand_equal (eval env a) (eval env b))
  | "!=" -> VBool (not (wand_equal (eval env a) (eval env b)))
  (* Normalized, so `90s > 1min` and two spellings of one instant compare
     as one value. The `Ord` constraint has already refused every type
     that has no order. *)
  | "<"  -> VBool (wand_order (eval env a) (eval env b) <  0)
  | ">"  -> VBool (wand_order (eval env a) (eval env b) >  0)
  | "<=" -> VBool (wand_order (eval env a) (eval env b) <= 0)
  | ">=" -> VBool (wand_order (eval env a) (eval env b) >= 0)
  | "&&" ->
    (match eval env a with
     | VBool false -> VBool false
     | VBool true  ->
       (match eval env b with
        | VBool b -> VBool b
        | _       -> raise (EvalError "'&&' requires bools"))
     | _ -> raise (EvalError "'&&' requires bools"))
  | "||" ->
    (match eval env a with
     | VBool true  -> VBool true
     | VBool false ->
       (match eval env b with
        | VBool b -> VBool b
        | _       -> raise (EvalError "'||' requires bools"))
     | _ -> raise (EvalError "'||' requires bools"))
  | "|>" ->
    let va = eval env a in
    (match b with
     | RunCmd (e, allow) ->
       let cmd = match eval env e with
         | VString s -> s
         | _ -> raise (EvalError "$(…) requires a string")
       in
       let stdin = to_text va in
       perform_shell "Shell!run" allow (VTuple [VString cmd; VString stdin])
     | RunQuery (e, allow) ->
       let cmd = match eval env e with
         | VString s -> s
         | _ -> raise (EvalError "$?(…) requires a string")
       in
       let stdin = to_text va in
       perform_shell "Shell!capture" allow (VTuple [VString cmd; VString stdin])
     | _ ->
       let vf = eval env b in
       apply vf va)
  | op -> raise (EvalError (Printf.sprintf "unknown operator '%s'" op))

(* Builtins that reach outside the program perform an effect rather than
   acting directly, so a handler can see, log, or replace what they do.
   `performing` registers the real implementation and hands back a builtin
   that performs in its place; the default handler looks the implementation
   up again. Wrapping at registration keeps the two from drifting apart. *)
let direct_impl : (string, value -> value) Hashtbl.t = Hashtbl.create 32

(* Wait, in slices, so that Ctrl-C during a sleep is taken at once rather
   than after the whole duration. A sleep is exactly the wrong thing to make
   uninterruptible.

   The slices are also what keeps this a relative wait with no clock read in
   it: each one is a fresh `nanosleep`, and the total is the sum. Reading a
   civil clock to find the remainder would make a machine that syncs its
   clock mid-sleep wake early or late.

   `Unix.sleepf` waits at least what it is given, so the total is a floor,
   which is what `Clock.sleep` promises. A zero or negative duration waits
   not at all and still performed the effect to get here. *)
let sleep_ms ms =
  let slice = 0.05 in
  let remaining = ref (float_of_int ms /. 1000.) in
  while !remaining > 0.0 do
    check_interrupt ();
    let this = if !remaining < slice then !remaining else slice in
    (try Unix.sleepf this with Unix.Unix_error (Unix.EINTR, _, _) -> ());
    remaining := !remaining -. this
  done;
  check_interrupt ()

(* Milliseconds since an arbitrary point in this run, from a clock that no
   NTP correction can move. `lib/ext/clock.c` states which clock each
   platform uses and why. *)
external elapsed_ms : unit -> int = "wand_elapsed_ms"

let performing name f =
  Hashtbl.replace direct_impl name f;
  VBuiltin (fun v -> Effect.perform (WandEffect (name, v)))

(* Read-only filesystem operations. They are named here and performed as
   effects below, so a trace can report what a script looked at, not only
   what it changed. *)

let fs_cwd_impl = function
  | VUnit -> VPath (Sys.getcwd ())
  | _ -> raise (EvalError "fs_cwd: expected Unit")

let fs_mtime_impl = function
  | VString p | VPath p ->
    (match (try Ok (Unix.stat p) with Unix.Unix_error (e, _, _) ->
      Error ("mtime: " ^ Unix.error_message e)) with
     | Error m -> raise (EvalError m)
     | Ok st ->
       let tm = Unix.gmtime st.Unix.st_mtime in
       VDateTime (Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
         (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
         tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec))
  | _ -> raise (EvalError "fs_mtime: expected Path")

let fs_size_impl = function
  | VString p | VPath p ->
    (match (try Ok (Unix.stat p) with Unix.Unix_error (e, _, _) ->
      Error ("size: " ^ Unix.error_message e)) with
     | Error m -> raise (EvalError m)
     (* In bytes, the only unit `stat` gives. `Size.format` is the readable
        spelling, and a threshold is written as the literal it is:
        `size < 4KB`. *)
     | Ok st   -> VSize (Printf.sprintf "%dB" st.Unix.st_size))
  | _ -> raise (EvalError "fs_size: expected Path")

(* ── String primitive helpers ─────────────────────────────────────────────── *)

let str_split_impl delim str =
  let dlen = String.length delim in
  let slen = String.length str in
  if dlen = 0 then
    List.init slen (fun i -> VString (String.make 1 str.[i]))
  else begin
    let result = ref [] in
    let start = ref 0 in
    let i = ref 0 in
    while !i <= slen - dlen do
      if String.sub str !i dlen = delim then begin
        result := VString (String.sub str !start (!i - !start)) :: !result;
        i := !i + dlen;
        start := !i
      end else
        incr i
    done;
    result := VString (String.sub str !start (slen - !start)) :: !result;
    List.rev !result
  end

let str_replace_impl old_ new_ str =
  let olen = String.length old_ in
  let slen = String.length str in
  if olen = 0 then str
  else begin
    let buf = Buffer.create slen in
    let i = ref 0 in
    while !i <= slen - olen do
      if String.sub str !i olen = old_ then begin
        Buffer.add_string buf new_;
        i := !i + olen
      end else begin
        Buffer.add_char buf str.[!i];
        incr i
      end
    done;
    if !i < slen then
      Buffer.add_string buf (String.sub str !i (slen - !i));
    Buffer.contents buf
  end

let str_contains_impl needle haystack =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen = 0 then true
  else if nlen > hlen then false
  else begin
    let found = ref false in
    for i = 0 to hlen - nlen do
      if String.sub haystack i nlen = needle then found := true
    done;
    !found
  end

let str_trim_left s =
  let n = String.length s in
  let i = ref 0 in
  while !i < n && (let c = s.[!i] in c = ' ' || c = '\t' || c = '\n' || c = '\r') do incr i done;
  String.sub s !i (n - !i)

let str_trim_right s =
  let n = String.length s in
  let i = ref (n - 1) in
  while !i >= 0 && (let c = s.[!i] in c = ' ' || c = '\t' || c = '\n' || c = '\r') do decr i done;
  String.sub s 0 (!i + 1)

let str_repeat n s =
  let buf = Buffer.create (max 0 (String.length s * n)) in
  for _ = 1 to n do Buffer.add_string buf s done;
  Buffer.contents buf

let str_reverse s =
  let n = String.length s in
  String.init n (fun i -> s.[n - 1 - i])

let path_normalize s =
  let is_abs = String.length s > 0 && s.[0] = '/' in
  let is_cur = (String.length s >= 2 && s.[0] = '.' && s.[1] = '/') || s = "." in
  let parts = String.split_on_char '/' s in
  let rec process acc = function
    | [] -> List.rev acc
    | ("" | ".") :: rest -> process acc rest
    | ".." :: rest ->
      (match acc with
       | [] | ".." :: _ -> process (".." :: acc) rest
       | _ :: tl -> process tl rest)
    | p :: rest -> process (p :: acc) rest
  in
  let parts = process [] parts in
  let joined = String.concat "/" parts in
  if is_abs then "/" ^ joined
  else if is_cur then "./" ^ joined
  else joined

let exe_args_ref : string list ref = ref []

(* One dotenv source into its (key, value) pairs: `export ` stripped, blank
   and `#` lines skipped, a quoted value unquoted. Shared by
   `Env.parse_dotenv` and `Env.load_file`, so the two cannot read the same
   file differently. *)
let dotenv_pairs src =
  List.filter_map (fun line ->
    let line = String.trim line in
    let line =
      if String.length line > 7 && String.sub line 0 7 = "export " then
        String.trim (String.sub line 7 (String.length line - 7))
      else line
    in
    if line = "" || line.[0] = '#' then None
    else match String.split_on_char '=' line with
      | [] | [""] -> None
      | key :: rest ->
        let key = String.trim key in
        if key = "" then None
        else
          let raw = String.concat "=" rest in
          let value =
            let n = String.length raw in
            if n >= 2 && ((raw.[0] = '"' && raw.[n-1] = '"')
                       || (raw.[0] = '\'' && raw.[n-1] = '\'')) then
              String.sub raw 1 (n - 2)
            else raw
          in
          Some (key, value))
    (String.split_on_char '\n' src)

(* Slurp a file whole; a `Sys_error` is the caller's to catch. *)
let read_whole_file path = In_channel.with_open_text path In_channel.input_all

(* ── CSV helpers ──────────────────────────────────────────────────────────── *)

let csv_parse_string sep src =
  (* RFC 4180: quoted fields, "" = escaped quote, \r\n or \n line endings *)
  let src = (* normalise line endings *)
    let n = String.length src in
    let buf = Buffer.create n in
    let i = ref 0 in
    while !i < n do
      if src.[!i] = '\r' && !i + 1 < n && src.[!i + 1] = '\n' then
        (Buffer.add_char buf '\n'; i := !i + 2)
      else
        (Buffer.add_char buf src.[!i]; incr i)
    done;
    Buffer.contents buf
  in
  let n = String.length src in
  let rows = ref [] in
  let row  = ref [] in
  let field = Buffer.create 16 in
  let i = ref 0 in
  let sep_char = if String.length sep > 0 then sep.[0] else ',' in
  let commit_field () =
    row := Buffer.contents field :: !row;
    Buffer.clear field
  in
  let commit () =
    commit_field ();
    rows := List.rev !row :: !rows;
    row := []
  in
  while !i < n do
    let c = src.[!i] in
    if c = '"' then begin
      (* quoted field *)
      incr i;
      let continue_ = ref true in
      while !continue_ && !i < n do
        if src.[!i] = '"' then begin
          if !i + 1 < n && src.[!i + 1] = '"' then begin
            Buffer.add_char field '"'; i := !i + 2
          end else begin
            incr i; continue_ := false
          end
        end else begin
          Buffer.add_char field src.[!i]; incr i
        end
      done
    end else if c = sep_char then begin
      commit_field (); incr i
    end else if c = '\n' then begin
      commit (); incr i
    end else begin
      Buffer.add_char field c; incr i
    end
  done;
  (* commit trailing content (file may not end with newline) *)
  if Buffer.length field > 0 || !row <> [] then commit ();
  List.rev !rows

let csv_stringify_rows sep rows =
  let sep_char = if String.length sep > 0 then sep.[0] else ',' in
  let needs_quoting s =
    String.exists (fun c -> c = sep_char || c = '"' || c = '\n' || c = '\r') s
  in
  let quote_field s =
    if needs_quoting s then
      "\"" ^ String.concat "" (List.map (fun c ->
        if c = '"' then "\"\"" else String.make 1 c)
        (List.init (String.length s) (String.get s))) ^ "\""
    else s
  in
  String.concat "\n" (List.map (fun row ->
    String.concat sep (List.map quote_field row)) rows)

(* Lexing one domain literal out of a string, keeping the lexer's complaint
   when it has one. `256.0.0.1` and `:99999` are not merely unreadable: the
   lexer knows an octet is 0-255 and a port is 0-65535, and a reader that
   answers "cannot parse" has thrown away the only sentence that says what to
   do about it. Whoever gets the message -- a person or a model -- is then
   guessing at a rule the program already knows. *)
let lex_single s : (Token.t, string option) result =
  match Lexer.tokenize_plain s with
  | [tok; Token.EOF] -> Ok tok
  | _ -> Error None
  | exception Lexer.LexError (_, msg) -> Error (Some msg)

let try_lex_single s =
  match lex_single s with Ok tok -> Some tok | Error _ -> None

(* `String.to_<domain>`: read the string exactly as the lexer would, and pass
   on what the lexer said when it had something specific to say. *)
let to_domain ?shown name build s =
  let shown = Option.value shown ~default:s in
  let cannot () =
    VConstr (Ctor.Builtin "Error", [VString (Printf.sprintf "cannot parse %S as %s" shown name)])
  in
  match lex_single s with
  | Ok tok -> (match build tok with Some v -> VConstr (Ctor.Builtin "Ok", [v]) | None -> cannot ())
  | Error (Some why) -> VConstr (Ctor.Builtin "Error", [VString why])
  | Error None -> cannot ()

(* A port is `:8080` in wand's own notation; a document or an environment
   variable holds the bare number. Adding the colon is how the second is read
   as the first. *)
let port_text s =
  let s = String.trim s in
  if String.length s > 0 && s.[0] = ':' then s else ":" ^ s

(* ── Decoding ────────────────────────────────────────────────────────────── *)

(* Reading data that arrived untyped. Every backend -- JSON, TOML, CSV rows,
   the lines of a command's output -- presents what it read in JSON's shape,
   so there is one set of combinators rather than one per format.

   A decoder is handed the path it stands at, kept innermost-first, so a
   failure deep inside a document can say where it happened:

       .items[3].metadata.name: expected String, got Int

   Naming the field is the whole point. A decoder that reported only the
   type would leave the reader doing by hand what a scrape already made them
   do -- find which of forty fields was wrong. *)

let path_string segs =
  match segs with [] -> "" | _ -> String.concat "" (List.rev segs)

let decode_error path msg =
  match path with
  | [] -> Error msg
  | _  -> Error (path_string path ^ ": " ^ msg)

(* What to call a JSON value in a message: the wand type where there is one,
   since the reader is looking for a wand type. *)
let json_kind (j : Yojson.Basic.t) =
  match j with
  | `Null     -> "null"
  | `Bool _   -> "Bool"
  | `Int _    -> "Int"
  | `Float _  -> "Float"
  | `String _ -> "String"
  | `List _   -> "a list"
  | `Assoc _  -> "an object"

let expected what path j =
  match j with
  (* A string that failed is worth quoting: the reader wants to see what was
     there, not to be told a second time that it was text. *)
  | `String s -> decode_error path (Printf.sprintf "expected %s, got %S" what s)
  | _ -> decode_error path (Printf.sprintf "expected %s, got %s" what (json_kind j))

(* A decoder reads a value out of text, and never the other way round.
   Backends that carry types -- JSON, TOML -- hand over an Int as an Int;
   backends that do not -- a CSV cell, a line of output -- hand over the
   text, and `Decode.int` reads it exactly as `String.to_int` would. So one
   decoder serves a document and a command's output both.

   The reverse is not allowed: `Decode.string` does not accept a number and
   stringify it. That direction would make `string` accept anything, which
   is the scrape it exists to replace. *)
let from_text parse (j : Yojson.Basic.t) =
  match j with `String s -> parse (String.trim s) | _ -> None

(* Every backend presents what it read in this shape. TOML carries its own
   types across; a date has no JSON of its own and comes over as the text it
   was written as, which is what `Decode.date` reads anyway. *)
let rec json_of_toml (v : Toml.Types.value) : Yojson.Basic.t =
  match v with
  | Toml.Types.TBool b   -> `Bool b
  | Toml.Types.TInt n    -> `Int n
  | Toml.Types.TFloat f  -> `Float f
  | Toml.Types.TString s -> `String s
  | Toml.Types.TDate d   -> `String (Toml.Printer.string_of_value (Toml.Types.TDate d))
  | Toml.Types.TTable tbl ->
    `Assoc (List.map (fun (k, v) ->
      (Toml.Types.Table.Key.to_string k, json_of_toml v))
      (Toml.Types.Table.to_list tbl))
  | Toml.Types.TArray arr ->
    `List (List.map json_of_toml (toml_array_values arr))

(* A domain literal decodes as itself: the string is lexed exactly as it
   would be if it had been written in the source, so `"30s"` in a document
   and `30s` in a script become the same Duration. *)
let decode_lexed name build (j : Yojson.Basic.t) path =
  match j with
  | `String s ->
    (match try_lex_single s with
     | Some tok ->
       (match build tok with
        | Some v -> Ok v
        | None -> decode_error path (Printf.sprintf "expected %s, got %S" name s))
     | None -> decode_error path (Printf.sprintf "expected %s, got %S" name s))
  | _ -> expected name path j



(* ── Par ─────────────────────────────────────────────────────────────────── *)

(* Fork-join, and nothing else. Workers never outlive the call, there is no
   handle to a running one, and these two functions are the only way to start
   any -- so there is no unstructured concurrency to build out of them.

   A worker does not handle its own effects. An effect performed on one
   domain cannot reach a handler on another, and a handler is not a value
   that can be copied there, so a worker hands each effect back to the
   calling domain and waits while it is performed there, inside whatever
   handlers the program already installed. Mocks, rehearsals and traces
   therefore reach into a worker exactly as they do anywhere else, and
   effects happen one at a time rather than racing.

   This runs where it is called rather than through an effect of its own: an
   effect would be caught by the outermost handler, and performing from
   inside that handler is outside the very handlers the work should see. *)
let par_run limit f items ~collect =
  let items = Array.of_list items in
  let n = Array.length items in
  let results = Array.make (max n 1) VUnit in
  let next = Atomic.make 0 in
  let live = Atomic.make 0 in
  let m = Mutex.create () in
  let ready = Condition.create () in
  let pending : (string * value * string list option) option ref = ref None in
  let reply : (value, exn) result option ref = ref None in

  (* One worker at a time may have a request outstanding. There is a single
     request slot and a single reply slot, and a reply carries no idea of who
     asked: with two workers waiting, either could take an answer meant for
     the other, leaving the rightful one waiting for a reply that has already
     been consumed. Held across the whole round trip, so a worker that has
     asked is the only one that can be answered. *)
  let speaking = Mutex.create () in
  let forward name arg =
    Mutex.lock speaking;
    let r =
      Fun.protect ~finally:(fun () -> Mutex.unlock speaking) (fun () ->
        Mutex.lock m;
        (* The worker's ambient allowlist rides along: the pump re-performs
           on the main domain, where the worker's domain-local value is
           invisible. *)
        pending := Some (name, arg, Domain.DLS.get ambient_shell_allow);
        Condition.broadcast ready;
        while !reply = None do Condition.wait ready m done;
        let answer = Option.get !reply in
        reply := None;
        Condition.broadcast ready;
        Mutex.unlock m;
        answer)
    in
    match r with Ok v -> v | Error e -> raise e
  in

  let record i outcome = results.(i) <- outcome in
  let finish () =
    Mutex.lock m;
    ignore (Atomic.fetch_and_add live (-1));
    Condition.broadcast ready;
    Mutex.unlock m
  in
  let outcome_of run =
    match run () with
    | v -> if collect then VConstr (Ctor.Builtin "Ok", [v]) else VUnit
    | exception EvalError msg ->
      (* A failure becomes a value, so it says what went wrong rather than
         where, exactly as `try` does. *)
      if collect then VConstr (Ctor.Builtin "Error", [VString (Util.strip_loc_prefix msg)])
      else VUnit
  in
  (* Effects go back to the calling domain, where the handlers are. *)
  let worker_forwarding () =
    let rec loop () =
      let i = Atomic.fetch_and_add next 1 in
      if i < n then begin
        let run () =
          Effect.Deep.match_with (fun () -> apply f items.(i)) ()
            { Effect.Deep.
                retc = (fun v -> v);
                exnc = raise;
                effc = fun (type a) (eff : a Effect.t) ->
                  match eff with
                  | WandEffect (name, arg) ->
                    Some (fun (k : (a, value) Effect.Deep.continuation) ->
                      match forward name arg with
                      | v -> Effect.Deep.continue k v
                      | exception (EvalError _ as e) ->
                        Effect.Deep.discontinue k e)
                  | _ -> None }
        in
        record i (outcome_of run);
        loop ()
      end
    in
    Fun.protect ~finally:finish loop
  in
  (* Nothing is watching: the worker performs its own effects. *)
  let worker_direct () =
    let rec loop () =
      let i = Atomic.fetch_and_add next 1 in
      if i < n then begin
        record i (outcome_of (fun () -> apply f items.(i)));
        loop ()
      end
    in
    Fun.protect ~finally:finish loop
  in

  (* When nothing is watching, a worker performs its own effects on its own
     domain and the work genuinely overlaps. When a handler is in scope -- a
     mock, a rehearsal, a trace -- effects come back here instead, because a
     handler cannot be reached from another domain. That costs the overlap,
     and buys the guarantee that moving work into Par cannot escape whoever
     is watching. Nobody rehearses for speed. *)
  let watched = Atomic.get observers > 0 in
  let worker () =
    if watched then worker_forwarding ()
    else ignore (!with_default_handler (fun () -> worker_direct (); VUnit))
  in
  if n = 0 then (if collect then VList [] else VUnit)
  else begin
    let count = max 1 (min limit n) in
    Atomic.set live count;
    let domains = List.init count (fun _ -> Domain.spawn worker) in
    let rec pump () =
      Mutex.lock m;
      while !pending = None && Atomic.get live > 0 do Condition.wait ready m done;
      match !pending with
      | None -> Mutex.unlock m
      | Some (name, arg, allow) ->
        pending := None;
        Mutex.unlock m;
        let answer =
          match perform_shell name allow arg with
          | v -> Ok v
          | exception (EvalError _ as e) -> Error e
        in
        Mutex.lock m;
        reply := Some answer;
        Condition.broadcast ready;
        Mutex.unlock m;
        pump ()
    in
    (* Answering workers and joining them is one stretch that has to finish:
       see `defer_interrupts`. *)
    defer_interrupts (fun () ->
    pump ();
    (* Every worker is joined before this returns, interrupted or not:
       workers never outlive the call, and an interrupt is not an excuse to
       leave one running. A worker that stopped because the program is
       stopping has already released what it held; the calling domain
       raises on its own next step, from its own stack. *)
    List.iter (fun d ->
      match Domain.join d with
      | () -> ()
      | exception Interrupted _ -> ()) domains);
    if collect then VList (Array.to_list (Array.sub results 0 n)) else VUnit
  end

(* Run every thunk at once and answer with the first to finish.

   No worker limit, breaking `par_map`'s convention on purpose: the count is
   the length of the list and is visible at the call site, so there is
   nothing left for the caller to state. A race with a limit below the list
   length would be a staged race, which nobody wants.

   First to *finish*, not first to succeed. A loser that raises is
   discarded. A winner that raises comes back as `Error`, the way `par_map`
   puts a raise in the element's place rather than failing the call.

   Cancellation is cooperative, and it is the machinery Ctrl-C already uses.
   The winner's completion sets each loser's cancel flag; the loser raises
   at its next checkpoint, releases what it holds, and is joined. Every
   worker is joined before this returns -- workers never outlive the call,
   which is the invariant that lets `Par` have no handles and nothing to
   await. What a race bounds is when you get the answer, not when the
   machine goes quiet: a loser blocked in a subprocess finishes that
   subprocess. `Shell.timeout` inside the thunk is how to bound that.

   Under a handler, refused. An effect cannot reach a handler on another
   domain, so the branches cannot run where they were written; the race
   would collapse to its first thunk and say nothing, and a test of racing
   code would then test one branch and pass. `Par.timeout` refuses for the
   same reason.

   A rehearsal and a trace are observers as well, and are not refused: each
   reports what the work would do, and the collapse costs the report
   nothing. The race is then left-biased and deterministic -- the first
   thunk is the one that finishes first. *)
let par_race thunks =
  let items = Array.of_list thunks in
  let n = Array.length items in
  let outcome_of run =
    match run () with
    | v -> VConstr (Ctor.Builtin "Ok", [v])
    | exception EvalError msg ->
      VConstr (Ctor.Builtin "Error", [VString (Util.strip_loc_prefix msg)])
  in
  if n = 0 then
    VConstr (Ctor.Builtin "Error", [VString "race: nothing to race"])
  else if Atomic.get handlers > 0 then
    raise (EvalError
      "a race inside a handler runs its first thunk only. Move the handler \
       inside each thunk, or take it off.")
  else if Atomic.get observers > 0 then
    outcome_of (fun () -> apply items.(0) VUnit)
  else with_race_running (fun () ->
    let flags = Array.init n (fun _ -> ref false) in
    let m = Mutex.create () in
    let done_ = Condition.create () in
    let winner = ref None in
    let worker i () =
      cancel_this_domain flags.(i);
      let result =
        ignore (!with_default_handler (fun () ->
          let o = outcome_of (fun () -> apply items.(i) VUnit) in
          Mutex.lock m;
          if !winner = None then winner := Some o;
          Condition.broadcast done_;
          Mutex.unlock m;
          VUnit));
        ()
      in
      result
    in
    let domains = Array.to_list (Array.init n (fun i -> Domain.spawn (worker i))) in
    (* Answering nothing and joining everything is one stretch that has to
       finish, as it is in `par_run`. *)
    defer_interrupts (fun () ->
      Mutex.lock m;
      while !winner = None do Condition.wait done_ m done;
      Mutex.unlock m;
      (* Whoever is still running has lost. *)
      Array.iter (fun f -> f := true) flags;
      List.iter (fun d ->
        match Domain.join d with
        | () -> ()
        (* A loser stopped where it stood. `Fun.Finally_raised` is the same
           thing seen through a bracket it was releasing. *)
        | exception Interrupted _ -> ()
        | exception Fun.Finally_raised (Interrupted _) -> ()) domains);
    match !winner with
    | Some o -> o
    | None -> VConstr (Ctor.Builtin "Error", [VString "race: no thunk finished"]))

(* ── Streams: running a terminal operation ────────────────────────────────
   A terminal operation performs one open-granularity effect per source --
   the answer is the line source: the default handler wraps the real
   channel, a mock answers with a plain list -- then pulls internally,
   running stages and the caller's closures from the ordinary stack, and
   releases on the way out however the run ends. *)

let stdin_streamed = Atomic.make false

let stream_provider (src : stream_source)
  : (unit -> value option) * (unit -> unit) =
  let of_vals vs =
    let rest = ref vs in
    ((fun () -> match !rest with [] -> None | v :: tl -> rest := tl; Some v),
     fun () -> ())
  in
  let of_channel ~close ic =
    ((fun () ->
        match In_channel.input_line ic with
        | Some l -> Some (VString l)
        | None -> None),
     if close then (fun () -> close_in_noerr ic) else (fun () -> ()))
  in
  match src with
  | SVals vs -> of_vals vs
  | SPull f -> (f, fun () -> ())
  | SFile p ->
    (match Effect.perform (WandEffect ("FS!stream_lines", VPath p)) with
     | VLineSource ic -> of_channel ~close:true ic
     | VList vs -> of_vals vs
     | _ -> raise (EvalError
         "stream_lines: the handler must answer with a list of lines"))
  | SStdin ->
    (match Effect.perform (WandEffect ("IO!stdin_lines", VUnit)) with
     | VLineSource ic ->
       (* The real stdin cannot be re-run; a mock can. The flag burns only
          on the real path, so tests replay freely. *)
       if Atomic.exchange stdin_streamed true then
         raise (EvalError
           "stdin has already been streamed once and cannot be re-run")
       else of_channel ~close:false ic
     | VList vs -> of_vals vs
     | _ -> raise (EvalError
         "stdin_lines: the handler must answer with a list of lines"))

let run_stream_terminal (desc : stream_desc) ~(on_item : value -> unit) : unit =
  let (pull, close) = stream_provider desc.s_source in
  let stages = List.map (function
    | StMap f    -> `Map f
    | StFilter f -> `Filter f
    | StTake n   -> `Take (ref n)) desc.s_stages in
  Fun.protect ~finally:close (fun () ->
    let stop = ref false in
    while not !stop do
      match pull () with
      | None -> stop := true
      | Some v0 ->
        let v = ref (Some v0) in
        List.iter (fun st ->
          match !v, st with
          | None, _ -> ()
          | Some x, `Map f -> v := Some (apply f x)
          | Some x, `Filter f ->
            (match apply f x with
             | VBool true -> ()
             | VBool false -> v := None
             | _ -> raise (EvalError
                 "Stream.filter: the predicate must return Bool"))
          | Some _, `Take r ->
            if !r <= 0 then v := None else decr r) stages;
        (match !v with Some x -> on_item x | None -> ());
        (* An exhausted take is a closed gate nothing later can pass, so
           stop pulling -- `take 100` of a 10GB file reads 100 lines. *)
        if List.exists (function `Take r -> !r <= 0 | _ -> false) stages
        then stop := true
    done)

let stream_builtins : env = [
  ("fs_stream_lines", VBuiltin (function
    | VPath p | VString p -> VStream { s_source = SFile p; s_stages = [] }
    | _ -> raise (EvalError "stream_lines: expected Path")));
  ("io_stdin_lines", VBuiltin (fun _ ->
    VStream { s_source = SStdin; s_stages = [] }));
  ("stream_of_list", VBuiltin (function
    | VList vs -> VStream { s_source = SVals vs; s_stages = [] }
    | _ -> raise (EvalError "Stream.of_list: expected List")));
  ("stream_map", VBuiltin (fun f -> VBuiltin (function
    | VStream d -> VStream { d with s_stages = d.s_stages @ [StMap f] }
    | _ -> raise (EvalError "Stream.map: expected Stream"))));
  ("stream_filter", VBuiltin (fun f -> VBuiltin (function
    | VStream d -> VStream { d with s_stages = d.s_stages @ [StFilter f] }
    | _ -> raise (EvalError "Stream.filter: expected Stream"))));
  ("stream_take", VBuiltin (function
    | VInt n -> VBuiltin (function
      | VStream d -> VStream { d with s_stages = d.s_stages @ [StTake n] }
      | _ -> raise (EvalError "Stream.take: expected Stream"))
    | _ -> raise (EvalError "Stream.take: expected Int")));
  ("stream_fold", VBuiltin (fun f -> VBuiltin (fun init -> VBuiltin (function
    | VStream d ->
      let acc = ref init in
      run_stream_terminal d ~on_item:(fun x -> acc := apply (apply f !acc) x);
      !acc
    | _ -> raise (EvalError "Stream.fold_left: expected Stream")))));
  ("stream_each", VBuiltin (fun f -> VBuiltin (function
    | VStream d ->
      run_stream_terminal d ~on_item:(fun x -> ignore (apply f x));
      VUnit
    | _ -> raise (EvalError "Stream.each: expected Stream"))));
  ("stream_to_list", VBuiltin (function
    | VStream d ->
      let acc = ref [] in
      run_stream_terminal d ~on_item:(fun x -> acc := x :: !acc);
      VList (List.rev !acc)
    | _ -> raise (EvalError "Stream.to_list: expected Stream")));
]

let stdlib_eval_env : env = [
  ("io_print",   VBuiltin (fun v -> Effect.perform (WandEffect ("IO!print",   v))));
  ("io_println", VBuiltin (fun v -> Effect.perform (WandEffect ("IO!println", v))));
  ("proc_exit",  performing "Proc!exit" (function VInt n -> raise (Interrupted n) | _ -> raise (EvalError "exit: expected Int")));
  (* A deadline on the commands a thunk runs. It is set for the extent of
     the call and taken off after, so a command outside the thunk waits as
     long as it takes.

     Only a timeout comes back as `Error`. Every other raise passes
     through: a command that exits non-zero has failed, not run late, and
     `$?()` is what asks about an exit code. *)
  ("shell_timeout", VBuiltin (function
    | VDuration d -> VBuiltin (fun thunk ->
      let saved = Domain.DLS.get shell_deadline in
      Domain.DLS.set shell_deadline (Some (parse_dur_ms d));
      let restore () = Domain.DLS.set shell_deadline saved in
      (match Fun.protect ~finally:restore (fun () -> apply thunk VUnit) with
       | v -> VConstr (Ctor.Builtin "Ok", [v])
       (* The raise carries a position by the time it gets here, and the
          marker sits after it. *)
       | exception EvalError msg
         when starts_with timeout_prefix (Util.strip_loc_prefix msg) ->
         VConstr (Ctor.Builtin "Error",
                  [VString (drop_prefix timeout_prefix
                              (Util.strip_loc_prefix msg))])))
    | _ -> raise (EvalError "Shell.timeout: expected a Duration")));
  (* Waiting is an effect, so a handler can answer it: a test that
     exercises an hour of backoff must not take an hour. *)
  ("clock_sleep", performing "Clock!sleep" (function
    | VDuration d -> sleep_ms (parse_dur_ms d); VUnit
    | _ -> raise (EvalError "Clock.sleep: expected Duration")));
  (* Reading the clock is an effect for the same reason waiting is: a
     handler can answer it, so a test pins the instant instead of arranging
     for one. UTC always -- a local reading would make one script answer
     differently on two machines. *)
  (* The reading behind `Clock.timed`. It is a primitive rather than a
     module export on purpose: two readings of a monotonic clock subtract
     soundly, and there is nothing else to do with one, so the only shape
     wand offers is the bracket. See `lib/ext/clock.c`. *)
  ("clock_elapsed", performing "Clock!elapsed" (function
    | VUnit -> VDuration (format_dur_ms (elapsed_ms ()))
    | _ -> raise (EvalError "Clock.timed: expected Unit")));
  ("clock_now", performing "Clock!now" (function
    | VUnit -> VDateTime (datetime_of_epoch (int_of_float (Unix.gettimeofday ())))
    | _ -> raise (EvalError "Clock.now: expected Unit")));
  ("option_get_exn", VBuiltin (function
    | VUnit -> raise (EvalError "Option.get!: called on None")
    | _ -> raise (EvalError "option_get_exn: expected Unit")));
  ("read_file",  VBuiltin (fun v -> Effect.perform (WandEffect ("FS!read_file",  v))));
  ("write_file", VBuiltin (fun path ->
    VBuiltin (fun content ->
      Effect.perform (WandEffect ("FS!write_file", VTuple [path; content])))));
  (* Result constructors *)
  ("Ok",    VPartialConstr (Ctor.Builtin "Ok",    1, []));
  ("Error", VPartialConstr (Ctor.Builtin "Error", 1, []));
  (* String primitives *)
  ("str_length", VBuiltin (function
    | VString s -> VInt (String.length s)
    | _ -> raise (EvalError "str_length: expected String")));
  ("str_upper", VBuiltin (function
    | VString s -> VString (String.uppercase_ascii s)
    | _ -> raise (EvalError "str_upper: expected String")));
  ("str_lower", VBuiltin (function
    | VString s -> VString (String.lowercase_ascii s)
    | _ -> raise (EvalError "str_lower: expected String")));
  ("str_trim", VBuiltin (function
    | VString s -> VString (String.trim s)
    | _ -> raise (EvalError "str_trim: expected String")));
  ("str_slice", VBuiltin (function
    | VInt start -> VBuiltin (function
      | VInt end_ -> VBuiltin (function
        | VString s ->
          let len = String.length s in
          let start = max 0 (min start len) in
          let end_  = max start (min end_ len) in
          VString (String.sub s start (end_ - start))
        | _ -> raise (EvalError "str_slice: expected String"))
      | _ -> raise (EvalError "str_slice: expected Int"))
    | _ -> raise (EvalError "str_slice: expected Int")));
  ("str_split", VBuiltin (function
    | VString delim -> VBuiltin (function
      | VString str -> VList (str_split_impl delim str)
      | _ -> raise (EvalError "str_split: expected String"))
    | _ -> raise (EvalError "str_split: expected String")));
  ("str_contains", VBuiltin (function
    | VString needle -> VBuiltin (function
      | VString haystack -> VBool (str_contains_impl needle haystack)
      | _ -> raise (EvalError "str_contains: expected String"))
    | _ -> raise (EvalError "str_contains: expected String")));
  ("str_starts_with", VBuiltin (function
    | VString prefix -> VBuiltin (function
      | VString s ->
        let plen = String.length prefix in
        VBool (String.length s >= plen && String.sub s 0 plen = prefix)
      | _ -> raise (EvalError "str_starts_with: expected String"))
    | _ -> raise (EvalError "str_starts_with: expected String")));
  ("str_ends_with", VBuiltin (function
    | VString suffix -> VBuiltin (function
      | VString s ->
        let suf = String.length suffix and slen = String.length s in
        VBool (slen >= suf && String.sub s (slen - suf) suf = suffix)
      | _ -> raise (EvalError "str_ends_with: expected String"))
    | _ -> raise (EvalError "str_ends_with: expected String")));
  ("str_replace", VBuiltin (function
    | VString old_ -> VBuiltin (function
      | VString new_ -> VBuiltin (function
        | VString s -> VString (str_replace_impl old_ new_ s)
        | _ -> raise (EvalError "str_replace: expected String"))
      | _ -> raise (EvalError "str_replace: expected String"))
    | _ -> raise (EvalError "str_replace: expected String")));
  ("str_trim_left", VBuiltin (function
    | VString s -> VString (str_trim_left s)
    | _ -> raise (EvalError "str_trim_left: expected String")));
  ("str_trim_right", VBuiltin (function
    | VString s -> VString (str_trim_right s)
    | _ -> raise (EvalError "str_trim_right: expected String")));
  ("str_repeat", VBuiltin (function
    | VInt n -> VBuiltin (function
      | VString s -> VString (str_repeat n s)
      | _ -> raise (EvalError "str_repeat: expected String"))
    | _ -> raise (EvalError "str_repeat: expected Int")));
  ("str_reverse", VBuiltin (function
    | VString s -> VString (str_reverse s)
    | _ -> raise (EvalError "str_reverse: expected String")));
  ("str_chars", VBuiltin (function
    | VString s ->
      VList (List.init (String.length s) (fun i -> VString (String.make 1 s.[i])))
    | _ -> raise (EvalError "str_chars: expected String")));
  ("int_to_str", VBuiltin (function
    | VInt n -> VString (string_of_int n)
    | _ -> raise (EvalError "int_to_str: expected Int")));
  ("float_of_int", VBuiltin (function
    | VInt n -> VFloat (float_of_int n)
    | _ -> raise (EvalError "float_of_int: expected Int")));
  (* Round half away from zero, the arithmetic reading of "round": -2.5
     rounds to -3, as Float.round's doc states. *)
  ("float_round", VBuiltin (function
    | VFloat f -> VInt (int_of_float (Float.round f))
    | _ -> raise (EvalError "float_round: expected Float")));
  ("float_floor", VBuiltin (function
    | VFloat f -> VInt (int_of_float (Float.floor f))
    | _ -> raise (EvalError "float_floor: expected Float")));
  ("float_ceil", VBuiltin (function
    | VFloat f -> VInt (int_of_float (Float.ceil f))
    | _ -> raise (EvalError "float_ceil: expected Float")));
  ("float_abs", VBuiltin (function
    | VFloat f -> VFloat (Float.abs f)
    | _ -> raise (EvalError "float_abs: expected Float")));
  (* A width is a printing decision, so this answers a String. Rounding the
     Float instead would answer a value that cannot hold the answer: no
     Float is exactly 0.1, and `%.*f` is the only place the digits are
     decided once. A negative width reads as none. *)
  ("float_format", VBuiltin (function
    | VInt digits -> VBuiltin (function
      | VFloat f -> VString (Printf.sprintf "%.*f" (max 0 digits) f)
      | _ -> raise (EvalError "float_format: expected Float"))
    | _ -> raise (EvalError "float_format: expected Int")));
  ("str_to_int", VBuiltin (function
    | VString s ->
      (match int_of_string_opt (String.trim s) with
       | Some n -> VConstr (Ctor.Builtin "Ok",    [VInt n])
       | None   -> VConstr (Ctor.Builtin "Error", [VString (Printf.sprintf "cannot parse %S as Int" s)]))
    | _ -> raise (EvalError "str_to_int: expected String")));
  ("str_to_float", VBuiltin (function
    | VString s ->
      (match float_of_string_opt (String.trim s) with
       | Some f -> VConstr (Ctor.Builtin "Ok",    [VFloat f])
       | None   -> VConstr (Ctor.Builtin "Error", [VString (Printf.sprintf "cannot parse %S as Float" s)]))
    | _ -> raise (EvalError "str_to_float: expected String")));
  ("str_to_bool", VBuiltin (function
    | VString s ->
      (match String.lowercase_ascii (String.trim s) with
       | "true"  -> VConstr (Ctor.Builtin "Ok",    [VBool true])
       | "false" -> VConstr (Ctor.Builtin "Ok",    [VBool false])
       | _       -> VConstr (Ctor.Builtin "Error", [VString (Printf.sprintf "cannot parse %S as Bool" s)]))
    | _ -> raise (EvalError "str_to_bool: expected String")));
  ("str_to_path", VBuiltin (function
    | VString s -> VPath s
    | _ -> raise (EvalError "str_to_path: expected String")));
  ("str_to_url", VBuiltin (function
    | VString s -> to_domain "URL" (function Token.URL v -> Some (VURL v) | _ -> None) s
    | _ -> raise (EvalError "str_to_url: expected String")));
  ("str_to_ipv4", VBuiltin (function
    | VString s -> to_domain "IPv4" (function Token.IPv4 v -> Some (VIPv4 v) | _ -> None) s
    | _ -> raise (EvalError "str_to_ipv4: expected String")));
  ("str_to_cidr", VBuiltin (function
    | VString s -> to_domain "CIDR" (function Token.CIDR v -> Some (VCIDR v) | _ -> None) s
    | _ -> raise (EvalError "str_to_cidr: expected String")));
  (* Both spellings read: `:8080` is wand's own notation, and the bare number
     is what an environment variable, a config file or a flag holds. A caller
     that has just read one should not have to add a colon to it, and
     `Decode.port` accepts both for the same reason. *)
  (* Port primitives. The colon is the literal's punctuation and stays in
     every string a port makes -- `"host%{:8080}"` is `host:8080`, which is
     the address anyone wants. The number is what a command wants for an
     argument of its own, and this is where it comes from. *)
  ("port_to_int", VBuiltin (function
    | VPort n -> VInt n
    | _ -> raise (EvalError "port_to_int: expected Port")));
  ("port_of_int", VBuiltin (function
    | VInt n ->
      if n >= 0 && n <= 65535 then VConstr (Ctor.Builtin "Ok", [VPort n])
      else VConstr (Ctor.Builtin "Error", [VString
        (Printf.sprintf "invalid port %d: must be 0-65535" n)])
    | _ -> raise (EvalError "port_of_int: expected Int")));
  ("str_to_port", VBuiltin (function
    | VString s ->
      to_domain ~shown:s "Port"
        (function Token.Port v -> Some (VPort v) | _ -> None) (port_text s)
    | _ -> raise (EvalError "str_to_port: expected String")));
  ("str_to_version", VBuiltin (function
    | VString s -> to_domain "Version" (function Token.Version v -> Some (VVersion v) | _ -> None) s
    | _ -> raise (EvalError "str_to_version: expected String")));
  ("str_to_size", VBuiltin (function
    | VString s -> to_domain "Size" (function Token.Size v -> Some (VSize v) | _ -> None) s
    | _ -> raise (EvalError "str_to_size: expected String")));
  (* ── Taking an instant apart ────────────────────────────────────────── *)

  (* Every one of these reads the value's own digits through
     `datetime_epoch`, so an instant written with an offset answers for the
     UTC moment it names rather than for the text it was written in:
     `2026-08-22T20:00:00+05:30` is the 22nd at 14:30 UTC, and `hour`
     answers 14. *)
  ("dt_year", VBuiltin (function
    | VDateTime s ->
      let (y, _, _) = civil_from_days (epoch_days (datetime_epoch s)) in VInt y
    | _ -> raise (EvalError "DateTime.year: expected DateTime")));
  ("dt_month", VBuiltin (function
    | VDateTime s ->
      let (_, m, _) = civil_from_days (epoch_days (datetime_epoch s)) in VInt m
    | _ -> raise (EvalError "DateTime.month: expected DateTime")));
  ("dt_day", VBuiltin (function
    | VDateTime s ->
      let (_, _, d) = civil_from_days (epoch_days (datetime_epoch s)) in VInt d
    | _ -> raise (EvalError "DateTime.day: expected DateTime")));
  ("dt_hour", VBuiltin (function
    | VDateTime s -> VInt (seconds_into_day (datetime_epoch s) / 3600)
    | _ -> raise (EvalError "DateTime.hour: expected DateTime")));
  ("dt_minute", VBuiltin (function
    | VDateTime s -> VInt (seconds_into_day (datetime_epoch s) mod 3600 / 60)
    | _ -> raise (EvalError "DateTime.minute: expected DateTime")));
  ("dt_second", VBuiltin (function
    | VDateTime s -> VInt (seconds_into_day (datetime_epoch s) mod 60)
    | _ -> raise (EvalError "DateTime.second: expected DateTime")));
  (* ISO 8601: Monday is 1 and Sunday is 7. 1970-01-01 was a Thursday, so
     the epoch day itself is 4. *)
  ("dt_weekday", VBuiltin (function
    | VDateTime s ->
      let d = epoch_days (datetime_epoch s) in
      VInt (((d + 3) mod 7 + 7) mod 7 + 1)
    | _ -> raise (EvalError "DateTime.weekday: expected DateTime")));
  (* Midnight UTC of the day the instant falls in. *)
  ("dt_day_start", VBuiltin (function
    | VDateTime s ->
      VDateTime (datetime_of_epoch (epoch_days (datetime_epoch s) * 86400))
    | _ -> raise (EvalError "DateTime.day_start: expected DateTime")));
  (* The one builder. A day that is not a day is refused rather than
     silently shifted, so `2026 2 30` does not answer March the 2nd: the
     round trip through `civil_from_days` is what catches it. *)
  ("dt_on", VBuiltin (function
    | VTuple [VInt y; VInt m; VInt d] ->
      (match day_at y m d with
       | Ok days -> VConstr (Ctor.Builtin "Ok", [VDateTime (datetime_of_epoch (days * 86400))])
       | Error msg -> VConstr (Ctor.Builtin "Error", [VString msg]))
    | _ -> raise (EvalError "DateTime.on: expected three Ints")));
  (* The raising sibling, over the same answer, so the two say the same
     thing about the same day. *)
  ("dt_on_exn", VBuiltin (function
    | VTuple [VInt y; VInt m; VInt d] ->
      (match day_at y m d with
       | Ok days -> VDateTime (datetime_of_epoch (days * 86400))
       | Error msg -> raise (EvalError msg))
    | _ -> raise (EvalError "DateTime.on!: expected three Ints")));
  ("dt_date_string", VBuiltin (function
    | VDateTime s -> VString (String.sub (datetime_of_epoch (datetime_epoch s)) 0 10)
    | _ -> raise (EvalError "DateTime.date_string: expected DateTime")));
  ("dt_time_string", VBuiltin (function
    | VDateTime s ->
      VString (String.sub (datetime_of_epoch (datetime_epoch s)) 11 8)
    | _ -> raise (EvalError "DateTime.time_string: expected DateTime")));

  ("str_to_datetime", VBuiltin (function
    | VString s -> to_domain "DateTime" (function Token.DateTime v -> Some (VDateTime v) | _ -> None) s
    | _ -> raise (EvalError "str_to_datetime: expected String")));
  ("str_to_duration", VBuiltin (function
    | VString s -> to_domain "Duration" (function Token.Duration v -> Some (VDuration v) | _ -> None) s
    | _ -> raise (EvalError "str_to_duration: expected String")));
  (* FS primitives *)
  ("fs_exists",  performing "FS!exists" (function
    | VPath p -> VBool (Sys.file_exists p)
    | _ -> raise (EvalError "fs_exists: expected Path")));
  ("fs_is_file", performing "FS!file" (function
    | VPath p -> VBool (Sys.file_exists p && not (Sys.is_directory p))
    | _ -> raise (EvalError "fs_is_file: expected Path")));
  ("fs_is_dir",  performing "FS!dir" (function
    | VPath p -> VBool (Sys.file_exists p && Sys.is_directory p)
    | _ -> raise (EvalError "fs_is_dir: expected Path")));
  ("fs_mkdir",   VBuiltin (fun v -> Effect.perform (WandEffect ("FS!mkdir", v))));
  ("fs_ls",      VBuiltin (fun v -> Effect.perform (WandEffect ("FS!list_dir",      v))));
  ("fs_remove",  VBuiltin (fun v -> Effect.perform (WandEffect ("FS!delete",  v))));
  ("fs_append",  VBuiltin (fun path ->
    VBuiltin (fun content ->
      Effect.perform (WandEffect ("FS!append", VTuple [path; content])))));
  ("fs_create",  VBuiltin (fun v -> Effect.perform (WandEffect ("FS!create_file",  v))));
  ("fs_temp_file", VBuiltin (fun prefix ->
    VBuiltin (fun suffix ->
      Effect.perform (WandEffect ("FS!temp_file", VTuple [prefix; suffix])))));
  ("fs_temp_dir", VBuiltin (fun prefix ->
    Effect.perform (WandEffect ("FS!temp_dir", prefix))));
  ("fs_delete_tree", VBuiltin (fun v ->
    Effect.perform (WandEffect ("FS!delete_tree", v))));
  ("fs_rename",  VBuiltin (fun old_ ->
    VBuiltin (fun new_ ->
      Effect.perform (WandEffect ("FS!rename", VTuple [old_; new_])))));
  ("fs_copy",    VBuiltin (fun src ->
    VBuiltin (fun dst ->
      Effect.perform (WandEffect ("FS!copy", VTuple [src; dst])))));
  ("fs_copy_tree", VBuiltin (fun src ->
    VBuiltin (fun dst ->
      Effect.perform (WandEffect ("FS!copy_tree", VTuple [src; dst])))));
  ("fs_cwd",     VBuiltin (fun v -> Effect.perform (WandEffect ("FS!cwd", v))));
  ("fs_mtime",   VBuiltin (fun v -> Effect.perform (WandEffect ("FS!mtime", v))));
  ("fs_size",    VBuiltin (fun v -> Effect.perform (WandEffect ("FS!size", v))));
  ("fs_glob",    VBuiltin (fun pattern ->
    VBuiltin (fun dir ->
      Effect.perform (WandEffect ("FS!glob", VTuple [pattern; dir])))));
  ("fs_glob_impl", VBuiltin (function
    | VString pat | VGlob pat ->
      VBuiltin (function
        | VString base | VPath base ->
          let norm_pat =
            if String.length pat > 2 && pat.[0] = '.' && pat.[1] = '/' then
              String.sub pat 2 (String.length pat - 2)
            else pat
          in
          let re = Re.compile (Re.Glob.glob ~anchored:true ~double_asterisk:true norm_pat) in
          let is_link p =
            match Unix.lstat p with
            | { Unix.st_kind = Unix.S_LNK; _ } -> true
            | _ -> false
            | exception Unix.Unix_error _ -> false
          in
          (* A symlink is an entry like any other -- it can match, and is
             answered with as itself -- but the walk does not go through it.
             Walking through one left the base directory the caller named:
             a link inside `./data` pointing at `/etc` had
             `FS.glob_in **.conf ./data` answering with files `./data` does
             not contain, which is not what the argument says. A link back
             to an ancestor was worse -- the walk went round it until the
             path outgrew what the system would take.

             The base itself is followed, since naming it is what asks for
             it. *)
          let rec collect ~walk_link path rel acc =
            if (not walk_link) && is_link path then
              (if Re.execp re rel then VPath path :: acc else acc)
            else if not (Sys.file_exists path) then acc
            else if Sys.is_directory path then begin
              let entries = Sys.readdir path in
              Array.sort String.compare entries;
              Array.fold_left (fun a name ->
                let child_path = Filename.concat path name in
                let child_rel  = if rel = "" then name
                                 else rel ^ "/" ^ name in
                collect ~walk_link:false child_path child_rel a) acc entries
            end else if Re.execp re rel then VPath path :: acc
            else acc
          in
          let results = List.rev (collect ~walk_link:true base "" []) in
          VList results
        | _ -> raise (EvalError "fs_glob: second argument must be Path"))
    | _ -> raise (EvalError "fs_glob: first argument must be Glob or String")));
  (* Duration primitives *)
  ("dur_zero",    VDuration "0s");
  ("dur_seconds", VBuiltin (function
    | VInt n -> VDuration (format_dur_ms (n * 1000))
    | _ -> raise (EvalError "dur_seconds: expected Int")));
  ("dur_minutes", VBuiltin (function
    | VInt n -> VDuration (format_dur_ms (n * 60000))
    | _ -> raise (EvalError "dur_minutes: expected Int")));
  ("dur_hours",   VBuiltin (function
    | VInt n -> VDuration (format_dur_ms (n * 3600000))
    | _ -> raise (EvalError "dur_hours: expected Int")));
  ("dur_days",    VBuiltin (function
    | VInt n -> VDuration (format_dur_ms (n * 24 * 3600000))
    | _ -> raise (EvalError "dur_days: expected Int")));
  ("dur_weeks",   VBuiltin (function
    | VInt n -> VDuration (format_dur_ms (n * 7 * 24 * 3600000))
    | _ -> raise (EvalError "dur_weeks: expected Int")));
  ("dur_add", VBuiltin (function
    | VDuration a -> VBuiltin (function
      | VDuration b -> VDuration (format_dur_ms (parse_dur_ms a + parse_dur_ms b))
      | _ -> raise (EvalError "dur_add: expected Duration"))
    | _ -> raise (EvalError "dur_add: expected Duration")));
  ("dur_sub", VBuiltin (function
    | VDuration a -> VBuiltin (function
      | VDuration b -> VDuration (format_dur_ms (max 0 (parse_dur_ms a - parse_dur_ms b)))
      | _ -> raise (EvalError "dur_sub: expected Duration"))
    | _ -> raise (EvalError "dur_sub: expected Duration")));
  ("dur_scale", VBuiltin (function
    | VInt n -> VBuiltin (function
      | VDuration d -> VDuration (format_dur_ms (n * parse_dur_ms d))
      | _ -> raise (EvalError "dur_scale: expected Duration"))
    | _ -> raise (EvalError "dur_scale: expected Int")));
  ("dur_format", VBuiltin (function
    | VDuration d -> VString (format_dur_ms (parse_dur_ms d))
    | _ -> raise (EvalError "dur_format: expected Duration")));
  ("dur_to_ms", VBuiltin (function
    | VDuration d -> VInt (parse_dur_ms d)
    | _ -> raise (EvalError "dur_to_ms: expected Duration")));
  (* Size primitives *)
  ("size_to_bytes", VBuiltin (function
    | VSize s -> VInt (size_bytes s)
    | _ -> raise (EvalError "size_to_bytes: expected Size")));
  ("size_of_bytes", VBuiltin (function
    | VInt n -> VSize (Printf.sprintf "%dB" (max 0 n))
    | _ -> raise (EvalError "size_of_bytes: expected Int")));
  ("size_format", VBuiltin (function
    | VSize s -> VString (format_size_bytes (size_bytes s))
    | _ -> raise (EvalError "size_format: expected Size")));
  (* Regex primitives *)
  ("regex_match", VBuiltin (function
    | VRegex re -> VBuiltin (function
      | VString s -> VBool (Re.execp re s)
      | _ -> raise (EvalError "regex_match: expected String"))
    | _ -> raise (EvalError "regex_match: expected Regex")));
  ("regex_capture", VBuiltin (function
    | VRegex re -> VBuiltin (function
      | VString s ->
        (match Re.exec_opt re s with
         | None   -> VList []
         | Some g ->
           let all = Re.Group.all g in
           VList (Array.to_list (Array.map (fun s -> VString s) all)))
      | _ -> raise (EvalError "regex_capture: expected String"))
    | _ -> raise (EvalError "regex_capture: expected Regex")));
  ("regex_replace", VBuiltin (function
    | VRegex re -> VBuiltin (function
      | VString repl -> VBuiltin (function
        | VString s ->
          (match Re.exec_opt re s with
           | None   -> VString s
           | Some g ->
             let (b, e) = Re.Group.offset g 0 in
             VString (String.sub s 0 b ^ repl ^ String.sub s e (String.length s - e)))
        | _ -> raise (EvalError "regex_replace: expected String"))
      | _ -> raise (EvalError "regex_replace: expected String repl"))
    | _ -> raise (EvalError "regex_replace: expected Regex")));
  ("regex_replace_all", VBuiltin (function
    | VRegex re -> VBuiltin (function
      | VString repl -> VBuiltin (function
        | VString s -> VString (Re.replace_string re ~by:repl s)
        | _ -> raise (EvalError "regex_replace_all: expected String"))
      | _ -> raise (EvalError "regex_replace_all: expected String repl"))
    | _ -> raise (EvalError "regex_replace_all: expected Regex")));
  ("regex_split", VBuiltin (function
    | VRegex re -> VBuiltin (function
      | VString s -> VList (List.map (fun s -> VString s) (Re.split re s))
      | _ -> raise (EvalError "regex_split: expected String"))
    | _ -> raise (EvalError "regex_split: expected Regex")));
  ("regex_find_all", VBuiltin (function
    | VRegex re -> VBuiltin (function
      | VString s ->
        VList (List.map (fun g -> VString (Re.Group.get g 0)) (Re.all re s))
      | _ -> raise (EvalError "regex_find_all: expected String"))
    | _ -> raise (EvalError "regex_find_all: expected Regex")));
  (* Pair an acquire with a release. The only way to build a resource, and
     the pair is built in one place so the two halves cannot drift apart. *)
  ("resource_make", VBuiltin (fun acquire ->
    VBuiltin (fun release -> VResource (acquire, release))));
  ("regex_compile", VBuiltin (function
    | VString pat ->
      (try VConstr (Ctor.Builtin "Ok", [VRegex (Re.compile (Re.Pcre.re pat))])
       with Re.Pcre.Parse_error ->
         VConstr (Ctor.Builtin "Error", [VString (Printf.sprintf "invalid regex: %s" pat)]))
    | _ -> raise (EvalError "regex_compile: expected String")));
  (* Path primitives — pure string operations on VPath values *)
  ("path_join", VBuiltin (function
    | VPath p1 | VString p1 -> VBuiltin (function
      | VPath p2 | VString p2 -> VPath (path_normalize (Filename.concat p1 p2))
      | _ -> raise (EvalError "path_join: expected Path"))
    | _ -> raise (EvalError "path_join: expected Path")));
  ("path_parent", VBuiltin (function
    | VPath s | VString s -> VPath (Filename.dirname s)
    | _ -> raise (EvalError "path_parent: expected Path")));
  ("path_basename", VBuiltin (function
    | VPath s | VString s -> VPath (Filename.basename s)
    | _ -> raise (EvalError "path_basename: expected Path")));
  ("path_extension", VBuiltin (function
    | VPath s | VString s -> VString (Filename.extension s)
    | _ -> raise (EvalError "path_extension: expected Path")));
  ("path_with_extension", VBuiltin (function
    | VString ext -> VBuiltin (function
      | VPath s | VString s ->
        (* `Path.extension` answers with the dot -- ".txt" -- so that
           spelling has to go back in unchanged. Somebody writing the
           extension the way it is said, "md", means the same thing, and
           pasting it straight on turned /a/b.txt into /a/bmd: a path with
           no extension at all, silently. An empty extension takes the
           extension off. *)
        let stem = Filename.remove_extension s in
        let dotted =
          if ext = "" then ""
          else if ext.[0] = '.' then ext
          else "." ^ ext
        in
        VPath (stem ^ dotted)
      | _ -> raise (EvalError "path_with_extension: expected Path"))
    | _ -> raise (EvalError "path_with_extension: expected String ext")));
  ("path_is_absolute", VBuiltin (function
    | VPath s | VString s ->
      VBool (String.length s > 0 && s.[0] = '/')
    | _ -> raise (EvalError "path_is_absolute: expected Path")));
  ("path_is_relative", VBuiltin (function
    | VPath s | VString s ->
      VBool (String.length s = 0 || s.[0] <> '/')
    | _ -> raise (EvalError "path_is_relative: expected Path")));
  ("path_normalize", VBuiltin (function
    | VPath s | VString s -> VPath (path_normalize s)
    | _ -> raise (EvalError "path_normalize: expected Path")));
  ("path_to_string", VBuiltin (function
    | VPath s | VString s -> VString s
    | _ -> raise (EvalError "path_to_string: expected Path")));
  ("path_of_string", VBuiltin (function
    | VString s -> VPath s
    | _ -> raise (EvalError "path_of_string: expected String")));
  ("path_components", VBuiltin (function
    | VPath s | VString s ->
      let parts = String.split_on_char '/' s |> List.filter (fun p -> p <> "") in
      VList (List.map (fun p -> VString p) parts)
    | _ -> raise (EvalError "path_components: expected Path")));
  (* IO primitives *)
  ("io_print_err",   VBuiltin (fun v -> Effect.perform (WandEffect ("IO!print_err",   v))));
  ("io_println_err", VBuiltin (fun v -> Effect.perform (WandEffect ("IO!println_err", v))));
  ("io_read_line",   VBuiltin (fun v -> Effect.perform (WandEffect ("IO!read_line",   v))));
  ("io_read_all",    VBuiltin (fun v -> Effect.perform (WandEffect ("IO!read_all",    v))));
  ("io_flush",       VBuiltin (fun v -> Effect.perform (WandEffect ("IO!flush",       v))));
  (* Par primitives. *)
  ("par_map", VBuiltin (fun limit ->
    VBuiltin (fun f ->
      VBuiltin (fun xs ->
        match limit, xs with
        | VInt n, VList items -> par_run n f items ~collect:true
        | _ -> raise (EvalError "par_map: expected a limit and a list")))));
  (* `Par.timeout` is a race between the work and a sleeper, and `par_race`
     refuses inside a handler. This guard runs first so the message is about
     the deadline: the sleeper is a branch, a branch cannot run where the
     handler is, and work that only the deadline would have stopped would
     run forever. Refused, with the reason, rather than hanging a test suite
     with no message.

     A rehearsal and a trace are observers too, and are not refused: a
     rehearsal collapsing the race still reports what the work would do.

     This is a run-time error, not the `Raise` effect, as division by zero
     is -- the signature says nothing about it because no wand code can
     answer it. *)
  ("par_deadline_guard", VBuiltin (fun _ ->
    if Atomic.get handlers > 0 then
      raise (EvalError
        "a deadline inside a handler never fires. Move the handler inside \
         the thunk -- `Par.timeout d (fn () -> with_clock (fn () -> ...))` \
         -- or take it off.")
    else VUnit));
  ("par_race", VBuiltin (function
    | VList thunks -> par_race thunks
    | _ -> raise (EvalError "par_race: expected a list of thunks")));
  ("par_each", VBuiltin (fun limit ->
    VBuiltin (fun f ->
      VBuiltin (fun xs ->
        match limit, xs with
        | VInt n, VList items -> par_run n f items ~collect:false
        | _ -> raise (EvalError "par_each: expected a limit and a list")))));
  (* Process primitives *)
  ("process_run", VBuiltin (fun v ->
    Effect.perform (WandEffect ("Shell!run", v))));
  ("process_run_quiet", VBuiltin (fun v ->
    Effect.perform (WandEffect ("Shell!run_quiet", v))));
  ("process_exit_code", VBuiltin (fun v ->
    Effect.perform (WandEffect ("Shell!exit_code", v))));
  (* Env primitives *)
  ("env_read_dotenv", performing "Env!parse_dotenv" (function
    | VString src | VPath src ->
      VList (List.map (fun (k, v) -> VTuple [VString k; VString v])
               (dotenv_pairs src))
    | _ -> raise (EvalError "env_read_dotenv: expected String or Path")));
  ("env_load_file", VBuiltin (function
    | VString path | VPath path ->
      (* Read through the same effect a plain read does, so a trace shows
         the file and a mock can substitute it. *)
      let src =
        match Effect.perform (WandEffect ("FS!read_file", VString path)) with
        | VString s -> s
        | _ -> raise (EvalError "env_load_file: expected file contents")
      in
      (* One env_set per variable, so a rehearsal names each one rather than
         reporting that a file was loaded. *)
      List.iter (fun (k, v) ->
        ignore (Effect.perform
          (WandEffect ("Env!set", VTuple [VString k; VString v]))))
        (dotenv_pairs src);
      VUnit
    | _ -> raise (EvalError "env_load_file: expected Path")));

  ("env_get_exn", performing "Env!get" (function
    | VString name ->
      (match Sys.getenv_opt name with
       | Some v -> VString v
       | None   -> raise (EvalError ("env: variable not set: " ^ name)))
    | _ -> raise (EvalError "env_get_exn: expected String")));
  (* Changing the environment is a mutation like any other, so it goes
     through an interceptable effect rather than straight to putenv. A
     rehearsal that still edited the environment would be worse than none. *)
  ("env_set", VBuiltin (fun name ->
    VBuiltin (fun value ->
      Effect.perform (WandEffect ("Env!set", VTuple [name; value])))));
  ("env_clear", VBuiltin (fun name ->
    Effect.perform (WandEffect ("Env!clear", name))));
  ("env_all", performing "Env!all" (function
    | VUnit ->
      let pairs = Array.to_list (Unix.environment ()) |> List.filter_map (fun s ->
        match String.split_on_char '=' s with
        | [] | [""] -> None
        | name :: rest -> Some (VTuple [VString name; VString (String.concat "=" rest)]))
      in
      VList pairs
    | _ -> raise (EvalError "env_all: expected Unit")));
  ("env_args", performing "Env!args" (function
    | VUnit -> VList (List.map (fun s -> VString s) !exe_args_ref)
    | _ -> raise (EvalError "env_args: expected Unit")));
  ("env_home", performing "Env!home" (function
    | VUnit ->
      (match Sys.getenv_opt "HOME" with
       | Some h -> VPath h
       | None   -> raise (EvalError "env: HOME not set"))
    | _ -> raise (EvalError "env_home: expected Unit")));
  ("env_user", performing "Env!user" (function
    | VUnit ->
      let user =
        match Sys.getenv_opt "USER" with
        | Some u -> u
        | None   -> (try Unix.getlogin () with _ -> "")
      in
      VString user
    | _ -> raise (EvalError "env_user: expected Unit")));
  (* CSV primitives *)
  ("csv_parse", VBuiltin (function
    | VString sep -> VBuiltin (function
      | VString src ->
        let rows = csv_parse_string sep src in
        VList (List.map (fun row -> VList (List.map (fun s -> VString s) row)) rows)
      | _ -> raise (EvalError "csv_parse: expected String content"))
    | _ -> raise (EvalError "csv_parse: expected String separator")));
  ("csv_stringify", VBuiltin (function
    | VString sep -> VBuiltin (function
      | VList rows ->
        let str_rows = List.map (function
          | VList fields -> List.map (function
            | VString s -> s
            | v -> to_text v) fields
          | _ -> raise (EvalError "csv_stringify: rows must be List (List String)")) rows
        in
        VString (csv_stringify_rows sep str_rows)
      | _ -> raise (EvalError "csv_stringify: expected List of rows"))
    | _ -> raise (EvalError "csv_stringify: expected String separator")));
  (* JSON primitives *)
  ("json_null",  VJson `Null);
  ("json_of_bool",   VBuiltin (function VBool b  -> VJson (`Bool b)   | _ -> raise (EvalError "json_of_bool: expected Bool")));
  ("json_of_int",    VBuiltin (function VInt n   -> VJson (`Int n)    | _ -> raise (EvalError "json_of_int: expected Int")));
  ("json_of_float",  VBuiltin (function VFloat f -> VJson (`Float f)  | _ -> raise (EvalError "json_of_float: expected Float")));
  ("json_of_string", VBuiltin (function VString s -> VJson (`String s) | _ -> raise (EvalError "json_of_string: expected String")));
  ("json_of_list",   VBuiltin (function
    | VList vs ->
      let items = List.map (function VJson j -> j | _ -> raise (EvalError "json_of_list: elements must be JSON")) vs in
      VJson (`List items)
    | _ -> raise (EvalError "json_of_list: expected List")));
  (* An object from a Map, in the order the Map holds. `JSON.get_object` gives
     back a Map, so this is its inverse.

     A key the Map holds twice is written once, at its first position. A Map
     can hold a repeated key -- `[a = 1, a = 9]` has two entries and
     `Map.get` finds the first -- and a document naming the same key twice is
     read differently by different parsers. Writing the one that can be read
     back is the only answer that round-trips. *)
  ("json_of_map",    VBuiltin (function
    | VMap kvs ->
      (* A Map holds a key once, so what comes out names each key once too. *)
      VJson (`Assoc (List.map (fun (k, v) -> match v with
        | VJson j -> (k, j)
        | _ -> raise (EvalError "json_of_map: values must be JSON")) kvs))
    | _ -> raise (EvalError "json_of_map: expected Map")));
  ("json_is_null",   VBuiltin (function VJson `Null -> VBool true | VJson _ -> VBool false | _ -> raise (EvalError "json_is_null: expected JSON")));
  ("json_get_bool",  VBuiltin (function
    | VJson (`Bool b) -> VConstr (Ctor.Builtin "Ok", [VBool b])
    | VJson j -> VConstr (Ctor.Builtin "Error", [VString ("expected bool, got " ^ Yojson.Basic.to_string j)])
    | _ -> raise (EvalError "json_get_bool: expected JSON")));
  ("json_get_int",   VBuiltin (function
    | VJson (`Int n) -> VConstr (Ctor.Builtin "Ok", [VInt n])
    | VJson j -> VConstr (Ctor.Builtin "Error", [VString ("expected int, got " ^ Yojson.Basic.to_string j)])
    | _ -> raise (EvalError "json_get_int: expected JSON")));
  ("json_get_float", VBuiltin (function
    | VJson (`Float f) -> VConstr (Ctor.Builtin "Ok", [VFloat f])
    | VJson (`Int n)   -> VConstr (Ctor.Builtin "Ok", [VFloat (float_of_int n)])
    | VJson j -> VConstr (Ctor.Builtin "Error", [VString ("expected float, got " ^ Yojson.Basic.to_string j)])
    | _ -> raise (EvalError "json_get_float: expected JSON")));
  ("json_get_string", VBuiltin (function
    | VJson (`String s) -> VConstr (Ctor.Builtin "Ok", [VString s])
    | VJson j -> VConstr (Ctor.Builtin "Error", [VString ("expected string, got " ^ Yojson.Basic.to_string j)])
    | _ -> raise (EvalError "json_get_string: expected JSON")));
  ("json_get_array", VBuiltin (function
    | VJson (`List vs) -> VConstr (Ctor.Builtin "Ok", [VList (List.map (fun j -> VJson j) vs)])
    | VJson j -> VConstr (Ctor.Builtin "Error", [VString ("expected array, got " ^ Yojson.Basic.to_string j)])
    | _ -> raise (EvalError "json_get_array: expected JSON")));
  ("json_get_object", VBuiltin (function
    | VJson (`Assoc kvs) ->
      VConstr (Ctor.Builtin "Ok", [VMap (map_of_pairs (List.map (fun (k, j) -> (k, VJson j)) kvs))])
    | VJson j -> VConstr (Ctor.Builtin "Error", [VString ("expected object, got " ^ Yojson.Basic.to_string j)])
    | _ -> raise (EvalError "json_get_object: expected JSON")));
  ("json_field", VBuiltin (fun key ->
    VBuiltin (function
      | VJson (`Assoc kvs) ->
        let k = (match key with VString s -> s | _ -> raise (EvalError "json_field: key must be String")) in
        (match assoc_last k kvs with
         | Some j -> VConstr (Ctor.Builtin "Ok", [VJson j])
         | None   -> VConstr (Ctor.Builtin "Error", [VString ("no field: " ^ k)]))
      | VJson j -> VConstr (Ctor.Builtin "Error", [VString ("expected object, got " ^ Yojson.Basic.to_string j)])
      | _ -> raise (EvalError "json_field: expected JSON"))));
  ("json_parse", VBuiltin (function
    | VString s ->
      (try VConstr (Ctor.Builtin "Ok", [VJson (Yojson.Basic.from_string s)])
       with Yojson.Json_error msg -> VConstr (Ctor.Builtin "Error", [VString msg]))
    | _ -> raise (EvalError "json_parse: expected String")));
  ("json_parse_exn", VBuiltin (function
    | VString s ->
      (try VJson (Yojson.Basic.from_string s)
       with Yojson.Json_error msg -> raise (EvalError ("json_parse: " ^ msg)))
    | _ -> raise (EvalError "json_parse_exn: expected String")));
  ("json_field_exn", VBuiltin (fun key ->
    VBuiltin (function
      | VJson (`Assoc kvs) ->
        let k = (match key with VString s -> s | _ -> raise (EvalError "json_field_exn: key must be String")) in
        (match assoc_last k kvs with
         | Some j -> VJson j
         | None   -> raise (EvalError ("json_field_exn: no field: " ^ k)))
      | VJson j -> raise (EvalError ("json_field_exn: expected object, got " ^ Yojson.Basic.to_string j))
      | _ -> raise (EvalError "json_field_exn: expected JSON"))));
  ("json_stringify", VBuiltin (function
    | VJson j -> VString (Yojson.Basic.to_string j)
    | _ -> raise (EvalError "json_stringify: expected JSON")));
  ("json_stringify_pretty", VBuiltin (function
    | VJson j -> VString (Yojson.Basic.pretty_to_string j)
    | _ -> raise (EvalError "json_stringify_pretty: expected JSON")));
  (* TOML primitives *)
  ("toml_parse", VBuiltin (function
    | VString s ->
      (match Toml.Parser.from_string s with
       | `Ok tbl  -> VConstr (Ctor.Builtin "Ok", [VToml (Toml.Types.TTable tbl)])
       | `Error (msg, _) -> VConstr (Ctor.Builtin "Error", [VString msg]))
    | _ -> raise (EvalError "toml_parse: expected String")));
  ("toml_parse_exn", VBuiltin (function
    | VString s ->
      (match Toml.Parser.from_string s with
       | `Ok tbl  -> VToml (Toml.Types.TTable tbl)
       | `Error (msg, _) -> raise (EvalError ("toml_parse: " ^ msg)))
    | _ -> raise (EvalError "toml_parse_exn: expected String")));
  ("toml_stringify", VBuiltin (function
    | VToml (Toml.Types.TTable tbl) -> VString (Toml.Printer.string_of_table tbl)
    | VToml _ -> raise (EvalError "toml_stringify: value must be a TOML table")
    | _ -> raise (EvalError "toml_stringify: expected TOML")));
  ("toml_is_table", VBuiltin (function
    | VToml (Toml.Types.TTable _) -> VBool true
    | VToml _ -> VBool false
    | _ -> raise (EvalError "toml_is_table: expected TOML")));
  ("toml_is_array", VBuiltin (function
    | VToml (Toml.Types.TArray _) -> VBool true
    | VToml _ -> VBool false
    | _ -> raise (EvalError "toml_is_array: expected TOML")));
  ("toml_get_bool", VBuiltin (function
    | VToml (Toml.Types.TBool b) -> VConstr (Ctor.Builtin "Ok", [VBool b])
    | VToml _ -> VConstr (Ctor.Builtin "Error", [VString "expected bool"])
    | _ -> raise (EvalError "toml_get_bool: expected TOML")));
  ("toml_get_int", VBuiltin (function
    | VToml (Toml.Types.TInt n) -> VConstr (Ctor.Builtin "Ok", [VInt n])
    | VToml _ -> VConstr (Ctor.Builtin "Error", [VString "expected int"])
    | _ -> raise (EvalError "toml_get_int: expected TOML")));
  ("toml_get_float", VBuiltin (function
    | VToml (Toml.Types.TFloat f) -> VConstr (Ctor.Builtin "Ok", [VFloat f])
    | VToml (Toml.Types.TInt n)   -> VConstr (Ctor.Builtin "Ok", [VFloat (float_of_int n)])
    | VToml _ -> VConstr (Ctor.Builtin "Error", [VString "expected float"])
    | _ -> raise (EvalError "toml_get_float: expected TOML")));
  ("toml_get_string", VBuiltin (function
    | VToml (Toml.Types.TString s) -> VConstr (Ctor.Builtin "Ok", [VString s])
    | VToml _ -> VConstr (Ctor.Builtin "Error", [VString "expected string"])
    | _ -> raise (EvalError "toml_get_string: expected TOML")));
  ("toml_get_array", VBuiltin (function
    | VToml (Toml.Types.TArray arr) ->
      let items = match arr with
        | Toml.Types.NodeBool bs   -> List.map (fun b -> VToml (Toml.Types.TBool b)) bs
        | Toml.Types.NodeInt ns    -> List.map (fun n -> VToml (Toml.Types.TInt n)) ns
        | Toml.Types.NodeFloat fs  -> List.map (fun f -> VToml (Toml.Types.TFloat f)) fs
        | Toml.Types.NodeString ss -> List.map (fun s -> VToml (Toml.Types.TString s)) ss
        | Toml.Types.NodeDate ds   -> List.map (fun d -> VToml (Toml.Types.TDate d)) ds
        | Toml.Types.NodeTable ts  -> List.map (fun t -> VToml (Toml.Types.TTable t)) ts
        | Toml.Types.NodeArray _   -> []
        | Toml.Types.NodeEmpty     -> []
      in
      VConstr (Ctor.Builtin "Ok", [VList items])
    | VToml _ -> VConstr (Ctor.Builtin "Error", [VString "expected array"])
    | _ -> raise (EvalError "toml_get_array: expected TOML")));
  ("toml_get_table", VBuiltin (function
    | VToml (Toml.Types.TTable tbl) ->
      let pairs = Toml.Types.Table.to_list tbl in
      let vmap = VMap (List.map (fun (k, v) ->
        (Toml.Types.Table.Key.to_string k, VToml v)) pairs) in
      VConstr (Ctor.Builtin "Ok", [vmap])
    | VToml _ -> VConstr (Ctor.Builtin "Error", [VString "expected table"])
    | _ -> raise (EvalError "toml_get_table: expected TOML")));
  ("toml_field", VBuiltin (fun key ->
    VBuiltin (function
      | VToml (Toml.Types.TTable tbl) ->
        let k = (match key with VString s -> s | _ -> raise (EvalError "toml_field: key must be String")) in
        (match Toml.Types.Table.find_opt (Toml.Types.Table.Key.of_string k) tbl with
         | Some v -> VConstr (Ctor.Builtin "Ok", [VToml v])
         | None   -> VConstr (Ctor.Builtin "Error", [VString ("no key: " ^ k)]))
      | VToml _ -> VConstr (Ctor.Builtin "Error", [VString "expected table"])
      | _ -> raise (EvalError "toml_field: expected TOML"))));
  ("toml_field_exn", VBuiltin (fun key ->
    VBuiltin (function
      | VToml (Toml.Types.TTable tbl) ->
        let k = (match key with VString s -> s | _ -> raise (EvalError "toml_field_exn: key must be String")) in
        (match Toml.Types.Table.find_opt (Toml.Types.Table.Key.of_string k) tbl with
         | Some v -> VToml v
         | None   -> raise (EvalError ("toml_field_exn: no key: " ^ k)))
      | VToml _ -> raise (EvalError "toml_field_exn: expected table")
      | _ -> raise (EvalError "toml_field_exn: expected TOML"))));
  (* List primitives *)
  ("list_get", VBuiltin (function
    | VInt n -> VBuiltin (function
      | VList xs ->
        let rec nth i = function
          | []     -> VConstr (Ctor.Builtin "Error", [VString (Printf.sprintf "index %d out of bounds" n)])
          | x :: _ when i = 0 -> VConstr (Ctor.Builtin "Ok", [x])
          | _ :: t -> nth (i - 1) t
        in
        if n < 0 then VConstr (Ctor.Builtin "Error", [VString (Printf.sprintf "index %d out of bounds" n)])
        else nth n xs
      | _ -> raise (EvalError "list_get: expected List"))
    | _ -> raise (EvalError "list_get: expected Int index")));
  ("list_get_exn", VBuiltin (function
    | VInt n -> VBuiltin (function
      | VList xs ->
        let rec nth i = function
          | []     -> raise (EvalError (Printf.sprintf "list_get!: index %d out of bounds" n))
          | x :: _ when i = 0 -> x
          | _ :: t -> nth (i - 1) t
        in
        if n < 0 then raise (EvalError (Printf.sprintf "list_get!: index %d out of bounds" n))
        else nth n xs
      | _ -> raise (EvalError "list_get!: expected List"))
    | _ -> raise (EvalError "list_get!: expected Int index")));
  ("list_sort", VBuiltin (function
    | VList xs -> VList (List.sort wand_compare xs)
    | _ -> raise (EvalError "list_sort: expected List")));
  ("list_sort_by", VBuiltin (fun f ->
    VBuiltin (function
      | VList xs ->
        VList (List.sort (fun a b -> wand_compare (apply f a) (apply f b)) xs)
      | _ -> raise (EvalError "list_sort_by: expected List"))));
  ("list_unique", VBuiltin (function
    | VList xs ->
      (* Membership is equality, and equality is what `==` answers with.
         This read the stored value instead, so `List.unique [60s, 1min]`
         kept both while `60s == 1min` was true -- and a list of one instant
         written two ways came back holding it twice.

         `eq_key` narrows the search to the values that could be equal;
         `wand_equal` decides among them. *)
      let seen : (value, value list) Hashtbl.t = Hashtbl.create 16 in
      VList (List.filter (fun x ->
        let k = eq_key x in
        let bucket = match Hashtbl.find seen k with
          | b -> b
          | exception Not_found -> []
        in
        if List.exists (wand_equal x) bucket then false
        else (Hashtbl.replace seen k (x :: bucket); true)) xs)
    | _ -> raise (EvalError "list_unique: expected List")));
  ("list_range", VBuiltin (function
    | VInt lo -> VBuiltin (function
      | VInt hi ->
        let rec go i acc =
          if i < lo then acc else go (i - 1) (VInt i :: acc)
        in
        VList (go hi [])
      | _ -> raise (EvalError "list_range: expected Int"))
    | _ -> raise (EvalError "list_range: expected Int")));
  ("list_flatten", VBuiltin (function
    | VList xss ->
      VList (List.concat_map (function
        | VList xs -> xs
        | _ -> raise (EvalError "list_flatten: expected List of Lists")) xss)
    | _ -> raise (EvalError "list_flatten: expected List")));
  ("list_concat", VBuiltin (function
    | VList xs -> VBuiltin (function
      | VList ys -> VList (xs @ ys)
      | _ -> raise (EvalError "list_concat: expected List"))
    | _ -> raise (EvalError "list_concat: expected List")));
]

(* ── Map builtins ─────────────────────────────────────────────────────────── *)

let apply_fn f v = match f with
  | VBuiltin g  -> g v
  | VFun (env, [p], body) ->
    (match try_match p v env with
     | Some env' -> eval env' body
     | None      -> raise (EvalError "apply_fn: pattern mismatch"))
  | VFix (name, env, [p], body) ->
    let rec self = lazy (VFix (name, (name, Lazy.force self) :: env, [p], body)) in
    (match try_match p v ((name, Lazy.force self) :: env) with
     | Some env' -> eval env' body
     | None      -> raise (EvalError "apply_fn: pattern mismatch"))
  | _ -> raise (EvalError "apply_fn: not a function")

let map_builtins : env = [
  ("map_empty",  VMap []);
  ("map_get", VBuiltin (function
    | VString key -> VBuiltin (function
      | VMap kvs ->
        (match List.assoc_opt key kvs with
         | Some v -> VConstr (Ctor.Builtin "Ok", [v])
         | None   -> VConstr (Ctor.Builtin "Error", [VString ("key not found: " ^ key)]))
      | _ -> raise (EvalError "map_get: expected Map"))
    | _ -> raise (EvalError "map_get: expected String key")));
  ("map_get_exn", VBuiltin (function
    | VString key -> VBuiltin (function
      | VMap kvs ->
        (match List.assoc_opt key kvs with
         | Some v -> v
         | None   -> raise (EvalError ("map key not found: " ^ key)))
      | _ -> raise (EvalError "map_get!: expected Map"))
    | _ -> raise (EvalError "map_get!: expected String key")));
  ("map_set", VBuiltin (function
    | VString key -> VBuiltin (fun v -> VBuiltin (function
      | VMap kvs -> VMap (map_put kvs key v)
      | _ -> raise (EvalError "map_set: expected Map")))
    | _ -> raise (EvalError "map_set: expected String key")));
  ("map_delete", VBuiltin (function
    | VString key -> VBuiltin (function
      | VMap kvs -> VMap (List.filter (fun (k, _) -> k <> key) kvs)
      | _ -> raise (EvalError "map_delete: expected Map"))
    | _ -> raise (EvalError "map_delete: expected String key")));
  ("map_has", VBuiltin (function
    | VString key -> VBuiltin (function
      | VMap kvs -> VBool (List.mem_assoc key kvs)
      | _ -> raise (EvalError "map_has?: expected Map"))
    | _ -> raise (EvalError "map_has?: expected String key")));
  ("map_keys", VBuiltin (function
    | VMap kvs -> VList (List.map (fun (k, _) -> VString k) kvs)
    | _ -> raise (EvalError "map_keys: expected Map")));
  ("map_values", VBuiltin (function
    | VMap kvs -> VList (List.map snd kvs)
    | _ -> raise (EvalError "map_values: expected Map")));
  ("map_size", VBuiltin (function
    | VMap kvs -> VInt (List.length kvs)
    | _ -> raise (EvalError "map_size: expected Map")));
  ("map_to_list", VBuiltin (function
    | VMap kvs -> VList (List.map (fun (k, v) -> VTuple [VString k; v]) kvs)
    | _ -> raise (EvalError "map_to_list: expected Map")));
  ("map_from_list", VBuiltin (function
    | VList pairs ->
      let kvs = List.map (function
        | VTuple [VString k; v] -> (k, v)
        | _ -> raise (EvalError "map_from_list: expected list of (String, value) tuples")) pairs
      in
      VMap (map_of_pairs kvs)
    | _ -> raise (EvalError "map_from_list: expected List")));
  ("map_merge", VBuiltin (function
    | VMap a -> VBuiltin (function
      | VMap b ->
        (* The right-hand value wins, and a key already on the left keeps its
           place there -- merging a change into a document should not shuffle
           the document. *)
        VMap (List.fold_left (fun acc (k, v) -> map_put acc k v) a b)
      | _ -> raise (EvalError "map_merge: expected Map"))
    | _ -> raise (EvalError "map_merge: expected Map")));
  ("map_map", VBuiltin (function
    | f -> VBuiltin (function
      | VMap kvs -> VMap (List.map (fun (k, v) -> (k, apply_fn f v)) kvs)
      | _ -> raise (EvalError "map_map: expected Map"))));
  ("map_filter", VBuiltin (function
    | f -> VBuiltin (function
      | VMap kvs ->
        VMap (List.filter (fun (_, v) ->
          match apply_fn f v with VBool b -> b | _ -> false) kvs)
      | _ -> raise (EvalError "map_filter: expected Map"))));
]

(* ── Decoder builtins ─────────────────────────────────────────────────────── *)

(* ── Derived decoders ─────────────────────────────────────────────────────
   A single-constructor type whose fields are named already says everything a
   decoder needs: the field names, and what each one holds.

   Built here when a decoder is *used*, never when a type is defined. Building
   at the definition is the obvious move and the expensive one: a type that
   mentions itself would not terminate, a pair that mention each other needs
   a fixpoint over a dependency graph, a type mentioned before it is defined
   needs topological ordering, and every built decoder becomes a value that
   has to cross the module boundary. Deferring costs none of that and buys no
   less: eager construction adds no decoding power whatever, it is the same
   feature built the expensive way. `Pod.decoder`
   reads exactly that, so adding a field to the type adds it to the decoder
   and there is no second copy to go stale.

   Only the flat record is covered. A document whose keys are nested, spelled
   differently, or need validating is what a hand-written decoder is for --
   derivation removes the boilerplate ones, not the interesting ones. *)

(* Why a type has no derived decoder, in a sentence that says what to do. *)
exception Not_derivable of string

(* The head of an applied type and its arguments: `Tree 'a` is ("Tree", ['a]). *)
let rec type_spine te =
  match te with
  | TEApp (f, a) -> let (head, args) = type_spine f in (head, args @ [a])
  | TEName n -> (Some n, [])
  | _ -> (None, [])

(* `venv` binds a type's parameters to the decoders supplied for them, so a
   generic type is read by a decoder that takes one decoder per parameter --
   `Box.decoder : Decoder 'a -> Decoder (Box 'a)`. It is threaded rather than
   global because a type may mention itself with different arguments. *)
(* The evaluator's half of `cmdline_shape`: a field whose type is a record is
   the flags, and the other one is what was written without a flag in front
   of it. The typechecker has already refused anything else, so this only has
   to tell the two apart. *)
let cmdline_parts fields =
  let named = List.filter_map (fun (n, te) ->
    match n with Some n -> Some (n, te) | None -> None) fields in
  match List.partition (fun (_, te) ->
    match te with
    | Ast.TEName n -> Hashtbl.mem derivable n
    | _ -> false) named with
  | [], _ -> None
  | (fname, Ast.TEName ftype) :: _, (aname, ate) :: _ ->
    Some (fname, ftype, aname, ate)
  | _ -> None

(* How many arguments the field that reads them will take, and what each one
   is. A `List` takes any number, an `Option` one or none, anything else
   exactly one -- which is the check `probe-args.wand` used to write by
   hand. *)
let argument_arity (te : Ast.type_expr) =
  match te with
  | Ast.TEApp (Ast.TEName "List", inner) -> (`Many, inner)
  | Ast.TEApp (Ast.TEName "Option", inner) -> (`Maybe, inner)
  | te -> (`One, te)

let rec decoder_of_type_expr venv (te : type_expr) :
  (Yojson.Basic.t -> string list -> (value, string) result) =
  let named name =
    match name with
    | "Int"      -> scalar_decoder "decode_int"
    | "Float"    -> scalar_decoder "decode_float"
    | "String"   -> scalar_decoder "decode_string"
    | "Bool"     -> scalar_decoder "decode_bool"
    | "Path"     -> scalar_decoder "decode_path"
    | "Duration" -> scalar_decoder "decode_duration"
    | "URL"      -> scalar_decoder "decode_url"
    | "Size"     -> scalar_decoder "decode_size"
    | "Version"  -> scalar_decoder "decode_version"
    | "Date"     -> scalar_decoder "decode_date"
    | "Time"     -> scalar_decoder "decode_time"
    | "DateTime" -> scalar_decoder "decode_datetime"
    | "IPv4"     -> scalar_decoder "decode_ipv4"
    | "CIDR"     -> scalar_decoder "decode_cidr"
    | "Port"     -> scalar_decoder "decode_port"
    | tname ->
      (* Another named type: looked up when a field is decoded, so a type may
         mention itself. *)
      (fun j path -> derived_decoder tname [] j path)
  in
  match te with
  | TEName name -> named name
  (* A decoder is derived from the declaration, which the module registered
     under the type's own name. *)
  | TEQual (_, name) -> named name
  | TEVar v ->
    (match List.assoc_opt v venv with
     | Some d -> d
     | None ->
       raise (Not_derivable (Printf.sprintf
         "a decoder cannot be derived for the type variable '%s" v)))
  | TEApp (TEName "List", inner) ->
    let elem = decoder_of_type_expr venv inner in
    (fun j path ->
      match j with
      | `List items ->
        let rec go i acc = function
          | [] -> Ok (VList (List.rev acc))
          | x :: rest ->
            (match elem x (Printf.sprintf "[%d]" i :: path) with
             | Ok v      -> go (i + 1) (v :: acc) rest
             | Error msg -> Error msg)
        in
        go 0 [] items
      | _ -> expected "a list" path j)
  | TETuple _ ->
    raise (Not_derivable
      "a field holds a tuple, which has no field names to read it by")
  | TEFun _ ->
    raise (Not_derivable "a field holds a function, which no document contains")
  | TEApp (TEName "Map", inner) ->
    let elem = decoder_of_type_expr venv inner in
    (fun j path ->
      match j with
      | `Assoc kvs ->
        let rec go acc = function
          | [] -> Ok (VMap (map_of_pairs (List.rev acc)))
          | (k, v) :: rest ->
            (match elem v (("." ^ k) :: path) with
             | Ok x      -> go ((k, x) :: acc) rest
             | Error msg -> Error msg)
        in
        go [] kvs
      | _ -> expected "an object" path j)
  | TEApp _ ->
    (* A generic type applied to something: `Tree 'a`, `Paged Pod`. Its own
       parameters are bound to decoders for the arguments, built here in the
       environment the mention stands in. *)
    (match type_spine te with
     | (Some tname, args) when Hashtbl.mem derivable tname ->
       let arg_decoders = List.map (decoder_of_type_expr venv) args in
       (fun j path -> derived_decoder tname arg_decoders j path)
     | _ -> raise (Not_derivable "a field holds a type no decoder is known for"))

(* A builtin decoder, by the name it is registered under. *)
and scalar_decoder name j path =
  match List.assoc_opt name !decode_registry with
  | Some (VDecoder d) -> d j path
  | _ -> raise (EvalError ("derive: no builtin decoder " ^ name))

and derived_decoder tname arg_decoders j path =
  match Hashtbl.find_opt derivable tname with
  | None ->
    Error (Printf.sprintf "no decoder for type '%s'" tname)
  | Some (ctor, params, fields) ->
    let venv =
      try List.combine params arg_decoders
      with Invalid_argument _ ->
        raise (EvalError (Printf.sprintf
          "'%s' takes %d type argument(s)" tname (List.length params)))
    in
    let defaults = defaults_of (ctor_named ctor) in
    let rec go acc = function
      | [] -> Ok (VConstr ((ctor_named ctor), List.rev acc))
      | (fname, te) :: rest ->
        let key = match fname with Some n -> n | None -> "" in
        (match read_field venv ~defaults key te j path with
         | Ok v      -> go (v :: acc) rest
         | Error msg -> Error msg)
    in
    (match j with
     | `Assoc _ -> go [] fields
     | _ -> expected "an object" path j)

(* One field of a derived decoder. A field whose type is an `Option` may be
   absent -- that is what the type says -- and every other field may not,
   unless it declares a default: a field left out of the document is the
   same case as a field left out of a construction, and takes the same
   value. A document has null where the language has nothing, and
   `Decode.optional` already reads absent and null alike, so a default
   answers for both. *)
and read_field venv ?(defaults = []) key te j path =
  let kvs = match j with `Assoc kvs -> kvs | _ -> [] in
  let absent () =
    match List.assoc_opt key defaults with
    | Some d -> Some (eval (ctor_env ()) d)
    | None -> None
  in
  match te with
  (* A flag is present or absent, and `Bool` is the type with a word for
     absent, so a document without the key reads as `false` -- the same
     reading `Option` has always had, in the type that a command line
     actually uses for it. Without this a `Bool` field had to carry a
     default to be usable at all, and `Args.parse_with ["verbose"]` failed
     on every line that left `--verbose` off. *)
  | TEName "Bool" when assoc_last key kvs = None ->
    (match absent () with
     | Some v -> Ok v
     | None -> Ok (VBool false))
  | TEApp (TEName "Option", inner) ->
    let d = decoder_of_type_expr venv inner in
    (match assoc_last key kvs with
     | None | Some `Null ->
       (match absent () with
        | Some v -> Ok v
        | None -> Ok (VConstr (Ctor.Builtin "None", [])))
     | Some v ->
       (match d v (("." ^ key) :: path) with
        | Ok x      -> Ok (VConstr (Ctor.Builtin "Some", [x]))
        | Error msg -> Error msg))
  | _ ->
    let d = decoder_of_type_expr venv te in
    let here = ("." ^ key) :: path in
    (match assoc_last key kvs with
     | Some `Null | None ->
       (match absent () with
        | Some v -> Ok v
        | None ->
          (match assoc_last key kvs with
           | Some v -> d v here
           | None -> decode_error here "no such field"))
     | Some v -> d v here)

(* ── Derived encoders ─────────────────────────────────────────────────────
   The other direction, and a much smaller thing: encoding cannot fail, so
   there is no error to thread and no path to carry. That is why an encoder
   is an ordinary function `'a -> JSON` rather than a type of its own --
   `JSON` and its constructors already exist, and a second abstraction beside
   `Decoder` would earn nothing.

   It works from the value rather than from the type, since a value carries
   its own tag and cannot disagree with itself. A field holding `None` is
   left out rather than written as null: both read back as `None`, and a
   config is tidier without the empty keys. *)
(* Encoding walks the field types when a type variable is involved, so an
   encoder passed in for a parameter is the one that runs. Everywhere else it
   falls through to the value, which carries its own tag. *)
and json_of_typed venv (te : type_expr) (v : value) : Yojson.Basic.t =
  match te, v with
  | TEVar name, _ ->
    (match List.assoc_opt name venv with
     | Some f ->
       (match apply f v with
        | VJson j -> j
        | other   -> json_of_value other)
     | None -> json_of_value v)
  | TEApp (TEName "Option", _), VConstr (Ctor.Builtin "None", []) -> `Null
  | TEApp (TEName "Option", inner), VConstr (Ctor.Builtin "Some", [x]) -> json_of_typed venv inner x
  | TEApp (TEName "List", inner), VList vs ->
    `List (List.map (json_of_typed venv inner) vs)
  | TEApp (TEName "Map", inner), VMap kvs ->
    `Assoc (List.map (fun (k, x) -> (k, json_of_typed venv inner x)) kvs)
  | _, VConstr (_, _) ->
    (match type_spine te with
     | (Some tname, args) when Hashtbl.mem derivable tname ->
       let arg_encoders =
         List.map (fun a ->
           VBuiltin (fun x -> VJson (json_of_typed venv a x))) args
       in
       (match encoded_with tname arg_encoders v with
        | VJson j -> j
        | other -> json_of_value other)
     | _ -> json_of_value v)
  | _ -> json_of_value v

and json_of_value (v : value) : Yojson.Basic.t =
  match v with
  | VInt n    -> `Int n
  | VFloat f  -> `Float f
  | VString s -> `String s
  | VBool b   -> `Bool b
  | VUnit     -> `Null
  | VPath s | VDuration s | VURL s | VSize s | VVersion s
  | VDateTime s | VIPv4 s | VCIDR s | VGlob s -> `String s
  (* A port reads back from either spelling, so it goes out as the number a
     document would have held. *)
  | VPort n -> `Int n
  | VList vs -> `List (List.map json_of_value vs)
  | VMap kvs -> `Assoc (List.map (fun (k, v) -> (k, json_of_value v)) kvs)
  | VJson j -> j
  | VConstr (Ctor.Builtin "None", []) -> `Null
  | VConstr (Ctor.Builtin "Some", [x]) -> json_of_value x
  | VConstr (ctor, vals) ->
    (match Hashtbl.find_opt constr_fields ctor with
     | Some names when List.length names = List.length vals ->
       let pairs =
         List.concat (List.map2 (fun n v ->
           match n, v with
           | Some _, VConstr (Ctor.Builtin "None", []) -> []   (* absent, not null *)
           | Some name, v -> [(name, json_of_value v)]
           | None, _ -> []) names vals)
       in
       `Assoc pairs
     | _ ->
       raise (EvalError (Printf.sprintf
         "cannot encode '%s': it has no named fields" (Ctor.name ctor))))
  | _ -> raise (EvalError "cannot encode this value as JSON")

and encoded_with tname arg_encoders v =
  match Hashtbl.find_opt derivable tname with
  | None -> raise (EvalError (Printf.sprintf "no encoder for type '%s'" tname))
  | Some (_, params, fields) ->
    let venv =
      try List.combine params arg_encoders
      with Invalid_argument _ ->
        raise (EvalError (Printf.sprintf
          "'%s' takes %d type argument(s)" tname (List.length params)))
    in
    (match v with
     | VConstr (_, vals) when List.length vals = List.length fields ->
       let pairs =
         List.concat (List.map2 (fun (fname, te) x ->
           match fname, x with
           (* A field holding None is left out rather than written as null. *)
           | Some _, VConstr (Ctor.Builtin "None", []) -> []
           | Some name, x -> [(name, json_of_typed venv te x)]
           | None, _ -> []) fields vals)
       in
       VJson (`Assoc pairs)
     | _ -> VJson (json_of_value v))

(* What `T.encoder` is worth: a function from the type, after one encoder per
   parameter. Encoding cannot fail, so these are plain functions to JSON. *)
and encoder_value tname =
  match Hashtbl.find_opt derivable tname with
  | None -> raise (EvalError (Printf.sprintf "no encoder for type '%s'" tname))
  | Some (_, params, _) ->
    let rec collect n acc =
      if n = 0 then VBuiltin (fun v -> encoded_with tname (List.rev acc) v)
      else VBuiltin (fun f -> collect (n - 1) (f :: acc))
    in
    collect (List.length params) []

(* What `T.decoder` is worth. A type with no parameters is a decoder; one
   with parameters is a function taking a decoder for each, in the order the
   type declares them -- `Box.decoder : Decoder 'a -> Decoder (Box 'a)`. *)
(* The decoder that reads a command line, as opposed to a document. `Args`
   builds one flat object -- the flags by name, and everything written
   without a flag under `_` -- and a type that describes a whole command line
   is two levels: its record field is those flags, and its other field is
   what was under `_`. So the mapping is here rather than in `Args`, which
   would have to be told the field names to do it, and rather than in
   `T.decoder`, which reads a document and has to keep doing so. *)
and reader_value tname =
  match Hashtbl.find_opt derivable tname with
  | None -> raise (EvalError (Printf.sprintf "no reader for type '%s'" tname))
  | Some (ctor, _, fields) ->
    (match cmdline_parts fields with
     (* No record field: every field is a flag, which is what the decoder
        already reads. *)
     | None -> decoder_value tname
     | Some (fname, ftype, aname, ate) ->
       VDecoder (fun j path ->
         (* The flags are read from the same object, not from a key of their
            own: `--port` is at the top of what `Args` built. *)
         match derived_decoder ftype [] j path with
         | Error msg -> Error msg
         | Ok flags ->
           let written =
             match j with
             | `Assoc kvs ->
               (match assoc_last "_" kvs with
                | Some (`List vs) -> vs
                | _ -> [])
             | _ -> []
           in
           let (arity, inner) = argument_arity ate in
           let d = decoder_of_type_expr [] inner in
           let here = ("." ^ aname) :: path in
           let read_one v = d v here in
           let build v = Ok (VConstr ((ctor_named ctor),
             List.map (fun (n, _) ->
               if n = Some fname then flags else v) fields))
           in
           (match arity, written with
            | `Many, vs ->
              let rec go acc = function
                | [] -> Ok (VList (List.rev acc))
                | v :: rest ->
                  (match read_one v with
                   | Ok x -> go (x :: acc) rest
                   | Error msg -> Error msg)
              in
              (match go [] vs with Ok l -> build l | Error msg -> Error msg)
            | `Maybe, [] -> build (VConstr (Ctor.Builtin "None", []))
            | `Maybe, [v] ->
              (match read_one v with
               | Ok x -> build (VConstr (Ctor.Builtin "Some", [x]))
               | Error msg -> Error msg)
            | `Maybe, vs ->
              decode_error here (Printf.sprintf
                "expected at most one %s, got %d" aname (List.length vs))
            | `One, [v] ->
              (match read_one v with Ok x -> build x | Error msg -> Error msg)
            | `One, [] ->
              decode_error here (Printf.sprintf "expected a %s" aname)
            | `One, vs ->
              decode_error here (Printf.sprintf
                "expected one %s, got %d" aname (List.length vs)))))

and decoder_value tname =
  match Hashtbl.find_opt derivable tname with
  | None -> raise (EvalError (Printf.sprintf "no decoder for type '%s'" tname))
  | Some (_, params, _) ->
    let rec collect n acc =
      if n = 0 then VDecoder (fun j path -> derived_decoder tname (List.rev acc) j path)
      else
        VBuiltin (fun d ->
          match d with
          | VDecoder inner -> collect (n - 1) (inner :: acc)
          | _ -> raise (EvalError (tname ^ ".decoder: expected a Decoder")))
    in
    collect (List.length params) []

and decode_registry : env ref = ref []

let as_decoder who = function
  | VDecoder d -> d
  | _ -> raise (EvalError (who ^ ": expected a Decoder"))

(* Backends that produce one record per row or per line share this: each
   record is decoded at its own index, so a failure says which row it was
   in before it says what was wrong with it. *)
let decode_each inner items =
  let rec go i acc = function
    | [] -> VConstr (Ctor.Builtin "Ok", [VList (List.rev acc)])
    | x :: rest ->
      (match inner x [Printf.sprintf "[%d]" i] with
       | Ok v      -> go (i + 1) (v :: acc) rest
       | Error msg -> VConstr (Ctor.Builtin "Error", [VString msg]))
  in
  go 0 [] items

let decode_builtins : env = [
  ("decode_int", VDecoder (fun j path ->
    match j, from_text int_of_string_opt j with
    | `Int n, _   -> Ok (VInt n)
    | _, Some n   -> Ok (VInt n)
    | _           -> expected "Int" path j));
  ("decode_float", VDecoder (fun j path ->
    match j, from_text float_of_string_opt j with
    (* A whole number in a document is an Int to a parser and a Float to
       whoever wrote it. Reading one as a Float is not a coercion the other
       way round: nothing is lost. *)
    | `Float f, _ -> Ok (VFloat f)
    | `Int n, _   -> Ok (VFloat (float_of_int n))
    | _, Some f   -> Ok (VFloat f)
    | _           -> expected "Float" path j));
  ("decode_string", VDecoder (fun j path ->
    match j with `String s -> Ok (VString s) | _ -> expected "String" path j));
  ("decode_bool", VDecoder (fun j path ->
    let as_bool s = match String.lowercase_ascii s with
      | "true"  -> Some true
      | "false" -> Some false
      | _       -> None
    in
    match j, from_text as_bool j with
    | `Bool b, _ -> Ok (VBool b)
    | _, Some b  -> Ok (VBool b)
    | _          -> expected "Bool" path j));
  (* The two ends of `and_then`: a decoder that reads nothing and answers,
     and one that refuses. Without them `and_then` has nothing to return. *)
  ("decode_succeed", VBuiltin (fun v -> VDecoder (fun _ _ -> Ok v)));
  ("decode_fail", VBuiltin (function
    | VString msg -> VDecoder (fun _ path -> decode_error path msg)
    | _ -> raise (EvalError "decode_fail: expected String")));
  ("decode_field", VBuiltin (function
    | VString key -> VBuiltin (fun d ->
      let inner = as_decoder "decode_field" d in
      VDecoder (fun j path ->
        match j with
        | `Assoc kvs ->
          let here = ("." ^ key) :: path in
          (match assoc_last key kvs with
           | Some v -> inner v here
           | None   -> decode_error here "no such field")
        | _ -> expected "an object" path j))
    | _ -> raise (EvalError "decode_field: key must be String")));
  (* Absence is an answer; a value that will not decode is not.
     `one_of [field name inner, succeed None]` is the version that writes
     itself, and it is wrong: it turns a renamed or retyped field into None
     as readily as a missing one, which is the silent null this whole layer
     exists to replace. Absence is decided here, where it can be told apart
     from failure, and a present field is decoded exactly as `field` would.
     A null is absence written down, so it answers None too. *)
  ("decode_optional", VBuiltin (function
    | VString key -> VBuiltin (fun d ->
      let inner = as_decoder "decode_optional" d in
      VDecoder (fun j path ->
        match j with
        | `Assoc kvs ->
          (match assoc_last key kvs with
           | None | Some `Null -> Ok (VConstr (Ctor.Builtin "None", []))
           | Some v ->
             (match inner v (("." ^ key) :: path) with
              | Ok x      -> Ok (VConstr (Ctor.Builtin "Some", [x]))
              | Error msg -> Error msg))
        | _ -> expected "an object" path j))
    | _ -> raise (EvalError "decode_optional: key must be String")));
  (* An object whose keys are data rather than field names -- a label map,
     per-host counts, anything keyed by a name the program does not know in
     advance. The keys become the Map's keys; a failure names the key it was
     under, exactly as a field would. *)
  ("decode_dict", VBuiltin (fun d ->
    let inner = as_decoder "decode_dict" d in
    VDecoder (fun j path ->
      match j with
      | `Assoc kvs ->
        let rec go acc = function
          | [] -> Ok (VMap (map_of_pairs (List.rev acc)))
          | (k, v) :: rest ->
            (match inner v (("." ^ k) :: path) with
             | Ok x      -> go ((k, x) :: acc) rest
             | Error msg -> Error msg)
        in
        go [] kvs
      | _ -> expected "an object" path j)));
  (* A value that may be null, where no field lookup is involved -- an
     element of a list, say. `optional` is the field-level sibling: it
     answers whether the field is *there*, which is a question only a lookup
     can ask. This one answers whether the value is null. *)
  ("decode_nullable", VBuiltin (fun d ->
    let inner = as_decoder "decode_nullable" d in
    VDecoder (fun j path ->
      match j with
      | `Null -> Ok (VConstr (Ctor.Builtin "None", []))
      | _ ->
        (match inner j path with
         | Ok v      -> Ok (VConstr (Ctor.Builtin "Some", [v]))
         | Error msg -> Error msg))));
  ("decode_list", VBuiltin (fun d ->
    let inner = as_decoder "decode_list" d in
    VDecoder (fun j path ->
      match j with
      | `List items ->
        (* The first element that fails stops the list: a decoder answers
           with a value or with the one thing that went wrong. *)
        let rec go i acc = function
          | [] -> Ok (VList (List.rev acc))
          | x :: rest ->
            (match inner x (Printf.sprintf "[%d]" i :: path) with
             | Ok v      -> go (i + 1) (v :: acc) rest
             | Error msg -> Error msg)
        in
        go 0 [] items
      | _ -> expected "a list" path j)));
  ("decode_map2", VBuiltin (fun f -> VBuiltin (fun da -> VBuiltin (fun db ->
    let a = as_decoder "decode_map2" da in
    let b = as_decoder "decode_map2" db in
    VDecoder (fun j path ->
      match a j path with
      | Error msg -> Error msg
      | Ok va ->
        (match b j path with
         | Error msg -> Error msg
         | Ok vb -> Ok (apply (apply f va) vb)))))));
  ("decode_and_then", VBuiltin (fun f -> VBuiltin (fun d ->
    let inner = as_decoder "decode_and_then" d in
    VDecoder (fun j path ->
      match inner j path with
      | Error msg -> Error msg
      | Ok v -> (as_decoder "decode_and_then" (apply f v)) j path))));
  ("decode_one_of", VBuiltin (function
    | VList ds ->
      let inners = List.map (as_decoder "decode_one_of") ds in
      VDecoder (fun j path ->
        (* Every alternative's complaint is kept. One of them is the reason
           the data is not what was expected, and which one is not for the
           decoder to guess. *)
        let rec go tried = function
          | [] ->
            decode_error path
              ("no alternative matched" ^
               (match List.rev tried with
                | [] -> ""
                | msgs -> ": " ^ String.concat "; " msgs))
          | d :: rest ->
            (match d j path with
             | Ok v      -> Ok v
             | Error msg -> go (msg :: tried) rest)
        in
        go [] inners)
    | _ -> raise (EvalError "decode_one_of: expected List")));
  (* A domain literal decodes as itself: `"30s"` in a document lexes exactly
     as `30s` in a script, so the boundary produces the same Duration the
     rest of the program is written against. *)
  ("decode_path", VDecoder (fun j path ->
    match j with `String s -> Ok (VPath s) | _ -> expected "Path" path j));
  ("decode_duration", VDecoder (decode_lexed "Duration"
    (function Token.Duration v -> Some (VDuration v) | _ -> None)));
  ("decode_url", VDecoder (decode_lexed "URL"
    (function Token.URL v -> Some (VURL v) | _ -> None)));
  ("decode_size", VDecoder (decode_lexed "Size"
    (function Token.Size v -> Some (VSize v) | _ -> None)));
  ("decode_version", VDecoder (decode_lexed "Version"
    (function Token.Version v -> Some (VVersion v) | _ -> None)));
  ("decode_datetime", VDecoder (decode_lexed "DateTime"
    (function Token.DateTime v -> Some (VDateTime v) | _ -> None)));
  ("decode_ipv4", VDecoder (decode_lexed "IPv4"
    (function Token.IPv4 v -> Some (VIPv4 v) | _ -> None)));
  ("decode_cidr", VDecoder (decode_lexed "CIDR"
    (function Token.CIDR v -> Some (VCIDR v) | _ -> None)));
  (* A port is written `:8080` in a script. In a document it is usually the
     number on its own, which is what a config file or an API contains, and
     sometimes the script's own form. All three go through the lexer in the
     end, so what a decoder accepts is exactly what could have been written
     in the source -- one rule rather than two that drift apart. *)
  ("decode_port", VDecoder (fun j path ->
    (* Out of range is the one case where the number matters more than its
       type, and the lexer has the sentence for it: "expected Port, got Int"
       would be describing what is right about it. *)
    let read text =
      match lex_single (port_text text) with
      | Ok (Token.Port n)  -> Ok (VPort n)
      | Error (Some why)   -> decode_error path why
      | _ ->
        (match j with
         | `Int n -> decode_error path (Printf.sprintf "expected Port, got %d" n)
         | _ -> expected "Port" path j)
    in
    match j with
    | `Int n    -> read (string_of_int n)
    | `String s -> read s
    | _ -> expected "Port" path j));
  ("json_decode", VBuiltin (fun d ->
    let inner = as_decoder "json_decode" d in
    VBuiltin (function
      | VJson j ->
        (match inner j [] with
         | Ok v      -> VConstr (Ctor.Builtin "Ok", [v])
         | Error msg -> VConstr (Ctor.Builtin "Error", [VString msg]))
      | _ -> raise (EvalError "json_decode: expected JSON"))));
  ("toml_decode", VBuiltin (fun d ->
    let inner = as_decoder "toml_decode" d in
    VBuiltin (function
      | VToml t ->
        (match inner (json_of_toml t) [] with
         | Ok v      -> VConstr (Ctor.Builtin "Ok", [v])
         | Error msg -> VConstr (Ctor.Builtin "Error", [VString msg]))
      | _ -> raise (EvalError "toml_decode: expected TOML"))));
  (* One record per line, and the line is text: a command's output has no
     types of its own, so `Decode.int` reads the digits. *)
  ("shell_lines", VBuiltin (fun d ->
    let inner = as_decoder "shell_lines" d in
    VBuiltin (function
      | VString s ->
        (* $() strips the trailing newline, so a non-empty capture has one
           line per record and an empty capture has none -- not one empty
           line, which is the mistake every hand-written count makes. *)
        let lines = if String.trim s = "" then [] else String.split_on_char '\n' s in
        decode_each inner (List.map (fun l -> `String l) lines)
      | _ -> raise (EvalError "shell_lines: expected String"))));
  ("shell_decode", VBuiltin (fun d ->
    let inner = as_decoder "shell_decode" d in
    VBuiltin (function
      | VString s ->
        (match inner (`String (String.trim s)) [] with
         | Ok v      -> VConstr (Ctor.Builtin "Ok", [v])
         | Error msg -> VConstr (Ctor.Builtin "Error", [VString msg]))
      | _ -> raise (EvalError "shell_decode: expected String"))));
  (* A CSV's first row names the columns, so a row arrives as an object and
     is read by field name like anything else. A file without a header is
     what `CSV.parse` is for. *)
  ("csv_rows", VBuiltin (fun d ->
    let inner = as_decoder "csv_rows" d in
    VBuiltin (function
      | VString s ->
        (match csv_parse_string "," s with
         | [] -> VConstr (Ctor.Builtin "Ok", [VList []])
         | header :: rows ->
           let as_object row =
             let rec pair hs cs = match hs, cs with
               | [], _ | _, [] -> []
               | h :: hs', c :: cs' -> (h, `String c) :: pair hs' cs'
             in
             `Assoc (pair header row)
           in
           decode_each inner (List.map as_object rows))
      | _ -> raise (EvalError "csv_rows: expected String"))));
]

(* Derivation reaches the builtin decoders by name, so it needs them after
   they are defined rather than while they are being defined. *)
let () = decode_registry := decode_builtins
let () = derive_decoder := decoder_value
let () = derive_encoder := encoder_value

(* ── Derived usage ────────────────────────────────────────────────────────
   What a command line reading this type looks like. `Args` turns argv into a
   document and a decoder reads it, so the flags are the fields, and the same
   declaration that decides how one is read decides how it is written down.
   The line that used to be a string beside the type could disagree with it;
   this cannot. *)

(* The type as a placeholder for what the flag takes. A flag's value arrives
   as a word, so what a reader needs is the name of the thing that word has
   to be. *)
let rec usage_type_name (te : Ast.type_expr) =
  match te with
  | Ast.TEName n -> n
  | Ast.TEQual (_, n) -> n
  | Ast.TEVar v -> "'" ^ v
  | Ast.TEApp (f, a) -> usage_type_name f ^ " " ^ usage_type_name a
  | Ast.TETuple ts ->
    "(" ^ String.concat ", " (List.map usage_type_name ts) ^ ")"
  | Ast.TEFun _ -> "function"

let rec usage_value tname =
  match Hashtbl.find_opt derivable tname with
  | None -> raise (EvalError (Printf.sprintf "no usage for type '%s'" tname))
  | Some (ctor, _, fields) ->
    (* A type that describes a whole command line prints its flags, then
       what it takes without one. *)
    (match cmdline_parts fields with
     | Some (_, ftype, aname, ate) ->
       let flags = match usage_value ftype with VString s -> s | _ -> "" in
       let arg = match fst (argument_arity ate) with
         | `Many  -> Printf.sprintf "<%s>..." aname
         | `Maybe -> Printf.sprintf "[<%s>]" aname
         | `One   -> Printf.sprintf "<%s>" aname
       in
       VString (if flags = "" then arg else flags ^ " " ^ arg)
     | None ->
    let defaults = defaults_of (ctor_named ctor) in
    let part (fname, te) =
      match fname with
      | None -> ""
      | Some name ->
        let default = List.assoc_opt name defaults in
        (match te with
         (* A flag with nothing after it: `Args.parse_with` reads it as
            present-or-absent, so there is no value to show. *)
         | Ast.TEName "Bool" -> "[--" ^ name ^ "]"
         (* The type already says this one may be left out. Its default, if
            it has one, is `Some` something, which is a spelling of the
            language rather than of a command line. *)
         | Ast.TEApp (Ast.TEName "Option", inner) ->
           Printf.sprintf "[--%s <%s>]" name (usage_type_name inner)
         | _ ->
           (match default with
            | Some d ->
              Printf.sprintf "[--%s %s]" name (to_text (eval (ctor_env ()) d))
            | None -> Printf.sprintf "--%s <%s>" name (usage_type_name te)))
    in
    VString (String.concat " " (List.filter (fun p -> p <> "")
      (List.map part fields))))

let () = derive_reader := reader_value

let () = derive_usage := usage_value

(* Everything a command line needs said about a flag that its own text cannot
   say. A `Bool` takes no value, and a `List` collects rather than replacing:
   `--tag a --tag b` is two tags, where `--name a --name b` is one name,
   written twice. Both are facts about the type, and neither is visible in
   argv -- a flag written once looks the same either way.

   Fields that need nothing said are left out, so the map is empty for a type
   whose flags all take one value. *)
let rec spec_value tname =
  match Hashtbl.find_opt derivable tname with
  | None -> raise (EvalError (Printf.sprintf "no spec for type '%s'" tname))
  | Some (_, _, fields) ->
    (* The flags of a whole command line are the record's, so the account of
       them is the record's too. *)
    match cmdline_parts fields with
    | Some (_, ftype, _, _) -> spec_value ftype
    | None ->
    VMap (List.filter_map (fun (fname, te) ->
      match fname, te with
      | Some name, Ast.TEName "Bool" -> Some (name, VString "switch")
      | Some name, Ast.TEApp (Ast.TEName "List", _) ->
        Some (name, VString "repeated")
      | _ -> None) fields)

let () = derive_spec := spec_value

(* Any wand value as TOML. TOML has no way to write a bare scalar, so the
   top level must be a table -- a map or a record -- and anything else says
   so rather than producing a document nothing can read.

   An array in this representation is homogeneous: the library holds one
   node per element type, so a list wand allows through its own `List 'a`
   is already uniform, and an empty one is `NodeEmpty`. *)
let rec toml_of_value (v : value) : Toml.Types.value =
  match v with
  | VInt n    -> Toml.Types.TInt n
  | VFloat f  -> Toml.Types.TFloat f
  | VString s -> Toml.Types.TString s
  | VBool b   -> Toml.Types.TBool b
  | VPath s | VDuration s | VURL s | VSize s | VVersion s
  | VDateTime s | VIPv4 s | VCIDR s | VGlob s -> Toml.Types.TString s
  | VPort n -> Toml.Types.TInt n
  | VConstr (Ctor.Builtin "Some", [x]) -> toml_of_value x
  | VList vs -> Toml.Types.TArray (toml_array vs)
  | VMap kvs -> Toml.Types.TTable (toml_table kvs)
  | VRecord kvs -> Toml.Types.TTable (toml_table kvs)
  | VConstr (ctor, vals) ->
    (match Hashtbl.find_opt constr_fields ctor with
     | Some names when List.length names = List.length vals ->
       let pairs =
         List.concat (List.map2 (fun n v ->
           match n, v with
           | Some _, VConstr (Ctor.Builtin "None", []) -> []   (* absent, not empty *)
           | Some name, v -> [(name, v)]
           | None, _ -> []) names vals)
       in
       Toml.Types.TTable (toml_table pairs)
     | _ ->
       raise (EvalError (Printf.sprintf
         "cannot write '%s' as TOML: it has no named fields" (Ctor.name ctor))))
  | _ -> raise (EvalError "cannot write this value as TOML")

and toml_table kvs =
  List.fold_left (fun tbl (k, v) ->
    (* A key that is absent is left out rather than written empty: TOML has
       no null, so the two would not read back the same. *)
    match v with
    | VConstr (Ctor.Builtin "None", []) -> tbl
    | _ -> Toml.Types.Table.add (Toml.Min.key k) (toml_of_value v) tbl)
    Toml.Types.Table.empty kvs

and toml_array vs =
  match List.map toml_of_value vs with
  | [] -> Toml.Types.NodeEmpty
  | Toml.Types.TInt _ :: _ as ts ->
    Toml.Types.NodeInt (List.map (function Toml.Types.TInt n -> n | _ -> 0) ts)
  | Toml.Types.TFloat _ :: _ as ts ->
    Toml.Types.NodeFloat (List.map (function Toml.Types.TFloat f -> f | _ -> 0.) ts)
  | Toml.Types.TBool _ :: _ as ts ->
    Toml.Types.NodeBool (List.map (function Toml.Types.TBool b -> b | _ -> false) ts)
  | Toml.Types.TString _ :: _ as ts ->
    Toml.Types.NodeString (List.map (function Toml.Types.TString s -> s | _ -> "") ts)
  | Toml.Types.TTable _ :: _ as ts ->
    Toml.Types.NodeTable (List.map (function Toml.Types.TTable t -> t | _ -> Toml.Types.Table.empty) ts)
  | Toml.Types.TArray _ :: _ as ts ->
    Toml.Types.NodeArray (List.map (function Toml.Types.TArray a -> a | _ -> Toml.Types.NodeEmpty) ts)
  | _ -> raise (EvalError "cannot write this list as a TOML array")

(* The top of a TOML document is a table, so a scalar is refused here rather
   than written into something no parser would accept back. *)
let toml_document v =
  match toml_of_value v with
  | Toml.Types.TTable _ as t -> t
  | _ ->
    raise (EvalError
      "a TOML document is a table: write a map or a record, not a bare value")

(* Any wand value as JSON, in one call, so a structure does not have to be
   converted a piece at a time. `json_of_value` already walks numbers, text,
   every domain type, lists, maps, options and records; what it cannot write
   is a function, a resource or a stream, and that is an `Error` rather than
   a raise. Registered here because it is defined after the table above. *)
let serialise_builtins : env = [
  ("json_of", VBuiltin (fun v ->
    match json_of_value v with
    | j -> VConstr (Ctor.Builtin "Ok", [VJson j])
    | exception EvalError m -> VConstr (Ctor.Builtin "Error", [VString m])));
  ("json_of_exn", VBuiltin (fun v -> VJson (json_of_value v)));
  ("toml_of", VBuiltin (fun v ->
    match toml_document v with
    | t -> VConstr (Ctor.Builtin "Ok", [VToml t])
    | exception EvalError m -> VConstr (Ctor.Builtin "Error", [VString m])));
  ("toml_of_exn", VBuiltin (fun v -> VToml (toml_document v)));
]

let stdlib_eval_env =
  stdlib_eval_env @ map_builtins @ decode_builtins @ stream_builtins
  (* `Option`'s constructors are built in, so a module reaches them the way
     it reaches a builtin function rather than by importing the module that
     used to declare the type. *)
  @ [ ("Some", VPartialConstr (Ctor.Builtin "Some", 1, []));
      ("None", VConstr (Ctor.Builtin "None", [])) ]
  @ serialise_builtins

(* Every function a file calls comes from a module it imported. These two
   are constructors of a built-in type, so there is no module to import
   them from. *)
let base_eval_env : env = [
  ("Ok",      VPartialConstr (Ctor.Builtin "Ok",    1, []));
  ("Error",   VPartialConstr (Ctor.Builtin "Error", 1, []));
  (* `Option` is built in, so its constructors are here beside `Result`'s
     rather than arriving with an import. *)
  ("Some",    VPartialConstr (Ctor.Builtin "Some",  1, []));
  ("None",    VConstr (Ctor.Builtin "None", []));
]
