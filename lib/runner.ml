open Evaluator

(* ── Default effect handlers ──────────────────────────────────────────────── *)

(* Drain a channel in blocks. Reading one byte at a time costs a call per
   byte, which is invisible on a line of output and very much not on a
   megabyte of it. *)
let drain_channel ic =
  let buf = Buffer.create 65536 in
  let chunk = Bytes.create 65536 in
  let rec loop () =
    let n = input ic chunk 0 (Bytes.length chunk) in
    if n > 0 then begin
      Buffer.add_subbytes buf chunk 0 n;
      loop ()
    end
  in
  (try loop () with End_of_file -> ());
  Buffer.contents buf

let discard_channel ic =
  let chunk = Bytes.create 65536 in
  let rec loop () =
    let n = input ic chunk 0 (Bytes.length chunk) in
    if n > 0 then loop ()
  in
  (try loop () with End_of_file -> ())

(* ── Children ─────────────────────────────────────────────────────────────── *)

(* Every process wand starts, so that stopping wand stops them too. A command
   left running after the script that started it has gone is the bash failure
   this language exists to avoid, and it is worse here: the script's own
   cleanup may be waiting on a process nobody is watching any more.

   Held in an atomic list rather than behind a mutex because the signal
   handler reads it, and a handler that blocked on a lock the interrupted
   code was already holding would never return. *)
let children : int list Atomic.t = Atomic.make []

let rec remember pid =
  let old = Atomic.get children in
  if not (Atomic.compare_and_set children old (pid :: old)) then remember pid

let rec forget pid =
  let old = Atomic.get children in
  let now = List.filter (fun p -> p <> pid) old in
  if not (Atomic.compare_and_set children old now) then forget pid

(* Stop what we started. Failures are ignored on purpose: a child that has
   already exited is exactly the case this is racing with. *)
let stop_children signal =
  List.iter (fun pid -> try Unix.kill pid signal with Unix.Unix_error _ -> ())
    (Atomic.get children)

let sh_argv cmd = [| "/bin/sh"; "-c"; cmd |]

