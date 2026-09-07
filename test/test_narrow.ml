(* The narrowing mechanism a manifest label uses to bound what it admits.
   `Shell(git, curl)` bounds which binaries run; a host list will bound
   where bytes go. What differs between them is the separator a pattern may
   not cross and whether an entry matches a trailing component, so those are
   what these tests are about. *)

open Wand

(* `*` matches any run of characters that holds no separator. The separator
   is what keeps the claim narrow: a pattern says "one level below this",
   not "anything under this". *)

let admits rule entry word = Narrow.admits ~rule entry word

let test_a_pattern_does_not_cross_the_separator () =
  let b = Narrow.binary in
  Alcotest.(check bool) "docker-* admits docker-compose" true
    (admits b "docker-*" "docker-compose");
  Alcotest.(check bool) "docker-* refuses docker" false
    (admits b "docker-*" "docker");
  Alcotest.(check bool) "./scripts/* admits ./scripts/probe.sh" true
    (admits b "./scripts/*" "./scripts/probe.sh");
  Alcotest.(check bool) "./scripts/* refuses a deeper path" false
    (admits b "./scripts/*" "./scripts/a/b.sh")

(* A host separates on `.` rather than `/`, and does not match a trailing
   component -- `example.com` is not `api.example.com`, and reading it as one
   would widen the claim without saying so. *)
let test_a_host_pattern_follows_the_certificate_rule () =
  let h = Narrow.host in
  Alcotest.(check bool) "*.example.com admits api.example.com" true
    (admits h "*.example.com" "api.example.com");
  Alcotest.(check bool) "*.example.com refuses a deeper host" false
    (admits h "*.example.com" "a.b.example.com");
  Alcotest.(check bool) "*.example.com refuses the bare host" false
    (admits h "*.example.com" "example.com");
  Alcotest.(check bool) "example.com refuses a subdomain" false
    (admits h "example.com" "api.example.com")

(* The rule a binary has and a host does not: an entry naming no path
   matches the word's final component, so a manifest need not know where on
   PATH something was found. *)
let test_a_binary_entry_matches_the_final_component () =
  let b = Narrow.binary and h = Narrow.host in
  Alcotest.(check bool) "git admits /usr/bin/git" true
    (admits b "git" "/usr/bin/git");
  Alcotest.(check bool) "docker-* admits /usr/local/bin/docker-compose" true
    (admits b "docker-*" "/usr/local/bin/docker-compose");
  Alcotest.(check bool) "/opt/bin/deploy refuses a bare deploy" false
    (admits b "/opt/bin/deploy" "deploy");
  Alcotest.(check bool) "a host has no such rule" false
    (admits h "com" "example.com")

let () =
  Alcotest.run "narrowing" [
    "a pattern", [
      Alcotest.test_case "does not cross the separator" `Quick
        test_a_pattern_does_not_cross_the_separator;
      Alcotest.test_case "a host follows the certificate rule" `Quick
        test_a_host_pattern_follows_the_certificate_rule;
      Alcotest.test_case "a binary matches the final component" `Quick
        test_a_binary_entry_matches_the_final_component;
    ];
  ]
