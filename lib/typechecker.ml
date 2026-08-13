open Ast

let stdlib_module_names =
  [ "List"; "String"; "Path"; "FS"; "IO"; "Duration"; "Env"; "Map"; "Regex";
    "JSON"; "TOML"; "CSV"; "Option"; "Par"; "Resource" ]

(* ── Types ────────────────────────────────────────────────────────────────── *)

type typ =
  | TInt | TFloat | TString | TBool | TUnit
  | TPath | TGlob | TDate | TTime | TDateTime | TDuration
  | TUrl | TIPv4 | TCIDR | TPort | TVersion | TSize
  | TVar    of tv
  | TFun    of typ * typ * Effect_row.row  (* arg, result, effects of calling *)
  | TTuple  of typ list
  | TList   of typ
  | TResult of typ * typ  (* error type, value type *)
  | TMap    of typ
  | TApp    of typ * typ  (* user-defined generic type application *)
  | TRegex
  (* A resource: how to acquire an 'a and give it back, and what doing
     either performs. The row is carried rather than hidden -- a bracket
     that concealed its own effects would let a file take a lock and
     report a signature that never mentions it. *)
  | TResource of Effect_row.row * typ
  | TJson
  | TToml
  | TName of string

and tv = {
  id  : int;
  mutable def : typ option;
}

(* Builtin signatures are written with `@->` so the tables stay readable.
   Every builtin's *own* latent effect is filled in separately; the arrow
   itself carries no effect until it is seeded. *)
let ( @-> ) a b = TFun (a, b, Effect_row.fresh_row ())

(* `a @! effs $ b` reads "a to b, performing effs". Only the arrow that is
   actually applied last carries them: reading a file happens when the path
   *and* the contents have arrived, not when the first argument does. *)
let effs es a b = TFun (a, b, Effect_row.of_list es)

(* ── Fresh variable generation ────────────────────────────────────────────── *)

let next_id = ref 0
let holes : typ list ref = ref []

(* Whether a pattern can fail to match. A parameter with a refutable pattern
   makes the function partial -- `let head! [h : _] = h` has nothing to do
   with an empty list but raise -- and that raise comes from the binding
   itself rather than from any call, so nothing else would record it. A
   `match` is different: it is checked for exhaustiveness, so its cases
   cannot all fail. *)
let rec pat_is_refutable (p : pat) =
  match p with
  | PVar _ | Wild -> false
  | Unit          -> false
  | PTuple ps     -> List.exists pat_is_refutable ps
  | PConstrNamed _ -> false   (* a single-constructor type cannot mismatch *)
  | _             -> true

(* Which effect an intercepted operation accounts for. A handler case names
   the builtin operation it catches, and catching it is what removes the
   corresponding effect from the handled expression. *)
let effect_of_operation = function
  | "Shell!run" | "Shell!run_quiet" | "Shell!exit_code" | "Shell!capture" ->
    Some Effect_row.Shell
  | "FS!read_file" | "FS!list_dir" | "FS!glob" | "FS!exists" | "FS!file"
  | "FS!dir" | "FS!mtime" | "FS!size" | "FS!cwd" -> Some Effect_row.FsRead
  | "FS!write_file" | "FS!append" | "FS!delete" | "FS!create_file"
  | "FS!rename" | "FS!copy" | "FS!mkdir" | "FS!temp_file"
  | "FS!temp_dir" | "FS!delete_tree" ->
    Some Effect_row.FsWrite
  | "IO!print" | "IO!println" | "IO!print_err" | "IO!println_err"
  | "IO!read_line" | "IO!read_all" | "IO!flush" -> Some Effect_row.IO
  | "Env!get" | "Env!set" | "Env!clear" | "Env!all" | "Env!args"
  | "Env!home" | "Env!user" | "Env!parse_dotenv" -> Some Effect_row.Env
  | "Proc!exit" -> Some Effect_row.Proc
  | _ -> None

(* Effects performed by whatever is currently being inferred.

   Evaluation is strict and left to right, so the effects of an expression
   are just the union of everything evaluated along the way -- which an
   accumulator expresses directly, rather than threading a row out of all
   forty-nine cases of `infer` and unioning it back together by hand.

   Only two places touch it: applying a function adds that function's latent
   effects, and inferring a lambda's body scopes them, because defining a
   function performs nothing. *)
(* A scope's effects start undetermined rather than empty: a function that
   performs nothing of its own still passes on whatever its arguments do,
   and an open row is what lets that be generalised into effect
   polymorphism. *)
let current_eff : Effect_row.row ref = ref (Effect_row.fresh_row ())

let performs r = current_eff := Effect_row.absorb ~ambient:!current_eff r

(* Run `f` with its own effect accumulator, returning what it performed
   alongside its result and leaving the enclosing accumulator untouched. *)
let scoped_eff f =
  let saved = !current_eff in
  current_eff := Effect_row.fresh_row ();
  let result = (try f () with e -> current_eff := saved; raise e) in
  let inner = !current_eff in
  current_eff := saved;
  (result, inner)

(* Name of the top-level function whose body is being inferred, so a match
   that came from a multi-equation definition can report failures in terms
   of that definition rather than the desugared match it became. *)
let current_fn : string option ref = ref None

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

(* Every row variable in `t`, with repeats, so display can tell a row that
   links two places apart from one that is merely undetermined. *)
let rec collect_rowvars t =
  match repr t with
  | TFun (a, b, r) ->
    collect_rowvars a @ collect_rowvars b @ Effect_row.free_rowvars r
  | TTuple ts   -> List.concat_map collect_rowvars ts
  | TList t     -> collect_rowvars t
  | TResult (e, t) -> collect_rowvars e @ collect_rowvars t
  | TResource (r, t) -> Effect_row.free_rowvars r @ collect_rowvars t
  | TMap t      -> collect_rowvars t
  | TApp (f, a) -> collect_rowvars f @ collect_rowvars a
  | _           -> []

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
  let linking_rows = collect_rowvars t in
  let row_names : (int, string) Hashtbl.t = Hashtbl.create 4 in
  let row_counter = ref 0 in
  let row_name_of rid =
    match Hashtbl.find_opt row_names rid with
    | Some n -> n
    | None   ->
      (* Written like a type variable, because that is what it is: one that
         ranges over effects rather than types. *)
      let n = if !row_counter = 0 then "'e"
              else Printf.sprintf "'e%d" !row_counter in
      incr row_counter; Hashtbl.add row_names rid n; n
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
    | TJson     -> "JSON"
    | TToml     -> "TOML"
    | TName n   -> n
    | TVar tv   -> name_of tv.id
    | TFun (a, b, eff) ->
      (* A row prints when it says something. Known effects always do. A row
         variable does only when it appears more than once, because then it
         is linking argument to result -- `List.map`'s says the list is
         processed with whatever effects the given function has. A variable
         appearing once means "undetermined", which is not information. *)
      let labels = Effect_row.labels_of eff in
      let var_name =
        match Effect_row.free_rowvars eff with
        | [rid] when List.length (List.filter (( = ) rid) linking_rows) > 1 ->
          Some (row_name_of rid)
        | _ -> None
      in
      let names =
        String.concat ", "
          (List.map Effect_row.name_of (Effect_row.EffSet.elements labels))
      in
      let suffix =
        match Effect_row.EffSet.is_empty labels, var_name with
        | true,  None   -> ""
        | true,  Some v -> " ! " ^ v
        (* An unnamed tail is one that appears once: undetermined, and so
           not worth printing beside the effects that are known. *)
        | false, None   -> " ! {" ^ names ^ "}"
        | false, Some v -> " ! {" ^ names ^ " | " ^ v ^ "}"
      in
      let sa = match repr a with TFun _ -> "(" ^ go a ^ ")" | _ -> go a in
      let rendered_b = go b in
      (* Each arrow of a curried function has its own row, but partial
         application ties them to the same one, so a chain would otherwise
         repeat itself: `a -> b -> c ! e ! e`. Print it once. *)
      let ends_with s suf =
        let n = String.length s and m = String.length suf in
        m <= n && String.sub s (n - m) m = suf
      in
      let suffix = if suffix <> "" && ends_with rendered_b suffix then "" else suffix in
      sa ^ " -> " ^ rendered_b ^ suffix
    | TTuple ts ->
      "(" ^ String.concat ", " (List.map go ts) ^ ")"
    | TList t ->
      let s = match repr t with
        | TFun _ | TList _ | TResult _ | TApp _ -> "(" ^ go t ^ ")"
        | _ -> go t
      in
      "List " ^ s
    | TResult (e, t) ->
      let wrap x = match repr x with
        | TFun _ | TList _ | TResult _ | TMap _ | TApp _ -> "(" ^ go x ^ ")"
        | _ -> go x
      in
      "Result " ^ wrap e ^ " " ^ wrap t
    | TResource (r, t) ->
      let wrap x = match repr x with
        | TFun _ | TList _ | TResult _ | TMap _ | TApp _ -> "(" ^ go x ^ ")"
        | _ -> go x
      in
      "Resource " ^ Effect_row.string_of_row r ^ " " ^ wrap t
    | TMap t ->
      let s = match repr t with
        | TFun _ | TList _ | TResult _ | TMap _ | TApp _ -> "(" ^ go t ^ ")"
        | _ -> go t
      in
      "Map " ^ s
    | TApp (f, a) ->
      let sa = match repr a with
        | TFun _ | TList _ | TResult _ | TMap _ | TApp _ -> "(" ^ go a ^ ")"
        | _ -> go a
      in
      go f ^ " " ^ sa
  in
  go t

