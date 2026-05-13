open Ast

(* ── Values ───────────────────────────────────────────────────────────────── *)

type value =
  | VInt      of int
  | VFloat    of float
  | VString   of string
  | VBool     of bool
  | VUnit
  | VPath     of string
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
  | VTuple         of value list
  | VList          of value list
  | VRecord        of (string * value) list
  | VFun           of env * pat list * expr
  | VConstr        of string * value list
  | VPartialConstr of string * int * value list
  | VRecordCtor
  | VFix           of string * env * pat list * expr

and env = (string * value) list

(* ── Display ──────────────────────────────────────────────────────────────── *)

let rec show_value = function
  | VInt n      -> string_of_int n
  | VFloat f    -> Printf.sprintf "%g" f
  | VString s   -> s
  | VBool b     -> string_of_bool b
  | VUnit       -> "()"
  | VPath s     -> s
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
  | VFun _ | VFix _  -> "<fn>"
  | VRecordCtor      -> "<record-ctor>"
  | VPartialConstr (n, _, _) -> Printf.sprintf "<%s>" n
  | VConstr (name, []) -> name
  | VConstr (name, vs) ->
    name ^ "(" ^ String.concat ", " (List.map show_value vs) ^ ")"
  | VTuple vs   ->
    "(" ^ String.concat ", " (List.map show_value vs) ^ ")"
  | VList vs    ->
    "[" ^ String.concat ", " (List.map show_value vs) ^ "]"
  | VRecord kvs ->
    "{ " ^ String.concat ", " (List.map (fun (k, v) ->
      k ^ " = " ^ show_value v) kvs) ^ " }"

(* ── Runtime error ────────────────────────────────────────────────────────── *)

exception EvalError of string

(* ── Pattern matching ─────────────────────────────────────────────────────── *)

let rec try_match (p : pat) v (env : env) : env option =
  match p, v with
  | PVar name, v          -> Some ((name, v) :: env)
  | Wild, _               -> Some env
  | Int n,    VInt m      when n = m -> Some env
  | Float f,  VFloat g    when f = g -> Some env
  | String s, VString t   when s = t -> Some env
  | Bool b,   VBool c     when b = c -> Some env
  | Unit,     VUnit                  -> Some env
  | PTuple ps, VTuple vs when List.length ps = List.length vs ->
    List.fold_left2
      (fun acc p v -> match acc with
        | None     -> None
        | Some env -> try_match p v env)
      (Some env) ps vs
  | PConstr (name, pats), VConstr (vname, vals)
    when name = vname && List.length pats = List.length vals ->
    List.fold_left2
      (fun acc p v -> match acc with
        | None     -> None
        | Some env -> try_match p v env)
      (Some env) pats vals
  | _ -> None

(* ── Evaluation ───────────────────────────────────────────────────────────── *)

let rec eval (env : env) (e : expr) : value =
  match e with
  | Int n      -> VInt n
  | Float f    -> VFloat f
  | String s   -> VString s
  | Bool b     -> VBool b
  | Unit       -> VUnit
  | Path s     -> VPath s
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
    (match List.assoc_opt name env with
     | Some v -> v
     | None   -> raise (EvalError (Printf.sprintf "unbound variable '%s'" name)))
  | Constr name ->
    (match List.assoc_opt name env with
     | Some v -> v
     | None   -> raise (EvalError (Printf.sprintf "unknown constructor '%s'" name)))
  | Hole ->
    raise (EvalError "cannot evaluate a hole")
  | UnOp ("-", e) ->
    (match eval env e with
     | VInt n   -> VInt (-n)
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
    eval (bind_pat p v1 env) e2
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
  | Record kvs ->
    VRecord (List.map (fun (k, e) -> (k, eval env e)) kvs)
  | Field (e, label) ->
    (match eval env e with
     | VRecord kvs ->
       (match List.assoc_opt label kvs with
        | Some v -> v
        | None   -> raise (EvalError (Printf.sprintf "no field '%s'" label)))
     | _ -> raise (EvalError "field access on non-record"))
  | Seq (a, b) ->
    ignore (eval env a); eval env b

and apply vf vx =
  match vf with
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
  | VPartialConstr (name, 1, args) -> VConstr (name, args @ [vx])
  | VPartialConstr (name, n, args) -> VPartialConstr (name, n - 1, args @ [vx])
  | VRecordCtor ->
    (match vx with
     | VRecord _ -> vx
     | _ -> raise (EvalError "record constructor requires a record literal"))
  | _ -> raise (EvalError "cannot apply a non-function")

and bind_pat (p : pat) v (env : env) : env =
  match try_match p v env with
  | Some env' -> env'
  | None      ->
    raise (EvalError (Printf.sprintf "pattern match failure"))

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
     | VInt x,   VInt y   -> VInt (x + y)
     | VFloat x, VFloat y -> VFloat (x +. y)
     | _ -> raise (EvalError "'+' requires matching numeric types"))
  | "-"  ->
    (match eval env a, eval env b with
     | VInt x,   VInt y   -> VInt (x - y)
     | VFloat x, VFloat y -> VFloat (x -. y)
     | _ -> raise (EvalError "'-' requires matching numeric types"))
  | "*"  ->
    (match eval env a, eval env b with
     | VInt x,   VInt y   -> VInt (x * y)
     | VFloat x, VFloat y -> VFloat (x *. y)
     | _ -> raise (EvalError "'*' requires matching numeric types"))
  | "/"  ->
    (match eval env a, eval env b with
     | VInt _,   VInt 0   -> raise (EvalError "division by zero")
     | VInt x,   VInt y   -> VInt (x / y)
     | VFloat x, VFloat y -> VFloat (x /. y)
     | _ -> raise (EvalError "'/' requires matching numeric types"))
  | "==" -> VBool (eval env a = eval env b)
  | "!=" -> VBool (eval env a <> eval env b)
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
     | _ -> raise (EvalError "'<=' requires comparable types"))
  | ">=" ->
    (match eval env a, eval env b with
     | VInt x,   VInt y   -> VBool (x >= y)
     | VFloat x, VFloat y -> VBool (x >= y)
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
    let vf = eval env b in
    apply vf va
  | op -> raise (EvalError (Printf.sprintf "unknown operator '%s'" op))

(* ── Public API ───────────────────────────────────────────────────────────── *)

let eval_expr (e : expr) : (value, string) result =
  try Ok (eval [] e)
  with EvalError msg -> Error msg