(* The ends wand keeps are close-on-exec, or one command's pipe would be
   inherited by the next command's process: with several running at once,
   a child would hold another's write end open and the reader would wait
   for an end-of-file that never came. The ends handed to create_process
   are duplicated onto the child's stdio, which clears the flag. *)
let spawn_in cmd =
  let (r, w) = Unix.pipe ~cloexec:true () in
  let pid = Unix.create_process "/bin/sh" (sh_argv cmd) Unix.stdin w Unix.stderr in
  Unix.close w;
  remember pid;
  (pid, Unix.in_channel_of_descr r)

let spawn_full cmd =
  let (out_r, out_w) = Unix.pipe ~cloexec:true () in
  let (err_r, err_w) = Unix.pipe ~cloexec:true () in
  let (in_r,  in_w)  = Unix.pipe ~cloexec:true () in
  let pid = Unix.create_process "/bin/sh" (sh_argv cmd) in_r out_w err_w in
  Unix.close out_w; Unix.close err_w; Unix.close in_r;
  remember pid;
  (pid,
   Unix.in_channel_of_descr out_r,
   Unix.out_channel_of_descr in_w,
   Unix.in_channel_of_descr err_r)

let reap pid channels =
  List.iter (fun close -> try close () with Sys_error _ -> ()) channels;
  let (_, status) = Unix.waitpid [] pid in
  forget pid;
  status

(* OCaml numbers signals with its own negative constants, so the raw value
   in a message means nothing to anyone reading it. *)
let signal_name n =
  if n = Sys.sigterm then "SIGTERM" else if n = Sys.sigint then "SIGINT"
  else if n = Sys.sigkill then "SIGKILL" else if n = Sys.sigsegv then "SIGSEGV"
  else if n = Sys.sighup then "SIGHUP" else if n = Sys.sigpipe then "SIGPIPE"
  else if n = Sys.sigquit then "SIGQUIT" else if n = Sys.sigabrt then "SIGABRT"
  else Printf.sprintf "signal %d" n

(* A command that died because wand is stopping is not the script's failure
   to report -- wand killed it on the way out. Surfacing it would put a
   confusing error in front of the reason the script is ending. *)
let died_from_our_own_stop () = Atomic.get Evaluator.interrupt_requested <> 0

let command_signalled cmd n =
  if died_from_our_own_stop () then
    raise (Evaluator.Interrupted (Atomic.get Evaluator.interrupt_requested))
  else
    raise (EvalError (Printf.sprintf "command killed by %s: %s" (signal_name n) cmd))

(* Running a command can end the program as well as fail it: wand kills its
   children when it is stopping, and the command's death arrives here. Both
   travel back through the continuation, so the body unwinds and releases
   what it holds -- raising here instead would abandon it. *)
let attempt f =
  try Ok (f ()) with
  | EvalError _ as e -> Error e
  | Evaluator.Interrupted _ as e -> Error e

let exec_command cmd =
  let (pid, ic) = spawn_in cmd in
  let output = drain_channel ic in
  let status = reap pid [(fun () -> close_in ic)] in
  let output =
    let n = String.length output in
    let i = ref n in
    while !i > 0 && output.[!i - 1] = '\n' do decr i done;
    String.sub output 0 !i
  in
  match status with
  | Unix.WEXITED 0   -> output
  | Unix.WEXITED n   -> raise (EvalError (Printf.sprintf "command exited with code %d: %s" n cmd))
  | Unix.WSIGNALED n -> command_signalled cmd n
  | Unix.WSTOPPED  n -> raise (EvalError (Printf.sprintf "command stopped by signal %d: %s" n cmd))

let exec_command_quiet cmd =
  let (pid, ic) = spawn_in cmd in
  discard_channel ic;
  match reap pid [(fun () -> close_in ic)] with
  | Unix.WEXITED 0   -> ()
  | Unix.WEXITED n   -> raise (EvalError (Printf.sprintf "command exited with code %d: %s" n cmd))
  | Unix.WSIGNALED n -> command_signalled cmd n
  | Unix.WSTOPPED  n -> raise (EvalError (Printf.sprintf "command stopped by signal %d: %s" n cmd))

let exec_command_exit_code cmd =
  let (pid, ic) = spawn_in cmd in
  discard_channel ic;
  match reap pid [(fun () -> close_in ic)] with
  | Unix.WEXITED n   -> n
  | Unix.WSIGNALED _ -> 128
  | Unix.WSTOPPED  _ -> 128

let read_all ic = drain_channel ic

let strip_trailing_newline s =
  let n = String.length s in
  let i = ref n in
  while !i > 0 && s.[!i - 1] = '\n' do decr i done;
  String.sub s 0 !i

let exec_command_stdin cmd stdin =
  let (pid, ic, oc, ec) = spawn_full cmd in
  output_string oc stdin; close_out oc;
  let stdout = strip_trailing_newline (read_all ic) in
  let _stderr = read_all ec in
  match reap pid [(fun () -> close_in ic); (fun () -> close_in ec)] with
  | Unix.WEXITED 0   -> stdout
  | Unix.WEXITED n   -> raise (EvalError (Printf.sprintf "command exited with code %d: %s" n cmd))
  | Unix.WSIGNALED n -> command_signalled cmd n
  | Unix.WSTOPPED  n -> raise (EvalError (Printf.sprintf "command stopped by signal %d: %s" n cmd))

let exec_command_full cmd =
  let (pid, ic, oc, ec) = spawn_full cmd in
  close_out oc;
  let stdout = strip_trailing_newline (read_all ic) in
  let stderr = read_all ec in
  let code = match reap pid [(fun () -> close_in ic); (fun () -> close_in ec)] with
    | Unix.WEXITED n   -> n
    | Unix.WSIGNALED _ -> 128
    | Unix.WSTOPPED  _ -> 128
  in
  (stdout, stderr, code)

let exec_command_full_stdin cmd stdin =
  let (pid, ic, oc, ec) = spawn_full cmd in
  output_string oc stdin; close_out oc;
  let stdout = strip_trailing_newline (read_all ic) in
  let stderr = read_all ec in
  let code = match reap pid [(fun () -> close_in ic); (fun () -> close_in ec)] with
    | Unix.WEXITED n   -> n
    | Unix.WSIGNALED _ -> 128
    | Unix.WSTOPPED  _ -> 128
  in
  (stdout, stderr, code)

let shell_result stdout stderr code =
  VConstr ("ShellResult", [VString stdout; VString stderr; VInt code])

(* ── Rehearsal and tracing ────────────────────────────────────────────────── *)

type mode = Normal | Trace | DryRun

(* The mode a program is running under. Workers spawned by Par install the
   same handlers on their own domain: an effect performed on one domain does
   not reach a handler on another, so a worker without them would either
   escape a rehearsal or fail outright. *)
let current_mode = ref Normal

(* Reports come from several domains at once, so a line is written whole
   rather than interleaved with another worker's. *)
let report_lock = Mutex.create ()

let report fmt =
  Printf.ksprintf (fun line ->
    Mutex.lock report_lock;
    prerr_string line;
    flush stderr;
    Mutex.unlock report_lock) fmt

(* How an operation reads in a report. Every operation name a user sees comes
   through here, so what they are called is one decision in one place rather
   than a vocabulary spread through the output. *)
let describe_operation name (v : value) =
  (* A report is read to judge blast radius, so each operation shows the one
     argument that decides it -- the command, the path, the variable -- and a
     size where the content matters but its text does not. *)
  let text = function
    | VString s | VPath s -> s
    | other -> show_value other
  in
  let first = function
    | VTuple (a :: _) -> text a
    | other -> text other
  in
  let with_size v = match v with
    | VTuple [target; VString contents] ->
      Printf.sprintf "%s (%d bytes)" (text target) (String.length contents)
    | other -> text other
  in
  let pair = function
    | VTuple [a; b] -> text a ^ " -> " ^ text b
    | other -> text other
  in
  match name with
  | "Shell!run" | "Shell!run_quiet" | "Shell!capture" | "Shell!exit_code"->
    Some ("run", first v)
  | "FS!write_file"   -> Some ("write", with_size v)
  | "FS!append"    -> Some ("append to", with_size v)
  | "FS!create_file"    -> Some ("create", text v)
  | "FS!delete"    -> Some ("delete", text v)
  | "FS!mkdir"   -> Some ("create directory", text v)
  | "FS!rename"    -> Some ("rename", pair v)
  | "FS!copy"      -> Some ("copy", pair v)
  | "FS!temp_file" -> Some ("create temp file", first v)
  | "FS!temp_dir"  -> Some ("create temp directory", text v)
  | "FS!delete_tree" -> Some ("delete recursively", text v)
  | "Env!set"      -> Some ("set", pair v)
  | "Env!clear"    -> Some ("clear", text v)
  | "FS!read_file"    -> Some ("read", text v)
  | "FS!list_dir"        -> Some ("list", text v)
  | "FS!glob"      -> Some ("glob", first v)
  | "Proc!exit"         -> Some ("exit", text v)
  | _              -> None

(* Whether an operation changes anything outside the program. Reads run even
   in a rehearsal, so that control flow follows the path a real run would
   take; only changes are withheld. *)
let is_mutation = function
  | "Shell!run" | "Shell!run_quiet" | "Shell!capture" | "Shell!exit_code" | "FS!write_file" | "FS!append" | "FS!create_file" | "FS!delete" | "FS!mkdir" | "FS!rename" | "FS!copy" | "FS!temp_file" | "FS!temp_dir" | "FS!delete_tree" | "Env!set" | "Env!clear"-> true
  | _ -> false

(* What an operation hands back when it is reported instead of carried out.
   Whatever this is steers the rest of the script, so a rehearsal says what it
   substituted rather than letting the script appear to have real output. *)
let substitute_for name =
  match name with
  | "Shell!run"-> Some (VString "", "\"\"")
  | "Shell!capture"->
    Some (shell_result "" "" 0, "exit 0, no output")
  | "Shell!exit_code" -> Some (VInt 0, "0")
  | "FS!temp_file"      -> Some (VPath "/tmp/wand-dry-run", "/tmp/wand-dry-run")
  | "FS!temp_dir"       -> Some (VPath "/tmp/wand-dry-run-dir", "/tmp/wand-dry-run-dir")
  | _ -> None

(* The spawn-time half of a `Shell(git, curl)` manifest. The site's own
   file's bound arrives via `Evaluator.ambient_shell_allow` -- set around
   the perform, threaded across domains by Par -- and is checked here, at
   the moment of actual spawn, over the fully resolved command line. A
   mock, a rehearsal, or any other handler that intercepted the effect
   never spawns, so it never trips this. *)
let guard_shell cmd =
  match Domain.DLS.get Evaluator.ambient_shell_allow with
  | None -> ()
  | Some allow ->
    List.iter (fun w ->
      match (w : Shell_scan.word_class) with
      | Shell_scan.Literal word when not (Shell_scan.allowed ~allow word) ->
        raise (EvalError (Printf.sprintf
          "this command runs '%s', which the manifest's %s does not allow"
          word (Shell_scan.render_label ("Shell", Some allow))))
      | Shell_scan.Compound kw ->
        raise (EvalError (Printf.sprintf
          "this command uses shell control flow ('%s'), which the \
           manifest's %s cannot bound; write the loop in wand, or declare \
           bare Shell" kw (Shell_scan.render_label ("Shell", Some allow))))
      | _ -> ())
      (Shell_scan.scan_string cmd).Shell_scan.words

let run_with_default_handler (thunk : unit -> value) : value =
  Effect.Deep.match_with thunk ()
    { Effect.Deep.
        retc = (fun v -> v);
        exnc = raise;
        effc = fun (type a) (eff : a Effect.t) ->
          match eff with
          | WandEffect ("IO!print", v) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              print_string (show_value v);
              Effect.Deep.continue k VUnit)
          | WandEffect ("IO!println", v) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              print_endline (show_value v);
              Effect.Deep.continue k VUnit)
          (* stderr is where a script reports what went wrong, so it is
             flushed rather than left in a buffer that a later `Proc.exit`
             would discard. *)
          | WandEffect ("IO!print_err", v) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              output_string stderr (show_value v);
              flush stderr;
              Effect.Deep.continue k VUnit)
          | WandEffect ("IO!println_err", v) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              output_string stderr (show_value v ^ "\n");
              flush stderr;
              Effect.Deep.continue k VUnit)
          | WandEffect ("FS!stream_lines", (VString p | VPath p)) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try Ok (open_in p)
                     with Sys_error m -> Error ("stream_lines: " ^ m)) with
              | Ok ic   -> Effect.Deep.continue    k (VLineSource ic)
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("IO!stdin_lines", VUnit) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              Effect.Deep.continue k (VLineSource stdin))
          | WandEffect ("IO!read_line", VUnit) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match In_channel.input_line stdin with
              | Some line -> Effect.Deep.continue k (VString line)
              (* End of input is not a line, and returning "" would make it
                 indistinguishable from a blank one. `IO.read_line` wraps
                 this into a Result. *)
              | None -> Effect.Deep.discontinue k (EvalError "end of input"))
          | WandEffect ("Shell!run", VString cmd) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match attempt (fun () -> guard_shell cmd; exec_command cmd) with
              | Ok s    -> Effect.Deep.continue    k (VString s)
              | Error e -> Effect.Deep.discontinue k e)
          | WandEffect ("Shell!run_quiet", VString cmd) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match attempt (fun () -> guard_shell cmd; exec_command_quiet cmd) with
              | Ok ()   -> Effect.Deep.continue    k VUnit
              | Error e -> Effect.Deep.discontinue k e)
          | WandEffect ("Shell!exit_code", VString cmd) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match attempt (fun () -> guard_shell cmd) with
              | Error e -> Effect.Deep.discontinue k e
              | Ok ()   -> Effect.Deep.continue k (VInt (exec_command_exit_code cmd)))
          | WandEffect ("Shell!run", VTuple [VString cmd; VString stdin]) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match attempt (fun () -> guard_shell cmd; exec_command_stdin cmd stdin) with
              | Ok s    -> Effect.Deep.continue    k (VString s)
              | Error e -> Effect.Deep.discontinue k e)
          | WandEffect ("Shell!capture", VString cmd) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match attempt (fun () -> guard_shell cmd) with
              | Error e -> Effect.Deep.discontinue k e
              | Ok () ->
                let (stdout, stderr, code) = exec_command_full cmd in
                Effect.Deep.continue k (shell_result stdout stderr code))
          | WandEffect ("Shell!capture", VTuple [VString cmd; VString stdin]) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match attempt (fun () -> guard_shell cmd) with
              | Error e -> Effect.Deep.discontinue k e
              | Ok () ->
                let (stdout, stderr, code) = exec_command_full_stdin cmd stdin in
                Effect.Deep.continue k (shell_result stdout stderr code))
          | WandEffect ("FS!read_file", (VString path | VPath path)) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try Ok (In_channel.with_open_text path In_channel.input_all)
                     with Sys_error m -> Error ("read_file: " ^ m)) with
              | Ok s    -> Effect.Deep.continue    k (VString s)
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("FS!write_file", VTuple [(VString path | VPath path); VString content]) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try Out_channel.with_open_text path
                           (fun oc -> Out_channel.output_string oc content); Ok ()
                     with Sys_error m -> Error ("write_file: " ^ m)) with
              | Ok ()   -> Effect.Deep.continue    k VUnit
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("fs_mkdir", VString path) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try Unix.mkdir path 0o755; Ok ()
                     with Unix.Unix_error (e, _, _) -> Error ("mkdir: " ^ Unix.error_message e)) with
              | Ok ()   -> Effect.Deep.continue    k VUnit
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("FS!mkdir", VPath path) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              let rec mkdir_p p =
                if Sys.file_exists p then ()
                else begin mkdir_p (Filename.dirname p); Unix.mkdir p 0o755 end
              in
              match (try mkdir_p path; Ok ()
                     with Unix.Unix_error (e, _, _) -> Error ("mkdir_p: " ^ Unix.error_message e)) with
              | Ok ()   -> Effect.Deep.continue    k VUnit
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("FS!list_dir", VPath path) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try
                       let entries = Sys.readdir path in
                       Array.sort String.compare entries;
                       Ok (Array.to_list (Array.map (fun s ->
                         VPath (Filename.concat path s)) entries))
                     with Sys_error m -> Error ("ls: " ^ m)) with
              | Ok vs   -> Effect.Deep.continue    k (VList vs)
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("FS!append", VTuple [VPath path; VString content]) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try Out_channel.with_open_gen
                           [Open_wronly; Open_creat; Open_append] 0o644 path
                           (fun oc -> Out_channel.output_string oc content); Ok ()
                     with Sys_error m -> Error ("append: " ^ m)) with
              | Ok ()   -> Effect.Deep.continue    k VUnit
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("FS!create_file", VPath path) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try Out_channel.with_open_gen
                           [Open_wronly; Open_creat; Open_trunc] 0o644 path
                           (fun _ -> ()); Ok ()
                     with Sys_error m -> Error ("create_file: " ^ m)) with
              | Ok ()   -> Effect.Deep.continue    k VUnit
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("FS!temp_file", VTuple [VString prefix; VString suffix]) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try Ok (Filename.temp_file prefix suffix)
                     with Sys_error m -> Error ("temp_file: " ^ m)) with
              | Ok path -> Effect.Deep.continue    k (VPath path)
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("FS!temp_dir", VString prefix) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              (* Filename.temp_file makes a unique name and reserves it; the
                 file is replaced by a directory of the same name, so two
                 callers cannot be handed the same path. *)
              match (try
                       let path = Filename.temp_file prefix "" in
                       Sys.remove path;
                       Unix.mkdir path 0o700;
                       Ok path
                     with Sys_error m -> Error ("temp_dir: " ^ m)
                        | Unix.Unix_error (e, _, _) ->
                          Error ("temp_dir: " ^ Unix.error_message e)) with
              | Ok path -> Effect.Deep.continue    k (VPath path)
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("FS!delete_tree", VPath path) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              (* Depth-first, and it does not follow symlinks out of the
                 tree: a link is unlinked, never descended into. *)
              let rec rm p =
                match Unix.lstat p with
                | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
                | st ->
                  if st.Unix.st_kind = Unix.S_DIR then begin
                    Array.iter (fun e -> rm (Filename.concat p e)) (Sys.readdir p);
                    Unix.rmdir p
                  end else Sys.remove p
              in
              match (try rm path; Ok ()
                     with Sys_error m -> Error ("delete_tree: " ^ m)
                        | Unix.Unix_error (e, _, _) ->
                          Error ("delete_tree: " ^ Unix.error_message e)) with
              | Ok ()   -> Effect.Deep.continue    k VUnit
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("FS!rename", VTuple [VPath old_; VPath new_]) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try Unix.rename old_ new_; Ok ()
                     with Unix.Unix_error (e, _, _) ->
                       Error ("rename: " ^ Unix.error_message e)) with
              | Ok ()   -> Effect.Deep.continue    k VUnit
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("FS!copy", VTuple [VPath src; VPath dst]) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try
                       let content = In_channel.with_open_bin src In_channel.input_all in
                       Out_channel.with_open_bin dst
                         (fun oc -> Out_channel.output_string oc content);
                       Ok ()
                     with Sys_error m -> Error ("copy: " ^ m)) with
              | Ok ()   -> Effect.Deep.continue    k VUnit
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          (* Read-only operations: performed so a trace can see them, and
             carried out by the same implementations the builtins used. A
             failure has to be delivered into the continuation rather than
             raised here, or it escapes the handler instead of reaching the
             `try` at the call site. *)
          | WandEffect ("FS!cwd", v) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match Evaluator.fs_cwd_impl v with
              | result -> Effect.Deep.continue k result
              | exception (EvalError _ as e) -> Effect.Deep.discontinue k e)
          | WandEffect ("FS!mtime", v) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match Evaluator.fs_mtime_impl v with
              | result -> Effect.Deep.continue k result
              | exception (EvalError _ as e) -> Effect.Deep.discontinue k e)
          | WandEffect ("FS!size", v) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match Evaluator.fs_size_impl v with
              | result -> Effect.Deep.continue k result
              | exception (EvalError _ as e) -> Effect.Deep.discontinue k e)
          | WandEffect ("FS!glob", VTuple [pattern; dir]) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (match List.assoc "fs_glob_impl" Evaluator.stdlib_eval_env with
                     | VBuiltin f ->
                       (match f pattern with
                        | VBuiltin g -> g dir
                        | other -> other)
                     | other -> other) with
              | result -> Effect.Deep.continue k result
              | exception (EvalError _ as e) -> Effect.Deep.discontinue k e)
          | WandEffect ("Env!set", VTuple [VString name; VString value]) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              Unix.putenv name value;
              Effect.Deep.continue k VUnit)
          | WandEffect ("Env!clear", VString name) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              Unix.putenv name "";
              Effect.Deep.continue k VUnit)
          | WandEffect ("FS!delete", VPath path) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              let rm () =
                if Sys.file_exists path && Sys.is_directory path
                then Unix.rmdir path
                else Sys.remove path
              in
              match (try rm (); Ok ()
                     with Sys_error m -> Error ("remove: " ^ m)
                        | Unix.Unix_error (e, _, _) -> Error ("remove: " ^ Unix.error_message e)) with
              | Ok ()   -> Effect.Deep.continue    k VUnit
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect (("io_print_err" | "print_err"), v) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              output_string stderr (show_value v);
              Effect.Deep.continue k VUnit)
          | WandEffect (("io_println_err" | "println_err"), v) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              output_string stderr (show_value v ^ "\n");
              Effect.Deep.continue k VUnit)
          | WandEffect (("io_read_line" | "read_line"), VUnit) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try Ok (input_line stdin) with End_of_file -> Error "end of input") with
              | Ok s    -> Effect.Deep.continue    k (VString s)
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("IO!read_all", VUnit) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              Effect.Deep.continue k (VString (In_channel.input_all stdin)))
          | WandEffect ("IO!flush", VUnit) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              flush stdout;
              Effect.Deep.continue k VUnit)
          (* Anything else that was registered as performing: the default
             behaviour is simply to run the implementation it was built
             from. Failures go back through the continuation so a `try` at
             the call site still sees them. *)
          | WandEffect (name, v) when Hashtbl.mem Evaluator.direct_impl name ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (Hashtbl.find Evaluator.direct_impl name) v with
              | result -> Effect.Deep.continue k result
              (* Back through the continuation, not raised beside it: an
                 exception raised here would abandon the body rather than
                 unwind it, and every `with` the body is holding would go
                 unreleased. That is how `exit` skipped cleanup. *)
              | exception ((EvalError _ | Interrupted _) as e) ->
                Effect.Deep.discontinue k e)
          | _ -> None
    }

