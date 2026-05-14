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
  | VBuiltin       of (value -> value)

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
  | VFun _ | VFix _ | VBuiltin _ -> "<fn>"
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

(* ── Algebraic effects ────────────────────────────────────────────────────── *)

type _ Effect.t += WandEffect : string * value -> value Effect.t

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
  | PList ps, VList vs when List.length ps = List.length vs ->
    List.fold_left2
      (fun acc p v -> match acc with
        | None     -> None
        | Some env -> try_match p v env)
      (Some env) ps vs
  | PList _, VList _ -> None
  | PCons (hp, tp), VList (v :: vs) ->
    (match try_match hp v env with
     | None      -> None
     | Some env' -> try_match tp (VList vs) env')
  | PCons _, VList [] -> None
  | PConstr (name, pats), VConstr (vname, vals)
    when name = vname && List.length pats = List.length vals ->
    List.fold_left2
      (fun acc p v -> match acc with
        | None     -> None
        | Some env -> try_match p v env)
      (Some env) pats vals
  | PRecord kvs, VRecord fields ->
    List.fold_left
      (fun acc (k, p) -> match acc with
        | None     -> None
        | Some env ->
          (match List.assoc_opt k fields with
           | None   -> None
           | Some v -> try_match p v env))
      (Some env) kvs
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
     | None   ->
       raise (EvalError (Printf.sprintf "unbound variable '%s'%s"
         name (Util.hint name (List.map fst env)))))
  | Constr name ->
    (match List.assoc_opt name env with
     | Some v -> v
     | None   ->
       raise (EvalError (Printf.sprintf "unknown constructor '%s'%s"
         name (Util.hint name (List.map fst env)))))
  | EnvVar name ->
    (match Sys.getenv_opt name with
     | Some v -> VString v
     | None   -> raise (EvalError (Printf.sprintf
         "environment variable '%s' is not set" name)))
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
        | None   ->
          raise (EvalError (Printf.sprintf "no field '%s'%s"
            label (Util.hint label (List.map fst kvs)))))
     | _ -> raise (EvalError "field access on non-record"))
  | Seq (a, b) ->
    ignore (eval env a); eval env b
  | RunCmd e ->
    let cmd = match eval env e with
      | VString s -> s
      | _ -> raise (EvalError "$(…) requires a string")
    in
    Effect.perform (WandEffect ("process_run", VString cmd))
  | Handle (body_expr, arms) ->
    let effect_arms = List.filter_map (function
      | Ast.EffectArm (n, p, k, b) -> Some (n, p, k, b)
      | _ -> None) arms in
    let return_arm = List.find_opt (function
      | Ast.ReturnArm _ -> true | _ -> false) arms in
    let apply_return v =
      match return_arm with
      | None -> v
      | Some (Ast.ReturnArm (p, b)) -> eval (bind_pat p v env) b
      | Some (Ast.EffectArm _) -> assert false
    in
    Effect.Deep.match_with (fun () -> eval env body_expr) ()
      { Effect.Deep.
          retc = apply_return;
          exnc = raise;
          effc = fun (type a) (eff : a Effect.t) ->
            match eff with
            | WandEffect (op, arg) ->
              let rec try_arms = function
                | [] -> (None : ((a, value) Effect.Deep.continuation -> value) option)
                | (name, arg_pat, cont_name, arm_body) :: rest ->
                  if name <> op then try_arms rest
                  else
                    match try_match arg_pat arg env with
                    | None -> try_arms rest
                    | Some env' ->
                      Some (fun (k : (a, value) Effect.Deep.continuation) ->
                        let cont = VBuiltin (fun v -> Effect.Deep.continue k v) in
                        eval ((cont_name, cont) :: env') arm_body)
              in
              try_arms effect_arms
            | _ -> None
      }
  | Interp (parts, tail) ->
    let buf = Buffer.create 32 in
    List.iter (fun (lit, e) ->
      Buffer.add_string buf lit;
      Buffer.add_string buf (show_value (eval env e))
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
            | EvalError msg -> VConstr ("Error", [VString msg])
            | Failure  msg  -> VConstr ("Error", [VString msg])
            | exn           -> raise exn);
          effc = fun (type a) (_ : a Effect.t) ->
            (None : ((a, value) Effect.Deep.continuation -> value) option) }
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
  | "++" ->
    (match eval env a, eval env b with
     | VString s1, VString s2 -> VString (s1 ^ s2)
     | _ -> raise (EvalError "'++' requires strings"))
  | "::" ->
    let vh = eval env a in
    (match eval env b with
     | VList vs -> VList (vh :: vs)
     | _        -> raise (EvalError "'::' right side must be a list"))
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

let exe_args_ref : string list ref = ref []

let base_eval_env : env = [
  ("print",      VBuiltin (fun v -> Effect.perform (WandEffect ("print",   v))));
  ("println",    VBuiltin (fun v -> Effect.perform (WandEffect ("println", v))));
  ("read_file",  VBuiltin (fun v -> Effect.perform (WandEffect ("read_file",  v))));
  ("write_file", VBuiltin (fun path ->
    VBuiltin (fun content ->
      Effect.perform (WandEffect ("write_file", VTuple [path; content])))));
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
  ("str_chars", VBuiltin (function
    | VString s ->
      VList (List.init (String.length s) (fun i -> VString (String.make 1 s.[i])))
    | _ -> raise (EvalError "str_chars: expected String")));
  ("int_to_str", VBuiltin (function
    | VInt n -> VString (string_of_int n)
    | _ -> raise (EvalError "int_to_str: expected Int")));
  ("str_to_int", VBuiltin (function
    | VString s ->
      (match int_of_string_opt s with
       | Some n -> VInt n
       | None   -> raise (EvalError (Printf.sprintf "str_to_int: cannot parse %S" s)))
    | _ -> raise (EvalError "str_to_int: expected String")));
  (* Fs primitives *)
  ("fs_exists",  VBuiltin (function
    | VString p -> VBool (Sys.file_exists p)
    | _ -> raise (EvalError "fs_exists: expected String")));
  ("fs_is_file", VBuiltin (function
    | VString p -> VBool (Sys.file_exists p && not (Sys.is_directory p))
    | _ -> raise (EvalError "fs_is_file: expected String")));
  ("fs_is_dir",  VBuiltin (function
    | VString p -> VBool (Sys.file_exists p && Sys.is_directory p)
    | _ -> raise (EvalError "fs_is_dir: expected String")));
  ("fs_mkdir",   VBuiltin (fun v -> Effect.perform (WandEffect ("fs_mkdir",   v))));
  ("fs_mkdir_p", VBuiltin (fun v -> Effect.perform (WandEffect ("fs_mkdir_p", v))));
  ("fs_ls",      VBuiltin (fun v -> Effect.perform (WandEffect ("fs_ls",      v))));
  ("fs_remove",  VBuiltin (fun v -> Effect.perform (WandEffect ("fs_remove",  v))));
  (* Exe primitives *)
  ("exe_args", VBuiltin (function
    | VUnit -> VList (List.map (fun s -> VString s) !exe_args_ref)
    | _ -> raise (EvalError "exe_args: expected Unit")));
  ("exe_exit", VBuiltin (function
    | VInt n -> exit n
    | _ -> raise (EvalError "exe_exit: expected Int")));
  ("exe_cwd", VString (Sys.getcwd ()));
]