(* ── Occurs check ─────────────────────────────────────────────────────────── *)

let rec occurs (tv : tv) t =
  match repr t with
  | TVar tv'    -> tv' == tv
  | TFun (a, b, _) -> occurs tv a || occurs tv b
  | TTuple ts   -> List.exists (occurs tv) ts
  | TList t     -> occurs tv t
  | TResult (e, t) -> occurs tv e || occurs tv t
  | TResource (_, t) -> occurs tv t
  | TMap t      -> occurs tv t
  | TApp (f, a) -> occurs tv f || occurs tv a
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
  | TJson,     TJson     -> ()
  | TToml,     TToml     -> ()
  | TName n1, TName n2 when n1 = n2 -> ()
  | TVar tv1, TVar tv2 when tv1 == tv2 -> ()
  | TVar tv, t | t, TVar tv ->
    if occurs tv t then raise (TypeError "infinite type")
    else tv.def <- Some t
  | TFun (a1, res1, eff1), TFun (a2, res2, eff2) ->
    unify a1 a2; unify res1 res2;
    (* Two functions are the same only if calling them does the same. A
       row conflict is a type error like any other. *)
    (try Effect_row.unify eff1 eff2
     with Effect_row.RowError msg -> raise (TypeError msg))
  | TTuple ts1, TTuple ts2 when List.length ts1 = List.length ts2 ->
    List.iter2 unify ts1 ts2
  | TList t1,   TList t2   -> unify t1 t2
  | TResult (e1, t1), TResult (e2, t2) -> unify e1 e2; unify t1 t2
  | TResource (r1, t1), TResource (r2, t2) ->
    Effect_row.unify r1 r2; unify t1 t2
  | TMap t1,    TMap t2    -> unify t1 t2
  | TApp (f1, a1), TApp (f2, a2) -> unify f1 f2; unify a1 a2
  | t1, t2 ->
    raise (TypeError (Printf.sprintf "cannot unify %s with %s"
      (string_of_typ t1) (string_of_typ t2)))

(* ── Schemes and environment ──────────────────────────────────────────────── *)

type scheme =
  | Mono of typ
  | Poly of int list * int list * typ   (* type vars, row vars, body *)
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
  | TFun (a, b, _) -> free_tvars a @ free_tvars b
  | TTuple ts   -> List.concat_map free_tvars ts
  | TList t     -> free_tvars t
  | TResult (e, t) -> free_tvars e @ free_tvars t
  | TResource (_, t) -> free_tvars t
  | TMap t      -> free_tvars t
  | TApp (f, a) -> free_tvars f @ free_tvars a
  | _           -> []

let rec free_rowvars_typ t =
  match repr t with
  | TFun (a, b, r) ->
    free_rowvars_typ a @ free_rowvars_typ b @ Effect_row.free_rowvars r
  | TTuple ts   -> List.concat_map free_rowvars_typ ts
  | TList t     -> free_rowvars_typ t
  | TResult (e, t) -> free_rowvars_typ e @ free_rowvars_typ t
  | TResource (r, t) -> Effect_row.free_rowvars r @ free_rowvars_typ t
  | TMap t      -> free_rowvars_typ t
  | TApp (f, a) -> free_rowvars_typ f @ free_rowvars_typ a
  | _           -> []

let free_tvars_scheme = function
  | Mono t           -> free_tvars t
  | Poly (ids, _, t) -> List.filter (fun id -> not (List.mem id ids)) (free_tvars t)
  | Namespace _      -> []

let free_rowvars_scheme = function
  | Mono t            -> free_rowvars_typ t
  | Poly (_, rids, t) -> List.filter (fun id -> not (List.mem id rids)) (free_rowvars_typ t)
  | Namespace _       -> []

let free_tvars_env (env : env) =
  List.concat_map (fun (_, s) -> free_tvars_scheme s) env

let free_rowvars_env (env : env) =
  List.concat_map (fun (_, s) -> free_rowvars_scheme s) env

(* ── Generalization and instantiation ────────────────────────────────────── *)

let generalize (env : env) t =
  let env_free = free_tvars_env env in
  let quantify =
    free_tvars t
    |> List.sort_uniq compare
    |> List.filter (fun id -> not (List.mem id env_free))
  in
  let env_free_rows = free_rowvars_env env in
  let quantify_rows =
    free_rowvars_typ t
    |> List.sort_uniq compare
    |> List.filter (fun id -> not (List.mem id env_free_rows))
  in
  if quantify = [] && quantify_rows = [] then Mono t
  else Poly (quantify, quantify_rows, t)

let instantiate = function
  | Namespace _ -> TUnit
  | Mono t -> t
  | Poly (ids, rids, t) ->
    let subst = List.map (fun id -> (id, fresh ())) ids in
    let rsubst = List.map (fun id -> (id, Effect_row.fresh_rowvar ())) rids in
    let rec inst t =
      match repr t with
      | TVar tv ->
        (match List.assoc_opt tv.id subst with
         | Some t' -> t'
         | None    -> TVar tv)
      | TFun (a, b, r) -> TFun (inst a, inst b, Effect_row.subst_row rsubst r)
      | TTuple ts   -> TTuple (List.map inst ts)
      | TList t     -> TList (inst t)
      | TResult (e, t) -> TResult (inst e, inst t)
      | TResource (r, t) -> TResource (Effect_row.subst_row rsubst r, inst t)
      | TMap t      -> TMap (inst t)
      | TApp (f, a) -> TApp (inst f, inst a)
      | t           -> t
    in
    inst t

(* ── Type definitions ─────────────────────────────────────────────────────── *)

type typedef_env = (string * type_def) list

let type_of_te (te : type_expr) : typ =
  let vars : (string, typ) Hashtbl.t = Hashtbl.create 4 in
  let rec go = function
    | TEName name ->
      (match name with
       | "Int"      -> TInt      | "Float"    -> TFloat
       | "String"   -> TString   | "Bool"     -> TBool
       | "Unit"     -> TUnit     | "Path"     -> TPath     | "Glob"     -> TGlob
       | "Date"     -> TDate     | "Time"     -> TTime
       | "DateTime" -> TDateTime | "Duration" -> TDuration
       | "Url"      -> TUrl      | "IPv4"     -> TIPv4
       | "CIDR"     -> TCIDR     | "Port"     -> TPort
       | "Version"  -> TVersion  | "Size"     -> TSize
       | "JSON"     -> TJson
       | "TOML"     -> TToml
       | n          -> TName n)
    | TEVar name ->
      (match Hashtbl.find_opt vars name with
       | Some t -> t
       | None -> let t = fresh () in Hashtbl.add vars name t; t)
    | TEFun (a, b) -> TFun (go a, go b, Effect_row.fresh_row ())
    | TETuple ts    -> TTuple (List.map go ts)
    | TEApp (TEName "List", arg)   -> TList   (go arg)
    | TEApp (TEApp (TEName "Result", e), a) -> TResult (go e, go a)
    | TEApp (TEName "Result", _) ->
      raise (TypeError "Result now takes two type arguments: Result <ErrorType> <ValueType>")
    | TEApp (TEName "Map", arg)    -> TMap    (go arg)
    | TEApp (f, arg) -> TApp (go f, go arg)
  in go te

