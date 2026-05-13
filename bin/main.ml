let () =
  match Sys.argv with
  | [| _; filename |] ->
    let src = In_channel.with_open_text filename In_channel.input_all in
    (match Wand.Runner.run_string src with
     | Ok v    -> print_endline v
     | Error e -> Printf.eprintf "Error: %s\n" e; exit 1)
  | _ ->
    Printf.eprintf "Usage: wand <file>\n"; exit 1
