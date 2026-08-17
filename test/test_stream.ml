open Wand
open Evaluator

(* The one claim no wand-level test can check: that `take` stops the
   pulling. Under open-granularity effects a mock hands its lines over
   wholesale and cannot count pulls, so the proof lives below the effect
   boundary -- an injected puller that counts, over a source that never
   ends. If early exit breaks, this test does not fail; it hangs. *)

let test_take_stops_pulling () =
  let pulls = ref 0 in
  let puller () = incr pulls; Some (VInt !pulls) in
  let even = VBuiltin (function
    | VInt n -> VBool (n mod 2 = 0)
    | _ -> VBool false) in
  let desc = { s_source = SPull puller;
               s_stages = [StFilter even; StTake 3] } in
  let seen = ref [] in
  run_stream_terminal desc ~on_item:(fun v -> seen := v :: !seen);
  Alcotest.(check int) "three delivered" 3 (List.length !seen);
  (* The evens among 1..6 are exactly three, so an early-exiting loop
     pulls six times from the infinite source and not once more. *)
  Alcotest.(check int) "six pulled" 6 !pulls

let test_bare_take_pulls_exactly () =
  let pulls = ref 0 in
  let puller () = incr pulls; Some (VInt !pulls) in
  let desc = { s_source = SPull puller; s_stages = [StTake 4] } in
  let seen = ref 0 in
  run_stream_terminal desc ~on_item:(fun _ -> incr seen);
  Alcotest.(check int) "four delivered" 4 !seen;
  Alcotest.(check int) "four pulled" 4 !pulls

let test_release_on_raise () =
  (* A closure raising mid-stream must not leave the loop running. *)
  let pulls = ref 0 in
  let puller () = incr pulls; Some (VInt !pulls) in
  let boom = VBuiltin (fun v ->
    if !pulls >= 3 then raise (EvalError "boom") else v) in
  let desc = { s_source = SPull puller; s_stages = [StMap boom] } in
  (match run_stream_terminal desc ~on_item:(fun _ -> ()) with
   | () -> Alcotest.fail "expected the raise to escape"
   | exception EvalError m -> Alcotest.(check string) "the raise" "boom" m);
  Alcotest.(check int) "stopped at the raise" 3 !pulls

let () =
  Alcotest.run "stream runtime" [
    "early exit", [
      Alcotest.test_case "take through a filter" `Quick test_take_stops_pulling;
      Alcotest.test_case "bare take"             `Quick test_bare_take_pulls_exactly;
    ];
    "unwinding", [
      Alcotest.test_case "raise mid-stream" `Quick test_release_on_raise;
    ];
  ]
