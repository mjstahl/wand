open Ast

(* ── Types ────────────────────────────────────────────────────────────────── *)

type typ =
  | TInt | TFloat | TString | TBool | TUnit
  | TPath | TGlob | TDate | TTime | TDateTime | TDuration
  | TUrl | TIPv4 | TCIDR | TPort | TVersion | TSize
  | TVar    of tv
  | TFun    of typ * typ
  | TTuple  of typ list
  | TList   of typ
  | TResult of typ
  | TMap    of typ
  | TRegex
  | TName of string

and tv = {
  id  : int;
  mutable def : typ option;
}

(* ── Fresh variable generation ────────────────────────────────────────────── *)

let next_id = ref 0
let holes : typ list ref = ref []

let fresh () =
  let id = !next_id in
  incr next_id;
  TVar { id; def = None }

(* ── Repr (follow unification links) ─────────────────────────────────────── *)

let rec repr t =
  match t with
  | TVar tv -> (match tv.def with
    | None    -> t
    | Some t' ->
      let t'' = repr t' in
      tv.def <- Some t'';
      t'')
  | _ -> t

(* ── string_of_typ ────────────────────────────────────────────────────────── *)

let string_of_typ t =
  let counter = ref 0 in
  let names : (int, string) Hashtbl.t = Hashtbl.create 4 in
  let name_of id =
    match Hashtbl.find_opt names id with
    | Some n -> n
    | None   ->
      let n = Printf.sprintf "'%c" (Char.chr (Char.code 'a' + !counter)) in
      incr counter; Hashtbl.add names id n; n
  in
  let rec go t =
    match repr t with
    | TInt      -> "Int"      | TFloat    -> "Float"    | TString   -> "String"
    | TBool     -> "Bool"     | TUnit     -> "Unit"
    | TPath     -> "Path"     | TGlob     -> "Glob"     | TDate     -> "Date"     | TTime     -> "Time"
    | TDateTime -> "DateTime" | TDuration -> "Duration"
    | TUrl      -> "Url"      | TIPv4     -> "IPv4"     | TCIDR     -> "CIDR"
    | TPort     -> "Port"     | TVersion  -> "Version"  | TSize     -> "Size"
    | TRegex    -> "Regex"
    | TName n   -> n
    | TVar tv   -> name_of tv.id
    | TFun (a, b) ->
      let sa = match repr a with TFun _ -> "(" ^ go a ^ ")" | _ -> go a in
      sa ^ " -> " ^ go b
    | TTuple ts ->
      String.concat " * " (List.map (fun t ->
        match repr t with TTuple _ -> "(" ^ go t ^ ")" | _ -> go t) ts)
    | TList t ->
      let s = match repr t with
        | TFun _ | TTuple _ | TList _ | TResult _ -> "(" ^ go t ^ ")"
        | _ -> go t
      in
      "List " ^ s
    | TResult t ->
      let s = match repr t with
        | TFun _ | TTuple _ | TList _ | TResult _ | TMap _ -> "(" ^ go t ^ ")"
        | _ -> go t
      in
      "Result " ^ s
    | TMap t ->
      let s = match repr t with
        | TFun _ | TTuple _ | TList _ | TResult _ | TMap _ -> "(" ^ go t ^ ")"
        | _ -> go t
      in
      "Map " ^ s
  in
  go t

(* ── Occurs check ─────────────────────────────────────────────────────────── *)

let rec occurs (tv : tv) t =
  match repr t with
  | TVar tv'    -> tv' == tv
  | TFun (a, b) -> occurs tv a || occurs tv b
  | TTuple ts   -> List.exists (occurs tv) ts
  | TList t     -> occurs tv t
  | TResult t   -> occurs tv t
  | TMap t      -> occurs tv t
  | _           -> false

(* ── Unification ──────────────────────────────────────────────────────────── *)

exception TypeError of string

let rec unify t1 t2 =
  match repr t1, repr t2 with
  | TInt,      TInt      | TFloat,    TFloat    | TString,  TString
  | TBool,     TBool     | TUnit,     TUnit
  | TPath,     TPath     | TGlob,     TGlob     | TDate,     TDate     | TTime,    TTime
  | TDateTime, TDateTime | TDuration, TDuration
  | TUrl,      TUrl      | TIPv4,     TIPv4     | TCIDR,    TCIDR
  | TPort,     TPort     | TVersion,  TVersion  | TSize,    TSize  -> ()
  | TRegex,    TRegex    -> ()
  | TName n1, TName n2 when n1 = n2 -> ()
  | TVar tv1, TVar tv2 when tv1 == tv2 -> ()
  | TVar tv, t | t, TVar tv ->
    if occurs tv t then raise (TypeError "infinite type")
    else tv.def <- Some t
  | TFun (a1, r1), TFun (a2, r2) ->
    unify a1 a2; unify r1 r2
  | TTuple ts1, TTuple ts2 when List.length ts1 = List.length ts2 ->
    List.iter2 unify ts1 ts2
  | TList t1,   TList t2   -> unify t1 t2
  | TResult t1, TResult t2 -> unify t1 t2
  | TMap t1,    TMap t2    -> unify t1 t2
  | t1, t2 ->
    raise (TypeError (Printf.sprintf "cannot unify %s with %s"
      (string_of_typ t1) (string_of_typ t2)))

