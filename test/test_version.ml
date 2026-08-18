open Wand

(* The version is generated from the VERSION file, and `make release` refuses
   to tag unless the two agree -- so what `wand version` prints is what was
   released. Both halves are checked here: that the generated module still
   matches the file, which a wrong dune dependency would silently break, and
   that the binary prints it in the form an installer parses. *)

let test_matches_the_file () =
  let on_disk =
    In_channel.with_open_bin "../VERSION" In_channel.input_all |> String.trim
  in
  Alcotest.(check string)
    "Version.value is what VERSION says" on_disk Version.value

let test_not_empty () =
  Alcotest.(check bool) "a version was baked in" true (Version.value <> "")

let wand_binary =
  let dir = Filename.dirname (Filename.dirname Sys.executable_name) in
  Filename.concat (Filename.concat dir "bin") "wand.exe"

let run args =
  let cmd =
    Printf.sprintf "%s %s 2>&1" (Filename.quote wand_binary)
      (String.concat " " (List.map Filename.quote args))
  in
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  ignore (Unix.close_process_in ic);
  String.trim out

(* `wand <version>` on one line, with nothing else: an installer compares it
   to the version it meant to install, and prose in the way makes that a
   parsing problem. *)
let test_binary_prints_it () =
  let expected = "wand " ^ Version.value in
  List.iter
    (fun flag ->
      Alcotest.(check string)
        (Printf.sprintf "wand %s" flag)
        expected (run [ flag ]))
    [ "V"; "version" ]

let () =
  Alcotest.run "version"
    [ ( "generated",
        [ Alcotest.test_case "matches VERSION" `Quick test_matches_the_file;
          Alcotest.test_case "is not empty" `Quick test_not_empty
        ] );
      ( "cli",
        [ Alcotest.test_case "printed bare" `Quick test_binary_prints_it ] )
    ]
