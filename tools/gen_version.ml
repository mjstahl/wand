(* Turns the VERSION file into a module holding it.

   One file holds the version, and `make release` refuses to tag unless it
   matches the tag being made -- so `wand --version` cannot report something
   that was never released.

   Written as a generator rather than a shell action because the release
   binaries are built inside Alpine, where `bash` is not installed. *)

let () =
  let path = Sys.argv.(1) in
  let raw = In_channel.with_open_bin path In_channel.input_all in
  let version = String.trim raw in
  if version = "" then failwith (path ^ " is empty");
  Printf.printf "(* Generated from VERSION. Do not edit. *)\n\nlet value = %S\n"
    version
