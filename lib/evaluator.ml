open Ast

(* ── Constructor field name registry ─────────────────────────────────────── *)

let constr_fields : (string, string option list) Hashtbl.t = Hashtbl.create 16

let () =
  Hashtbl.add constr_fields "ShellResult"
    [Some "stdout"; Some "stderr"; Some "code"]

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

and env = (string * value) list

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
  | VPartialConstr (n, _, _) -> Printf.sprintf "<%s>" n
  | VConstr (name, []) -> name
  | VConstr (name, vs) ->
    name ^ "(" ^ String.concat ", " (List.map show_value vs) ^ ")"
  | VTuple vs   ->
    "(" ^ String.concat ", " (List.map show_value vs) ^ ")"
  | VList vs    ->
    "[" ^ String.concat ", " (List.map show_value vs) ^ "]"
  | VMap kvs    ->
    "[" ^ String.concat ", " (List.map (fun (k, v) -> k ^ " = " ^ show_value v) kvs) ^ "]"
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
  | PTuple ps, VConstr (_, vals) when List.length ps = List.length vals ->
    List.fold_left2
      (fun acc p v -> match acc with
        | None     -> None
        | Some env -> try_match p v env)
      (Some env) ps vals
  | PConstr (name, pats), VConstr (vname, vals)
    when name = vname && List.length pats = List.length vals ->
    List.fold_left2
      (fun acc p v -> match acc with
        | None     -> None
        | Some env -> try_match p v env)
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
               | Some v -> try_match p v env))
       ) (Some env) bindings)
  | PMap bindings, (VMap kvs | VRecord kvs) ->
    List.fold_left (fun acc (key, p) ->
      match acc with
      | None -> None
      | Some env ->
        (match List.assoc_opt key kvs with
         | None   -> None
         | Some v -> try_match p v env)
    ) (Some env) bindings
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
    VMap (List.map (fun (k, e) -> (k, eval env e)) kvs)
  | Field (e, label) ->
    (match eval env e with
     | VMap kvs ->
       (match List.assoc_opt label kvs with
        | Some v -> v
        | None   -> raise (EvalError (Printf.sprintf "map has no key '%s'" label)))
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
     | _ -> raise (EvalError "field access on non-record"))
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
  | RunCmd e ->
    let cmd = match eval env e with
      | VString s -> s
      | _ -> raise (EvalError "$(…) requires a string")
    in
    Effect.perform (WandEffect ("process_run", VString cmd))
  | RunQuery e ->
    let cmd = match eval env e with
      | VString s -> s
      | _ -> raise (EvalError "$?(…) requires a string")
    in
    Effect.perform (WandEffect ("process_run_full", VString cmd))
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
    (match b with
     | RunCmd e ->
       let cmd = match eval env e with
         | VString s -> s
         | _ -> raise (EvalError "$(…) requires a string")
       in
       let stdin = show_value va in
       Effect.perform (WandEffect ("process_run_stdin", VTuple [VString cmd; VString stdin]))
     | RunQuery e ->
       let cmd = match eval env e with
         | VString s -> s
         | _ -> raise (EvalError "$?(…) requires a string")
       in
       let stdin = show_value va in
       Effect.perform (WandEffect ("process_run_full_stdin", VTuple [VString cmd; VString stdin]))
     | _ ->
       let vf = eval env b in
       apply vf va)
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
      let num = int_of_string (String.sub s !i (!j - !i)) in
      i := !j;
      if      at !i "min" then (total := !total + num * 60000;              i := !i + 3)
      else if at !i "ms"  then (total := !total + num;                      i := !i + 2)
      else if at !i "w"   then (total := !total + num * 7 * 24 * 3600000;  i := !i + 1)
      else if at !i "d"   then (total := !total + num * 24 * 3600000;       i := !i + 1)
      else if at !i "h"   then (total := !total + num * 3600000;             i := !i + 1)
      else if at !i "m"   then (total := !total + num * 60000;              i := !i + 1)
      else if at !i "s"   then (total := !total + num * 1000;               i := !i + 1)
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
  let commit_row () =
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
      commit_row (); incr i
    end else begin
      Buffer.add_char field c; incr i
    end
  done;
  (* commit trailing content (file may not end with newline) *)
  if Buffer.length field > 0 || !row <> [] then commit_row ();
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

