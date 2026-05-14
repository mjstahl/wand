let () =
  let argv = Sys.argv in
  let argc = Array.length argv in
  if argc < 2 then (Printf.eprintf "Usage: wand <file> [args...]\n"; exit 1);
  let filename = argv.(1) in
  let args = Array.to_list (Array.sub argv 2 (argc - 2)) in
  Wand.Evaluator.exe_args_ref := args;
  match Wand.Runner.run_file filename with
  | Ok v    -> if v <> "()" then print_endline v
  | Error e -> Printf.eprintf "Error: %s\n" e; exit 1