(* ── Schemes and environment ──────────────────────────────────────────────── *)

type scheme =
  | Mono of typ
  | Poly of int list * typ
  | Namespace of env

and env = (string * scheme) list

let lookup name (env : env) =
  match List.assoc_opt name env with
  | Some s -> s
  | None   ->
    raise (TypeError (Printf.sprintf "unbound variable '%s'%s"
      name (Util.hint name (List.map fst env))))

(* ── Free type variables ──────────────────────────────────────────────────── *)

let rec free_tvars t =
  match repr t with
  | TVar tv     -> [tv.id]
  | TFun (a, b) -> free_tvars a @ free_tvars b
  | TTuple ts   -> List.concat_map free_tvars ts
  | TList t     -> free_tvars t
  | TResult t   -> free_tvars t
  | TMap t      -> free_tvars t
  | _           -> []

let free_tvars_scheme = function
  | Mono t        -> free_tvars t
  | Poly (ids, t) -> List.filter (fun id -> not (List.mem id ids)) (free_tvars t)
  | Namespace _   -> []

let free_tvars_env (env : env) =
  List.concat_map (fun (_, s) -> free_tvars_scheme s) env

(* ── Generalization and instantiation ────────────────────────────────────── *)

let generalize (env : env) t =
  let env_free = free_tvars_env env in
  let quantify =
    free_tvars t
    |> List.sort_uniq compare
    |> List.filter (fun id -> not (List.mem id env_free))
  in
  if quantify = [] then Mono t else Poly (quantify, t)

let instantiate = function
  | Namespace _ -> TUnit
  | Mono t -> t
  | Poly (ids, t) ->
    let subst = List.map (fun id -> (id, fresh ())) ids in
    let rec inst t =
      match repr t with
      | TVar tv ->
        (match List.assoc_opt tv.id subst with
         | Some t' -> t'
         | None    -> TVar tv)
      | TFun (a, b) -> TFun (inst a, inst b)
      | TTuple ts   -> TTuple (List.map inst ts)
      | TList t     -> TList (inst t)
      | TResult t   -> TResult (inst t)
      | TMap t      -> TMap (inst t)
      | t           -> t
    in
    inst t

(* ── Type definitions ─────────────────────────────────────────────────────── *)

type typedef_env = (string * type_def) list

let type_of_te : type_expr -> typ = function
  | TEName name ->
    match name with
    | "Int"      -> TInt      | "Float"    -> TFloat
    | "String"   -> TString   | "Bool"     -> TBool
    | "Unit"     -> TUnit     | "Path"     -> TPath     | "Glob"     -> TGlob
    | "Date"     -> TDate     | "Time"     -> TTime
    | "DateTime" -> TDateTime | "Duration" -> TDuration
    | "Url"      -> TUrl      | "IPv4"     -> TIPv4
    | "CIDR"     -> TCIDR     | "Port"     -> TPort
    | "Version"  -> TVersion  | "Size"     -> TSize
    | n          -> TName n

let ctor_schemes (tdef : type_def) : (string * scheme) list =
  match tdef with
  | Variants (tname, ctors) ->
    List.map (fun ctor ->
      let result = TName tname in
      let t = List.fold_right (fun (_, te) acc -> TFun (type_of_te te, acc))
                ctor.fields result in
      (ctor.name, Mono t)
    ) ctors

let find_ctor_in_tenv tenv name =
  List.find_map (fun (tname, tdef) ->
    match tdef with
    | Variants (_, ctors) ->
      (match List.find_opt (fun c -> c.name = name) ctors with
       | Some c -> Some (tname, c)
       | None -> None)
  ) tenv

let tenv_to_ctor_env (tenv : typedef_env) : env =
  List.concat_map (fun (_, tdef) -> ctor_schemes tdef) tenv

(* ── Pattern inference ────────────────────────────────────────────────────── *)

let rec unwrap_ctor_type t =
  match repr t with
  | TFun (arg, rest) ->
    let (args, result) = unwrap_ctor_type rest in
    (arg :: args, result)
  | _ -> ([], t)