let ctor_schemes (tdef : type_def) : (string * scheme) list =
  match tdef with
  | Variants (tname, params, ctors) ->
    let var_table = List.map (fun p -> (p, fresh ())) params in
    let result =
      List.fold_left (fun acc (_, v) -> TApp (acc, v)) (TName tname) var_table
    in
    let rec conv = function
      | TEVar name ->
        (match List.assoc_opt name var_table with
         | Some v -> v
         | None -> raise (TypeError (Printf.sprintf
             "type variable ''%s' is not declared as a parameter of type '%s'"
             name tname)))
      | TEName _ as te -> type_of_te te
      | TEFun (a, b) -> TFun (conv a, conv b, Effect_row.fresh_row ())
      | TETuple ts -> TTuple (List.map conv ts)
      | TEApp (TEName "List", arg)   -> TList   (conv arg)
      | TEApp (TEApp (TEName "Result", e), a) -> TResult (conv e, conv a)
      | TEApp (TEName "Result", _) ->
        raise (TypeError "Result now takes two type arguments: Result <ErrorType> <ValueType>")
      | TEApp (TEName "Map", arg)    -> TMap    (conv arg)
      | TEApp (f, arg) -> TApp (conv f, conv arg)
    in
    List.map (fun ctor ->
      let t = List.fold_right (fun (_, te) acc -> conv te @-> acc) ctor.fields result in
      (ctor.name, generalize [] t)
    ) ctors

let find_ctor_in_tenv tenv name =
  List.find_map (fun (tname, tdef) ->
    match tdef with
    | Variants (_, _, ctors) ->
      (match List.find_opt (fun c -> c.name = name) ctors with
       | Some c -> Some (tname, c)
       | None -> None)
  ) tenv

let tenv_to_ctor_env (tenv : typedef_env) : env =
  List.concat_map (fun (_, tdef) -> ctor_schemes tdef) tenv

(* ── Pattern inference ────────────────────────────────────────────────────── *)

