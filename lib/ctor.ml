(* Which constructor a value is, and which declaration it came from.

   The identity used to be the bare name. Two modules that each declare
   `Status` therefore shared one identity: they collided in the evaluator's
   tables, and a pattern from one file matched a value from the other. That
   is why `Foo.Status` and `Bar.Status` cannot both be used in one file.

   A variant rather than a record, so an identity reads the same in a pattern
   as in an expression -- `VConstr (Ctor.Builtin "Ok", [v])` matches and
   builds. *)

type t =
  (* `Ok`, `Error`, `Some`, `None`, `ShellResult`: the language's own, which
     no module declares and no file may redeclare. *)
  | Builtin of string
  (* Declared in the file being run. A script is not a module, so nothing
     else can name its types, and the bare name is identity enough. *)
  | Local of string
  (* Declared in a module, keyed by the module's path rather than by whatever
     the importing file calls it. Two files that alias one module
     differently still agree about its constructors. *)
  | Owned of string * string

let name = function
  | Builtin n | Local n -> n
  | Owned (_, n) -> n

let modul = function
  | Builtin _ | Local _ -> None
  | Owned (m, _) -> Some m

let equal (a : t) (b : t) = a = b

(* What a reader sees: the constructor as it was written. Two constructors of
   one name print alike, which is what a value has always looked like. *)
let to_string c = name c

(* For a message that has to tell two of one name apart. *)
let to_qualified_string = function
  | Builtin n | Local n -> n
  | Owned (m, n) -> m ^ "." ^ n