(* ── Import resolution ────────────────────────────────────────────────────── *)

(* Path resolution, `import`-expression matching, and other purely
   type/AST-level pieces of this live in `Module_types` (shared with
   `Evaluator`'s `Types` primitives, which typecheck imports without
   evaluating them). Only the parts that need `Evaluator.value`/`eval` stay
   here. *)
let add_ext          = Module_types.add_ext
let resolve_import    = Module_types.resolve_import
let namespace_name_of = Module_types.namespace_name_of
let local_tenv_of     = Module_types.local_tenv_of
let is_private        = Module_types.is_private
let strip_located     = Module_types.strip_located
let import_kind_of    = Module_types.import_kind_of

type import_env = {
  tenv     : (string * Ast.type_def) list;
  type_env : Typechecker.env;
  eval_env : env;
}

let empty_import_env = { tenv = []; type_env = []; eval_env = [] }

let merge_import_env a b = {
  tenv     = b.tenv @ a.tenv;
  type_env = b.type_env @ a.type_env;
  eval_env = b.eval_env @ a.eval_env;
}

(* ── Multi-clause merging ─────────────────────────────────────────────────── *)

(* True for patterns that unconditionally match (no structural constraint). *)
let is_catchall_pat = function
  | Ast.PVar _ | Ast.Wild -> true
  | _ -> false

