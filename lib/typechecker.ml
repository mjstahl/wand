open Ast

(* ── Types ────────────────────────────────────────────────────────────────── *)

type typ =
  | TInt | TFloat | TString | TBool | TUnit
  | TPath | TDate | TTime | TDateTime | TDuration
  | TUrl | TIPv4 | TCIDR | TPort | TVersion | TSize
  | TVar    of tv
  | TFun    of typ * typ
  | TTuple  of typ list
  | TList   of typ
  | TName   of string
  | TRecord of (string * typ) list

and tv = {
  id  : int;
  mutable def : typ option;
}

(* ── Fresh variable generation ────────────────────────────────────────────── *)

let next_id = ref 0

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
    | TPath     -> "Path"     | TDate     -> "Date"     | TTime     -> "Time"
    | TDateTime -> "DateTime" | TDuration -> "Duration"
    | TUrl      -> "Url"      | TIPv4     -> "IPv4"     | TCIDR     -> "CIDR"
    | TPort     -> "Port"     | TVersion  -> "Version"  | TSize     -> "Size"
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
        | TFun _ | TTuple _ | TList _ -> "(" ^ go t ^ ")"
        | _ -> go t
      in
      "List " ^ s
    | TRecord kvs ->
      "{ " ^ String.concat ", " (List.map (fun (k, t) -> k ^ ": " ^ go t) kvs) ^ " }"
  in
  go t

(* ── Occurs check ─────────────────────────────────────────────────────────── *)

let rec occurs (tv : tv) t =
  match repr t with
  | TVar tv'    -> tv' == tv
  | TFun (a, b) -> occurs tv a || occurs tv b
  | TTuple ts   -> List.exists (occurs tv) ts
  | TList t     -> occurs tv t
  | TRecord kvs -> List.exists (fun (_, t) -> occurs tv t) kvs
  | _           -> false

(* ── Unification ──────────────────────────────────────────────────────────── *)

exception TypeError of string

let rec unify t1 t2 =
  match repr t1, repr t2 with
  | TInt,      TInt      | TFloat,    TFloat    | TString,  TString
  | TBool,     TBool     | TUnit,     TUnit
  | TPath,     TPath     | TDate,     TDate     | TTime,    TTime
  | TDateTime, TDateTime | TDuration, TDuration
  | TUrl,      TUrl      | TIPv4,     TIPv4     | TCIDR,    TCIDR
  | TPort,     TPort     | TVersion,  TVersion  | TSize,    TSize  -> ()
  | TName n1, TName n2 when n1 = n2 -> ()
  | TVar tv1, TVar tv2 when tv1 == tv2 -> ()
  | TVar tv, t | t, TVar tv ->
    if occurs tv t then raise (TypeError "infinite type")
    else tv.def <- Some t
  | TFun (a1, r1), TFun (a2, r2) ->
    unify a1 a2; unify r1 r2
  | TTuple ts1, TTuple ts2 when List.length ts1 = List.length ts2 ->
    List.iter2 unify ts1 ts2
  | TList t1, TList t2 ->
    unify t1 t2
  | TRecord kvs1, TRecord kvs2 ->
    let s1 = List.sort (fun (a,_) (b,_) -> compare a b) kvs1 in
    let s2 = List.sort (fun (a,_) (b,_) -> compare a b) kvs2 in
    if List.map fst s1 <> List.map fst s2 then
      raise (TypeError "record field mismatch");
    List.iter2 (fun (_, t1) (_, t2) -> unify t1 t2) s1 s2
  | t1, t2 ->
    raise (TypeError (Printf.sprintf "cannot unify %s with %s"
      (string_of_typ t1) (string_of_typ t2)))

(* ── Schemes and environment ──────────────────────────────────────────────── *)

type scheme =
  | Mono of typ
  | Poly of int list * typ

type env = (string * scheme) list

let lookup name (env : env) =
  match List.assoc_opt name env with
  | Some s -> s
  | None   -> raise (TypeError (Printf.sprintf "unbound variable '%s'" name))

(* ── Free type variables ──────────────────────────────────────────────────── *)

let rec free_tvars t =
  match repr t with
  | TVar tv     -> [tv.id]
  | TFun (a, b) -> free_tvars a @ free_tvars b
  | TTuple ts   -> List.concat_map free_tvars ts
  | TList t     -> free_tvars t
  | TRecord kvs -> List.concat_map (fun (_, t) -> free_tvars t) kvs
  | _           -> []