let try_lex_single s =
  match Lexer.tokenize_plain s with
  | [tok; Token.EOF] -> Some tok
  | _ -> None
  | exception Lexer.LexError _ -> None

let stdlib_eval_env : env = [
  ("print",      VBuiltin (fun v -> Effect.perform (WandEffect ("print",   v))));
  ("println",    VBuiltin (fun v -> Effect.perform (WandEffect ("println", v))));
  ("exit",       VBuiltin (function VInt n -> exit n | _ -> raise (EvalError "exit: expected Int")));
  ("option_get_exn", VBuiltin (function
    | VUnit -> raise (EvalError "Option.get!: called on None")
    | _ -> raise (EvalError "option_get_exn: expected Unit")));
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
  ("types_check_expr", VBuiltin (function
    | VString s ->
      (match
         Lexer.tokenize s
         |> Parser.parse_expr
         |> Typechecker.infer_expr
         |> Result.map Typechecker.string_of_typ
       with
       | Ok t    -> VConstr ("Ok",    [VString t])
       | Error e -> VConstr ("Error", [VString e])
       | exception (Lexer.LexError e | Parser.ParseError e) -> VConstr ("Error", [VString e]))
    | _ -> raise (EvalError "types_check_expr: expected String")));
  ("types_check_program", VBuiltin (function
    | VString s ->
      (match
         Lexer.tokenize s
         |> Parser.parse_program
         |> Typechecker.infer_program
         |> Result.map Typechecker.string_of_typ
       with
       | Ok t    -> VConstr ("Ok",    [VString t])
       | Error e -> VConstr ("Error", [VString e])
       | exception (Lexer.LexError e | Parser.ParseError e) -> VConstr ("Error", [VString e]))
    | _ -> raise (EvalError "types_check_program: expected String")));
  ("types_holes", VBuiltin (function
    | VString s ->
      (match
         Lexer.tokenize s
         |> Parser.parse_program
         |> Typechecker.infer_program_full_with_own
       with
       | Ok (_, _, _, holes) ->
         VConstr ("Ok", [VList (List.map (fun t -> VString (Typechecker.string_of_typ t)) holes)])
       | Error e -> VConstr ("Error", [VString e])
       | exception (Lexer.LexError e | Parser.ParseError e) -> VConstr ("Error", [VString e]))
    | _ -> raise (EvalError "types_holes: expected String")));
  ("str_to_path", VBuiltin (function
    | VString s -> VPath s
    | _ -> raise (EvalError "str_to_path: expected String")));
  ("str_to_url", VBuiltin (function
    | VString s ->
      (match try_lex_single s with
       | Some (Token.Url u) -> VConstr ("Ok", [VUrl u])
       | _ -> VConstr ("Error", [VString (Printf.sprintf "cannot parse %S as Url" s)]))
    | _ -> raise (EvalError "str_to_url: expected String")));
  ("str_to_ipv4", VBuiltin (function
    | VString s ->
      (match try_lex_single s with
       | Some (Token.IPv4 v) -> VConstr ("Ok", [VIPv4 v])
       | _ -> VConstr ("Error", [VString (Printf.sprintf "cannot parse %S as IPv4" s)]))
    | _ -> raise (EvalError "str_to_ipv4: expected String")));
  ("str_to_cidr", VBuiltin (function
    | VString s ->
      (match try_lex_single s with
       | Some (Token.CIDR v) -> VConstr ("Ok", [VCIDR v])
       | _ -> VConstr ("Error", [VString (Printf.sprintf "cannot parse %S as CIDR" s)]))
    | _ -> raise (EvalError "str_to_cidr: expected String")));
  ("str_to_port", VBuiltin (function
    | VString s ->
      (match try_lex_single s with
       | Some (Token.Port n) -> VConstr ("Ok", [VPort n])
       | _ -> VConstr ("Error", [VString (Printf.sprintf "cannot parse %S as Port" s)]))
    | _ -> raise (EvalError "str_to_port: expected String")));
  ("str_to_version", VBuiltin (function
    | VString s ->
      (match try_lex_single s with
       | Some (Token.Version v) -> VConstr ("Ok", [VVersion v])
       | _ -> VConstr ("Error", [VString (Printf.sprintf "cannot parse %S as Version" s)]))
    | _ -> raise (EvalError "str_to_version: expected String")));
  ("str_to_size", VBuiltin (function
    | VString s ->
      (match try_lex_single s with
       | Some (Token.Size v) -> VConstr ("Ok", [VSize v])
       | _ -> VConstr ("Error", [VString (Printf.sprintf "cannot parse %S as Size" s)]))
    | _ -> raise (EvalError "str_to_size: expected String")));
  ("str_to_date", VBuiltin (function
    | VString s ->
      (match try_lex_single s with
       | Some (Token.Date v) -> VConstr ("Ok", [VDate v])
       | _ -> VConstr ("Error", [VString (Printf.sprintf "cannot parse %S as Date" s)]))
    | _ -> raise (EvalError "str_to_date: expected String")));
  ("str_to_time", VBuiltin (function
    | VString s ->
      (match try_lex_single s with
       | Some (Token.Time v) -> VConstr ("Ok", [VTime v])
       | _ -> VConstr ("Error", [VString (Printf.sprintf "cannot parse %S as Time" s)]))
    | _ -> raise (EvalError "str_to_time: expected String")));
  ("str_to_datetime", VBuiltin (function
    | VString s ->
      (match try_lex_single s with
       | Some (Token.DateTime v) -> VConstr ("Ok", [VDateTime v])
       | _ -> VConstr ("Error", [VString (Printf.sprintf "cannot parse %S as DateTime" s)]))
    | _ -> raise (EvalError "str_to_datetime: expected String")));
  ("str_to_duration", VBuiltin (function
    | VString s ->
      (match try_lex_single s with
       | Some (Token.Duration v) -> VConstr ("Ok", [VDuration v])
       | _ -> VConstr ("Error", [VString (Printf.sprintf "cannot parse %S as Duration" s)]))
    | _ -> raise (EvalError "str_to_duration: expected String")));
  (* FS primitives *)
  ("fs_exists",  VBuiltin (function
    | VPath p -> VBool (Sys.file_exists p)
    | _ -> raise (EvalError "fs_exists: expected Path")));
  ("fs_is_file", VBuiltin (function
    | VPath p -> VBool (Sys.file_exists p && not (Sys.is_directory p))
    | _ -> raise (EvalError "fs_is_file: expected Path")));
  ("fs_is_dir",  VBuiltin (function
    | VPath p -> VBool (Sys.file_exists p && Sys.is_directory p)
    | _ -> raise (EvalError "fs_is_dir: expected Path")));
  ("fs_mkdir",   VBuiltin (fun v -> Effect.perform (WandEffect ("fs_mkdir_p", v))));
  ("fs_ls",      VBuiltin (fun v -> Effect.perform (WandEffect ("fs_ls",      v))));
  ("fs_remove",  VBuiltin (fun v -> Effect.perform (WandEffect ("fs_remove",  v))));
  ("fs_append",  VBuiltin (fun path ->
    VBuiltin (fun content ->
      Effect.perform (WandEffect ("fs_append", VTuple [path; content])))));
  ("fs_create",  VBuiltin (fun v -> Effect.perform (WandEffect ("fs_create",  v))));
  ("fs_temp_file", VBuiltin (fun prefix ->
    VBuiltin (fun suffix ->
      Effect.perform (WandEffect ("fs_temp_file", VTuple [prefix; suffix])))));
  ("fs_rename",  VBuiltin (fun old_ ->
    VBuiltin (fun new_ ->
      Effect.perform (WandEffect ("fs_rename", VTuple [old_; new_])))));
  ("fs_copy",    VBuiltin (fun src ->
    VBuiltin (fun dst ->
      Effect.perform (WandEffect ("fs_copy", VTuple [src; dst])))));
  ("fs_cd",      VBuiltin (fun v -> Effect.perform (WandEffect ("fs_cd",      v))));
  ("fs_cwd",     VBuiltin (function
    | VUnit -> VPath (Sys.getcwd ())
    | _ -> raise (EvalError "fs_cwd: expected Unit")));
  ("fs_mtime",   VBuiltin (function
    | VString p | VPath p ->
      (match (try Ok (Unix.stat p) with Unix.Unix_error (e, _, _) ->
        Error ("mtime: " ^ Unix.error_message e)) with
       | Error m -> raise (EvalError m)
       | Ok st ->
         let tm = Unix.gmtime st.Unix.st_mtime in
         VDateTime (Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
           (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
           tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec))
    | _ -> raise (EvalError "fs_mtime: expected Path")));
  ("fs_size",    VBuiltin (function
    | VString p | VPath p ->
      (match (try Ok (Unix.stat p) with Unix.Unix_error (e, _, _) ->
        Error ("size: " ^ Unix.error_message e)) with
       | Error m -> raise (EvalError m)
       | Ok st   -> VInt st.Unix.st_size)
    | _ -> raise (EvalError "fs_size: expected Path")));
  ("fs_walk",    VBuiltin (function
    | VString p | VPath p ->
      let rec collect path acc =
        if not (Sys.file_exists path) then acc
        else if Sys.is_directory path then
          let entries = Sys.readdir path in
          Array.sort String.compare entries;
          Array.fold_left
            (fun a name -> collect (Filename.concat path name) a)
            acc entries
        else VPath path :: acc
      in
      VList (List.rev (collect p []))
    | _ -> raise (EvalError "fs_walk: expected Path")));
  ("fs_glob",    VBuiltin (function
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
    | VPath s | VString s -> VString (Filename.basename s)
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
  ("io_print_err",   VBuiltin (fun v -> Effect.perform (WandEffect ("io_print_err",   v))));
  ("io_println_err", VBuiltin (fun v -> Effect.perform (WandEffect ("io_println_err", v))));
  ("io_read_line",   VBuiltin (fun v -> Effect.perform (WandEffect ("io_read_line",   v))));
  ("io_read_all",    VBuiltin (fun v -> Effect.perform (WandEffect ("io_read_all",    v))));
  ("io_flush",       VBuiltin (fun v -> Effect.perform (WandEffect ("io_flush",       v))));
  (* Process primitives *)
  ("process_run", VBuiltin (fun v ->
    Effect.perform (WandEffect ("process_run", v))));
  ("process_run_quiet", VBuiltin (fun v ->
    Effect.perform (WandEffect ("process_run_quiet", v))));
  ("process_exit_code", VBuiltin (fun v ->
    Effect.perform (WandEffect ("process_exit_code", v))));
  (* Env primitives *)
  ("env_read_dotenv", VBuiltin (function
    | VString src | VPath src ->
      let parse_dotenv s =
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
                Some (VTuple [VString key; VString value]))
          (String.split_on_char '\n' s)
      in
      VList (parse_dotenv src)
    | _ -> raise (EvalError "env_read_dotenv: expected String or Path")));
  ("env_load_file", VBuiltin (function
    | VString path | VPath path ->
      let src = try
        let ic = open_in path in
        let n = in_channel_length ic in
        let s = Bytes.create n in
        really_input ic s 0 n; close_in ic;
        Bytes.to_string s
      with Sys_error msg -> raise (EvalError ("env_load_file: " ^ msg))
      in
      let pairs = List.filter_map (fun line ->
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
      in
      List.iter (fun (k, v) -> Unix.putenv k v) pairs;
      VUnit
    | _ -> raise (EvalError "env_load_file: expected Path")));
  ("env_get", VBuiltin (function
    | VString name -> VString (Option.value ~default:"" (Sys.getenv_opt name))
    | _ -> raise (EvalError "env_get: expected String")));
  ("env_get_exn", VBuiltin (function
    | VString name ->
      (match Sys.getenv_opt name with
       | Some v -> VString v
       | None   -> raise (EvalError ("env: variable not set: " ^ name)))
    | _ -> raise (EvalError "env_get_exn: expected String")));
  ("env_set", VBuiltin (function
    | VString name -> VBuiltin (function
      | VString value -> Unix.putenv name value; VUnit
      | _ -> raise (EvalError "env_set: expected String value"))
    | _ -> raise (EvalError "env_set: expected String name")));
  ("env_unset", VBuiltin (function
    | VString name -> Unix.putenv name ""; VUnit
    | _ -> raise (EvalError "env_unset: expected String")));
  ("env_all", VBuiltin (function
    | VUnit ->
      let pairs = Array.to_list (Unix.environment ()) |> List.filter_map (fun s ->
        match String.split_on_char '=' s with
        | [] | [""] -> None
        | name :: rest -> Some (VTuple [VString name; VString (String.concat "=" rest)]))
      in
      VList pairs
    | _ -> raise (EvalError "env_all: expected Unit")));
  ("env_args", VBuiltin (function
    | VUnit -> VList (List.map (fun s -> VString s) !exe_args_ref)
    | _ -> raise (EvalError "env_args: expected Unit")));
  ("env_home", VBuiltin (function
    | VUnit ->
      (match Sys.getenv_opt "HOME" with
       | Some h -> VPath h
       | None   -> raise (EvalError "env: HOME not set"))
    | _ -> raise (EvalError "env_home: expected Unit")));
  ("env_user", VBuiltin (function
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
  ("csv_read_file", VBuiltin (function
    | VString path | VPath path ->
      (try
        let ic = open_in path in
        let n = in_channel_length ic in
        let s = Bytes.create n in
        really_input ic s 0 n; close_in ic;
        let rows = csv_parse_string "," (Bytes.to_string s) in
        let v = VList (List.map (fun row -> VList (List.map (fun f -> VString f) row)) rows) in
        VConstr ("Ok", [v])
      with Sys_error msg -> VConstr ("Error", [VString msg]))
    | _ -> raise (EvalError "csv_read_file: expected Path")));
  ("csv_read_file_exn", VBuiltin (function
    | VString path | VPath path ->
      (try
        let ic = open_in path in
        let n = in_channel_length ic in
        let s = Bytes.create n in
        really_input ic s 0 n; close_in ic;
        let rows = csv_parse_string "," (Bytes.to_string s) in
        VList (List.map (fun row -> VList (List.map (fun f -> VString f) row)) rows)
      with Sys_error msg -> raise (EvalError ("csv_read_file: " ^ msg)))
    | _ -> raise (EvalError "csv_read_file_exn: expected Path")));
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
  ("json_of_map",    VBuiltin (function
    | VMap kvs ->
      let assoc = List.map (fun (k, v) -> match v with
        | VJson j -> (k, j)
        | _ -> raise (EvalError "json_of_map: values must be JSON")) kvs in
      VJson (`Assoc assoc)
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
    | VJson (`Assoc kvs) -> VConstr ("Ok", [VMap (List.map (fun (k, j) -> (k, VJson j)) kvs)])
    | VJson j -> VConstr ("Error", [VString ("expected object, got " ^ Yojson.Basic.to_string j)])
    | _ -> raise (EvalError "json_get_object: expected JSON")));
  ("json_field", VBuiltin (fun key ->
    VBuiltin (function
      | VJson (`Assoc kvs) ->
        let k = (match key with VString s -> s | _ -> raise (EvalError "json_field: key must be String")) in
        (match List.assoc_opt k kvs with
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
        (match List.assoc_opt k kvs with
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
  ("json_read_file", VBuiltin (function
    | VString path | VPath path ->
      (try VConstr ("Ok", [VJson (Yojson.Basic.from_file path)])
       with
       | Sys_error msg      -> VConstr ("Error", [VString msg])
       | Yojson.Json_error msg -> VConstr ("Error", [VString msg]))
    | _ -> raise (EvalError "json_read_file: expected Path")));
  ("json_read_file_exn", VBuiltin (function
    | VString path | VPath path ->
      (try VJson (Yojson.Basic.from_file path)
       with
       | Sys_error msg      -> raise (EvalError ("json_read_file: " ^ msg))
       | Yojson.Json_error msg -> raise (EvalError ("json_read_file: " ^ msg)))
    | _ -> raise (EvalError "json_read_file_exn: expected Path")));
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
  ("toml_read_file", VBuiltin (function
    | VString path | VPath path ->
      (try
        let ic = open_in path in
        let n = in_channel_length ic in
        let s = Bytes.create n in
        really_input ic s 0 n; close_in ic;
        (match Toml.Parser.from_string (Bytes.to_string s) with
         | `Ok tbl -> VConstr ("Ok", [VToml (Toml.Types.TTable tbl)])
         | `Error (msg, _) -> VConstr ("Error", [VString msg]))
      with Sys_error msg -> VConstr ("Error", [VString msg]))
    | _ -> raise (EvalError "toml_read_file: expected Path")));
  ("toml_read_file_exn", VBuiltin (function
    | VString path | VPath path ->
      (try
        let ic = open_in path in
        let n = in_channel_length ic in
        let s = Bytes.create n in
        really_input ic s 0 n; close_in ic;
        (match Toml.Parser.from_string (Bytes.to_string s) with
         | `Ok tbl -> VToml (Toml.Types.TTable tbl)
         | `Error (msg, _) -> raise (EvalError ("toml_read_file: " ^ msg)))
      with Sys_error msg -> raise (EvalError ("toml_read_file: " ^ msg)))
    | _ -> raise (EvalError "toml_read_file_exn: expected Path")));
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
    | VList xs -> VList (List.sort compare xs)
    | _ -> raise (EvalError "list_sort: expected List")));
  ("list_sort_by", VBuiltin (fun f ->
    VBuiltin (function
      | VList xs ->
        VList (List.sort (fun a b -> compare (apply f a) (apply f b)) xs)
      | _ -> raise (EvalError "list_sort_by: expected List"))));
  ("list_unique", VBuiltin (function
    | VList xs ->
      let seen = Hashtbl.create 16 in
      VList (List.filter (fun x ->
        if Hashtbl.mem seen x then false
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
      | VMap kvs ->
        let kvs' = List.filter (fun (k, _) -> k <> key) kvs in
        VMap ((key, v) :: kvs')
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
      VMap kvs
    | _ -> raise (EvalError "map_from_list: expected List")));
  ("map_merge", VBuiltin (function
    | VMap a -> VBuiltin (function
      | VMap b ->
        let keys_b = List.map fst b in
        let a' = List.filter (fun (k, _) -> not (List.mem k keys_b)) a in
        VMap (b @ a')
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

let stdlib_eval_env = stdlib_eval_env @ map_builtins

(* User-visible globals — the only names available without an import *)
let base_eval_env : env = [
  ("print",   VBuiltin (fun v -> Effect.perform (WandEffect ("print",   v))));
  ("println", VBuiltin (fun v -> Effect.perform (WandEffect ("println", v))));
  ("exit",    VBuiltin (function VInt n -> exit n | _ -> raise (EvalError "exit: expected Int")));
  ("Ok",      VPartialConstr ("Ok",    1, []));
  ("Error",   VPartialConstr ("Error", 1, []));
]