let rec unwrap_ctor_type t =
  match repr t with
  | TFun (arg, rest, _) ->
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
    (* Tuple syntax destructures tuples only. It used to also unwrap a
       single-constructor named type, so `let (w, h) = rect` bound fields by
       position -- silently wrong on reorder, and invisible at the binding
       site. Named-field types are destructured by naming their fields. *)
    (match repr t with
     | TName tname ->
       (match find_ctor_in_tenv tenv tname with
        | Some (_, ctor) when List.length ctor.fields = List.length ps ->
          let named = List.filter_map (fun (fname, _) -> fname) ctor.fields in
          if named <> [] then
            raise (TypeError (Printf.sprintf
              "cannot destructure '%s' with tuple syntax; match its fields by \
               name, as in %s(%s)" tname tname
              (String.concat ", " (List.map (fun n -> n ^ " = " ^ n) named))))
          else begin
            let arg_ts = List.map (fun (_, te) -> type_of_te te) ctor.fields in
            List.fold_left2 (fun env p at -> infer_pat tenv p at env) env ps arg_ts
          end
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
      | "Ok"    -> let e = fresh () in let t = fresh () in Some (Mono (t @-> TResult (e, t)))
      | "Error" -> let e = fresh () in let t = fresh () in Some (Mono (e @-> TResult (e, t)))
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

(* ── Match exhaustiveness ─────────────────────────────────────────────────── *)
(* Maranget-style specialization algorithm: recurse over a matrix of
   pattern rows and a parallel list of column types, checking that every
   constructor of the head column's type is either matched directly or
   covered by a wildcard, then recursing into each covered constructor's
   sub-columns. Guards are excluded by the caller (a guarded case might not
   fire, so it can't be relied on for exhaustiveness). *)

let is_wild_pat = function
  | PVar _ | Wild -> true
  | _ -> false

let builtin_result_scheme = function
  | "Ok"    -> let e = fresh () in let t = fresh () in Some (Mono (t @-> TResult (e, t)))
  | "Error" -> let e = fresh () in let t = fresh () in Some (Mono (e @-> TResult (e, t)))
  | _ -> None

(* A generic type like `Option 'a` instantiates to `TApp (TName "Option", arg)`;
   peel the TApp chain down to the underlying type-def name. *)
let rec app_head_name t =
  match repr t with
  | TName tname -> Some tname
  | TApp (f, _) -> app_head_name f
  | _ -> None

(* All constructors of t's type, each with its arg types instantiated to
   match t specifically (so `Option Int`'s `Some` reports arg type Int,
   not a generic fresh var) -- reuses the same instantiate/unify machinery
   `infer_pat`'s PConstr case already uses for the same reason. *)
let ctors_of_type tenv (ctor_env : env) (t : typ) : (string * typ list) list =
  let via_scheme name scheme =
    let ctor_t = instantiate scheme in
    let (arg_ts, result_t) = unwrap_ctor_type ctor_t in
    (try unify result_t t with TypeError _ -> ());
    (name, arg_ts)
  in
  match repr t with
  | TBool -> [("true", []); ("false", [])]
  | TUnit -> [("()", [])]
  | TTuple ts -> [("(tuple)", ts)]
  | TList elem_t -> [("[]", []); ("::", [elem_t; TList elem_t])]
  | TResult _ ->
    List.filter_map (fun name ->
      match builtin_result_scheme name with
      | Some s -> Some (via_scheme name s)
      | None -> None
    ) ["Ok"; "Error"]
  | TMap _ -> []  (* partial by design (README) -- never flagged as non-exhaustive *)
  | TName _ | TApp _ ->
    (match app_head_name t with
     | Some tname ->
       (match List.assoc_opt tname tenv with
        | Some (Variants (_, _, ctors)) ->
          List.map (fun c ->
            match List.assoc_opt c.name ctor_env with
            | Some s -> via_scheme c.name s
            | None -> (c.name, [])
          ) ctors
        | None -> [])
     | None -> [])
  | TVar _ -> []  (* still unresolved -- shape unknown, can't check, never flagged *)
  | TInt | TFloat | TString | TPath | TGlob | TDate | TTime | TDateTime
  | TDuration | TUrl | TIPv4 | TCIDR | TPort | TVersion | TSize
  | TRegex | TJson | TToml | TFun _ | TResource _ ->
    []  (* infinite/opaque domains: only a wildcard row can cover these *)

let is_infinite_domain t =
  match repr t with
  | TApp _ when app_head_name t <> None -> false
  | TVar _ -> false  (* unresolved -- handled as "unchecked" via ctors_of_type = [] *)
  | TInt | TFloat | TString | TPath | TGlob | TDate | TTime | TDateTime
  | TDuration | TUrl | TIPv4 | TCIDR | TPort | TVersion | TSize
  | TRegex | TJson | TToml | TFun _ | TApp _ | TResource _ -> true
  | _ -> false

(* Does pattern p match constructor `name` (of the given arity)? Returns
   the sub-patterns to specialize with if so. PConstrNamed/PMap match
   their own constructor as fully covered without recursing into named
   fields (a deliberate, conservative simplification: this can miss a
   genuinely non-exhaustive nested pattern inside a named field, but never
   produces a false "exhaustive" claim for the outer constructor itself). *)
let match_against_ctor name arity (p : pat) =
  match p with
  | _ when is_wild_pat p -> `Wildcard
  | Bool b -> if (b && name = "true") || (not b && name = "false") then `Match [] else `NoMatch
  | Unit -> `Match []
  | PTuple ps -> `Match ps
  | PList [] -> if name = "[]" then `Match [] else `NoMatch
  | PList (hd :: tl) -> if name = "::" then `Match [hd; PList tl] else `NoMatch
  | PCons (hp, tp) -> if name = "::" then `Match [hp; tp] else `NoMatch
  | PConstr (n, ps) -> if n = name then `Match ps else `NoMatch
  | PConstrNamed (n, _) ->
    if n = name then `Match (List.init arity (fun _ -> Wild)) else `NoMatch
  | _ -> `NoMatch  (* literal patterns never arise for finite-ctor types *)

type witness = Witness of string * witness list

let rec render_witness (Witness (name, args) : witness) : string =
  match name, args with
  | _, [] -> name
  | "(tuple)", args -> "(" ^ String.concat ", " (List.map render_witness_arg args) ^ ")"
  | "::", [h; t] -> render_witness_arg h ^ " : " ^ render_witness_arg t
  | name, args -> name ^ " " ^ String.concat " " (List.map render_witness_arg args)
and render_witness_arg (Witness (name, args) as w : witness) : string =
  match args with
  | [] -> name
  | _  -> "(" ^ render_witness w ^ ")"

(* A multi-equation definition desugars to a match over synthetic `_p0.._pN`
   parameters (parser.ml's collapse_multi_equation). That exact shape is what
   distinguishes it from a match the author actually wrote, and it decides
   both how failures are phrased and whether unreachable cases are rejected --
   an unreachable case in a hand-written match can be deliberate, but a dead
   equation is always a mistake, since nothing about the definition hints
   that an earlier line already answered for it. *)
let rec strip_loc_expr e = match e with
  | Located (_, x) -> strip_loc_expr x
  | x -> x

let is_equation_group (scrutinee : expr) (arity : int) =
  let synthetic i = Printf.sprintf "_p%d" i in
  match strip_loc_expr scrutinee with
  | Var v when arity = 1 -> v = synthetic 0
  | Tuple vs ->
    List.length vs = arity &&
    List.for_all2 (fun v i -> match strip_loc_expr v with
      | Var name -> name = synthetic i
      | _ -> false) vs (List.init arity (fun i -> i))
  | _ -> false

(* Returns None if exhaustive, or Some human-readable witness pattern
   naming one uncovered case. *)
let check_exhaustive tenv (scrutinee_t : typ) (pats : pat list) : string option =
  let ctor_env = tenv_to_ctor_env tenv in
  (* go types matrix: None if `matrix` covers every value of `types`,
     else Some witnesses -- one witness per column in `types`, describing
     one concrete uncovered combination. *)
  let rec go (types : typ list) (matrix : pat list list) : witness list option =
    match types with
    | [] -> if matrix = [] then Some [] else None
    | t :: rest_types ->
      if matrix <> [] && List.for_all (fun row -> is_wild_pat (List.hd row)) matrix then begin
        let default = List.map (fun row -> List.tl row) matrix in
        match go rest_types default with
        | None -> None
        | Some rest_w -> Some (Witness ("_", []) :: rest_w)
      end else if is_infinite_domain t then begin
        if List.exists (fun row -> is_wild_pat (List.hd row)) matrix then begin
          let default = List.filter_map (fun row ->
            if is_wild_pat (List.hd row) then Some (List.tl row) else None) matrix in
          match go rest_types default with
          | None -> None
          | Some rest_w -> Some (Witness ("_", []) :: rest_w)
        end else
          Some (Witness ("_", []) :: List.map (fun _ -> Witness ("_", [])) rest_types)
      end else begin
        let ctors = ctors_of_type tenv ctor_env t in
        match ctors with
        | [] -> None  (* TMap, or an unresolved type var: nothing to check *)
        | _ ->
          List.find_map (fun (cname, arg_ts) ->
            let arity = List.length arg_ts in
            let specialized = List.filter_map (fun row ->
              match row with
              | [] -> None
              | h :: tl ->
                match match_against_ctor cname arity h with
                | `Match subs -> Some (subs @ tl)
                | `Wildcard -> Some (List.init arity (fun _ -> Wild) @ tl)
                | `NoMatch -> None
            ) matrix in
            if specialized = [] then
              Some (Witness (cname, List.init arity (fun _ -> Witness ("_", [])))
                    :: List.map (fun _ -> Witness ("_", [])) rest_types)
            else
              match go (arg_ts @ rest_types) specialized with
              | None -> None
              | Some all_w ->
                let rec split n xs =
                  if n <= 0 then ([], xs)
                  else match xs with
                    | [] -> ([], [])
                    | x :: xs' -> let (a, b) = split (n - 1) xs' in (x :: a, b)
                in
                let (this_ctor_args, rest_w) = split arity all_w in
                Some (Witness (cname, this_ctor_args) :: rest_w)
          ) ctors
      end
  in
  match go [scrutinee_t] (List.map (fun p -> [p]) pats) with
  | None -> None
  | Some [] -> None
  | Some (w :: _) -> Some (render_witness w)

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
    (* A constructor with named fields is built by naming them. Supplying its
       fields positionally is silently wrong whenever two of them share a
       type, since reordering still typechecks. *)
    (match find_ctor_in_tenv tenv name with
     | Some (_, ctor)
       when List.exists (fun (fname, _) -> Option.is_some fname) ctor.fields ->
       let names = List.filter_map (fun (fname, _) -> fname) ctor.fields in
       raise (TypeError (Printf.sprintf
         "constructor '%s' has named fields; construct it as %s(%s)"
         name name
         (String.concat ", " (List.map (fun n -> n ^ " = ...") names))))
     | _ -> ());
    (match List.assoc_opt name ctor_env with
     | Some s -> instantiate s
     | None   ->
       (match name with
        | "Ok"    -> let e = fresh () in let t = fresh () in t @-> TResult (e, t)
        | "Error" -> let e = fresh () in let t = fresh () in e @-> TResult (e, t)
        | _ when List.mem name stdlib_module_names ->
          raise (TypeError (Printf.sprintf
            "did you forget to import the standard library %s?" name))
        | _ ->
          raise (TypeError (Printf.sprintf "unknown constructor '%s'%s"
            name (Util.hint name (List.map fst ctor_env))))))
  (* $NAME reads the environment. *)
  | EnvVar _ -> performs (Effect_row.single Effect_row.Env); TString
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
    let (body_t, body_row) = scoped_eff (fun () -> infer tenv env' body) in
    let body_row =
      if List.exists pat_is_refutable params
      then Effect_row.add Effect_row.Raise body_row
      else body_row
    in
    (* Only the innermost arrow carries the body's effects: supplying one
       argument of a curried function does nothing until the last one
       arrives. *)
    let rec build = function
      | []      -> body_t
      | [t]     -> TFun (t, body_t, body_row)
      | t :: tl -> TFun (t, build tl, Effect_row.fresh_row ())
    in
    build param_ts
  | App (f, x) ->
    (* `Rect (3, 4)` reads naturally but means "apply Rect to a tuple", and
       Rect takes two arguments. The constructor's arity is known here even
       when it was declared in another file, so say what to write. *)
    (match (let rec strip = function Located (_, e) -> strip e | e -> e in
            strip f, strip x) with
     | Constr name, Tuple es when List.length es > 1 ->
       (match find_ctor_in_tenv tenv name with
        | Some (_, ctor)
          when List.length ctor.fields = List.length es
            && List.for_all (fun (n, _) -> n = None) ctor.fields ->
          raise (TypeError (Printf.sprintf
            "'%s' takes %d arguments, so write `%s %s` rather than `%s (%s)`"
            name (List.length ctor.fields) name
            (String.concat " " (List.init (List.length es)
               (fun i -> Printf.sprintf "a%d" (i + 1))))
            name
            (String.concat ", " (List.init (List.length es)
               (fun i -> Printf.sprintf "a%d" (i + 1))))))
        | _ -> ())
     | _ -> ());
    let tf = infer tenv env f in
    (match (let rec strip = function Located (_, e) -> strip e | e -> e in strip x) with
     | Fn (params, body) ->
       (* Propagate f's expected argument type into a literal lambda
          argument's params before inferring its body, so the body can
          see a concrete (not fresh/unresolved) param type -- needed for
          e.g. field access on the param when its type is otherwise only
          known from how this call site uses it. *)
       let param_ts = List.map (fun _ -> fresh ()) params in
       let body_result_t = fresh () in
       let arg_row = Effect_row.fresh_row () in
       let fn_arg_t =
         let rec build = function
           | []      -> body_result_t
           | [t]     -> TFun (t, body_result_t, arg_row)
           | t :: tl -> TFun (t, build tl, Effect_row.fresh_row ())
         in
         build param_ts
       in
       let tr = fresh () in
       let latent = Effect_row.fresh_row () in
       unify tf (TFun (fn_arg_t, tr, latent));
       let env' = List.fold_left2 (fun env p t -> infer_pat tenv p t env) env params param_ts in
       let (body_t, body_row) = scoped_eff (fun () -> infer tenv env' body) in
    let body_row =
      if List.exists pat_is_refutable params
      then Effect_row.add Effect_row.Raise body_row
      else body_row
    in
       unify body_t body_result_t;
       (try Effect_row.unify arg_row body_row
        with Effect_row.RowError msg -> raise (TypeError msg));
       performs latent;
       tr
     | _ ->
       let tx = infer tenv env x in
       let tr = fresh () in
       let latent = Effect_row.fresh_row () in
       unify tf (TFun (tx, tr, latent));
       performs latent;
       tr)
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
  | LetRec (bindings, e2) ->
    let placeholders = List.map (fun (name, _, _) -> (name, fresh ())) bindings in
    let env_rec = List.map (fun (name, t) -> (name, Mono t)) placeholders @ env in
    let inferred = List.map (fun (name, params, body) ->
      let t = infer tenv env_rec (Fn (params, body)) in
      unify (List.assoc name placeholders) t;
      (name, t)
    ) bindings in
    let env' = List.map (fun (name, t) -> (name, generalize env t)) inferred @ env in
    infer tenv env' e2
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
    let unguarded_pats = List.filter_map (fun (p, guard, _) ->
      match guard with None -> Some p | Some _ -> None) cases in
    (* Phrase failures as equations when this match is a desugared
       multi-equation definition -- `_p0` means nothing to its author. *)
    let arity = match strip_loc_expr scrutinee with
      | Tuple vs -> List.length vs
      | _ -> 1
    in
    let as_equations = is_equation_group scrutinee arity in
    let fn_desc = match !current_fn with
      | Some n -> Printf.sprintf " for '%s'" n
      | None   -> ""
    in
    if as_equations then begin
      (* An equation that no value can reach is dead code the author cannot
         see: source order decides, so an earlier equation already answered
         for everything this one names. *)
      let n = List.length unguarded_pats in
      let rec find_dead i =
        if i >= n then None
        else
          let prefix = List.filteri (fun j _ -> j < i) unguarded_pats in
          if prefix <> [] && check_exhaustive tenv ts prefix = None then Some i
          else find_dead (i + 1)
      in
      (match find_dead 1 with
       | Some i ->
         raise (TypeError (Printf.sprintf
           "equation %d%s is unreachable — an earlier equation already \
            matches every remaining case" (i + 1) fn_desc))
       | None -> ())
    end;
    (match check_exhaustive tenv ts unguarded_pats with
     | None -> ()
     | Some witness ->
       raise (TypeError (
         if as_equations then Printf.sprintf
           "the equations%s do not cover every case, e.g. %s" fn_desc witness
         else Printf.sprintf
           "non-exhaustive match: missing case, e.g. %s" witness)));
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
           | Some (Variants (_, _, ctors)) ->
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
        (* Dot access is checked field access: `p.x` on a named type is
           verified to exist. Key presence in a Map is a runtime question, so
           the same syntax cannot carry the same guarantee -- Map.get returns
           an Option and Map.get! raises, each saying so at the call site. *)
        | TMap vt -> raise (TypeError (Printf.sprintf
            "cannot use dot access on a Map (Map %s); use Map.get for an \
             Option or Map.get! to raise on a missing key" (string_of_typ vt)))
        | t -> raise (TypeError (Printf.sprintf
            "field access requires a named type, got %s" (string_of_typ t)))))
  | MapLit [] ->
    TMap (fresh ())
  | MapLit ((_, e0) :: rest) ->
    let t = infer tenv env e0 in
    List.iter (fun (_, e) -> unify t (infer tenv env e)) rest;
    TMap t
  (* Shell execution is its own form rather than a call to a builtin, so it
     records its effects here. $() raises on a non-zero exit; $?() hands back
     a ShellResult instead, so it cannot. *)
  | RunCmd    e       ->
    unify (infer tenv env e) TString;
    performs (Effect_row.of_list [Effect_row.Shell; Effect_row.Raise]);
    TString
  | RunQuery  e       ->
    unify (infer tenv env e) TString;
    performs (Effect_row.single Effect_row.Shell);
    TName "ShellResult"
  | RegexLit  _       -> TRegex
  | ImportExpr _      -> raise (TypeError "import can only appear in a let binding")
  | Handle (body_expr, cases) ->
    let (body_t, body_row) = scoped_eff (fun () -> infer tenv env body_expr) in
    (* An case intercepts an operation, so the handled expression no longer
       performs it: handling process_run is what makes a deploy script
       testable with the network unplugged, and the signature should say so. *)
    let discharged =
      List.fold_left (fun row case ->
        match case with
        | Ast.EffectCase (op, _, _, _) ->
          (match effect_of_operation op with
           | Some e -> Effect_row.remove e row
           | None   -> row)
        | Ast.ReturnCase _ -> row
      ) body_row cases
    in
    performs discharged;
    let result_t = fresh () in
    (* Without a `return` case the handler returns what the body returned, so
       the two types are the same. Leaving them apart lost the body's type
       entirely. *)
    if not (List.exists (function Ast.ReturnCase _ -> true | _ -> false) cases)
    then unify result_t body_t;
    List.iter (fun case ->
      match case with
      | Ast.ReturnCase (p, b) ->
        let env' = infer_pat tenv p body_t env in
        unify result_t (infer tenv env' b)
      | Ast.EffectCase (_, arg_pat, cont_name, case_body) ->
        let arg_t = fresh () in
        let env' = infer_pat tenv arg_pat arg_t env in
        let cont_arg_t = fresh () in
        (* Resuming a handler's continuation runs the rest of the handled
           expression, whose effects the handler is in the middle of
           deciding, so its row is left to inference. *)
        let cont_t = TFun (cont_arg_t, result_t, Effect_row.fresh_row ()) in
        let env'' = (cont_name, Mono cont_t) :: env' in
        unify result_t (infer tenv env'' case_body)
    ) cases;
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
  | Try e ->
    (* try turns a raise into a Result, so Raise does not escape it.
       Subtracting from an open row can only remove what is already known:
       if the body's effects are still undetermined here, a Raise that
       surfaces later stays in the row. That over-reports rather than
       hiding an effect, which is the direction that keeps a signature
       trustworthy. *)
    let (t, row) = scoped_eff (fun () -> infer tenv env e) in
    performs (Effect_row.remove Effect_row.Raise row);
    TResult (TString, t)
  | With (resource, p, body) ->
    (* The resource says what acquiring and releasing perform; the bracket
       performs all of it, plus whatever the body does. Nothing here is
       discharged -- a bracket is not a handler, it just guarantees the
       release runs -- so every row is folded into the enclosing scope and
       a file that takes a lock says so in its signature. *)
    let held = fresh () in
    let row = Effect_row.fresh_row () in
    unify (infer tenv env resource) (TResource (row, held));
    performs row;
    let env' = infer_pat tenv p held env in
    infer tenv env' body
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
       let latent = Effect_row.fresh_row () in
       unify tb (TFun (ta, tr, latent));
       performs latent;
       tr)
  | op -> raise (TypeError (Printf.sprintf "unknown operator '%s'" op))

(* ── Public API ───────────────────────────────────────────────────────────── *)

let infer_expr (e : expr) : (typ, string) result =
  try Ok (infer [] [] e)
  with TypeError msg -> Error msg

(* All primitives — used when typechecking stdlib modules *)
let stdlib_type_env : env = [
  ("print",      let a = fresh () in generalize [] (effs [Effect_row.IO] (a) (TUnit)));
  ("println",    let a = fresh () in generalize [] (effs [Effect_row.IO] (a) (TUnit)));
  ("exit",       let a = fresh () in generalize [] (effs [Effect_row.Proc] (TInt) (a)));
  ("option_get_exn", let a = fresh () in generalize [] (effs [Effect_row.Raise] (TUnit) (a)));
  ("read_file",  generalize [] (effs [Effect_row.FsRead; Effect_row.Raise] (TString) (TString)));
  ("write_file", generalize [] (effs [Effect_row.FsWrite; Effect_row.Raise] (TString) ((TString @-> TUnit))));
  (* String primitives *)
  ("str_length",     generalize [] ((TString @-> TInt)));
  ("str_upper",      generalize [] ((TString @-> TString)));
  ("str_lower",      generalize [] ((TString @-> TString)));
  ("str_trim",       generalize [] ((TString @-> TString)));
  ("str_slice",      generalize [] ((TInt @-> (TInt @-> (TString @-> TString)))));
  ("str_split",      generalize [] ((TString @-> (TString @-> TList TString))));
  ("str_contains",   generalize [] ((TString @-> (TString @-> TBool))));
  ("str_starts_with",generalize [] ((TString @-> (TString @-> TBool))));
  ("str_ends_with",  generalize [] ((TString @-> (TString @-> TBool))));
  ("str_replace",    generalize [] ((TString @-> (TString @-> (TString @-> TString)))));
  ("str_trim_left",  generalize [] ((TString @-> TString)));
  ("str_trim_right", generalize [] ((TString @-> TString)));
  ("str_repeat",     generalize [] ((TInt @-> (TString @-> TString))));
  ("str_reverse",    generalize [] ((TString @-> TString)));
  ("str_chars",      generalize [] ((TString @-> TList TString)));
  ("int_to_str",       generalize [] ((TInt @-> TString)));
  ("str_to_int",       generalize [] ((TString @-> TResult (TString, TInt))));
  ("str_to_float",     generalize [] ((TString @-> TResult (TString, TFloat))));
  ("str_to_bool",      generalize [] ((TString @-> TResult (TString, TBool))));
  ("str_to_path",      generalize [] ((TString @-> TPath)));
  ("str_to_url",       generalize [] ((TString @-> TResult (TString, TUrl))));
  ("str_to_ipv4",      generalize [] ((TString @-> TResult (TString, TIPv4))));
  ("str_to_cidr",      generalize [] ((TString @-> TResult (TString, TCIDR))));
  ("str_to_port",      generalize [] ((TString @-> TResult (TString, TPort))));
  ("str_to_version",   generalize [] ((TString @-> TResult (TString, TVersion))));
  ("str_to_size",      generalize [] ((TString @-> TResult (TString, TSize))));
  ("str_to_date",      generalize [] ((TString @-> TResult (TString, TDate))));
  ("str_to_time",      generalize [] ((TString @-> TResult (TString, TTime))));
  ("str_to_datetime",  generalize [] ((TString @-> TResult (TString, TDateTime))));
  ("str_to_duration",  generalize [] ((TString @-> TResult (TString, TDuration))));
  (* Regex primitives *)
  ("regex_match",       generalize [] ((TRegex @-> (TString @-> TBool))));
  ("regex_capture",     generalize [] ((TRegex @-> (TString @-> TList TString))));
  ("regex_replace",     generalize [] ((TRegex @-> (TString @-> (TString @-> TString)))));
  ("regex_replace_all", generalize [] ((TRegex @-> (TString @-> (TString @-> TString)))));
  ("regex_split",       generalize [] ((TRegex @-> (TString @-> TList TString))));
  ("regex_find_all",    generalize [] ((TRegex @-> (TString @-> TList TString))));
  ("resource_make",
   (* Acquire and release share one row: a resource performs what either of
      them performs, and `with` folds that into its caller. *)
   let a = fresh () in
   let e = Effect_row.fresh_row () in
   generalize []
     (TFun (TFun (TUnit, a, e),
            TFun (TFun (a, TUnit, e), TResource (e, a), Effect_row.pure),
            Effect_row.pure)));
  ("regex_compile",     generalize [] ((TString @-> TResult (TString, TRegex))));
  (* Duration primitives *)
  ("dur_zero",    Mono TDuration);
  ("dur_seconds", generalize [] ((TInt @-> TDuration)));
  ("dur_minutes", generalize [] ((TInt @-> TDuration)));
  ("dur_hours",   generalize [] ((TInt @-> TDuration)));
  ("dur_days",    generalize [] ((TInt @-> TDuration)));
  ("dur_weeks",   generalize [] ((TInt @-> TDuration)));
  ("dur_add",     generalize [] ((TDuration @-> (TDuration @-> TDuration))));
  ("dur_sub",     generalize [] ((TDuration @-> (TDuration @-> TDuration))));
  ("dur_scale",   generalize [] ((TInt @-> (TDuration @-> TDuration))));
  ("dur_format",  generalize [] ((TDuration @-> TString)));
  ("dur_to_ms",   generalize [] ((TDuration @-> TInt)));
  (* Path primitives *)
  ("path_join",           generalize [] ((TPath @-> (TPath @-> TPath))));
  ("path_parent",         generalize [] ((TPath @-> TPath)));
  ("path_basename",       generalize [] ((TPath @-> TString)));
  ("path_extension",      generalize [] ((TPath @-> TString)));
  ("path_with_extension", generalize [] ((TString @-> (TPath @-> TPath))));
  ("path_is_absolute",    generalize [] ((TPath @-> TBool)));
  ("path_is_relative",    generalize [] ((TPath @-> TBool)));
  ("path_normalize",      generalize [] ((TPath @-> TPath)));
  ("path_to_string",      generalize [] ((TPath @-> TString)));
  ("path_of_string",      generalize [] ((TString @-> TPath)));
  ("path_components",     generalize [] ((TPath @-> TList TString)));
  (* FS primitives *)
  ("fs_exists",  generalize [] (effs [Effect_row.FsRead] (TPath) (TBool)));
  ("fs_is_file", generalize [] (effs [Effect_row.FsRead] (TPath) (TBool)));
  ("fs_is_dir",  generalize [] (effs [Effect_row.FsRead] (TPath) (TBool)));
  ("fs_mkdir",   generalize [] (effs [Effect_row.FsWrite; Effect_row.Raise] (TPath) (TUnit)));
  ("fs_ls",      generalize [] (effs [Effect_row.FsRead; Effect_row.Raise] (TPath) (TList TPath)));
  ("fs_remove",  generalize [] (effs [Effect_row.FsWrite; Effect_row.Raise] (TPath) (TUnit)));
  ("fs_append",  generalize [] (effs [Effect_row.FsWrite; Effect_row.Raise] (TPath) ((TString @-> TUnit))));
  ("fs_create",  generalize [] (effs [Effect_row.FsWrite; Effect_row.Raise] (TPath) (TUnit)));
  ("fs_temp_file", generalize [] (effs [Effect_row.FsWrite; Effect_row.Raise] (TString) ((TString @-> TPath))));
  ("fs_temp_dir",  generalize [] (effs [Effect_row.FsWrite; Effect_row.Raise] (TString) TPath));
  ("fs_delete_tree", generalize [] (effs [Effect_row.FsWrite; Effect_row.Raise] (TPath) TUnit));
  ("fs_rename",  generalize [] (effs [Effect_row.FsWrite; Effect_row.Raise] (TPath) ((TPath @-> TUnit))));
  ("fs_copy",    generalize [] (effs [Effect_row.FsWrite; Effect_row.Raise] (TPath) ((TPath @-> TUnit))));
  ("fs_cwd",     generalize [] (effs [Effect_row.FsRead] (TUnit) (TPath)));
  ("fs_mtime",   generalize [] (effs [Effect_row.FsRead; Effect_row.Raise] (TPath) (TDateTime)));
  ("fs_size",    generalize [] (effs [Effect_row.FsRead; Effect_row.Raise] (TPath) (TInt)));
  ("fs_glob",    generalize [] (effs [Effect_row.FsRead] (TGlob) ((TPath @-> TList TPath))));
  (* IO primitives *)
  ("io_print_err",   generalize [] (effs [Effect_row.IO] (TString) (TUnit)));
  ("io_println_err", generalize [] (effs [Effect_row.IO] (TString) (TUnit)));
  ("io_read_line",   generalize [] (effs [Effect_row.IO; Effect_row.Raise] (TUnit) (TString)));
  ("io_read_all",    generalize [] (effs [Effect_row.IO; Effect_row.Raise] (TUnit) (TString)));
  ("io_flush",       generalize [] (effs [Effect_row.IO] (TUnit) (TUnit)));
  (* Process primitives *)
  ("process_run",       generalize [] (effs [Effect_row.Shell; Effect_row.Raise] (TString) (TString)));
  ("process_run_quiet", generalize [] (effs [Effect_row.Shell] (TString) (TUnit)));
  ("process_exit_code", generalize [] (effs [Effect_row.Shell] (TString) (TInt)));
  (* Env primitives *)
  ("env_read_dotenv", generalize [] (effs [Effect_row.Env; Effect_row.Raise] (TString) (TList (TTuple [TString; TString]))));
  ("env_load_file",   generalize [] (effs [Effect_row.Env; Effect_row.Raise] (TPath) (TUnit)));
  (* CSV primitives *)
  ("csv_parse",         generalize [] ((TString @-> (TString @-> TList (TList TString)))));
  ("csv_stringify",     generalize [] ((TString @-> (TList (TList TString) @-> TString))));
  ("csv_read_file",     generalize [] ((TPath @-> TResult (TString, (TList (TList TString))))));
  ("csv_read_file_exn", generalize [] (effs [Effect_row.Raise] (TPath) (TList (TList TString))));
  (* JSON primitives *)
  ("json_parse",         generalize [] ((TString @-> TResult (TString, TJson))));
  ("json_parse_exn",     generalize [] (effs [Effect_row.Raise] (TString) (TJson)));
  ("json_stringify",     generalize [] ((TJson @-> TString)));
  ("json_stringify_pretty", generalize [] ((TJson @-> TString)));
  ("json_read_file",     generalize [] ((TPath @-> TResult (TString, TJson))));
  ("json_read_file_exn", generalize [] (effs [Effect_row.Raise] (TPath) (TJson)));
  ("json_field_exn",     generalize [] (effs [Effect_row.Raise] (TString) ((TJson @-> TJson))));
  ("json_null",         Mono TJson);
  ("json_of_bool",      generalize [] ((TBool @-> TJson)));
  ("json_of_int",       generalize [] ((TInt @-> TJson)));
  ("json_of_float",     generalize [] ((TFloat @-> TJson)));
  ("json_of_string",    generalize [] ((TString @-> TJson)));
  ("json_of_list",      generalize [] ((TList TJson @-> TJson)));
  ("json_of_map",       generalize [] ((TMap TJson @-> TJson)));
  ("json_is_null",      generalize [] ((TJson @-> TBool)));
  ("json_get_bool",     generalize [] ((TJson @-> TResult (TString, TBool))));
  ("json_get_int",      generalize [] ((TJson @-> TResult (TString, TInt))));
  ("json_get_float",    generalize [] ((TJson @-> TResult (TString, TFloat))));
  ("json_get_string",   generalize [] ((TJson @-> TResult (TString, TString))));
  ("json_get_array",    generalize [] ((TJson @-> TResult (TString, (TList TJson)))));
  ("json_get_object",   generalize [] ((TJson @-> TResult (TString, (TMap TJson)))));
  ("json_field",        generalize [] ((TString @-> (TJson @-> TResult (TString, TJson)))));
  (* Par primitives. The row on the last arrow is the same variable as the
     one on the supplied function, so calling par_map performs exactly what
     that function performs -- the work happens inside, where inference
     cannot otherwise see it. *)
  ("par_map",  let a = fresh () in let b = fresh () in
               let e = Effect_row.fresh_row () in
               generalize [] (TInt @-> (TFun (a, b, e)
                 @-> TFun (TList a, TList (TResult (TString, b)), e))));
  ("par_each", let a = fresh () in
               let e = Effect_row.fresh_row () in
               generalize [] (TInt @-> (TFun (a, TUnit, e)
                 @-> TFun (TList a, TUnit, e))));
  (* TOML primitives *)
  ("toml_parse",        generalize [] ((TString @-> TResult (TString, TToml))));
  ("toml_parse_exn",    generalize [] (effs [Effect_row.Raise] (TString) (TToml)));
  ("toml_read_file",    generalize [] ((TPath @-> TResult (TString, TToml))));
  ("toml_read_file_exn",generalize [] (effs [Effect_row.Raise] (TPath) (TToml)));
  ("toml_stringify",    generalize [] ((TToml @-> TString)));
  ("toml_is_table",     generalize [] ((TToml @-> TBool)));
  ("toml_is_array",     generalize [] ((TToml @-> TBool)));
  ("toml_get_bool",     generalize [] ((TToml @-> TResult (TString, TBool))));
  ("toml_get_int",      generalize [] ((TToml @-> TResult (TString, TInt))));
  ("toml_get_float",    generalize [] ((TToml @-> TResult (TString, TFloat))));
  ("toml_get_string",   generalize [] ((TToml @-> TResult (TString, TString))));
  ("toml_get_array",    generalize [] ((TToml @-> TResult (TString, (TList TToml)))));
  ("toml_get_table",    generalize [] ((TToml @-> TResult (TString, (TMap TToml)))));
  ("toml_field",        generalize [] ((TString @-> (TToml @-> TResult (TString, TToml)))));
  ("toml_field_exn",    generalize [] (effs [Effect_row.Raise] (TString) ((TToml @-> TToml))));
  ("env_get_exn", generalize [] (effs [Effect_row.Env; Effect_row.Raise] (TString) (TString)));
  ("env_set",     generalize [] (effs [Effect_row.Env] (TString) ((TString @-> TUnit))));
  ("env_clear",   generalize [] (effs [Effect_row.Env] (TString) (TUnit)));
  ("env_all",     generalize [] (effs [Effect_row.Env] (TUnit) (TList (TTuple [TString; TString]))));
  ("env_args",    generalize [] (effs [Effect_row.Env] (TUnit) (TList TString)));
  ("env_home",    generalize [] (effs [Effect_row.Env] (TUnit) (TPath)));
  ("env_user",    generalize [] (effs [Effect_row.Env] (TUnit) (TString)));
  (* List primitives *)
  ("list_get",     let a = fresh () in generalize [] ((TInt @-> (TList a @-> TResult (TString, a)))));
  ("list_get_exn", let a = fresh () in generalize [] (TInt @-> effs [Effect_row.Raise] (TList a) (a)));
  ("list_sort",    let a = fresh () in generalize [] ((TList a @-> TList a)));
  ("list_sort_by", let a = fresh () in let b = fresh () in
                   generalize [] (((a @-> b) @-> (TList a @-> TList a))));
  ("list_unique",  let a = fresh () in generalize [] ((TList a @-> TList a)));
  ("list_range",   generalize [] ((TInt @-> (TInt @-> TList TInt))));
  ("list_flatten", let a = fresh () in generalize [] ((TList (TList a) @-> TList a)));
  ("list_concat",  let a = fresh () in generalize [] ((TList a @-> (TList a @-> TList a))));
  (* Map builtins *)
  ("map_empty",    let a = fresh () in generalize [] (TMap a));
  ("map_get",      let a = fresh () in generalize [] ((TString @-> (TMap a @-> TResult (TString, a)))));
  ("map_get_exn",  let a = fresh () in generalize [] (TString @-> effs [Effect_row.Raise] (TMap a) (a)));
  ("map_set",      let a = fresh () in generalize [] ((TString @-> (a @-> (TMap a @-> TMap a)))));
  ("map_delete",   let a = fresh () in generalize [] ((TString @-> (TMap a @-> TMap a))));
  ("map_has",      let a = fresh () in generalize [] ((TString @-> (TMap a @-> TBool))));
  ("map_keys",     let a = fresh () in generalize [] ((TMap a @-> TList TString)));
  ("map_values",   let a = fresh () in generalize [] ((TMap a @-> TList a)));
  ("map_size",     let a = fresh () in generalize [] ((TMap a @-> TInt)));
  ("map_to_list",  let a = fresh () in generalize [] ((TMap a @-> TList (TTuple [TString; a]))));
  ("map_from_list",let a = fresh () in generalize [] ((TList (TTuple [TString; a]) @-> TMap a)));
  ("map_merge",    let a = fresh () in generalize [] ((TMap a @-> (TMap a @-> TMap a))));
  ("map_map",      let a = fresh () in let b = fresh () in
                   generalize [] (((a @-> b) @-> (TMap a @-> TMap b))));
  ("map_filter",   let a = fresh () in generalize [] (((a @-> TBool) @-> (TMap a @-> TMap a))));
]

(* Built-in type definitions always available *)
let shell_result_tdef : type_def =
  Variants ("ShellResult", [], [{
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
  ("print",   let a = fresh () in generalize [] (effs [Effect_row.IO] (a) (TUnit)));
  ("println", let a = fresh () in generalize [] (effs [Effect_row.IO] (a) (TUnit)));
  ("exit",    let a = fresh () in generalize [] (effs [Effect_row.Proc] (TInt) (a)));
]

(* ── Manifests ────────────────────────────────────────────────────────────── *)

let eff_of_label = function
  | "Shell"    -> Some Effect_row.Shell
  | "FS.Read"  -> Some Effect_row.FsRead
  | "FS.Write" -> Some Effect_row.FsWrite
  | "Env"      -> Some Effect_row.Env
  | "IO"       -> Some Effect_row.IO
  | "Proc"     -> Some Effect_row.Proc
  | "Raise"    -> Some Effect_row.Raise
  | _          -> None

(* Every effect anywhere in a type, including the arrows nested inside it: a
   function that returns a function still performs what the inner one does
   once it is called. *)
let rec labels_of_typ t =
  match repr t with
  | TFun (a, b, r) ->
    Effect_row.EffSet.union (Effect_row.labels_of r)
      (Effect_row.EffSet.union (labels_of_typ a) (labels_of_typ b))
  | TTuple ts -> List.fold_left (fun acc t ->
      Effect_row.EffSet.union acc (labels_of_typ t)) Effect_row.EffSet.empty ts
  | TList t | TMap t -> labels_of_typ t
  | TResult (e, t) -> Effect_row.EffSet.union (labels_of_typ e) (labels_of_typ t)
  | TResource (r, t) ->
    Effect_row.EffSet.union (Effect_row.labels_of r) (labels_of_typ t)
  | TApp (f, a) -> Effect_row.EffSet.union (labels_of_typ f) (labels_of_typ a)
  | _ -> Effect_row.EffSet.empty

(* A manifest bounds what a file can do to the machine. Raise is control
   flow, not reach: it is already visible in a `!` name and in a signature,
   and including it would put Raise in almost every manifest while saying
   nothing about blast radius. *)
let manifest_relevant labels = Effect_row.EffSet.remove Effect_row.Raise labels

let render_manifest labels =
  "uses {" ^ String.concat ", "
    (List.map Effect_row.name_of (Effect_row.EffSet.elements labels)) ^ "}"

(* A manifest bounds what the file can do, so it is checked against every
   binding in it -- not only what running the file performs. A function that
   shells out still shells out when something else imports and calls it. *)
(* What the last manifest check concluded, for the linter: the declared set,
   what the file actually uses, and where the manifest sits. Reported as a
   warning rather than an error -- permitting more than you use is the safe
   direction, and failing a build over it would punish caution. *)
let last_manifest : (Effect_row.EffSet.t * Effect_row.EffSet.t * Token.loc) option ref =
  ref None

(* What the file reaches outside itself to do, whether or not it says so.
   Recorded for every file, because the linter's question about a file with
   no manifest is exactly this set: a file that does nothing outward has
   nothing to declare, and one that does should say what. *)
let last_file_effects : Effect_row.EffSet.t ref = ref Effect_row.EffSet.empty

let check_manifest (prog : program) (own_env : env) =
  last_manifest := None;
  let per_binding =
    List.filter_map (fun (name, scheme) ->
      match scheme with
      | Mono t | Poly (_, _, t) ->
        let ls = manifest_relevant (labels_of_typ t) in
        if Effect_row.EffSet.is_empty ls then None else Some (name, ls)
      | Namespace _ -> None
    ) own_env
  in
  let inferred =
    List.fold_left (fun acc (_, ls) -> Effect_row.EffSet.union acc ls)
      (manifest_relevant (Effect_row.labels_of !current_eff)) per_binding
  in
  last_file_effects := inferred;
  match prog.manifest with
  | None -> ()
  | Some (labels, loc) ->
    let declared =
      List.fold_left (fun acc name ->
        match eff_of_label name with
        | Some e -> Effect_row.EffSet.add e acc
        | None ->
          raise (TypeError (Printf.sprintf
            "'%s' is not an effect. The effects are %s" name
            (String.concat ", " (List.map Effect_row.name_of Effect_row.all))))
      ) Effect_row.EffSet.empty labels
    in
    last_manifest := Some (declared, inferred, loc);
    let missing = Effect_row.EffSet.diff inferred declared in
    if not (Effect_row.EffSet.is_empty missing) then begin
      (* Name a binding that needs one of the missing effects, so the reader
         is pointed at the code rather than only told the total is wrong. *)
      (* Name the binding that accounts for most of what is missing, rather
         than the first that happens to share one effect with it. *)
      let culprit =
        List.fold_left (fun best (name, ls) ->
          let overlap =
            Effect_row.EffSet.cardinal (Effect_row.EffSet.inter ls missing) in
          match best with
          | Some (_, n) when n >= overlap -> best
          | _ when overlap = 0 -> best
          | _ -> Some (name, overlap)
        ) None (List.rev per_binding)
      in
      let culprit = Option.map (fun (n, _) -> (n, ())) culprit in
      let where = match culprit with
        | Some (name, _) -> Printf.sprintf "'%s' " name
        | None -> ""
      in
      raise (TypeError (Printf.sprintf
        "%sperforms %s, which the manifest does not allow.\n       The manifest should be:  \"%s\""
        where
        (String.concat ", "
          (List.map Effect_row.name_of (Effect_row.EffSet.elements missing)))
        (render_manifest inferred)))
    end

(* Single inference pass: builds env and returns (tenv, full_env, own_env, last_expr_typ). *)
let infer_program_ ?(base_env=builtin_type_env) ?(init_tenv=[]) ?(init_env=[]) (prog : program)
    : typedef_env * env * env * typ =
  next_id := 0;
  current_eff := Effect_row.fresh_row ();
  holes := [];
  let local_tenv = List.filter_map (function
    | TLType (Variants (n, _, _) as tdef) -> Some (n, tdef)
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
      let saved_fn = !current_fn in
      current_fn := Some name;
      let t = (try infer tenv env_rec (Fn (params, body))
               with e -> current_fn := saved_fn; raise e) in
      current_fn := saved_fn;
      unify placeholder t;
      ((name, generalize env t) :: env, last_t)
    | TLLetRec bindings ->
      let placeholders = List.map (fun (name, _, _) -> (name, fresh ())) bindings in
      let env_rec = List.map (fun (name, t) -> (name, Mono t)) placeholders @ env in
      let inferred = List.map (fun (name, params, body) ->
        let t = infer tenv env_rec (Fn (params, body)) in
        unify (List.assoc name placeholders) t;
        (name, t)
      ) bindings in
      let env' = List.map (fun (name, t) -> (name, generalize env t)) inferred @ env in
      (env', last_t)
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
  check_manifest prog own_env;
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
  | Mono t | Poly (_, _, t) -> string_of_typ t
  | Namespace _           -> "<namespace>"

let infer_program_full_with_own ?(init_tenv=[]) ?(init_env=[]) (prog : program)
    : (env * env * typ * typ list, string) result =
  try
    let (_, full_env, own_env, last_t) = infer_program_ ~init_tenv ~init_env prog in
    let hole_types = List.rev_map repr !holes in
    Ok (full_env, own_env, last_t, hole_types)
  with TypeError msg -> Error msg