let rec infer_pat tenv (p : pat) t (env : env) : env =
  match p with
  | PVar name  -> (name, Mono t) :: env
  | Wild       -> env
  | Int _      -> unify t TInt;      env
  | Float _    -> unify t TFloat;    env
  | String _   -> unify t TString;   env
  | Bool _     -> unify t TBool;     env
  | Unit       -> unify t TUnit;     env
  | Path _     -> unify t TPath;     env
  | Date _     -> unify t TDate;     env
  | Time _     -> unify t TTime;     env
  | DateTime _ -> unify t TDateTime; env
  | Duration _ -> unify t TDuration; env
  | Url _      -> unify t TUrl;      env
  | IPv4 _     -> unify t TIPv4;     env
  | CIDR _     -> unify t TCIDR;     env
  | Port _     -> unify t TPort;     env
  | Version _  -> unify t TVersion;  env
  | Size _     -> unify t TSize;     env
  | PTuple ps  ->
    (* If the expected type is a single-constructor ADT with matching arity, unwrap it *)
    (match repr t with
     | TName tname ->
       (match find_ctor_in_tenv tenv tname with
        | Some (_, ctor) when List.length ctor.fields = List.length ps ->
          let arg_ts = List.map (fun (_, te) -> type_of_te te) ctor.fields in
          List.fold_left2 (fun env p at -> infer_pat tenv p at env) env ps arg_ts
        | _ ->
          let ts = List.map (fun _ -> fresh ()) ps in
          unify t (TTuple ts);
          List.fold_left2 (fun env p t -> infer_pat tenv p t env) env ps ts)
     | TVar _ ->
       (* Type is unresolved — don't commit to tuple; let the call site resolve it *)
       let ts = List.map (fun _ -> fresh ()) ps in
       List.fold_left2 (fun env p t -> infer_pat tenv p t env) env ps ts
     | _ ->
       let ts = List.map (fun _ -> fresh ()) ps in
       unify t (TTuple ts);
       List.fold_left2 (fun env p t -> infer_pat tenv p t env) env ps ts)
  | PList [] ->
    unify t (TList (fresh ())); env
  | PList (p :: rest) ->
    let elem_t = fresh () in
    unify t (TList elem_t);
    let env' = infer_pat tenv p elem_t env in
    List.fold_left (fun env p -> infer_pat tenv p elem_t env) env' rest
  | PCons (hp, tp) ->
    let elem_t = fresh () in
    unify t (TList elem_t);
    let env' = infer_pat tenv hp elem_t env in
    infer_pat tenv tp (TList elem_t) env'
  | PConstr (name, pats) ->
    let ctor_env = tenv_to_ctor_env tenv in
    let builtin_result_ctor = match name with
      | "Ok"    -> let t = fresh () in Some (Mono (TFun (t, TResult t)))
      | "Error" -> let t = fresh () in Some (Mono (TFun (TString, TResult t)))
      | _       -> None
    in
    (match Option.fold ~none:(List.assoc_opt name ctor_env) ~some:Option.some builtin_result_ctor with
     | None -> raise (TypeError (Printf.sprintf "unknown constructor '%s'" name))
     | Some s ->
       let ctor_t = instantiate s in
       let (arg_ts, result_t) = unwrap_ctor_type ctor_t in
       if List.length arg_ts <> List.length pats then
         raise (TypeError (Printf.sprintf
           "constructor '%s' expects %d argument(s), got %d"
           name (List.length arg_ts) (List.length pats)));
       unify t result_t;
       List.fold_left2 (fun env p at -> infer_pat tenv p at env) env pats arg_ts)
  | PConstrNamed (name, bindings) ->
    (match find_ctor_in_tenv tenv name with
     | None -> raise (TypeError (Printf.sprintf "unknown constructor '%s'" name))
     | Some (tname, ctor) ->
       unify t (TName tname);
       List.fold_left (fun env (fname, p) ->
         match List.find_opt (fun (dn, _) -> dn = Some fname) ctor.fields with
         | None -> raise (TypeError (Printf.sprintf
             "constructor '%s' has no field '%s'%s"
             name fname (Util.hint fname (List.filter_map Fun.id (List.map fst ctor.fields)))))
         | Some (_, te) -> infer_pat tenv p (type_of_te te) env
       ) env bindings)

  | PMap bindings ->
    let vt = fresh () in
    unify t (TMap vt);
    List.fold_left (fun env (_, p) -> infer_pat tenv p vt env) env bindings

(* for let bindings: PVar gets the generalized scheme, rest are monomorphic *)
let infer_pat_let tenv (p : pat) t scheme (env : env) : env =
  match p with
  | PVar name -> (name, scheme) :: env
  | Wild      -> env
  | _         -> infer_pat tenv p t env

(* ── Expression inference ─────────────────────────────────────────────────── *)

let rec strip_located = function
  | Located (_, e) -> strip_located e
  | e -> e

let is_import_expr e = match strip_located e with ImportExpr _ -> true | _ -> false

let rec infer tenv (env : env) (e : expr) : typ =
  match e with
  | Int _      -> TInt
  | Float _    -> TFloat
  | String _   -> TString
  | Bool _     -> TBool
  | Unit       -> TUnit
  | Path _     -> TPath
  | Glob _     -> TGlob
  | Date _     -> TDate
  | Time _     -> TTime
  | DateTime _ -> TDateTime
  | Duration _ -> TDuration
  | Url _      -> TUrl
  | IPv4 _     -> TIPv4
  | CIDR _     -> TCIDR
  | Port _     -> TPort
  | Version _  -> TVersion
  | Size _     -> TSize
  | Var name   -> instantiate (lookup name env)
  | Constr name ->
    let ctor_env = tenv_to_ctor_env tenv in
    (match List.assoc_opt name ctor_env with
     | Some s -> instantiate s
     | None   ->
       (match name with
        | "Ok"    -> let t = fresh () in TFun (t, TResult t)
        | "Error" -> let t = fresh () in TFun (TString, TResult t)
        | _ ->
          raise (TypeError (Printf.sprintf "unknown constructor '%s'%s"
            name (Util.hint name (List.map fst ctor_env))))))
  | EnvVar _ -> TString
  | Hole ->
    let t = fresh () in
    holes := t :: !holes;
    t
  | UnOp ("-", e) -> unify (infer tenv env e) TInt; TInt
  | UnOp ("!", e) -> unify (infer tenv env e) TBool; TBool
  | UnOp (op, _)  -> raise (TypeError (Printf.sprintf "unknown operator '%s'" op))
  | BinOp (op, a, b) -> infer_binop tenv env op a b
  | Fn (params, body) ->
    let (param_ts, env') =
      List.fold_left (fun (ts, env) p ->
        let t = fresh () in
        (ts @ [t], infer_pat tenv p t env)
      ) ([], env) params
    in
    let body_t = infer tenv env' body in
    List.fold_right (fun t acc -> TFun (t, acc)) param_ts body_t
  | App (f, x) ->
    let tf = infer tenv env f in
    let tx = infer tenv env x in
    let tr = fresh () in
    unify tf (TFun (tx, tr));
    tr
  | Let (p, e1, e2) ->
    (match p, e1 with
     | PVar name, Fn _ ->
       let placeholder = fresh () in
       let env_rec = (name, Mono placeholder) :: env in
       let t1 = infer tenv env_rec e1 in
       unify placeholder t1;
       infer tenv ((name, generalize env t1) :: env) e2
     | _ ->
       let t1     = infer tenv env e1 in
       let scheme = generalize env t1 in
       infer tenv (infer_pat_let tenv p t1 scheme env) e2)
  | If (cond, then_, else_) ->
    unify (infer tenv env cond) TBool;
    let tt = infer tenv env then_ in
    unify tt (infer tenv env else_);
    tt
  | Match (scrutinee, cases) ->
    let ts       = infer tenv env scrutinee in
    let result_t = fresh () in
    List.iteri (fun _ (p, guard, body) ->
      let env' = infer_pat tenv p ts env in
      (match guard with
       | None   -> ()
       | Some g -> unify (infer tenv env' g) TBool);
      unify result_t (infer tenv env' body)
    ) cases;
    result_t
  | Tuple es -> TTuple (List.map (infer tenv env) es)
  | List []        -> TList (fresh ())
  | List (e :: rest) ->
    let t = infer tenv env e in
    List.iter (fun e' -> unify t (infer tenv env e')) rest;
    TList t
  | ConstrApp (name, fields) ->
    (match find_ctor_in_tenv tenv name with
     | None -> raise (TypeError (Printf.sprintf "unknown constructor '%s'%s"
         name (Util.hint name (List.map fst (tenv_to_ctor_env tenv)))))
     | Some (tname, ctor) ->
       List.iter (fun (fname_opt, e) ->
         match fname_opt with
         | None -> raise (TypeError "positional field in named construction")
         | Some fname ->
           (match List.find_opt (fun (dn, _) -> dn = Some fname) ctor.fields with
            | None -> raise (TypeError (Printf.sprintf
                "constructor '%s' has no field '%s'%s"
                name fname (Util.hint fname (List.filter_map Fun.id (List.map fst ctor.fields)))))
            | Some (_, te) -> unify (infer tenv env e) (type_of_te te))
       ) fields;
       TName tname)
  | Field (e, label) ->
    (* Namespace access: Ns.member — check before falling into regular field inference *)
    let rec unwrap_loc = function Located (_, x) -> unwrap_loc x | x -> x in
    let lookup_ns ns_name =
      match List.assoc_opt ns_name env with
      | Some (Namespace ns_env) ->
        Some (match List.assoc_opt label ns_env with
          | Some s -> instantiate s
          | None   -> raise (TypeError (Printf.sprintf
              "namespace '%s' has no member '%s'%s"
              ns_name label (Util.hint label (List.map fst ns_env)))))
      | _ -> None
    in
    let ns_result = match unwrap_loc e with
      | Constr ns_name | Var ns_name -> lookup_ns ns_name
      | _ -> None
    in
    (match ns_result with
     | Some t -> t
     | None ->
       (match repr (infer tenv env e) with
        | TName tname ->
          (match List.assoc_opt tname tenv with
           | Some (Variants (_, ctors)) ->
             let all_named = List.concat_map (fun c ->
               List.filter_map (fun (fname, te) ->
                 match fname with Some n -> Some (n, te) | None -> None)
               c.fields) ctors in
             (match List.assoc_opt label all_named with
              | Some te -> type_of_te te
              | None    ->
                let names = List.map fst all_named in
                raise (TypeError (Printf.sprintf "type '%s' has no field '%s'%s"
                  tname label (Util.hint label names))))
           | _ -> raise (TypeError (Printf.sprintf
               "cannot access field '%s' on type '%s'" label tname)))
        | TMap vt -> vt
        | t -> raise (TypeError (Printf.sprintf
            "field access requires a named type or Map, got %s" (string_of_typ t)))))
  | MapLit [] ->
    TMap (fresh ())
  | MapLit ((_, e0) :: rest) ->
    let t = infer tenv env e0 in
    List.iter (fun (_, e) -> unify t (infer tenv env e)) rest;
    TMap t
  | RunCmd    e       -> unify (infer tenv env e) TString; TString
  | RunQuery  e       -> unify (infer tenv env e) TString; TName "ShellResult"
  | RegexLit  _       -> TRegex
  | ImportExpr _      -> raise (TypeError "import can only appear in a let binding")
  | Handle (body_expr, arms) ->
    let body_t = infer tenv env body_expr in
    let result_t = fresh () in
    List.iter (fun arm ->
      match arm with
      | Ast.ReturnArm (p, b) ->
        let env' = infer_pat tenv p body_t env in
        unify result_t (infer tenv env' b)
      | Ast.EffectArm (_, arg_pat, cont_name, arm_body) ->
        let arg_t = fresh () in
        let env' = infer_pat tenv arg_pat arg_t env in
        let cont_arg_t = fresh () in
        let cont_t = TFun (cont_arg_t, result_t) in
        let env'' = (cont_name, Mono cont_t) :: env' in
        unify result_t (infer tenv env'' arm_body)
    ) arms;
    result_t
  | Interp (parts, _) ->
    List.iter (fun (_, e) -> ignore (infer tenv env e)) parts;
    TString
  | Seq (a, b) -> ignore (infer tenv env a); infer tenv env b
  | Contract (reqs, ens, body) ->
    List.iter (fun req -> unify (infer tenv env req) TBool) reqs;
    let body_t = infer tenv env body in
    List.iter (fun e ->
      unify (infer tenv (("result", Mono body_t) :: env) e) TBool
    ) ens;
    body_t
  | Try e -> TResult (infer tenv env e)
  | Annot (te, e) ->
    let t = type_of_te te in
    unify t (infer tenv env e);
    t
  | Located (loc, e) ->
    (try infer tenv env e
     with TypeError msg ->
       if Util.has_loc_prefix msg then raise (TypeError msg)
       else raise (TypeError (Printf.sprintf "%d:%d: %s"
              loc.Token.line loc.Token.col msg)))

and infer_binop tenv (env : env) op a b : typ =
  match op with
  | "+" | "-" | "*" | "/" | "%" ->
    unify (infer tenv env a) TInt;
    unify (infer tenv env b) TInt;
    TInt
  | "++" ->
    unify (infer tenv env a) TString;
    unify (infer tenv env b) TString;
    TString
  | ":" ->
    let elem_t = fresh () in
    unify (infer tenv env a) elem_t;
    unify (infer tenv env b) (TList elem_t);
    TList elem_t
  | "==" | "!=" ->
    unify (infer tenv env a) (infer tenv env b); TBool
  | "<" | ">" | "<=" | ">=" ->
    unify (infer tenv env a) (infer tenv env b); TBool
  | "&&" | "||" ->
    unify (infer tenv env a) TBool;
    unify (infer tenv env b) TBool;
    TBool
  | "|>" ->
    let ta = infer tenv env a in
    (match b with
     | RunCmd e ->
       unify (infer tenv env e) TString;
       unify ta TString;
       TString
     | RunQuery e ->
       unify (infer tenv env e) TString;
       unify ta TString;
       TName "ShellResult"
     | _ ->
       let tb = infer tenv env b in
       let tr = fresh () in
       unify tb (TFun (ta, tr));
       tr)
  | op -> raise (TypeError (Printf.sprintf "unknown operator '%s'" op))

(* ── Public API ───────────────────────────────────────────────────────────── *)

let infer_expr (e : expr) : (typ, string) result =
  try Ok (infer [] [] e)
  with TypeError msg -> Error msg

(* All primitives — used when typechecking stdlib modules *)
let stdlib_type_env : env = [
  ("print",      let a = fresh () in generalize [] (TFun (a, TUnit)));
  ("println",    let a = fresh () in generalize [] (TFun (a, TUnit)));
  ("exit",       let a = fresh () in generalize [] (TFun (TInt, a)));
  ("read_file",  Mono (TFun (TString, TString)));
  ("write_file", Mono (TFun (TString, TFun (TString, TUnit))));
  (* String primitives *)
  ("str_length",     Mono (TFun (TString, TInt)));
  ("str_upper",      Mono (TFun (TString, TString)));
  ("str_lower",      Mono (TFun (TString, TString)));
  ("str_trim",       Mono (TFun (TString, TString)));
  ("str_slice",      Mono (TFun (TInt, TFun (TInt, TFun (TString, TString)))));
  ("str_split",      Mono (TFun (TString, TFun (TString, TList TString))));
  ("str_contains",   Mono (TFun (TString, TFun (TString, TBool))));
  ("str_starts_with",Mono (TFun (TString, TFun (TString, TBool))));
  ("str_ends_with",  Mono (TFun (TString, TFun (TString, TBool))));
  ("str_replace",    Mono (TFun (TString, TFun (TString, TFun (TString, TString)))));
  ("str_trim_left",  Mono (TFun (TString, TString)));
  ("str_trim_right", Mono (TFun (TString, TString)));
  ("str_repeat",     Mono (TFun (TInt, TFun (TString, TString))));
  ("str_reverse",    Mono (TFun (TString, TString)));
  ("str_chars",      Mono (TFun (TString, TList TString)));
  ("int_to_str",       Mono (TFun (TInt,    TString)));
  ("str_to_int",       Mono (TFun (TString, TResult TInt)));
  ("str_to_float",     Mono (TFun (TString, TResult TFloat)));
  ("str_to_bool",      Mono (TFun (TString, TResult TBool)));
  ("str_to_path",      Mono (TFun (TString, TPath)));
  ("str_to_url",       Mono (TFun (TString, TResult TUrl)));
  ("str_to_ipv4",      Mono (TFun (TString, TResult TIPv4)));
  ("str_to_cidr",      Mono (TFun (TString, TResult TCIDR)));
  ("str_to_port",      Mono (TFun (TString, TResult TPort)));
  ("str_to_version",   Mono (TFun (TString, TResult TVersion)));
  ("str_to_size",      Mono (TFun (TString, TResult TSize)));
  ("str_to_date",      Mono (TFun (TString, TResult TDate)));
  ("str_to_time",      Mono (TFun (TString, TResult TTime)));
  ("str_to_datetime",  Mono (TFun (TString, TResult TDateTime)));
  ("str_to_duration",  Mono (TFun (TString, TResult TDuration)));
  (* Regex primitives *)
  ("regex_match",       Mono (TFun (TRegex, TFun (TString, TBool))));
  ("regex_capture",     Mono (TFun (TRegex, TFun (TString, TList TString))));
  ("regex_replace",     Mono (TFun (TRegex, TFun (TString, TFun (TString, TString)))));
  ("regex_replace_all", Mono (TFun (TRegex, TFun (TString, TFun (TString, TString)))));
  ("regex_split",       Mono (TFun (TRegex, TFun (TString, TList TString))));
  ("regex_compile",     Mono (TFun (TString, TResult TRegex)));
  (* Duration primitives *)
  ("dur_zero",    Mono TDuration);
  ("dur_seconds", Mono (TFun (TInt, TDuration)));
  ("dur_minutes", Mono (TFun (TInt, TDuration)));
  ("dur_hours",   Mono (TFun (TInt, TDuration)));
  ("dur_days",    Mono (TFun (TInt, TDuration)));
  ("dur_weeks",   Mono (TFun (TInt, TDuration)));
  ("dur_add",     Mono (TFun (TDuration, TFun (TDuration, TDuration))));
  ("dur_sub",     Mono (TFun (TDuration, TFun (TDuration, TDuration))));
  ("dur_scale",   Mono (TFun (TInt, TFun (TDuration, TDuration))));
  ("dur_format",  Mono (TFun (TDuration, TString)));
  ("dur_to_ms",   Mono (TFun (TDuration, TInt)));
  (* Path primitives *)
  ("path_join",           Mono (TFun (TPath, TFun (TPath, TPath))));
  ("path_parent",         Mono (TFun (TPath, TPath)));
  ("path_basename",       Mono (TFun (TPath, TString)));
  ("path_extension",      Mono (TFun (TPath, TString)));
  ("path_with_extension", Mono (TFun (TString, TFun (TPath, TPath))));
  ("path_is_absolute",    Mono (TFun (TPath, TBool)));
  ("path_is_relative",    Mono (TFun (TPath, TBool)));
  ("path_normalize",      Mono (TFun (TPath, TPath)));
  ("path_to_string",      Mono (TFun (TPath, TString)));
  ("path_of_string",      Mono (TFun (TString, TPath)));
  ("path_components",     Mono (TFun (TPath, TList TString)));
  (* FS primitives *)
  ("fs_exists",  Mono (TFun (TPath, TBool)));
  ("fs_is_file", Mono (TFun (TPath, TBool)));
  ("fs_is_dir",  Mono (TFun (TPath, TBool)));
  ("fs_mkdir",   Mono (TFun (TPath, TUnit)));
  ("fs_ls",      Mono (TFun (TPath, TList TPath)));
  ("fs_remove",  Mono (TFun (TPath, TUnit)));
  ("fs_append",  Mono (TFun (TPath, TFun (TString, TUnit))));
  ("fs_create",  Mono (TFun (TPath, TUnit)));
  ("fs_rename",  Mono (TFun (TPath, TFun (TPath, TUnit))));
  ("fs_copy",    Mono (TFun (TPath, TFun (TPath, TUnit))));
  ("fs_cd",      Mono (TFun (TPath, TUnit)));
  ("fs_cwd",     Mono (TFun (TUnit, TPath)));
  ("fs_mtime",   Mono (TFun (TPath, TDateTime)));
  ("fs_size",    Mono (TFun (TPath, TInt)));
  ("fs_walk",    Mono (TFun (TPath, TList TPath)));
  ("fs_glob",    Mono (TFun (TGlob, TFun (TPath, TList TPath))));
  (* IO primitives *)
  ("io_print_err",   Mono (TFun (TString, TUnit)));
  ("io_println_err", Mono (TFun (TString, TUnit)));
  ("io_read_line",   Mono (TFun (TUnit, TString)));
  ("io_read_all",    Mono (TFun (TUnit, TString)));
  ("io_flush",       Mono (TFun (TUnit, TUnit)));
  (* Process primitives *)
  ("process_run",       Mono (TFun (TString, TString)));
  ("process_run_quiet", Mono (TFun (TString, TUnit)));
  ("process_exit_code", Mono (TFun (TString, TInt)));
  (* Env primitives *)
  ("env_read_dotenv", Mono (TFun (TString, TList (TTuple [TString; TString]))));
  ("env_load_file",   Mono (TFun (TPath, TUnit)));
  (* CSV primitives *)
  ("csv_parse",         Mono (TFun (TString, TFun (TString, TList (TList TString)))));
  ("csv_stringify",     Mono (TFun (TString, TFun (TList (TList TString), TString))));
  ("csv_read_file",     Mono (TFun (TPath, TResult (TList (TList TString)))));
  ("csv_read_file_exn", Mono (TFun (TPath, TList (TList TString))));
  ("env_get",     Mono (TFun (TString, TString)));
  ("env_get_exn", Mono (TFun (TString, TString)));
  ("env_set",     Mono (TFun (TString, TFun (TString, TUnit))));
  ("env_unset",   Mono (TFun (TString, TUnit)));
  ("env_all",     Mono (TFun (TUnit,   TList (TTuple [TString; TString]))));
  ("env_args",    Mono (TFun (TUnit,   TList TString)));
  ("env_home",    Mono (TFun (TUnit,   TPath)));
  ("env_user",    Mono (TFun (TUnit,   TString)));
  (* List primitives *)
  ("list_sort",    let a = fresh () in generalize [] (TFun (TList a, TList a)));
  ("list_sort_by", let a = fresh () in let b = fresh () in
                   generalize [] (TFun (TFun (a, b), TFun (TList a, TList a))));
  ("list_unique",  let a = fresh () in generalize [] (TFun (TList a, TList a)));
  ("list_range",   Mono (TFun (TInt, TFun (TInt, TList TInt))));
  ("list_flatten", let a = fresh () in generalize [] (TFun (TList (TList a), TList a)));
  ("list_concat",  let a = fresh () in generalize [] (TFun (TList a, TFun (TList a, TList a))));
  (* Map builtins *)
  ("map_empty",    let a = fresh () in generalize [] (TMap a));
  ("map_get",      let a = fresh () in generalize [] (TFun (TString, TFun (TMap a, TResult a))));
  ("map_get_exn",  let a = fresh () in generalize [] (TFun (TString, TFun (TMap a, a))));
  ("map_set",      let a = fresh () in generalize [] (TFun (TString, TFun (a, TFun (TMap a, TMap a)))));
  ("map_delete",   let a = fresh () in generalize [] (TFun (TString, TFun (TMap a, TMap a))));
  ("map_has",      let a = fresh () in generalize [] (TFun (TString, TFun (TMap a, TBool))));
  ("map_keys",     let a = fresh () in generalize [] (TFun (TMap a, TList TString)));
  ("map_values",   let a = fresh () in generalize [] (TFun (TMap a, TList a)));
  ("map_size",     let a = fresh () in generalize [] (TFun (TMap a, TInt)));
  ("map_to_list",  let a = fresh () in generalize [] (TFun (TMap a, TList (TTuple [TString; a]))));
  ("map_from_list",let a = fresh () in generalize [] (TFun (TList (TTuple [TString; a]), TMap a)));
  ("map_merge",    let a = fresh () in generalize [] (TFun (TMap a, TFun (TMap a, TMap a))));
  ("map_map",      let a = fresh () in let b = fresh () in
                   generalize [] (TFun (TFun (a, b), TFun (TMap a, TMap b))));
  ("map_filter",   let a = fresh () in generalize [] (TFun (TFun (a, TBool), TFun (TMap a, TMap a))));
]

(* Built-in type definitions always available *)
let shell_result_tdef : type_def =
  Variants ("ShellResult", [{
    name   = "ShellResult";
    fields = [ (Some "stdout", TEName "String");
               (Some "stderr", TEName "String");
               (Some "code",   TEName "Int") ];
  }])

let builtin_tenv : typedef_env = [
  ("ShellResult", shell_result_tdef);
]

(* User-visible globals — the only names available without an import *)
let builtin_type_env : env = [
  ("print",   let a = fresh () in generalize [] (TFun (a, TUnit)));
  ("println", let a = fresh () in generalize [] (TFun (a, TUnit)));
  ("exit",    let a = fresh () in generalize [] (TFun (TInt, a)));
]

(* Single inference pass: builds env and returns (tenv, full_env, own_env, last_expr_typ). *)
let infer_program_ ?(base_env=builtin_type_env) ?(init_tenv=[]) ?(init_env=[]) (prog : program)
    : typedef_env * env * env * typ =
  next_id := 0;
  holes := [];
  let local_tenv = List.filter_map (function
    | TLType (Variants (n, _) as tdef) -> Some (n, tdef)
    | _ -> None) prog.items
  in
  let tenv = local_tenv @ init_tenv @ builtin_tenv in
  let base_env = tenv_to_ctor_env tenv @ base_env @ init_env in
  let (env, last_t) = List.fold_left (fun (env, last_t) item ->
    match item with
    | TLLet (_, [], body) when is_import_expr body ->
      (env, last_t)  (* pre-loaded by load_imports_for *)
    | TLLet (name, [], body) ->
      let t = infer tenv env body in
      ((name, generalize env t) :: env, last_t)
    | TLLet (name, params, body) ->
      let placeholder = fresh () in
      let env_rec = (name, Mono placeholder) :: env in
      let t = infer tenv env_rec (Fn (params, body)) in
      unify placeholder t;
      ((name, generalize env t) :: env, last_t)
    | TLLetPat (_, body) when is_import_expr body ->
      (env, last_t)  (* pre-loaded by load_imports_for *)
    | TLLetPat (pat, e) ->
      let t = infer tenv env e in
      let env' = infer_pat tenv pat t env in
      (env', last_t)
    | TLExpr e ->
      (env, infer tenv env e)
    | TLType _ | TLImport _ -> (env, last_t)
  ) (base_env, TUnit) prog.items
  in
  let n_own = List.length env - List.length base_env in
  let own_env = List.filteri (fun i _ -> i < n_own) env in
  (tenv, env, own_env, last_t)

let infer_program_full ?(init_tenv=[]) ?(init_env=[]) (prog : program)
    : (env * typ, string) result =
  try
    let (_, env, _, last_t) = infer_program_ ~init_tenv ~init_env prog in
    Ok (env, last_t)
  with TypeError msg -> Error msg

(* Returns (full_env, own_env); uses stdlib_type_env as base (for module loading). *)
let infer_program_env_with_own ?(init_tenv=[]) ?(init_env=[]) (prog : program)
    : (env * env, string) result =
  try
    let (_, env, own, _) = infer_program_ ~base_env:stdlib_type_env ~init_tenv ~init_env prog in
    Ok (env, own)
  with TypeError msg -> Error msg

let infer_program (prog : program) : (typ, string) result =
  Result.map snd (infer_program_full prog)

let infer_program_env ?(init_tenv=[]) ?(init_env=[]) (prog : program)
    : (env, string) result =
  Result.map fst (infer_program_full ~init_tenv ~init_env prog)

let string_of_scheme = function
  | Mono t | Poly (_, t) -> string_of_typ t
  | Namespace _           -> "<namespace>"

let infer_program_full_with_own ?(init_tenv=[]) ?(init_env=[]) (prog : program)
    : (env * env * typ * typ list, string) result =
  try
    let (_, full_env, own_env, last_t) = infer_program_ ~init_tenv ~init_env prog in
    let hole_types = List.rev_map repr !holes in
    Ok (full_env, own_env, last_t, hole_types)
  with TypeError msg -> Error msg
