open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err label input =
  match run input with
  | Error _ -> ()
  | Ok v -> Alcotest.failf "%s: expected error but got: %s" label v

(* ── Glob lexer ──────────────────────────────────────────────────────────────── *)

let test_glob_tokens () =
  let toks src =
    Lexer.tokenize_plain src
    |> List.filter (fun t -> t <> Token.EOF && t <> Token.Newline)
  in
  Alcotest.(check (list (testable Token.pp Token.equal))) "*.wand"
    [Token.Glob "*.wand"] (toks "*.wand");
  Alcotest.(check (list (testable Token.pp Token.equal))) "**"
    [Token.Glob "**"] (toks "**");
  Alcotest.(check (list (testable Token.pp Token.equal))) "./**/*.ml"
    [Token.Glob "./**/*.ml"] (toks "./**/*.ml");
  Alcotest.(check (list (testable Token.pp Token.equal))) "./*.wand"
    [Token.Glob "./*.wand"] (toks "./*.wand");
  (* paths without wildcards are still Path, not Glob *)
  Alcotest.(check (list (testable Token.pp Token.equal))) "/etc/hosts is Path"
    [Token.Path "/etc/hosts"] (toks "/etc/hosts")

(* ── Glob type ───────────────────────────────────────────────────────────────── *)

let test_glob_type () =
  (* Glob is distinct from Path — typechecker should accept Glob where Glob expected *)
  ok "glob literal type" {|import FS
let g = *.wand
"ok"|} "ok";
  (* passing a Path where Glob expected is a type error *)
  err "path not glob" {|import FS
FS.glob /etc .|};
  (* passing a bare string also errors at the type level *)
  err "string not glob" {|import FS
FS.glob "*.wand" .|}

(* ── FS.glob ─────────────────────────────────────────────────────────────────── *)

let test_fs_glob () =
  (* create a temp dir with some files *)
  let tmpdir = Filename.temp_file "wand_glob_" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  let touch name =
    let path = Filename.concat tmpdir name in
    let oc = open_out path in close_out oc
  in
  touch "foo.wand";
  touch "bar.wand";
  touch "baz.ml";
  let cleanup () =
    Array.iter (fun f -> Sys.remove (Filename.concat tmpdir f)) (Sys.readdir tmpdir);
    Unix.rmdir tmpdir
  in
  let src pattern =
    Printf.sprintf {|import FS
import Path
import List
import String
let dir = Path.of_string "%s"
FS.glob! %s dir
  |> List.map Path.basename
  |> List.sort
  |> List.map (fn s -> s)
  |> List.fold_left (fn acc s -> if acc == "" then s else acc ++ "," ++ s) ""|}
      tmpdir pattern
  in
  (try
    ok "*.wand matches"   (src "*.wand") "bar.wand,foo.wand";
    ok "*.ml matches"     (src "*.ml")   "baz.ml";
    ok "no match"         (src "*.py")   "";
    ok "./* matches all"  (src "./*")    "bar.wand,baz.ml,foo.wand";
  with e -> cleanup (); raise e);
  cleanup ()

(* ── FS.glob with ** ─────────────────────────────────────────────────────────── *)

let test_fs_glob_recursive () =
  let tmpdir = Filename.temp_file "wand_glob_rec_" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o700;
  Unix.mkdir (Filename.concat tmpdir "sub") 0o700;
  let touch rel =
    let path = Filename.concat tmpdir rel in
    let oc = open_out path in close_out oc
  in
  touch "a.wand";
  touch "sub/b.wand";
  let cleanup () =
    Sys.remove (Filename.concat tmpdir "a.wand");
    Sys.remove (Filename.concat tmpdir "sub/b.wand");
    Unix.rmdir (Filename.concat tmpdir "sub");
    Unix.rmdir tmpdir
  in
  let src pattern =
    Printf.sprintf {|import FS
import Path
import List
import String
let dir = Path.of_string "%s"
FS.glob! %s dir
  |> List.map Path.basename
  |> List.sort
  |> List.fold_left (fn acc s -> if acc == "" then s else acc ++ "," ++ s) ""|}
      tmpdir pattern
  in
  (try
    ok "** recursive" (src "**.wand") "a.wand,b.wand";
  with e -> cleanup (); raise e);
  cleanup ()

(* ── Suite ───────────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Glob" [
    "lexer", [
      Alcotest.test_case "glob tokens"    `Quick test_glob_tokens;
    ];
    "types", [
      Alcotest.test_case "glob type"      `Quick test_glob_type;
    ];
    "FS.glob", [
      Alcotest.test_case "basic"          `Quick test_fs_glob;
      Alcotest.test_case "recursive"      `Quick test_fs_glob_recursive;
    ];
  ]
