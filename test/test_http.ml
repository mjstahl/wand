(* What a manifest admits is a property of a file, not of a call, so these
   run whole files through the real binary. The double tests -- which need
   no manifest, because a sealed file reaches nothing -- are in
   `test/wand/test_http.wand`. *)

let wand_binary =
  let dir = Filename.dirname (Filename.dirname Sys.executable_name) in
  Filename.concat (Filename.concat dir "bin") "wand.exe"

let contains haystack needle =
  let hn = String.length haystack and nn = String.length needle in
  let rec go i = i + nn <= hn && (String.sub haystack i nn = needle || go (i + 1)) in
  go 0

let run_source src =
  let path = Filename.temp_file "wand_http_" ".wand" in
  let oc = open_out path in
  output_string oc src; close_out oc;
  let cmd =
    String.concat " " (List.map Filename.quote [wand_binary; path]) ^ " 2>&1"
  in
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  ignore (Unix.close_process_in ic);
  (try Sys.remove path with Sys_error _ -> ());
  out

(* Nothing here reaches a host: a request that the manifest refuses is
   refused before anything is sent, and one it admits is never sent because
   these files stop at building it. *)
let building url manifest =
  Printf.sprintf
    {|uses {IO, %s}
import IO
let r = HTTPRequest(url = %s)
let () = IO.println r.url|} manifest url

let refuses label ~manifest ~url ~host =
  let out = run_source (building url manifest) in
  if not (contains out "does not allow") then
    Alcotest.failf "%s: expected a refusal, got: %s" label out;
  if not (contains out host) then
    Alcotest.failf "%s: the message does not name the host: %s" label out

let admits label ~manifest ~url =
  let out = run_source (building url manifest) in
  if contains out "does not allow" then
    Alcotest.failf "%s: expected it to be admitted, got: %s" label out

(* The host as written is what the manifest allows. *)
let test_a_named_host_is_admitted () =
  admits "the named host" ~manifest:"Net(api.example.com)"
    ~url:"https://api.example.com/x"

let test_an_unnamed_host_is_refused () =
  refuses "an unnamed host" ~manifest:"Net(api.example.com)"
    ~url:"https://evil.test/x" ~host:"evil.test"

(* A pattern covers one label below the domain and not the domain itself,
   which is what a TLS certificate does with the same spelling. *)
let test_a_pattern_covers_one_level () =
  admits "one level below" ~manifest:"Net(*.example.com)"
    ~url:"https://api.example.com/x";
  refuses "two levels below" ~manifest:"Net(*.example.com)"
    ~url:"https://a.b.example.com/x" ~host:"a.b.example.com";
  refuses "the bare domain" ~manifest:"Net(*.example.com)"
    ~url:"https://example.com/x" ~host:"example.com"

(* Bare `Net` admits any host, which is the same reading a bare `Shell`
   gives. *)
let test_bare_net_admits_anything () =
  admits "bare Net" ~manifest:"Net" ~url:"https://anywhere.test/x"

(* A port is not part of the host, and neither are credentials. *)
let test_a_port_is_not_part_of_the_host () =
  admits "a port" ~manifest:"Net(api.example.com)"
    ~url:"https://api.example.com:8443/x"

(* An update may name a different host, so it is checked like a
   construction. *)
let test_an_update_is_checked () =
  let out = run_source
    {|uses {IO, Net(api.example.com)}
import IO
let base = HTTPRequest(url = https://api.example.com/x)
let r = HTTPRequest(base, url = https://evil.test/y)
let () = IO.println r.url|}
  in
  if not (contains out "does not allow") then
    Alcotest.failf "an update to an unnamed host was admitted: %s" out

(* `HTTP.get` builds its request inside the standard library, so the bound
   cannot come from the construction. It comes from the URL, which is the
   part the caller wrote -- without that, the manifest bounded nothing on
   the module's commonest path. *)
let test_the_convenience_functions_are_bounded () =
  let out = run_source
    {|uses {IO, Net(api.example.com)}
import HTTP
import IO
let r = HTTP.get! https://evil.test/x
let () = IO.println r.body|}
  in
  if not (contains out "does not allow") then
    Alcotest.failf "HTTP.get reached an unnamed host: %s" out;
  if not (contains out "evil.test") then
    Alcotest.failf "the message does not name the host: %s" out

(* A rehearsal follows the filesystem rule, and the protocol already draws
   the line: GET and HEAD are defined not to change anything. *)
let rehearse src =
  let path = Filename.temp_file "wand_http_dry_" ".wand" in
  let oc = open_out path in
  output_string oc src; close_out oc;
  let cmd =
    String.concat " " (List.map Filename.quote [wand_binary; "--dry-run"; path])
    ^ " 2>&1"
  in
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  ignore (Unix.close_process_in ic);
  (try Sys.remove path with Sys_error _ -> ());
  out

let test_a_rehearsal_withholds_an_unsafe_method () =
  let out = rehearse
    {|uses {IO, Net(api.example.com)}
import HTTP
import IO
let r = HTTP.post! https://api.example.com/deploy "{}"
let () = IO.println r.status|}
  in
  if not (contains out "would post") then
    Alcotest.failf "the rehearsal did not withhold the post:\n%s" out;
  (* Withheld, so it answers rather than reaching anything: 202 is what a
     server that took it and said nothing would say. *)
  if not (contains out "202") then
    Alcotest.failf "the rehearsal did not answer the withheld request:\n%s" out

let () =
  Alcotest.run "HTTP" [
    "what a manifest admits", [
      Alcotest.test_case "a named host" `Slow test_a_named_host_is_admitted;
      Alcotest.test_case "an unnamed host is refused" `Slow
        test_an_unnamed_host_is_refused;
      Alcotest.test_case "a pattern covers one level" `Slow
        test_a_pattern_covers_one_level;
      Alcotest.test_case "bare Net admits anything" `Slow
        test_bare_net_admits_anything;
      Alcotest.test_case "a port is not part of the host" `Slow
        test_a_port_is_not_part_of_the_host;
      Alcotest.test_case "an update is checked" `Slow test_an_update_is_checked;
      Alcotest.test_case "the convenience functions are bounded" `Slow
        test_the_convenience_functions_are_bounded;
    ];
    "a rehearsal", [
      Alcotest.test_case "withholds an unsafe method" `Slow
        test_a_rehearsal_withholds_an_unsafe_method;
    ];
  ]
