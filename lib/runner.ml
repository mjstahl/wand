open Evaluator

let run_item (env : env) (item : Ast.top_item) : env =
  match item with
  | Ast.TLLet (name, [], body) ->
    let v = eval env body in
    (name, v) :: env
  | Ast.TLLet (name, params, body) ->
    let v = VFix (name, env, params, body) in
    (name, v) :: env
  | Ast.TLImport _ -> env
  | Ast.TLType (Ast.Variants (_, ctors)) ->
    List.fold_left (fun env ctor ->
      let v = match ctor.Ast.fields with
        | [] -> VConstr (ctor.Ast.name, [])
        | fs -> VPartialConstr (ctor.Ast.name, List.length fs, [])
      in
      (ctor.Ast.name, v) :: env
    ) env ctors
  | Ast.TLType (Ast.RecordType (type_name, _)) ->
    (type_name, VRecordCtor) :: env

let run_string src =
  try
    let tokens = Lexer.tokenize src in
    let prog   = Parser.parse_program tokens in
    let env    = List.fold_left run_item [] prog.Ast.items in
    let result = match prog.Ast.start with
      | None   -> VUnit
      | Some e -> eval env e
    in
    Ok (show_value result)
  with
  | Lexer.LexError msg    -> Error ("lex error: " ^ msg)
  | Parser.ParseError msg -> Error ("parse error: " ^ msg)
  | EvalError msg         -> Error ("eval error: " ^ msg)
