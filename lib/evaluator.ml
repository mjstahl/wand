open Ast

(* ── Constructor field name registry ─────────────────────────────────────── *)

let constr_fields : (string, string option list) Hashtbl.t = Hashtbl.create 16

let () =
  Hashtbl.add constr_fields "ShellResult"
    [Some "stdout"; Some "stderr"; Some "code"]

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
  | VDate     of string
  | VTime     of string
  | VDateTime of string
  | VDuration of string
  | VUrl      of string
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
  | VConstr        of string * value list
  | VPartialConstr of string * int * value list
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

(* ── Display ──────────────────────────────────────────────────────────────── *)

let rec show_value = function
  | VInt n      -> string_of_int n
  | VFloat f    -> Printf.sprintf "%g" f
  | VString s   -> s
  | VBool b     -> string_of_bool b
  | VUnit       -> "()"
  | VPath s     -> s
  | VGlob s     -> s
  | VDate s     -> s
  | VTime s     -> s
  | VDateTime s -> s
  | VDuration s -> s
  | VUrl s      -> s
  | VIPv4 s     -> s
  | VCIDR s     -> s
  | VPort n     -> Printf.sprintf ":%d" n
  | VVersion s  -> s
  | VSize s     -> s
  | VRegex _    -> "<regex>"
  | VJson j     -> Yojson.Basic.to_string j
  | VToml v     ->
    (match v with
     | Toml.Types.TBool b   -> string_of_bool b
     | Toml.Types.TInt n    -> string_of_int n
     | Toml.Types.TFloat f  -> Printf.sprintf "%g" f
     | Toml.Types.TString s -> s
     | Toml.Types.TTable tbl -> Toml.Printer.string_of_table tbl
     | Toml.Types.TArray _  -> "<toml-array>"
     | Toml.Types.TDate _   -> "<toml-date>")
  | VFun _ | VFix _ | VFixGroup _ | VBuiltin _ -> "<fn>"
  | VResource _ -> "<resource>"
  | VStream _ -> "<stream>"
  | VLineSource _ -> "<line source>"
  | VDecoder _  -> "<decoder>"
  | VEnvIndex _ -> "<env index>"
  | VPartialConstr (n, _, _) -> Printf.sprintf "<%s>" n
  | VConstr (name, []) -> name
  | VConstr (name, vs) ->
    name ^ "(" ^ String.concat ", " (List.map show_value vs) ^ ")"
  | VTuple vs   ->
    "(" ^ String.concat ", " (List.map show_value vs) ^ ")"
  | VList vs    ->
    "[" ^ String.concat ", " (List.map show_value vs) ^ "]"
  | VMap kvs    ->
    "{" ^ String.concat ", " (List.map (fun (k, v) -> k ^ " = " ^ show_value v) kvs) ^ "}"
  | VRecord kvs ->
    "{ " ^ String.concat ", " (List.map (fun (k, v) ->
      k ^ " = " ^ show_value v) kvs) ^ " }"

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

let check_interrupt () =
  let code = Atomic.get interrupt_requested in
  if code <> 0 && !(Domain.DLS.get interrupts_deferred) = 0 then begin
    let taken = Domain.DLS.get interrupt_taken in
    if not !taken then begin taken := true; raise (Interrupted code) end
  end

(* Structural comparison that a script can catch. OCaml's `=` and `compare`
   raise Invalid_argument when they reach a closure, and a value may carry one
   -- a function, a builtin, a compiled regex or a decoder, directly or inside
   a list, tuple, Map or constructor. That exception is not an EvalError, so
   `try` re-raises it and the interpreter dies with a fatal error on code that
   typechecked: `==`, `!=` and `List.sort` all admit function-typed operands.
   Turning it into an EvalError makes it a value the language can see. *)
let wand_equal a b =
  try a = b
  with Invalid_argument _ ->
    raise (EvalError "cannot compare functions for equality")

let wand_compare a b =
  try compare a b
  with Invalid_argument _ ->
    raise (EvalError "cannot order functions")

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