(* Extract the match cases from a previously merged VFix, or return a single case. *)
let extract_arms arity existing_params existing_body =
  let fresh     = List.init arity (fun i -> Printf.sprintf "_p%d" i) in
  let fresh_pats = List.map (fun v -> Ast.PVar v) fresh in
  let scrutinee = match fresh with
    | [v] -> Ast.Var v
    | vs  -> Ast.Tuple (List.map (fun v -> Ast.Var v) vs)
  in
  if existing_params = fresh_pats then
    match strip_located existing_body with
    | Ast.Match (scrut, cases) when strip_located scrut = scrutinee -> cases
    | body ->
      let pat = match existing_params with [p] -> p | ps -> Ast.PTuple ps in
      [(pat, None, body)]
  else
    let pat = match existing_params with [p] -> p | ps -> Ast.PTuple ps in
    [(pat, None, existing_body)]

(* Merge a new clause into an existing same-arity VFix.
   Specific patterns are placed before catch-all patterns so that
   a base case added after a catch-all still fires correctly.
   Within each group the new clause takes precedence. *)
let merge_clause env name arity params body existing_params existing_body =
  let fresh     = List.init arity (fun i -> Printf.sprintf "_p%d" i) in
  let scrutinee = match fresh with
    | [v] -> Ast.Var v
    | vs  -> Ast.Tuple (List.map (fun v -> Ast.Var v) vs)
  in
  let new_pat  = match params with [p] -> p | ps -> Ast.PTuple ps in
  let new_case  = (new_pat, None, body) in
  let old_arms = extract_arms arity existing_params existing_body in
  let (new_sp, new_ca) =
    if is_catchall_pat new_pat then ([], [new_case]) else ([new_case], []) in
  let (old_sp, old_ca) =
    List.partition (fun (p, _, _) -> not (is_catchall_pat p)) old_arms in
  let cases = new_sp @ old_sp @ new_ca @ old_ca in
  VFix (name, env, List.map (fun v -> Ast.PVar v) fresh, Ast.Match (scrutinee, cases))

(* Evaluate a single top-level item; imports already merged into env *)
let run_item env item =
  match item with
  | Ast.TLLet (_, [], body) when Option.is_some (import_kind_of body) -> env  (* pre-loaded *)
  | Ast.TLLet (name, [], body) ->
    (name, eval env body) :: env
  | Ast.TLLet (name, params, body) ->
    (name, VFix (name, env, params, body)) :: env
  | Ast.TLLetRec bindings ->
    List.fold_left (fun acc (name, _, _) ->
      (name, VFixGroup (bindings, env, name)) :: acc) env bindings
  | Ast.TLLetPat (_, body) when Option.is_some (import_kind_of body) -> env  (* pre-loaded *)
  | Ast.TLLetPat (pat, e) ->
    Evaluator.bind_pat ~prefix:true pat (eval env e) env
  | Ast.TLImport _ -> env  (* already loaded by load_imports_for *)
  | Ast.TLType (Ast.Variants (tname, params, ctors)) ->
    (* A single-constructor type with named fields can have its decoder
       derived, so the definition is kept where the derivation can find it.
       Anything else -- several constructors, positional fields, a generic --
       has no shape a decoder could read, and is not recorded. *)
    (match ctors with
     | [ctor] when ctor.Ast.fields <> []
                       && List.for_all (fun (n, _) -> n <> None) ctor.Ast.fields ->
       Hashtbl.replace Evaluator.derivable tname
         (ctor.Ast.name, params, ctor.Ast.fields)
     | _ -> Hashtbl.remove Evaluator.derivable tname);
    List.fold_left (fun env ctor ->
      let field_names = List.map fst ctor.Ast.fields in
      Hashtbl.replace Evaluator.constr_fields ctor.Ast.name field_names;
      let v = match ctor.Ast.fields with
        | [] -> VConstr (ctor.Ast.name, [])
        | fs -> VPartialConstr (ctor.Ast.name, List.length fs, [])
      in
      (ctor.Ast.name, v) :: env
    ) env ctors
  | Ast.TLExpr _ -> env

