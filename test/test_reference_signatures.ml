(* Every signature the reference states, checked against the binary.

   `Par.each` was documented as `('a -> Unit ! 'e)` for a while after it
   stopped requiring Unit. Nothing caught it: the module-list test compares
   `stdlib_module_names` against the directory, and the lint-rule tests
   check that cited rules exist, but no test read a documented type.

   So this one reads them all. A line of the form `Module.name : type`
   inside the reference is looked up with `wand t` and compared. Lines
   naming something that is not a standard library module are skipped --
   the document defines a few types of its own for examples. *)

let wand_binary =
  let dir = Filename.dirname (Filename.dirname Sys.executable_name) in
  Filename.concat (Filename.concat dir "bin") "wand.exe"

let reference_path = "../docs/reference.md"

let run_type expr =
  let cmd =
    Printf.sprintf "%s t %s 2>&1" (Filename.quote wand_binary)
      (Filename.quote expr)
  in
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  ignore (Unix.close_process_in ic);
  String.trim out

(* Alignment is not a difference: the reference pads `JSON.decode ` and
   `Args.parse  ` to line up their colons. *)
let squeeze s =
  let buf = Buffer.create (String.length s) in
  let last_space = ref false in
  String.iter
    (fun c ->
      let is_space = c = ' ' || c = '\t' in
      if is_space then (if not !last_space then Buffer.add_char buf ' ')
      else Buffer.add_char buf c;
      last_space := is_space)
    s;
  String.trim (Buffer.contents buf)

let is_name_char c =
  (c >= 'a' && c <= 'z')
  || (c >= 'A' && c <= 'Z')
  || (c >= '0' && c <= '9')
  || c = '_' || c = '?' || c = '!'

(* `Module.name : type`, and nothing else. A space on the left means this is
   prose or a binding (`let n : Int = ...`), not a signature. *)
let signature_of line =
  match String.index_opt line ':' with
  | None -> None
  | Some i when i + 1 >= String.length line || line.[i + 1] <> ' ' -> None
  | Some i ->
    let lhs = String.trim (String.sub line 0 i) in
    let rhs = String.trim (String.sub line (i + 1) (String.length line - i - 1)) in
    if lhs = "" || rhs = "" then None
    else if String.exists (fun c -> c = ' ') lhs then None
    else if not (String.for_all (fun c -> is_name_char c || c = '.') lhs) then None
    else
      (match String.index_opt lhs '.' with
       | None -> None
       | Some d ->
         let m = String.sub lhs 0 d in
         let member = String.sub lhs (d + 1) (String.length lhs - d - 1) in
         if member = "" || not (List.mem m Wand.Typechecker.stdlib_module_names)
         then None
         else Some (lhs, rhs))

let signatures () =
  let ic = open_in reference_path in
  let rec loop acc =
    match In_channel.input_line ic with
    | None -> List.rev acc
    | Some line ->
      (match signature_of line with
       | Some s -> loop (s :: acc)
       | None -> loop acc)
  in
  let out = loop [] in
  close_in ic;
  out

let test_documented_signatures_are_real () =
  let sigs = signatures () in
  (* A parser that matches nothing passes every comparison it never makes. *)
  Alcotest.(check bool)
    "found signatures to check (the parser still matches the document)" true
    (List.length sigs >= 5);
  List.iter
    (fun (name, documented) ->
      let actual = run_type name in
      if squeeze documented <> squeeze actual then
        Alcotest.failf
          "the reference documents %s as:\n  %s\nbut wand reports:\n  %s" name
          documented actual)
    sigs

let () =
  Alcotest.run "reference signatures"
    [ ( "stdlib",
        [ Alcotest.test_case "match the binary" `Quick
            test_documented_signatures_are_real
        ] )
    ]
