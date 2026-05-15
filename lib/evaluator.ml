open Ast

(* ── Constructor field name registry ─────────────────────────────────────── *)

let constr_fields : (string, string option list) Hashtbl.t = Hashtbl.create 16

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
  | VRecord        of (string * value) list  (* used for module namespaces *)
  | VFun           of env * pat list * expr
  | VConstr        of string * value list
  | VPartialConstr of string * int * value list
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
  | Field (e, label) ->
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

let stdlib_eval_env : env = [
  ("print",      VBuiltin (fun v -> Effect.perform (WandEffect ("print",   v))));
  ("println",    VBuiltin (fun v -> Effect.perform (WandEffect ("println", v))));
  ("exit",       VBuiltin (function VInt n -> exit n | _ -> raise (EvalError "exit: expected Int")));
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
      (match int_of_string_opt s with
       | Some n -> VInt n
       | None   -> raise (EvalError (Printf.sprintf "str_to_int: cannot parse %S" s)))
    | _ -> raise (EvalError "str_to_int: expected String")));
  ("str_to_float", VBuiltin (function
    | VString s ->
      (match float_of_string_opt s with
       | Some f -> VFloat f
       | None   -> raise (EvalError (Printf.sprintf "str_to_float: cannot parse %S" s)))
    | _ -> raise (EvalError "str_to_float: expected String")));
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
  (* Exe primitives *)
  ("exe_stdin", VBuiltin (function
    | VUnit -> VString (In_channel.input_all In_channel.stdin)
    | _ -> raise (EvalError "exe_stdin: expected Unit")));
  ("exe_args", VBuiltin (function
    | VUnit -> VList (List.map (fun s -> VString s) !exe_args_ref)
    | _ -> raise (EvalError "exe_args: expected Unit")));
  ("exe_exit", VBuiltin (function
    | VInt n -> exit n
    | _ -> raise (EvalError "exe_exit: expected Int")));
  ("exe_cwd", VString (Sys.getcwd ()));
  (* Process primitives *)
  ("process_run", VBuiltin (fun v ->
    Effect.perform (WandEffect ("process_run", v))));
  ("process_run_quiet", VBuiltin (fun v ->
    Effect.perform (WandEffect ("process_run_quiet", v))));
  ("process_exit_code", VBuiltin (fun v ->
    Effect.perform (WandEffect ("process_exit_code", v))));
  ("process_pid", VBuiltin (function
    | VUnit -> VInt (Unix.getpid ())
    | _ -> raise (EvalError "process_pid: expected Unit")));
  (* Env primitives *)
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
  (* List primitives *)
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

(* User-visible globals — the only names available without an import *)
let base_eval_env : env = [
  ("print",   VBuiltin (fun v -> Effect.perform (WandEffect ("print",   v))));
  ("println", VBuiltin (fun v -> Effect.perform (WandEffect ("println", v))));
  ("exit",    VBuiltin (function VInt n -> exit n | _ -> raise (EvalError "exit: expected Int")));
  ("Ok",      VPartialConstr ("Ok",    1, []));
  ("Error",   VPartialConstr ("Error", 1, []));
]
