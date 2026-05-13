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
  | PConstr  of string * pat list
  | PRecord  of (string * pat) list

type expr =
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
  | Var      of string
  | Constr   of string
  | Hole
  | App      of expr * expr
  | Fn       of pat list * expr
  | Let      of pat * expr * expr
  | If       of expr * expr * expr
  | Match    of expr * case list
  | BinOp    of string * expr * expr
  | UnOp     of string * expr
  | Tuple    of expr list
  | List     of expr list
  | Record   of (string * expr) list
  | Field    of expr * string
  | Seq      of expr * expr
  | Located  of Token.loc * expr
  | Contract of expr list * expr list * expr

and case = pat * expr option * expr

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
  | PConstr (c,[]) -> c
  | PConstr (c,ps) -> Printf.sprintf "(%s %s)" c (String.concat " " (List.map show_pat ps))
  | PRecord kvs    -> Printf.sprintf "{%s}" (String.concat "; "
                        (List.map (fun (k,p) -> k ^ "=" ^ show_pat p) kvs))

let rec show : expr -> string = function
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
  | Var x      -> x
  | Constr x   -> x
  | Hole       -> "?"
  | App (f, x)      -> Printf.sprintf "(@ %s %s)" (show f) (show x)
  | Fn (ps, e)      -> Printf.sprintf "(fn %s -> %s)"
                         (String.concat " " (List.map show_pat ps)) (show e)
  | Let (p, e1, e2) -> Printf.sprintf "(let %s = %s in %s)" (show_pat p) (show e1) (show e2)
  | If (c, t, e)    -> Printf.sprintf "(if %s %s %s)" (show c) (show t) (show e)
  | Match (e, cs)   -> Printf.sprintf "(match %s %s)" (show e) (show_cases cs)
  | BinOp (op,a,b)  -> Printf.sprintf "(%s %s %s)" (show a) op (show b)
  | UnOp (op, e)    -> Printf.sprintf "(%s%s)" op (show e)
  | Tuple es        -> Printf.sprintf "(tuple %s)" (String.concat " " (List.map show es))
  | List es         -> Printf.sprintf "[%s]" (String.concat "; " (List.map show es))
  | Record kvs      -> Printf.sprintf "{%s}" (String.concat "; "
                         (List.map (fun (k,v) -> k ^ "=" ^ show v) kvs))
  | Field (e, l)    -> Printf.sprintf "(. %s %s)" (show e) l
  | Seq (a, b)      -> Printf.sprintf "(seq %s %s)" (show a) (show b)
  | Located (_, e)  -> show e
  | Contract (reqs, ens, body) ->
    let clause kw e = Printf.sprintf "(%s %s)" kw (show e) in
    let rs = String.concat " " (List.map (clause "requires") reqs) in
    let es = String.concat " " (List.map (clause "ensures") ens) in
    Printf.sprintf "(contract %s %s %s)" rs es (show body)

and show_cases cs = String.concat " " (List.map show_case cs)

and show_case (p, g, e) =
  match g with
  | None   -> Printf.sprintf "(| %s -> %s)" (show_pat p) (show e)
  | Some g -> Printf.sprintf "(| %s when %s -> %s)" (show_pat p) (show g) (show e)

let pp ppf (e : expr) = Format.pp_print_string ppf (show e)
let equal : expr -> expr -> bool = (=)

(* ── Top-level program ────────────────────────────────────────────────────── *)

type type_expr =
  | TEName of string

type ctor_def = {
  name   : string;
  fields : type_expr list;
}

type type_def =
  | Variants   of string * ctor_def list
  | RecordType of string * (string * type_expr) list

type top_item =
  | TLLet    of string * pat list * expr
  | TLImport of string
  | TLType   of type_def

type program = {
  items : top_item list;
  start : expr option;
}