let free_tvars_scheme = function
  | Mono t        -> free_tvars t
  | Poly (ids, t) -> List.filter (fun id -> not (List.mem id ids)) (free_tvars t)

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
      | TRecord kvs -> TRecord (List.map (fun (k, t) -> (k, inst t)) kvs)
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
    | "Unit"     -> TUnit     | "Path"     -> TPath
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
      let t = List.fold_right (fun te acc -> TFun (type_of_te te, acc))
                ctor.fields result in
      (ctor.name, Mono t)
    ) ctors
  | RecordType (tname, fields) ->
    let field_types = List.map (fun (k, te) -> (k, type_of_te te)) fields in
    [(tname, Mono (TFun (TRecord field_types, TName tname)))]

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
    let ts = List.map (fun _ -> fresh ()) ps in
    unify t (TTuple ts);
    List.fold_left2 (fun env p t -> infer_pat tenv p t env) env ps ts
  | PConstr (name, pats) ->
    let ctor_env = tenv_to_ctor_env tenv in
    (match List.assoc_opt name ctor_env with
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
  | PRecord _ -> raise (TypeError "record patterns not yet supported")

(* for let bindings: PVar gets the generalized scheme, rest are monomorphic *)
let infer_pat_let tenv (p : pat) t scheme (env : env) : env =
  match p with
  | PVar name -> (name, scheme) :: env
  | Wild      -> env
  | PTuple ps ->
    let ts = List.map (fun _ -> fresh ()) ps in
    unify t (TTuple ts);
    List.fold_left2 (fun env p t -> infer_pat tenv p t env) env ps ts
  | _         -> infer_pat tenv p t env

(* ── Expression inference ─────────────────────────────────────────────────── *)

let rec infer tenv (env : env) (e : expr) : typ =
  match e with
  | Int _      -> TInt
  | Float _    -> TFloat
  | String _   -> TString
  | Bool _     -> TBool
  | Unit       -> TUnit
  | Path _     -> TPath
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
     | None   -> raise (TypeError (Printf.sprintf "unknown constructor '%s'" name)))
  | Hole -> fresh ()
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
    List.iter (fun (p, guard, body) ->
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
  | Record kvs ->
    TRecord (List.map (fun (k, e) -> (k, infer tenv env e)) kvs)
  | Field (e, label) ->
    (match repr (infer tenv env e) with
     | TRecord kvs ->
       (match List.assoc_opt label kvs with
        | Some t -> t
        | None   -> raise (TypeError (Printf.sprintf "no field '%s'" label)))
     | TName tname ->
       (match List.assoc_opt tname tenv with
        | Some (RecordType (_, fields)) ->
          (match List.assoc_opt label fields with
           | Some te -> type_of_te te
           | None    -> raise (TypeError (Printf.sprintf
               "type '%s' has no field '%s'" tname label)))
        | _ -> raise (TypeError (Printf.sprintf
            "cannot access field '%s' on non-record type '%s'" label tname)))
     | t -> raise (TypeError (Printf.sprintf
         "field access requires a record, got %s" (string_of_typ t))))
  | Seq (a, b) -> ignore (infer tenv env a); infer tenv env b

and infer_binop tenv (env : env) op a b : typ =
  match op with
  | "+" | "-" | "*" | "/" ->
    unify (infer tenv env a) TInt;
    unify (infer tenv env b) TInt;
    TInt
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
    let tb = infer tenv env b in
    let tr = fresh () in
    unify tb (TFun (ta, tr));
    tr
  | op -> raise (TypeError (Printf.sprintf "unknown operator '%s'" op))

(* ── Public API ───────────────────────────────────────────────────────────── *)

let infer_expr (e : expr) : (typ, string) result =
  try Ok (infer [] [] e)
  with TypeError msg -> Error msg

let infer_program (prog : program) : (typ, string) result =
  try
    let tenv = List.filter_map (function
      | TLType tdef ->
        let name = match tdef with
          | Variants (n, _) | RecordType (n, _) -> n
        in
        Some (name, tdef)
      | _ -> None) prog.items
    in
    let base_env = tenv_to_ctor_env tenv in
    let env = List.fold_left (fun env item ->
      match item with
      | TLLet (name, [], body) ->
        let t = infer tenv env body in
        (name, generalize env t) :: env
      | TLLet (name, params, body) ->
        let placeholder = fresh () in
        let env_rec = (name, Mono placeholder) :: env in
        let t = infer tenv env_rec (Fn (params, body)) in
        unify placeholder t;
        (name, generalize env t) :: env
      | TLType _ | TLImport _ -> env
    ) base_env prog.items
    in
    let result_t = match prog.start with
      | None   -> TUnit
      | Some e -> infer tenv env e
    in
    Ok result_t
  with TypeError msg -> Error msg
