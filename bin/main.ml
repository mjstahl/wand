let () =
  match Sys.argv with
  | [| _; filename |] ->
    (match Wand.Runner.run_file filename with
     | Ok v    -> print_endline v
     | Error e -> Printf.eprintf "Error: %s\n" e; exit 1)
  | _ ->
    Printf.eprintf "Usage: wand <file>\n"; exit 1
