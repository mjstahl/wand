type type_expr =
  | TEName  of string
  | TEVar   of string                    (* 'a — type variable *)
  | TEApp   of type_expr * type_expr    (* List Int, Result Int *)
  | TETuple of type_expr list            (* (Int, Int), 2+ elements *)
  | TEFun   of type_expr * type_expr     (* Int -> Int *)

type import_kind =
  | StdlibModule of string   (* import List        — resolves to stdlib/List.wand *)
  | UserPath     of string   (* import ./utils     — resolves relative to caller  *)

type pat =
  | Int      of int
  | Float    of float
  | String   of string
  | Bool     of bool
  | Unit
  | Path     of string
  | Date     of string
  | Time     of string
  | DateTime of string
  | Duration of string
  | Url      of string
  | IPv4     of string
  | CIDR     of string
  | Port     of int
  | Version  of string
  | Size     of string
  | PVar     of string
  | Wild
  | PTuple   of pat list
  | PList    of pat list
  | PCons    of pat * pat
  | PConstr       of string * pat list
  | PConstrNamed  of string * (string * pat) list
  | PMap          of (string * pat) list

type expr =
  | Int      of int
  | Float    of float
  | String   of string
  | Bool     of bool
  | Unit
  | Path     of string
  | Glob     of string
  | Date     of string
  | Time     of string
  | DateTime of string
  | Duration of string
  | Url      of string
  | IPv4     of string
  | CIDR     of string
  | Port     of int
  | Version  of string
  | Size     of string
  | Var      of string
  | Constr   of string
  | EnvVar   of string
  | Hole
  | App      of expr * expr
  | Fn       of pat list * expr
  | Let      of pat * expr * expr
  | LetRec   of (string * pat list * expr) list * expr
      (* mutually-recursive function group: let f ... = ... and g ... = ... *)
  | If       of expr * expr * expr
  | Match    of expr * case list
  | BinOp    of string * expr * expr
  | UnOp     of string * expr
  | Tuple      of expr list
  | List       of expr list
  | ConstrApp  of string * (string option * expr) list
  | Field      of expr * string
  | Seq      of expr * expr
  | Located  of Token.loc * expr
  | Contract of expr list * expr list * expr
  | RunCmd    of expr
  | RunQuery  of expr
  | RegexLit  of string * string
  | ImportExpr of import_kind
  | Interp   of (string * expr) list * string
  | Handle   of expr * handle_arm list
  | Try      of expr
  | Annot    of type_expr * expr
  | MapLit   of (string * expr) list

and case = pat * expr option * expr

and handle_arm =
  | EffectArm of string * pat * string * expr  (* op, arg_pat, cont_name, body *)
  | ReturnArm of pat * expr

(* ── Pretty-print ─────────────────────────────────────────────────────────── *)

let rec show_pat : pat -> string = function
  | Int n      -> string_of_int n
  | Float f    -> string_of_float f
  | String s   -> Printf.sprintf "%S" s
  | Bool b     -> string_of_bool b
  | Unit       -> "()"
  | Path s     -> Printf.sprintf "path:%s" s
  | Date s     -> Printf.sprintf "date:%s" s
  | Time s     -> Printf.sprintf "time:%s" s
  | DateTime s -> Printf.sprintf "datetime:%s" s
  | Duration s -> Printf.sprintf "dur:%s" s
  | Url s      -> Printf.sprintf "url:%s" s
  | IPv4 s     -> Printf.sprintf "ipv4:%s" s
  | CIDR s     -> Printf.sprintf "cidr:%s" s
  | Port n     -> Printf.sprintf "port:%d" n
  | Version s  -> Printf.sprintf "ver:%s" s
  | Size s     -> Printf.sprintf "size:%s" s
  | PVar s         -> s
  | Wild           -> "_"
  | PTuple ps      -> Printf.sprintf "(%s)" (String.concat ", " (List.map show_pat ps))
  | PList ps       -> "[" ^ String.concat ", " (List.map show_pat ps) ^ "]"
  | PCons (h, t)   -> Printf.sprintf "[%s : %s]" (show_pat h) (show_pat t)
  | PConstr (c,[]) -> c
  | PConstr (c,ps) -> Printf.sprintf "(%s %s)" c (String.concat " " (List.map show_pat ps))
  | PConstrNamed (c, kvs) ->
    Printf.sprintf "(%s %s)" c (String.concat ", "
      (List.map (fun (k, p) -> k ^ "=" ^ show_pat p) kvs))
  | PMap kvs ->
    "[" ^ String.concat ", " (List.map (fun (k, p) -> k ^ " = " ^ show_pat p) kvs) ^ "]"

let rec show : expr -> string = function
  | Int n      -> string_of_int n
  | Float f    -> string_of_float f
  | String s   -> Printf.sprintf "%S" s
  | Bool b     -> string_of_bool b
  | Unit       -> "()"
  | Path s     -> Printf.sprintf "path:%s" s
  | Glob s     -> Printf.sprintf "glob:%s" s
  | Date s     -> Printf.sprintf "date:%s" s
  | Time s     -> Printf.sprintf "time:%s" s
  | DateTime s -> Printf.sprintf "datetime:%s" s
  | Duration s -> Printf.sprintf "dur:%s" s
  | Url s      -> Printf.sprintf "url:%s" s
  | IPv4 s     -> Printf.sprintf "ipv4:%s" s
  | CIDR s     -> Printf.sprintf "cidr:%s" s
  | Port n     -> Printf.sprintf "port:%d" n
  | Version s  -> Printf.sprintf "ver:%s" s
  | Size s     -> Printf.sprintf "size:%s" s
  | Var x      -> x
  | Constr x   -> x
  | EnvVar x   -> Printf.sprintf "$%s" x
  | Hole       -> "?"
  | App (f, x)      -> Printf.sprintf "(@ %s %s)" (show f) (show x)
  | Fn (ps, e)      -> Printf.sprintf "(fn %s -> %s)"
                         (String.concat " " (List.map show_pat ps)) (show e)
  | Let (p, e1, e2) -> Printf.sprintf "(let %s = %s in %s)" (show_pat p) (show e1) (show e2)
  | LetRec (bindings, e2) ->
    Printf.sprintf "(let rec %s in %s)"
      (String.concat " and " (List.map (fun (n, ps, b) ->
        Printf.sprintf "%s %s = %s" n
          (String.concat " " (List.map show_pat ps)) (show b)) bindings))
      (show e2)
  | If (c, t, e)    -> Printf.sprintf "(if %s %s %s)" (show c) (show t) (show e)
  | Match (e, cs)   -> Printf.sprintf "(match %s %s)" (show e) (show_cases cs)
  | BinOp (op,a,b)  -> Printf.sprintf "(%s %s %s)" (show a) op (show b)
  | UnOp (op, e)    -> Printf.sprintf "(%s%s)" op (show e)
  | Tuple es        -> Printf.sprintf "(tuple %s)" (String.concat " " (List.map show es))
  | List es         -> Printf.sprintf "[%s]" (String.concat "; " (List.map show es))
  | ConstrApp (c, kvs) ->
    Printf.sprintf "(%s %s)" c (String.concat ", "
      (List.map (fun (k, v) -> (match k with Some n -> n ^ "=" | None -> "") ^ show v) kvs))
  | Field (e, l)    -> Printf.sprintf "(. %s %s)" (show e) l
  | Seq (a, b)      -> Printf.sprintf "(seq %s %s)" (show a) (show b)
  | Located (_, e)  -> show e
  | RunCmd   e        -> Printf.sprintf "$(%s)" (show e)
  | RunQuery e        -> Printf.sprintf "$?(%s)" (show e)
  | RegexLit (p, f)   -> Printf.sprintf "r/%s/%s" p f
  | ImportExpr (StdlibModule n) -> Printf.sprintf "import %s" n
  | ImportExpr (UserPath p)     -> Printf.sprintf "import %s" p
  | Interp (parts, tail) ->
    let buf = Buffer.create 32 in
    Buffer.add_char buf '"';
    List.iter (fun (lit, e) ->
      Buffer.add_string buf lit;
      Buffer.add_string buf "${";
      Buffer.add_string buf (show e);
      Buffer.add_char buf '}'
    ) parts;
    Buffer.add_string buf tail;
    Buffer.add_char buf '"';
    Buffer.contents buf
  | Handle (body, arms) ->
    let show_arm = function
      | EffectArm (op, p, k, b) ->
        Printf.sprintf "(| %s %s %s -> %s)" op (show_pat p) k (show b)
      | ReturnArm (p, b) ->
        Printf.sprintf "(| return %s -> %s)" (show_pat p) (show b)
    in
    Printf.sprintf "(handle %s with %s)" (show body)
      (String.concat " " (List.map show_arm arms))
  | Contract (reqs, ens, body) ->
    let clause kw e = Printf.sprintf "(%s %s)" kw (show e) in
    let rs = String.concat " " (List.map (clause "requires") reqs) in
    let es = String.concat " " (List.map (clause "ensures") ens) in
    Printf.sprintf "(contract %s %s %s)" rs es (show body)
  | Try e -> Printf.sprintf "(try %s)" (show e)
  | Annot (_, e) -> show e
  | MapLit kvs ->
    "[" ^ String.concat ", " (List.map (fun (k, e) -> k ^ " = " ^ show e) kvs) ^ "]"

and show_cases cs = String.concat " " (List.map show_case cs)

and show_case (p, g, e) =
  match g with
  | None   -> Printf.sprintf "(| %s -> %s)" (show_pat p) (show e)
  | Some g -> Printf.sprintf "(| %s when %s -> %s)" (show_pat p) (show g) (show e)

let pp ppf (e : expr) = Format.pp_print_string ppf (show e)
let equal a b = show a = show b

(* ── Top-level program ────────────────────────────────────────────────────── *)

type ctor_def = {
  name   : string;
  fields : (string option * type_expr) list;
}

type type_def =
  | Variants of string * string list * ctor_def list
      (* name, type parameters (e.g. ["a"] for Option 'a), constructors *)

type top_item =
  | TLLet    of string * pat list * expr
  | TLLetRec of (string * pat list * expr) list
  | TLLetPat of pat * expr
  | TLImport of import_kind
  | TLType   of type_def
  | TLExpr   of expr

type program = {
  items : top_item list;
  docs  : (string * string) list;  (* name -> doc string *)
  (* `uses {Shell, FS.Write}`, when the file declares one. Syntactically the
     first item, so a reader knows the bound without searching. *)
  manifest : (string list * Token.loc) option;
}