(* Installs the runtime's own handlers. Set by the runner, which owns them. *)
let with_default_handler : ((unit -> value) -> value) ref = ref (fun f -> f ())

(* In a match arm, a list pattern states the whole shape: `[a, b]` is a
   two-element list and nothing else, because the arms discriminate and a
   longer list belongs to another arm. A destructuring `let` has no other
   arm -- it only binds -- so there `[a, b]` names the leading elements and
   whatever follows is ignored, the way a map pattern binds the keys it
   names and ignores the rest. [prefix] selects the binding reading. *)
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
    when name = vname && same_length pats vals ->
    List.fold_left2
      (fun acc p v -> match acc with
        | None     -> None
        | Some env -> try_match ~prefix p v env)
      (Some env) pats vals
  | PConstrNamed (name, bindings), VConstr (vname, vals) when name = vname ->
    (match Hashtbl.find_opt constr_fields name with
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

let rec eval (env : env) (e : expr) : value =
  check_interrupt ();
  match e with
  | Int n      -> VInt n
  | Float f    -> VFloat f
  | String s   -> VString s
  | Bool b     -> VBool b
  | Unit       -> VUnit
  | Path s     -> VPath s
  | Glob s     -> VGlob s
  | Date s     -> VDate s
  | Time s     -> VTime s
  | DateTime s -> VDateTime s
  | Duration s -> VDuration s
  | Url s      -> VUrl s
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
    apply vf vx
  | Let (p, e1, e2) ->
    let v1 = eval env e1 in
    let v1 = match p, v1 with
      | PVar name, VFun (fenv, params, body) ->
        VFix (name, fenv, params, body)
      | _ -> v1
    in
    eval (bind_pat ~prefix:true p v1 env) e2
  | LetRec (bindings, e2) ->
    let env' = List.fold_left (fun acc (name, _, _) ->
      (name, VFixGroup (bindings, env, name)) :: acc) env bindings in
    eval env' e2
  | If (cond, then_, else_) ->
    (match eval env cond with
     | VBool true  -> eval env then_
     | VBool false -> eval env else_
     | _           -> raise (EvalError "if condition must be a bool"))
  | Match (scrutinee, cases) ->
    let sv = eval env scrutinee in
    eval_match env sv cases
  | Tuple es  -> VTuple (List.map (eval env) es)
  | List es   -> VList  (List.map (eval env) es)
  | ConstrApp (name, fields) ->
    let provided = List.filter_map (fun (fname_opt, e) ->
      match fname_opt with
      | Some fname -> Some (fname, eval env e)
      | None -> None
    ) fields in
    (match Hashtbl.find_opt constr_fields name with
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
            | None -> raise (EvalError (Printf.sprintf
                "constructor '%s' missing field '%s'" name fn)))
       ) field_names in
       VConstr (name, ordered))
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
                  "constructor '%s' is not fully applied" name)))
           | None -> raise (EvalError (Printf.sprintf
               "constructor '%s' has no field named '%s'" name label)))
        | None -> raise (EvalError (Printf.sprintf
            "constructor '%s' has no named fields" name)))
     | _ -> raise (EvalError "field access on non-record")))
  | Seq (a, b) ->
    ignore (eval env a); eval env b
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
    observed (fun () ->
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
      })
  | RawString s -> VString s
  | Interp (parts, tail) | RawInterp (parts, tail) ->
    let buf = Buffer.create 32 in
    List.iter (fun (lit, e) ->
      Buffer.add_string buf lit;
      Buffer.add_string buf (show_value (eval env e))
    ) parts;
    Buffer.add_string buf tail;
    VString (Buffer.contents buf)
  | CmdInterp (parts, tail) ->
    let buf = Buffer.create 32 in
    List.iter (fun (lit, e, h) ->
      Buffer.add_string buf lit;
      let v = show_value (eval env e) in
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
    Effect.Deep.match_with (fun () -> eval env e) ()
      { Effect.Deep.
          retc = (fun v -> VConstr ("Ok", [v]));
          exnc = (function
            | EvalError msg -> VConstr ("Error", [VString (Util.strip_loc_prefix msg)])
            | Failure  msg  -> VConstr ("Error", [VString (Util.strip_loc_prefix msg)])
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
  | Annot (_, e) -> eval env e
  | Located (loc, e) ->
    (try eval env e
     with EvalError msg ->
       if Util.has_loc_prefix msg then raise (EvalError msg)
       else raise (EvalError (Printf.sprintf "%d:%d: %s"
              loc.Token.line loc.Token.col msg)))

and apply vf vx =
  match vf with
  | VBuiltin f -> f vx
  | VFun (fenv, params, body) ->
    (match params with
     | []      -> raise (EvalError "function with no parameters")
     | [p]     -> eval (bind_pat p vx fenv) body
     | p :: rest ->
       let env' = bind_pat p vx fenv in
       VFun (env', rest, body))
  | VFix (name, fenv, params, body) ->
    let fenv' = (name, VFix (name, fenv, params, body)) :: fenv in
    apply (VFun (fenv', params, body)) vx
  | VFixGroup (bindings, fenv, my_name) ->
    let fenv' = List.fold_left (fun acc (n, _, _) ->
      (n, VFixGroup (bindings, fenv, n)) :: acc) fenv bindings in
    let (_, params, body) = List.find (fun (n, _, _) -> n = my_name) bindings in
    apply (VFun (fenv', params, body)) vx
  | VPartialConstr (name, 1, args) -> VConstr (name, args @ [vx])
  | VPartialConstr (name, n, args) -> VPartialConstr (name, n - 1, args @ [vx])
  | _ -> raise (EvalError "cannot apply a non-function")

and bind_pat ?(prefix = false) (p : pat) v (env : env) : env =
  match try_match ~prefix p v env with
  | Some env' -> env'
  | None      -> raise (EvalError "pattern match failure")

and eval_match (env : env) sv cases =
  match cases with
  | [] -> raise (EvalError "non-exhaustive match")
  | (p, guard, body) :: rest ->
    (match try_match p sv env with
     | None      -> eval_match env sv rest
     | Some env' ->
       let passes = match guard with
         | None   -> true
         | Some g ->
           (match eval env' g with
            | VBool b -> b
            | _       -> raise (EvalError "guard must evaluate to a bool"))
       in
       if passes then eval env' body
       else eval_match env sv rest)

and eval_binop (env : env) op a b : value =
  match op with
  | "+"  ->
    (match eval env a, eval env b with
     | VInt x,   VInt y   -> VInt (add_ovf x y)
     | VFloat x, VFloat y -> VFloat (x +. y)
     | _ -> raise (EvalError "'+' requires matching numeric types"))
  | "-"  ->
    (match eval env a, eval env b with
     | VInt x,   VInt y   -> VInt (sub_ovf x y)
     | VFloat x, VFloat y -> VFloat (x -. y)
     | _ -> raise (EvalError "'-' requires matching numeric types"))
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
  | ":" ->
    let vh = eval env a in
    (match eval env b with
     | VList vs -> VList (vh :: vs)
     | _        -> raise (EvalError "':' right side must be a list"))
  | "==" -> VBool (wand_equal (eval env a) (eval env b))
  | "!=" -> VBool (not (wand_equal (eval env a) (eval env b)))
  | "<"  ->
    (match eval env a, eval env b with
     | VInt x,   VInt y   -> VBool (x < y)
     | VFloat x, VFloat y -> VBool (x < y)
     | VString x, VString y -> VBool (x < y)
     | _ -> raise (EvalError "'<' requires comparable types"))
  | ">"  ->
    (match eval env a, eval env b with
     | VInt x,   VInt y   -> VBool (x > y)
     | VFloat x, VFloat y -> VBool (x > y)
     | VString x, VString y -> VBool (x > y)
     | _ -> raise (EvalError "'>' requires comparable types"))
  | "<=" ->
    (match eval env a, eval env b with
     | VInt x,   VInt y   -> VBool (x <= y)
     | VFloat x, VFloat y -> VBool (x <= y)
     | VString x, VString y -> VBool (x <= y)
     | _ -> raise (EvalError "'<=' requires comparable types"))
  | ">=" ->
    (match eval env a, eval env b with
     | VInt x,   VInt y   -> VBool (x >= y)
     | VFloat x, VFloat y -> VBool (x >= y)
     | VString x, VString y -> VBool (x >= y)
     | _ -> raise (EvalError "'>=' requires comparable types"))
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
       let stdin = show_value va in
       perform_shell "Shell!run" allow (VTuple [VString cmd; VString stdin])
     | RunQuery (e, allow) ->
       let cmd = match eval env e with
         | VString s -> s
         | _ -> raise (EvalError "$?(…) requires a string")
       in
       let stdin = show_value va in
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
     | Ok st   -> VInt st.Unix.st_size)
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
    VConstr ("Error", [VString (Printf.sprintf "cannot parse %S as %s" shown name)])
  in
  match lex_single s with
  | Ok tok -> (match build tok with Some v -> VConstr ("Ok", [v]) | None -> cannot ())
  | Error (Some why) -> VConstr ("Error", [VString why])
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
    let items = match arr with
      | Toml.Types.NodeBool bs   -> List.map (fun b -> Toml.Types.TBool b) bs
      | Toml.Types.NodeInt ns    -> List.map (fun n -> Toml.Types.TInt n) ns
      | Toml.Types.NodeFloat fs  -> List.map (fun f -> Toml.Types.TFloat f) fs
      | Toml.Types.NodeString ss -> List.map (fun s -> Toml.Types.TString s) ss
      | Toml.Types.NodeDate ds   -> List.map (fun d -> Toml.Types.TDate d) ds
      | Toml.Types.NodeTable ts  -> List.map (fun t -> Toml.Types.TTable t) ts
      | Toml.Types.NodeArray ars -> List.map (fun a -> Toml.Types.TArray a) ars
      | Toml.Types.NodeEmpty     -> []
    in
    `List (List.map json_of_toml items)

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
    | v -> if collect then VConstr ("Ok", [v]) else VUnit
    | exception EvalError msg ->
      (* A failure becomes a value, so it says what went wrong rather than
         where, exactly as `try` does. *)
      if collect then VConstr ("Error", [VString (Util.strip_loc_prefix msg)])
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
  ("print",      VBuiltin (fun v -> Effect.perform (WandEffect ("IO!print",   v))));
  ("println",    VBuiltin (fun v -> Effect.perform (WandEffect ("IO!println", v))));
  ("proc_exit",  performing "Proc!exit" (function VInt n -> raise (Interrupted n) | _ -> raise (EvalError "exit: expected Int")));
  ("option_get_exn", VBuiltin (function
    | VUnit -> raise (EvalError "Option.get!: called on None")
    | _ -> raise (EvalError "option_get_exn: expected Unit")));
  ("read_file",  VBuiltin (fun v -> Effect.perform (WandEffect ("FS!read_file",  v))));
  ("write_file", VBuiltin (fun path ->
    VBuiltin (fun content ->
      Effect.perform (WandEffect ("FS!write_file", VTuple [path; content])))));
  (* Result constructors *)
  ("Ok",    VPartialConstr ("Ok",    1, []));
  ("Error", VPartialConstr ("Error", 1, []));
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
  ("str_to_int", VBuiltin (function
    | VString s ->
      (match int_of_string_opt (String.trim s) with
       | Some n -> VConstr ("Ok",    [VInt n])
       | None   -> VConstr ("Error", [VString (Printf.sprintf "cannot parse %S as Int" s)]))
    | _ -> raise (EvalError "str_to_int: expected String")));
  ("str_to_float", VBuiltin (function
    | VString s ->
      (match float_of_string_opt (String.trim s) with
       | Some f -> VConstr ("Ok",    [VFloat f])
       | None   -> VConstr ("Error", [VString (Printf.sprintf "cannot parse %S as Float" s)]))
    | _ -> raise (EvalError "str_to_float: expected String")));
  ("str_to_bool", VBuiltin (function
    | VString s ->
      (match String.lowercase_ascii (String.trim s) with
       | "true"  -> VConstr ("Ok",    [VBool true])
       | "false" -> VConstr ("Ok",    [VBool false])
       | _       -> VConstr ("Error", [VString (Printf.sprintf "cannot parse %S as Bool" s)]))
    | _ -> raise (EvalError "str_to_bool: expected String")));
  ("str_to_path", VBuiltin (function
    | VString s -> VPath s
    | _ -> raise (EvalError "str_to_path: expected String")));
  ("str_to_url", VBuiltin (function
    | VString s -> to_domain "Url" (function Token.Url v -> Some (VUrl v) | _ -> None) s
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
  ("str_to_date", VBuiltin (function
    | VString s -> to_domain "Date" (function Token.Date v -> Some (VDate v) | _ -> None) s
    | _ -> raise (EvalError "str_to_date: expected String")));
  ("str_to_time", VBuiltin (function
    | VString s -> to_domain "Time" (function Token.Time v -> Some (VTime v) | _ -> None) s
    | _ -> raise (EvalError "str_to_time: expected String")));
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
          let rec collect path rel acc =
            if not (Sys.file_exists path) then acc
            else if Sys.is_directory path then begin
              let entries = Sys.readdir path in
              Array.sort String.compare entries;
              Array.fold_left (fun a name ->
                let child_path = Filename.concat path name in
                let child_rel  = if rel = "" then name
                                 else rel ^ "/" ^ name in
                collect child_path child_rel a) acc entries
            end else if Re.execp re rel then VPath path :: acc
            else acc
          in
          let results = List.rev (collect base "" []) in
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
      (try VConstr ("Ok", [VRegex (Re.compile (Re.Pcre.re pat))])
       with Re.Pcre.Parse_error ->
         VConstr ("Error", [VString (Printf.sprintf "invalid regex: %s" pat)]))
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
      | VPath s | VString s -> VPath (Filename.remove_extension s ^ ext)
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
            | v -> show_value v) fields
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
    | VJson (`Bool b) -> VConstr ("Ok", [VBool b])
    | VJson j -> VConstr ("Error", [VString ("expected bool, got " ^ Yojson.Basic.to_string j)])
    | _ -> raise (EvalError "json_get_bool: expected JSON")));
  ("json_get_int",   VBuiltin (function
    | VJson (`Int n) -> VConstr ("Ok", [VInt n])
    | VJson j -> VConstr ("Error", [VString ("expected int, got " ^ Yojson.Basic.to_string j)])
    | _ -> raise (EvalError "json_get_int: expected JSON")));
  ("json_get_float", VBuiltin (function
    | VJson (`Float f) -> VConstr ("Ok", [VFloat f])
    | VJson (`Int n)   -> VConstr ("Ok", [VFloat (float_of_int n)])
    | VJson j -> VConstr ("Error", [VString ("expected float, got " ^ Yojson.Basic.to_string j)])
    | _ -> raise (EvalError "json_get_float: expected JSON")));
  ("json_get_string", VBuiltin (function
    | VJson (`String s) -> VConstr ("Ok", [VString s])
    | VJson j -> VConstr ("Error", [VString ("expected string, got " ^ Yojson.Basic.to_string j)])
    | _ -> raise (EvalError "json_get_string: expected JSON")));
  ("json_get_array", VBuiltin (function
    | VJson (`List vs) -> VConstr ("Ok", [VList (List.map (fun j -> VJson j) vs)])
    | VJson j -> VConstr ("Error", [VString ("expected array, got " ^ Yojson.Basic.to_string j)])
    | _ -> raise (EvalError "json_get_array: expected JSON")));
  ("json_get_object", VBuiltin (function
    | VJson (`Assoc kvs) ->
      VConstr ("Ok", [VMap (map_of_pairs (List.map (fun (k, j) -> (k, VJson j)) kvs))])
    | VJson j -> VConstr ("Error", [VString ("expected object, got " ^ Yojson.Basic.to_string j)])
    | _ -> raise (EvalError "json_get_object: expected JSON")));
  ("json_field", VBuiltin (fun key ->
    VBuiltin (function
      | VJson (`Assoc kvs) ->
        let k = (match key with VString s -> s | _ -> raise (EvalError "json_field: key must be String")) in
        (match assoc_last k kvs with
         | Some j -> VConstr ("Ok", [VJson j])
         | None   -> VConstr ("Error", [VString ("no field: " ^ k)]))
      | VJson j -> VConstr ("Error", [VString ("expected object, got " ^ Yojson.Basic.to_string j)])
      | _ -> raise (EvalError "json_field: expected JSON"))));
  ("json_parse", VBuiltin (function
    | VString s ->
      (try VConstr ("Ok", [VJson (Yojson.Basic.from_string s)])
       with Yojson.Json_error msg -> VConstr ("Error", [VString msg]))
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
       | `Ok tbl  -> VConstr ("Ok", [VToml (Toml.Types.TTable tbl)])
       | `Error (msg, _) -> VConstr ("Error", [VString msg]))
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
    | VToml (Toml.Types.TBool b) -> VConstr ("Ok", [VBool b])
    | VToml _ -> VConstr ("Error", [VString "expected bool"])
    | _ -> raise (EvalError "toml_get_bool: expected TOML")));
  ("toml_get_int", VBuiltin (function
    | VToml (Toml.Types.TInt n) -> VConstr ("Ok", [VInt n])
    | VToml _ -> VConstr ("Error", [VString "expected int"])
    | _ -> raise (EvalError "toml_get_int: expected TOML")));
  ("toml_get_float", VBuiltin (function
    | VToml (Toml.Types.TFloat f) -> VConstr ("Ok", [VFloat f])
    | VToml (Toml.Types.TInt n)   -> VConstr ("Ok", [VFloat (float_of_int n)])
    | VToml _ -> VConstr ("Error", [VString "expected float"])
    | _ -> raise (EvalError "toml_get_float: expected TOML")));
  ("toml_get_string", VBuiltin (function
    | VToml (Toml.Types.TString s) -> VConstr ("Ok", [VString s])
    | VToml _ -> VConstr ("Error", [VString "expected string"])
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
      VConstr ("Ok", [VList items])
    | VToml _ -> VConstr ("Error", [VString "expected array"])
    | _ -> raise (EvalError "toml_get_array: expected TOML")));
  ("toml_get_table", VBuiltin (function
    | VToml (Toml.Types.TTable tbl) ->
      let pairs = Toml.Types.Table.to_list tbl in
      let vmap = VMap (List.map (fun (k, v) ->
        (Toml.Types.Table.Key.to_string k, VToml v)) pairs) in
      VConstr ("Ok", [vmap])
    | VToml _ -> VConstr ("Error", [VString "expected table"])
    | _ -> raise (EvalError "toml_get_table: expected TOML")));
  ("toml_field", VBuiltin (fun key ->
    VBuiltin (function
      | VToml (Toml.Types.TTable tbl) ->
        let k = (match key with VString s -> s | _ -> raise (EvalError "toml_field: key must be String")) in
        (match Toml.Types.Table.find_opt (Toml.Types.Table.Key.of_string k) tbl with
         | Some v -> VConstr ("Ok", [VToml v])
         | None   -> VConstr ("Error", [VString ("no key: " ^ k)]))
      | VToml _ -> VConstr ("Error", [VString "expected table"])
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
          | []     -> VConstr ("Error", [VString (Printf.sprintf "index %d out of bounds" n)])
          | x :: _ when i = 0 -> VConstr ("Ok", [x])
          | _ :: t -> nth (i - 1) t
        in
        if n < 0 then VConstr ("Error", [VString (Printf.sprintf "index %d out of bounds" n)])
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
      (* Membership uses structural equality, which raises on a functional
         value the same way `==` would; surface it as a catchable error
         rather than a fatal one. *)
      let seen = Hashtbl.create 16 in
      VList (List.filter (fun x ->
        if (try Hashtbl.mem seen x
            with Invalid_argument _ ->
              raise (EvalError "cannot compare functions for equality"))
        then false
        else (Hashtbl.add seen x (); true)) xs)
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
         | Some v -> VConstr ("Ok", [v])
         | None   -> VConstr ("Error", [VString ("key not found: " ^ key)]))
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
    | "Url"      -> scalar_decoder "decode_url"
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
    let rec go acc = function
      | [] -> Ok (VConstr (ctor, List.rev acc))
      | (fname, te) :: rest ->
        let key = match fname with Some n -> n | None -> "" in
        (match read_field venv key te j path with
         | Ok v      -> go (v :: acc) rest
         | Error msg -> Error msg)
    in
    (match j with
     | `Assoc _ -> go [] fields
     | _ -> expected "an object" path j)

(* One field of a derived decoder. A field whose type is an `Option` may be
   absent -- that is what the type says -- and every other field may not. *)
and read_field venv key te j path =
  let kvs = match j with `Assoc kvs -> kvs | _ -> [] in
  match te with
  | TEApp (TEName "Option", inner) ->
    let d = decoder_of_type_expr venv inner in
    (match assoc_last key kvs with
     | None | Some `Null -> Ok (VConstr ("None", []))
     | Some v ->
       (match d v (("." ^ key) :: path) with
        | Ok x      -> Ok (VConstr ("Some", [x]))
        | Error msg -> Error msg))
  | _ ->
    let d = decoder_of_type_expr venv te in
    let here = ("." ^ key) :: path in
    (match assoc_last key kvs with
     | Some v -> d v here
     | None   -> decode_error here "no such field")

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
  | TEApp (TEName "Option", _), VConstr ("None", []) -> `Null
  | TEApp (TEName "Option", inner), VConstr ("Some", [x]) -> json_of_typed venv inner x
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
  | VPath s | VDuration s | VUrl s | VSize s | VVersion s
  | VDate s | VTime s | VDateTime s | VIPv4 s | VCIDR s | VGlob s -> `String s
  (* A port reads back from either spelling, so it goes out as the number a
     document would have held. *)
  | VPort n -> `Int n
  | VList vs -> `List (List.map json_of_value vs)
  | VMap kvs -> `Assoc (List.map (fun (k, v) -> (k, json_of_value v)) kvs)
  | VJson j -> j
  | VConstr ("None", []) -> `Null
  | VConstr ("Some", [x]) -> json_of_value x
  | VConstr (ctor, vals) ->
    (match Hashtbl.find_opt constr_fields ctor with
     | Some names when List.length names = List.length vals ->
       let pairs =
         List.concat (List.map2 (fun n v ->
           match n, v with
           | Some _, VConstr ("None", []) -> []   (* absent, not null *)
           | Some name, v -> [(name, json_of_value v)]
           | None, _ -> []) names vals)
       in
       `Assoc pairs
     | _ ->
       raise (EvalError (Printf.sprintf
         "cannot encode '%s': it has no named fields" ctor)))
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
           | Some _, VConstr ("None", []) -> []
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
    | [] -> VConstr ("Ok", [VList (List.rev acc)])
    | x :: rest ->
      (match inner x [Printf.sprintf "[%d]" i] with
       | Ok v      -> go (i + 1) (v :: acc) rest
       | Error msg -> VConstr ("Error", [VString msg]))
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
           | None | Some `Null -> Ok (VConstr ("None", []))
           | Some v ->
             (match inner v (("." ^ key) :: path) with
              | Ok x      -> Ok (VConstr ("Some", [x]))
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
      | `Null -> Ok (VConstr ("None", []))
      | _ ->
        (match inner j path with
         | Ok v      -> Ok (VConstr ("Some", [v]))
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
  ("decode_url", VDecoder (decode_lexed "Url"
    (function Token.Url v -> Some (VUrl v) | _ -> None)));
  ("decode_size", VDecoder (decode_lexed "Size"
    (function Token.Size v -> Some (VSize v) | _ -> None)));
  ("decode_version", VDecoder (decode_lexed "Version"
    (function Token.Version v -> Some (VVersion v) | _ -> None)));
  ("decode_date", VDecoder (decode_lexed "Date"
    (function Token.Date v -> Some (VDate v) | _ -> None)));
  ("decode_time", VDecoder (decode_lexed "Time"
    (function Token.Time v -> Some (VTime v) | _ -> None)));
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
         | Ok v      -> VConstr ("Ok", [v])
         | Error msg -> VConstr ("Error", [VString msg]))
      | _ -> raise (EvalError "json_decode: expected JSON"))));
  ("toml_decode", VBuiltin (fun d ->
    let inner = as_decoder "toml_decode" d in
    VBuiltin (function
      | VToml t ->
        (match inner (json_of_toml t) [] with
         | Ok v      -> VConstr ("Ok", [v])
         | Error msg -> VConstr ("Error", [VString msg]))
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
         | Ok v      -> VConstr ("Ok", [v])
         | Error msg -> VConstr ("Error", [VString msg]))
      | _ -> raise (EvalError "shell_decode: expected String"))));
  (* A CSV's first row names the columns, so a row arrives as an object and
     is read by field name like anything else. A file without a header is
     what `CSV.parse` is for. *)
  ("csv_rows", VBuiltin (fun d ->
    let inner = as_decoder "csv_rows" d in
    VBuiltin (function
      | VString s ->
        (match csv_parse_string "," s with
         | [] -> VConstr ("Ok", [VList []])
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

let stdlib_eval_env = stdlib_eval_env @ map_builtins @ decode_builtins @ stream_builtins

(* User-visible globals — the only names available without an import *)
let base_eval_env : env = [
  ("print",   VBuiltin (fun v -> Effect.perform (WandEffect ("IO!print",   v))));
  ("println", VBuiltin (fun v -> Effect.perform (WandEffect ("IO!println", v))));
  ("Ok",      VPartialConstr ("Ok",    1, []));
  ("Error",   VPartialConstr ("Error", 1, []));
]