(* The constructors of a set of type definitions, as evaluation bindings.
   Type definitions cross an import boundary, so their constructors have to
   as well: the typechecker learns them from the definition, and this is the
   evaluator's half of the same fact. *)
let ctor_bindings_of tenv =
  List.fold_left (fun acc (_, tdef) -> run_item acc (Ast.TLType tdef)) [] tenv

(* Run top-level items, dropping a fresh index in every so often: a file's
   own definitions accumulate in front of the base, and without this a name
   defined early is walked past by everything defined later. *)
let fold_items step env items =
  let (env, _) =
    List.fold_left (fun (env, since) item ->
      let env = step env item in
      if since >= Evaluator.index_every then (Evaluator.index_env env, 0)
      else (env, since + 1)
    ) (env, 0) items
  in
  env

(* ── Module loading ───────────────────────────────────────────────────────── *)

type module_result = import_env * (string * Typechecker.scheme) list * env * (string * string) list

(* A module's cache key, by path: the hash of its source and of everything it
   imports. Recorded as modules load so a parent can fold its children's keys
   into its own -- which is what makes a stale entry unreachable instead of
   merely wrong. Per process, like `cache`. *)
let module_keys : (string, string) Hashtbl.t = Hashtbl.create 16

(* Load imports for a program.
   `cache` maps path -> result so each module is loaded once per run_program.
   `loading` detects import cycles. *)
let rec load_imports_for ~base_dir ~cache ~loading prog =
  List.fold_left (fun (acc, acc_docs) item ->
    let load_kind kind =
      let src_ref = resolve_import base_dir kind in
      let key = Module_types.key_of src_ref in
      match Hashtbl.find_opt cache key with
      | Some cached -> cached
      | None ->
        if List.mem key !loading then failwith ("import cycle detected: " ^ key)
        else load_module src_ref ~cache ~loading
    in
    let bind_field own_type own_eval field alias =
      let t = match List.assoc_opt field own_type with
        | Some s -> s
        | None -> failwith (Printf.sprintf "module has no exported symbol '%s'" field)
      in
      let v = match List.assoc_opt field own_eval with
        | Some v -> v
        | None -> failwith (Printf.sprintf "module has no exported symbol '%s'" field)
      in
      ((alias, t), (alias, v))
    in
    (* An import brings in exactly what it names -- the namespace, or the
       fields a destructuring pattern lists -- and nothing else. The module's
       own environment is deliberately not spliced in: its functions are
       closures that already carry the scope they were written in, so they do
       not need the importer's, and splicing it would put every name in the
       module into scope unqualified, whether or not the import asked for it.

       Type definitions are the exception and do propagate, along with their
       constructors, because a value of an imported type is matched by
       constructor here. *)
    let add_import modul_import type_entries eval_entries mod_docs =
      ({ tenv     = modul_import.tenv @ acc.tenv;
         type_env = type_entries @ acc.type_env;
         eval_env = eval_entries @ ctor_bindings_of modul_import.tenv @ acc.eval_env },
       mod_docs @ acc_docs)
    in
    match item with
    | Ast.TLImport kind ->
      let ns_name = namespace_name_of kind in
      let (modul_import, own_type, own_eval, mod_docs) = load_kind kind in
      let prefixed_docs = List.map (fun (n, d) -> (ns_name ^ "." ^ n, d)) mod_docs in
      add_import modul_import
        [(ns_name, Typechecker.Namespace own_type)]
        [(ns_name, VRecord own_eval)]
        prefixed_docs
    | Ast.TLLet (name, [], body) when Option.is_some (import_kind_of body) ->
      let kind = Option.get (import_kind_of body) in
      let (modul_import, own_type, own_eval, mod_docs) = load_kind kind in
      let prefixed_docs = List.map (fun (n, d) -> (name ^ "." ^ n, d)) mod_docs in
      add_import modul_import
        [(name, Typechecker.Namespace own_type)]
        [(name, VRecord own_eval)]
        prefixed_docs
    | Ast.TLLetPat (pat, body) when Option.is_some (import_kind_of body) ->
      let kind = Option.get (import_kind_of body) in
      let (modul_import, own_type, own_eval, mod_docs) = load_kind kind in
      let (type_entries, eval_entries, extra_docs) = match pat with
        | Ast.PVar name ->
          let pdocs = List.map (fun (n, d) -> (name ^ "." ^ n, d)) mod_docs in
          [(name, Typechecker.Namespace own_type)],
          [(name, VRecord own_eval)],
          pdocs
        | Ast.PMap binds ->
          let te, ee = List.map (fun (field, p) ->
            match p with
            | Ast.PVar alias -> bind_field own_type own_eval field alias
            | _ -> failwith "import destructuring only supports name bindings"
          ) binds |> List.split in
          te, ee, []
        | Ast.PList pats ->
          let te, ee = List.map (fun p ->
            match p with
            | Ast.PVar name -> bind_field own_type own_eval name name
            | _ -> failwith "import destructuring only supports name bindings"
          ) pats |> List.split in
          te, ee, []
        | _ -> failwith "unsupported pattern in import destructuring"
      in
      add_import modul_import type_entries eval_entries extra_docs
    | _ -> (acc, acc_docs)
  ) (empty_import_env, []) prog.Ast.items

and load_module src_ref ~cache ~loading =
  (* Embedded or on disk, a module is a name and some source from here on:
     the name keys the caches and the cycle check, and nothing below asks
     where the bytes came from. *)
  let path = Module_types.key_of src_ref in
  let src = Module_types.read_source src_ref in
  let tokens =
    try Lexer.tokenize src
    with Lexer.LexError msg ->
      failwith ("lex error in '" ^ path ^ "': " ^ msg)
  in
  let prog =
    try Parser.parse_program tokens
    with Parser.ParseError msg ->
      failwith ("parse error in '" ^ path ^ "': " ^ msg)
  in
  let base_dir = Filename.dirname path in
  loading := path :: !loading;
  let (imported, imp_docs) = load_imports_for ~base_dir ~cache ~loading prog in
  (* The key covers this module's source and its imports' keys, which cover
     theirs. Parsing happens either way -- it is a fifth of what inference
     costs, and the import list has to be read to know what the key depends
     on. Inference is what the entry saves. *)
  let dep_keys =
    List.filter_map (fun item ->
      match item with
      | Ast.TLImport kind
      | Ast.TLLet (_, [], Ast.ImportExpr kind)
      | Ast.TLLetPat (_, Ast.ImportExpr kind) ->
        Hashtbl.find_opt module_keys
          (Module_types.key_of (resolve_import base_dir kind))
      | _ -> None) prog.Ast.items
  in
  let own_key = Compile_cache.key ~source:src ~deps:dep_keys in
  Hashtbl.replace module_keys path own_key;
  (* Only the module's own share is written down. What inference returns is
     `own @ constructors @ stdlib @ imports`, and the last two are the same
     for everyone -- storing them would put a copy of the whole standard
     library in every entry, which costs more to write and read back than
     the inference it saves. The tail is rebuilt from what is already in
     hand. *)
  let tail_len =
    List.length Typechecker.stdlib_type_env + List.length imported.type_env
  in
  let rebuild own_part =
    own_part @ Typechecker.stdlib_type_env @ imported.type_env
  in
  let refresh = List.map (fun (n, s) -> (n, Typechecker.refresh_scheme s)) in
  let inferred =
    match Compile_cache.find own_key with
    | Some (own_part, own_type) ->
      Ok (rebuild (refresh own_part), refresh own_type)
    | None ->
      (match Typechecker.infer_program_env_with_own
               ~init_tenv:imported.tenv ~init_env:imported.type_env prog with
       | Ok (type_env, own_type) as ok ->
         let n_own = List.length type_env - tail_len in
         if n_own >= 0 then begin
           let own_part = List.filteri (fun i _ -> i < n_own) type_env in
           (* Stored only if the tail really is what it is assumed to be.
              Compared by name: a scheme is a graph of mutable variables and
              deep-comparing several hundred of them would cost more than the
              inference being cached. *)
           if List.map fst (rebuild own_part) = List.map fst type_env then
             Compile_cache.store own_key (own_part, own_type)
         end;
         ok
       | Error _ as e -> e)
  in
  let result =
    (match inferred with
     | Error msg -> failwith ("type error: " ^ msg)
     | Ok (type_env, own_type) ->
       (* Indexed here: everything a module can see that it did not define
          itself is fixed by this point, and every name the module goes on to
          look up sits in front of it. *)
       let base = index_env (stdlib_eval_env @ imported.eval_env) in
       let full_eval = fold_items run_item base prog.Ast.items in
       let n_own = List.length full_eval - List.length base in
       let own_eval = List.filteri (fun i _ -> i < n_own) full_eval
         |> List.filter (fun (n, _) -> not (is_private n)) in
       let own_type = List.filter (fun (n, _) -> not (is_private n)) own_type in
       let full_import = { tenv     = local_tenv_of prog @ imported.tenv;
                           type_env;
                           eval_env = full_eval } in
       (full_import, own_type, own_eval, prog.Ast.docs @ imp_docs))
  in
  Hashtbl.replace cache path result;
  loading := List.filter (fun p -> p <> path) !loading;
  result

(* ── Run a parsed program ─────────────────────────────────────────────────── *)

(* Wraps a program in the chosen mode. The mode handler sits inside the
   default one, so an operation it decides to allow is simply performed
   again and carried out as usual -- there is one implementation of each
   operation, and a rehearsal cannot drift from a real run by reimplementing
   them. *)
let run_in_mode mode (thunk : unit -> value) : value =
  current_mode := mode;
  match mode with
  | Normal -> run_with_default_handler thunk
  | Trace | DryRun ->
    (* A rehearsal or trace is an observer, so Par sends its workers' effects
       back here to be reported rather than letting them run on their own. *)
    Evaluator.observed (fun () ->
    run_with_default_handler (fun () ->
      Effect.Deep.match_with thunk ()
        { Effect.Deep.
            retc = (fun v -> v);
            exnc = raise;
            effc = fun (type a) (eff : a Effect.t) ->
              match eff with
              | WandEffect (name, v) ->
                Some (fun (k : (a, value) Effect.Deep.continuation) ->
                  let described = describe_operation name v in
                  let withhold = mode = DryRun && is_mutation name in
                  (match described with
                   | Some (verb, what) ->
                     if withhold then
                       (match substitute_for name with
                        | Some (_, shown) ->
                          report "would %s: %s -> %s\n" verb what shown
                        | None -> report "would %s: %s\n" verb what)
                     else report "%s: %s\n" verb what
                   | None -> ());
                  if withhold then
                    match substitute_for name with
                    | Some (v, _) -> Effect.Deep.continue k v
                    | None        -> Effect.Deep.continue k VUnit
                  else
                    (* Hand it to the default handler, which owns the real
                       behaviour. *)
                    match (try Ok (Effect.perform (WandEffect (name, v)))
                           with EvalError m -> Error m) with
                    | Ok result -> Effect.Deep.continue    k result
                    | Error m   -> Effect.Deep.discontinue k (EvalError m))
              | _ -> None
        }))

(* ── Par ─────────────────────────────────────────────────────────────────── *)

(* Fork-join, and nothing else. Workers never outlive the call, there is no
   handle to a running one, and the only way to start any is these two
   functions -- so a script cannot build unstructured concurrency out of
   them.

   Each worker installs the program's handlers on its own domain, because an
   effect performed on one domain does not reach a handler on another. A
   worker without them would escape a rehearsal, which is the one thing a
   rehearsal must not permit.

   A failure is a value: one item raising does not cancel its siblings or
   fail the call, it comes back as an Error in that item's place. *)
let () = Evaluator.with_default_handler := run_with_default_handler

let run_program ?(mode = Normal) ~base_dir prog =
  let cache = Hashtbl.create 8 in
  let loading = ref [] in
  let (imp, _) = load_imports_for ~base_dir ~cache ~loading prog in
  (match Typechecker.infer_program_env ~init_tenv:imp.tenv ~init_env:imp.type_env prog with
   | Error msg -> Error ("type error: " ^ msg)
   | Ok _ ->
     let result = run_in_mode mode (fun () ->
       let ((_, last), _) = List.fold_left (fun ((env, last), since) item ->
         let (env, last) =
           match item with
           | Ast.TLExpr e -> (env, eval env e)
           | _            -> (run_item env item, last)
         in
         (* A file's own definitions pile up in front of the base, so a fresh
            index goes in every so often: without it everything defined late
            walks past everything defined early. *)
         if since >= Evaluator.index_every then ((Evaluator.index_env env, last), 0)
         else ((env, last), since + 1)
       ) ((index_env (base_eval_env @ imp.eval_env), VUnit), 0) prog.Ast.items
       in last
     ) in
     (* A request that arrived with nothing left to evaluate would otherwise
        be dropped, and the script would report success after being asked to
        stop. Whatever it was holding has already been released by the
        unwinding above -- this is only about saying so. *)
     Evaluator.check_interrupt ();
     Ok (show_value result))

(* ── Public API ───────────────────────────────────────────────────────────── *)

let run_string src =
  try
    let tokens = Lexer.tokenize src in
    let prog   = Parser.parse_program tokens in
    run_program ~base_dir:(Sys.getcwd ()) prog
  with
  | Lexer.LexError msg    -> Error ("lex error: " ^ msg)
  | Parser.ParseError msg -> Error ("parse error: " ^ msg)
  | EvalError msg         -> Error ("eval error: " ^ msg)
  | Failure msg           -> Error (msg)

(* ── Stopping ─────────────────────────────────────────────────────────────── *)

(* A script that is stopped from outside should leave nothing behind, so a
   signal becomes an exception and unwinds like anything else -- every `with`
   on the stack releases on the way out.

   Installing a handler also un-ignores the signal: a script started as a
   background job inherits SIG_IGN for SIGINT, and would otherwise not stop
   at all. *)
let interrupting = Atomic.make false

let install_signal_handlers () =
  let stop signal code (_ : int) =
    (* Taking the request also hands the signal back to the system, so a
       second one stops the process outright, without cleanup, the way it
       would have if wand had never installed a handler.

       This is bounded by how OCaml delivers signals: a handler runs when
       the program next reaches a safe point, so neither the first request
       nor the second is seen while it sits in a syscall waiting on a slow
       command. At a terminal that does not arise -- the whole process group
       is signalled, the command dies with it, and the wait ends at once.
       Signalling wand alone, as a supervisor does, waits for the commands
       already running. *)
    if not (Atomic.exchange interrupting true) then begin
      Sys.set_signal signal Sys.Signal_default;
      Evaluator.request_interrupt code;
      (* Stop what we started. Until the commands wand is waiting on end, it
         is inside a read and cannot act on the request at all -- so the
         script's own cleanup is waiting on processes nobody is watching any
         more. Terminated rather than interrupted, because a child signalled
         alongside its parent has already had its chance to notice. *)
      stop_children Sys.sigterm
    end
  in
  (* 128 + the signal number, which is what a shell reports and what CI
     reads, so nothing downstream has to learn a wand-specific code. *)
  Sys.set_signal Sys.sigint  (Sys.Signal_handle (stop Sys.sigint  130));
  Sys.set_signal Sys.sigterm (Sys.Signal_handle (stop Sys.sigterm 143))

(* For a session that survives an interrupt. A script stops at the first
   one, so it never needs this; a prompt takes as many as it is given. *)
let rearm_signal_handlers () =
  Atomic.set interrupting false;
  Evaluator.clear_interrupt ();
  install_signal_handlers ()

let run_file ?(mode = Normal) path =
  let full =
    if Filename.is_relative path
    then Filename.concat (Sys.getcwd ()) (add_ext path)
    else add_ext path
  in
  try
    let src      = In_channel.with_open_text full In_channel.input_all in
    let tokens   = Lexer.tokenize src in
    let prog     = Parser.parse_program tokens in
    let base_dir = Filename.dirname full in
    run_program ~mode ~base_dir prog
  with
  | Sys_error msg         -> Error ("cannot open file: " ^ msg)
  | Lexer.LexError msg    -> Error ("lex error: " ^ msg)
  | Parser.ParseError msg -> Error ("parse error: " ^ msg)
  | EvalError msg         -> Error ("eval error: " ^ msg)
  | Failure msg           -> Error (msg)

(* ── `wand test` ──────────────────────────────────────────────────────────── *)

(* A test file's top-level expressions are the `stdlib/Test.wand` module's
   `Pass`/`Fail` constructors (see Test.wand's `test` function); a raised
   runtime error is reported the same way a deliberate Fail would be, just
   without a caller-chosen message. Any other top-level expression's value
   is simply not a test outcome and is ignored (still executed normally,
   e.g. ordinary setup code/side effects). Only lex/parse/type errors for
   the whole file are fatal -- each TLExpr's *evaluation* is isolated so
   one failing/raising test doesn't stop the rest of the file. *)
type test_outcome = TPass of string | TFail of string | TError of string

let run_test_program ~base_dir prog : (test_outcome list, string) result =
  let cache = Hashtbl.create 8 in
  let loading = ref [] in
  let (imp, _) = load_imports_for ~base_dir ~cache ~loading prog in
  match Typechecker.infer_program_env ~init_tenv:imp.tenv ~init_env:imp.type_env prog with
  | Error msg -> Error ("type error: " ^ msg)
  | Ok _ ->
    let outcomes = ref [] in
    ignore (run_with_default_handler (fun () ->
      ignore (List.fold_left (fun env item ->
        match item with
        | Ast.TLExpr e ->
          let result =
            try Ok (eval env e)
            with
            | EvalError msg -> Error msg
            | Failure msg   -> Error msg
          in
          (match result with
           | Ok (VConstr ("Pass", [VString label])) -> outcomes := !outcomes @ [TPass label]
           | Ok (VConstr ("Fail", [VString msg]))   -> outcomes := !outcomes @ [TFail msg]
           | Ok _    -> ()
           | Error m -> outcomes := !outcomes @ [TError m]);
          env
        | _ -> run_item env item
      ) (index_env (base_eval_env @ imp.eval_env)) prog.Ast.items);
      VUnit
    ));
    Ok !outcomes

(* A test file is one named `test_*.wand`. The prefix rather than a suffix,
   because a script's tests live beside the script: `deploy.wand` and
   `test_deploy.wand` in one directory, where the prefix sorts every test
   together and away from the things being tested. *)
let is_test_file name =
  let prefix = "test_" and ext = ".wand" in
  Filename.check_suffix name ext
  && String.length name > String.length prefix + String.length ext
  && String.sub name 0 (String.length prefix) = prefix

(* Every test file at or below `root`, in a stable order so a run's output
   is comparable to the last one. Directories a script has no business
   descending into are skipped: `_build` holds dune's copies of these very
   files, and finding each test twice under two paths is worse than useless. *)
let skipped_dir name =
  name = "_build" || name = "_opam" || name = ".git" || name = "node_modules"

(* A broken symlink answers neither question, so it is not a directory and
   not a test: stepping around it beats crashing a test run over it. *)
let is_dir path = try Sys.is_directory path with Sys_error _ -> false

let find_test_files root =
  let found = ref [] in
  let rec walk dir =
    match Sys.readdir dir with
    | exception Sys_error _ -> ()  (* unreadable: not this command's problem *)
    | entries ->
      Array.sort compare entries;
      Array.iter (fun name ->
        let path = Filename.concat dir name in
        if is_dir path then begin
          if not (skipped_dir name) then walk path
        end else if is_test_file name then found := path :: !found
      ) entries
  in
  if is_dir root then walk root
  else if Sys.file_exists root then found := [root];
  List.rev !found

let run_test_file path : (test_outcome list, string) result =
  let full =
    if Filename.is_relative path
    then Filename.concat (Sys.getcwd ()) (add_ext path)
    else add_ext path
  in
  try
    let src      = In_channel.with_open_text full In_channel.input_all in
    let tokens   = Lexer.tokenize src in
    let prog     = Parser.parse_program tokens in
    let base_dir = Filename.dirname full in
    run_test_program ~base_dir prog
  with
  | Sys_error msg         -> Error ("cannot open file: " ^ msg)
  | Lexer.LexError msg    -> Error ("lex error: " ^ msg)
  | Parser.ParseError msg -> Error ("parse error: " ^ msg)
  | EvalError msg         -> Error ("eval error: " ^ msg)
  | Failure msg           -> Error (msg)

(* ── REPL session ─────────────────────────────────────────────────────────── *)

type repl_result =
  | RBind     of string * string
  | RType     of string
  | RVal      of string * string
  | RTypeExpr of string
  | RHoles    of string list
  | RSilent

type session = {
  s_tenv      : (string * Ast.type_def) list;
  s_type_env  : Typechecker.env;
  s_eval_env  : env;
  s_cache     : (string, module_result) Hashtbl.t;
  s_base_dir  : string;
  s_last_load : string option;
  s_sources   : (string * string) list;  (* name -> source text *)
  s_docs      : (string * string) list;  (* name -> doc string *)
}

let make_session ?(base_dir = Sys.getcwd ()) () = {
  s_tenv      = [];
  s_type_env  = [];
  s_eval_env  = [];
  s_cache     = Hashtbl.create 8;
  s_base_dir  = base_dir;
  s_last_load = None;
  s_sources   = [];
  s_docs      = [];
}

let lookup_type (sess : session) (name : string) : string option =
  match String.split_on_char '.' name with
  | [ns; member] ->
    (match List.assoc_opt ns sess.s_type_env with
     | Some (Typechecker.Namespace members) ->
       (match List.assoc_opt member members with
        | Some s -> Some (Typechecker.string_of_scheme s)
        | None   -> None)
     | _ -> None)
  | [plain] ->
    (match List.assoc_opt plain sess.s_type_env with
     | Some s -> Some (Typechecker.string_of_scheme s)
     | None   -> None)
  | _ -> None

let last_non_import prog =
  List.fold_left (fun acc item ->
    match item with Ast.TLImport _ -> acc | other -> Some other
  ) None prog.Ast.items

let run_session (sess : session) (src : string) : (session * repl_result, string) result =
  try
    let tokens = Lexer.tokenize src in
    let prog   = Parser.parse_program tokens in
    let loading = ref [] in
    let (imp, imp_docs) = load_imports_for ~base_dir:sess.s_base_dir ~cache:sess.s_cache ~loading prog in
    let merged_tenv     = local_tenv_of prog @ imp.tenv @ sess.s_tenv in
    let merged_type_env = imp.type_env @ sess.s_type_env in
    match Typechecker.infer_program_full_with_own
            ~init_tenv:merged_tenv ~init_env:merged_type_env prog with
    | Error msg -> Error ("type error: " ^ msg)
    | Ok (full_type_env, own_type_env, last_t, hole_types) ->
      let dedup lst =
        let seen = Hashtbl.create 16 in
        List.filter (fun (k, _) ->
          if Hashtbl.mem seen k then false
          else (Hashtbl.add seen k (); true)) lst
      in
      if hole_types <> [] then begin
        (* Holes present — skip evaluation, report hole types *)
        let new_sources =
          List.filter_map (function
            | Ast.TLLet (name, _, _) -> Some (name, src)
            | _ -> None) prog.Ast.items
        in
        let new_sess = { sess with
          s_tenv     = dedup (local_tenv_of prog @ imp.tenv @ sess.s_tenv);
          s_type_env = dedup (own_type_env @ imp.type_env @ sess.s_type_env);
          s_sources  = new_sources @ sess.s_sources;
          s_docs     = prog.Ast.docs @ imp_docs @ sess.s_docs;
        } in
        let hole_strs = List.map Typechecker.string_of_typ hole_types in
        Ok (new_sess, RHoles hole_strs)
      end else begin
        let base_eval = index_env (base_eval_env @ imp.eval_env @ sess.s_eval_env) in
        let env_ref  = ref base_eval in
        let last_ref = ref VUnit in
        ignore (run_with_default_handler (fun () ->
          List.iter (fun item ->
            match item with
            | Ast.TLLet (_, [], body) when Option.is_some (import_kind_of body) -> ()  (* pre-loaded *)
            | Ast.TLLet (name, [], body) ->
              env_ref := (name, eval !env_ref body) :: !env_ref
            | Ast.TLLet (name, params, body) ->
              let arity = List.length params in
              let v = match List.assoc_opt name !env_ref with
                | Some (VFix (_, _, ep, eb)) when List.length ep = arity ->
                  merge_clause !env_ref name arity params body ep eb
                | _ -> VFix (name, !env_ref, params, body)
              in
              env_ref := (name, v) :: !env_ref
            | Ast.TLLetRec bindings ->
              List.iter (fun (name, _, _) ->
                env_ref := (name, VFixGroup (bindings, !env_ref, name)) :: !env_ref
              ) bindings
            | Ast.TLLetPat (_, body) when Option.is_some (import_kind_of body) -> ()  (* pre-loaded *)
            | Ast.TLLetPat (pat, e) ->
              env_ref := Evaluator.bind_pat ~prefix:true pat (eval !env_ref e) !env_ref
            | Ast.TLType (Ast.Variants (_, _, ctors)) ->
              List.iter (fun ctor ->
                Hashtbl.replace constr_fields ctor.Ast.name (List.map fst ctor.Ast.fields);
                env_ref := (ctor.Ast.name,
                  match ctor.Ast.fields with
                  | [] -> VConstr (ctor.Ast.name, [])
                  | _  -> VPartialConstr (ctor.Ast.name, List.length ctor.Ast.fields, [])
                ) :: !env_ref
              ) ctors
            | Ast.TLExpr e ->
              last_ref := eval !env_ref e
            | Ast.TLImport _ -> ()
          ) prog.Ast.items;
          VUnit));
        let new_eval_env = !env_ref in
        let last_v       = !last_ref in
        let n_own = List.length new_eval_env - List.length base_eval in
        let own_eval_env = List.filteri (fun i _ -> i < n_own) new_eval_env in
        let new_sources =
          List.filter_map (function
            | Ast.TLLet (name, _, _) -> Some (name, src)
            | _ -> None) prog.Ast.items
        in
        (* Keep only namespace entries from imports — raw primitives come from
           the typechecker/evaluator base and don't belong in the session. *)
        let new_sess = { sess with
          s_tenv     = dedup (local_tenv_of prog @ imp.tenv @ sess.s_tenv);
          s_type_env = dedup (own_type_env @ imp.type_env @ sess.s_type_env);
          s_eval_env = dedup (own_eval_env @ imp.eval_env @ sess.s_eval_env);
          s_sources  = new_sources @ sess.s_sources;
          s_docs     = prog.Ast.docs @ imp_docs @ sess.s_docs;
        } in
        (* The REPL edits definitions; files declare them. A new clause for an
           existing function merges into it here (merge_clause above), which
           is only safe to do silently if the result is visible -- so report
           how many equations the function now has. *)
        let equation_count name =
          match List.assoc_opt name new_eval_env with
          | Some (VFix (_, _, params, body)) ->
            let arity = List.length params in
            let synthetic = List.mapi (fun i p -> match p with
              | Ast.PVar v -> v = Printf.sprintf "_p%d" i
              | _ -> false) params
            in
            if arity > 0 && List.for_all (fun b -> b) synthetic then
              (match strip_located body with
               | Ast.Match (_, cases) when List.length cases > 1 -> Some (List.length cases)
               | _ -> None)
            else None
          | _ -> None
        in
        let display = match last_non_import prog with
          | None -> RSilent
          | Some (Ast.TLLet (name, _, _)) ->
            let ty = match List.assoc_opt name full_type_env with
              | Some s -> Typechecker.string_of_scheme s
              | None   -> "?"
            in
            (match equation_count name with
             | Some n -> RBind (name, Printf.sprintf "%s, %d equations" ty n)
             | None   -> RBind (name, ty))
          | Some (Ast.TLLetPat _) -> RSilent
          | Some (Ast.TLType (Ast.Variants (name, _, _))) -> RType name
          | Some (Ast.TLExpr _) ->
            (match last_v with
             | VUnit -> RSilent
             | v     -> RVal (show_value v, Typechecker.string_of_typ last_t))
          | Some _ -> RSilent
        in
        Ok (new_sess, display)
      end
  with
  | Lexer.LexError msg    -> Error ("lex error: " ^ msg)
  | Parser.ParseError msg -> Error ("parse error: " ^ msg)
  | EvalError msg         -> Error ("runtime error: " ^ msg)
  | Failure msg           -> Error msg

(* Typecheck a file without running it, resolving its imports the same way
   running it would. The editing loop and CI both want an answer that costs
   nothing and changes nothing. *)
(* Whether a path names one of the standard library's own modules. The
   library is embedded, so the only files this can be true of are the
   sources it was built from -- `wand t stdlib/List.wand` in the tree, or a
   directory `WAND_STDLIB` points at. Asked of the directory the file is
   actually in, so a user file called FS.wand is a user file. *)
let is_stdlib_file full =
  let dir = Filename.dirname full in
  Module_types.is_stdlib_dir dir
  && List.mem_assoc
       (Filename.remove_extension (Filename.basename full))
       Stdlib_embed.table

let typecheck_file path : (string * string list * Lint.finding list, string) result =
  let full =
    if Filename.is_relative path
    then Filename.concat (Sys.getcwd ()) (add_ext path)
    else add_ext path
  in
  try
    let src      = In_channel.with_open_text full In_channel.input_all in
    let tokens   = Lexer.tokenize src in
    let (prog, item_locs) = Parser.parse_program_with_locs tokens in
    let base_dir = Filename.dirname full in
    let cache = Hashtbl.create 8 in
    let loading = ref [] in
    let (imp, _) = load_imports_for ~base_dir ~cache ~loading prog in
    (* A file in the stdlib is checked as what it is: a module, whose body
       calls the raw builtins the modules are built from. Checked as a
       script it fails on the first one, so nothing here could be checked
       at all -- and a module that goes wrong would be found only when
       something imported it. The rule is the file's home rather than an
       option, because an option meant for the people writing the standard
       library is one more thing in everyone else's way. *)
    let base_env =
      if is_stdlib_file full then Typechecker.stdlib_type_env
      else Typechecker.builtin_type_env
    in
    match Typechecker.infer_program_full_with_own ~base_env
            ~init_tenv:imp.tenv ~init_env:imp.type_env prog with
    | Error msg -> Error ("type error: " ^ msg)
    | Ok (_, own_type_env, last_t, holes) ->
      Ok (Typechecker.string_of_typ last_t,
          List.map Typechecker.string_of_typ holes,
          Lint.check prog item_locs own_type_env)
  with
  | Sys_error msg         -> Error ("cannot open file: " ^ msg)
  | Lexer.LexError msg    -> Error ("lex error: " ^ msg)
  | Parser.ParseError msg -> Error ("parse error: " ^ msg)
  | Typechecker.TypeError msg -> Error ("type error: " ^ msg)
  | Failure msg           -> Error msg

(* Lint a stdlib module's own source. Module bodies are inferred against the
   raw builtins rather than the user-visible globals, so they need the same
   base environment module loading uses -- without it, `toml_parse` and its
   kind read as unbound. *)
let lint_module_source (src : string) : (Lint.finding list, string) result =
  try
    let tokens = Lexer.tokenize src in
    let (prog, item_locs) = Parser.parse_program_with_locs tokens in
    let cache = Hashtbl.create 8 in
    let loading = ref [] in
    let base_dir = Module_types.stdlib_base_dir in
    let (imp, _) = load_imports_for ~base_dir ~cache ~loading prog in
    match Typechecker.infer_program_env_with_own
            ~init_tenv:(local_tenv_of prog @ imp.tenv)
            ~init_env:imp.type_env prog with
    | Error msg -> Error ("type error: " ^ msg)
    | Ok (_, own_type_env) -> Ok (Lint.check prog item_locs own_type_env)
  with
  | Lexer.LexError msg    -> Error ("lex error: " ^ msg)
  | Parser.ParseError msg -> Error ("parse error: " ^ msg)
  | Typechecker.TypeError msg -> Error ("type error: " ^ msg)
  | Failure msg           -> Error msg

(* Lints share the typecheck's parse and inference rather than repeating
   them: they are reported by `wand t`, so they must cost it almost nothing. *)
let lint_session (sess : session) (src : string) : (Lint.finding list, string) result =
  try
    let tokens = Lexer.tokenize src in
    let (prog, item_locs) = Parser.parse_program_with_locs tokens in
    let loading = ref [] in
    let (imp, _) = load_imports_for ~base_dir:sess.s_base_dir ~cache:sess.s_cache ~loading prog in
    let merged_tenv     = local_tenv_of prog @ imp.tenv @ sess.s_tenv in
    let merged_type_env = imp.type_env @ sess.s_type_env in
    match Typechecker.infer_program_full_with_own
            ~init_tenv:merged_tenv ~init_env:merged_type_env prog with
    | Error msg -> Error ("type error: " ^ msg)
    | Ok (_, own_type_env, _, _) -> Ok (Lint.check prog item_locs own_type_env)
  with
  | Lexer.LexError msg    -> Error ("lex error: " ^ msg)
  | Parser.ParseError msg -> Error ("parse error: " ^ msg)
  | Typechecker.TypeError msg -> Error ("type error: " ^ msg)
  | Failure msg           -> Error msg

let typecheck_session (sess : session) (src : string) : (repl_result, string) result =
  try
    let tokens = Lexer.tokenize src in
    let prog   = Parser.parse_program tokens in
    let loading = ref [] in
    let (imp, _) = load_imports_for ~base_dir:sess.s_base_dir ~cache:sess.s_cache ~loading prog in
    let merged_tenv     = local_tenv_of prog @ imp.tenv @ sess.s_tenv in
    let merged_type_env = imp.type_env @ sess.s_type_env in
    match Typechecker.infer_program_full_with_own
            ~init_tenv:merged_tenv ~init_env:merged_type_env prog with
    | Error msg -> Error ("type error: " ^ msg)
    | Ok (full_type_env, _, last_t, hole_types) ->
      if hole_types <> [] then
        Ok (RHoles (List.map Typechecker.string_of_typ hole_types))
      else
        let display = match last_non_import prog with
          | None -> RSilent
          | Some (Ast.TLLet (name, _, _)) ->
            (match List.assoc_opt name full_type_env with
             | Some s -> RBind (name, Typechecker.string_of_scheme s)
             | None   -> RBind (name, "?"))
          | Some (Ast.TLType (Ast.Variants (name, _, _))) -> RType name
          | Some (Ast.TLExpr _) -> RTypeExpr (Typechecker.string_of_typ last_t)
          | Some _ -> RSilent
        in
        Ok display
  with
  | Lexer.LexError msg    -> Error ("lex error: " ^ msg)
  | Parser.ParseError msg -> Error ("parse error: " ^ msg)
  | Failure msg           -> Error msg
