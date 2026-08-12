open Wand

(* Every operation that reaches outside the program has to be interceptable,
   or a rehearsal is a lie: --dry-run works by handling these effects, and
   anything that calls the OS directly would run for real while the output
   claimed otherwise.

   This is checked as a property of the signature rather than against a list
   of names. A new builtin that carries an effect but performs nothing fails
   here without anyone remembering to add it. *)

let outside_world_effects =
  [Effect_row.Shell; Effect_row.FsRead; Effect_row.FsWrite;
   Effect_row.Env; Effect_row.Proc]

(* The effects a builtin's signature claims, ignoring Raise: raising is not
   an interaction with the outside world and nothing intercepts it. *)
let rec claimed_effects (t : Typechecker.typ) =
  match Typechecker.repr t with
  | Typechecker.TFun (a, b, r) ->
    List.filter (fun e -> Effect_row.mem e r) outside_world_effects
    @ claimed_effects a @ claimed_effects b
  | _ -> []

let scheme_type (s : Typechecker.scheme) =
  match s with
  | Typechecker.Mono t -> Some t
  | Typechecker.Poly (_, _, t) -> Some t
  | Typechecker.Namespace _ -> None

(* A builtin is interceptable when evaluating it performs an effect. Applying
   it to a wrong-typed argument is enough to find out: performing happens
   before any argument is inspected, so the effect is raised before the
   error would be. *)
let performs_an_effect name arity =
  let v = List.assoc_opt name Evaluator.stdlib_eval_env in
  match v with
  | None -> None
  | Some v ->
    let rec apply v n =
      if n = 0 then v
      else match v with
        | Evaluator.VBuiltin f -> apply (f (Evaluator.VString "")) (n - 1)
        | other -> other
    in
    (* Run under a handler that answers any effect, so a builtin that
       performs is detected rather than crashing the test. *)
    let performed = ref false in
    (try
       ignore (Effect.Deep.match_with (fun () -> apply v arity) ()
         { Effect.Deep.
             retc = (fun x -> x);
             exnc = (fun _ -> Evaluator.VUnit);
             effc = (fun (type a) (eff : a Effect.t) ->
               match eff with
               | Evaluator.WandEffect _ ->
                 performed := true;
                 Some (fun (_ : (a, Evaluator.value) Effect.Deep.continuation) ->
                   Evaluator.VUnit)
               | _ -> None) })
     with _ -> ());
    Some !performed

let test_effectful_builtins_are_interceptable () =
  let offenders = ref [] in
  List.iter (fun (name, scheme) ->
    match scheme_type scheme with
    | None -> ()
    | Some t ->
      let effects = claimed_effects t in
      if effects <> [] then begin
        (* Try applying one argument at a time: a builtin performs as soon as
           it has what it needs, and we only care that it performs at all. *)
        let performed =
          List.exists (fun arity ->
            match performs_an_effect name arity with
            | Some true -> true
            | _ -> false) [0; 1; 2; 3]
        in
        if not performed then
          offenders := (name, List.map Effect_row.name_of effects) :: !offenders
      end
  ) Typechecker.stdlib_type_env;
  match !offenders with
  | [] -> ()
  | os ->
    Alcotest.failf
      "these builtins claim to touch the outside world but perform no \
       interceptable effect, so --dry-run could not stop them:\n%s"
      (String.concat "\n"
         (List.map (fun (n, es) ->
            Printf.sprintf "  %s ! {%s}" n (String.concat ", " es)) os))

let () =
  Alcotest.run "Interceptable" [
    "builtins", [
      Alcotest.test_case "effectful ones perform" `Quick
        test_effectful_builtins_are_interceptable;
    ];
  ]
