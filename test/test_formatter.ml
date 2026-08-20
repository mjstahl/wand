open Wand

let fmt s = Formatter.format_source s

(* ── Idempotency ──────────────────────────────────────────────────────────── *)

let assert_idempotent label src =
  let once = fmt src in
  let twice = fmt once in
  Alcotest.(check string) label once twice

let test_idempotent_stdlib () =
  let dir = "../stdlib" in
  if not (Sys.file_exists dir) then
    Alcotest.failf "stdlib not found at %s (relative to test sandbox)" dir
  else
    Array.iter (fun name ->
      if Filename.check_suffix name ".wand" then
        let path = Filename.concat dir name in
        let src = In_channel.with_open_text path In_channel.input_all in
        assert_idempotent name src
    ) (Sys.readdir dir)

let test_idempotent_snippets () =
  assert_idempotent "let binding" "let x = 1\nx + 1";
  assert_idempotent "if/else" "let f x = if x > 0 then \"pos\" else \"neg\"";
  assert_idempotent "match" "let f x = match x with\n| 0 -> \"zero\"\n| _ -> \"other\"";
  assert_idempotent "semicolon sequence" "let f x = (x + 1; x * 2)\nf 1";
  assert_idempotent "semicolon sequence wrapped"
    "let long_named_function x = (String.append x \"a considerable suffix string\"; String.append x \"another considerable suffix\"; x)\nlong_named_function \"y\""

(* ── Behavior preservation ───────────────────────────────────────────────── *)

let ok_after_format label src expected =
  let formatted = fmt src in
  match Runner.run_string formatted with
  | Ok v -> Alcotest.(check string) label expected v
  | Error msg -> Alcotest.failf "%s: formatted code failed to run: %s\nformatted:\n%s" label msg formatted

(* A string the source wrote with escaped quotes moves between backticks,
   where a quote is a quote -- unless the raw form could not reproduce it:
   a backtick in the text, a literal `%{`, or control characters whose
   spelled-out escapes are the more legible form. *)
let fmt_eq label src expected =
  Alcotest.(check string) label (expected ^ "\n") (fmt src)

let test_escaped_quotes_prefer_backticks () =
  fmt_eq "plain string converts"
    {|let a = "say \"hi\""|} "let a = `say \"hi\"`";
  fmt_eq "interpolation converts, splice intact"
    {|let n = "ada"
let g = "greet \"%{n}\""|} "let n = \"ada\"\nlet g = `greet \"%{n}\"`";
  fmt_eq "a backtick in the text keeps the quoted form"
    {|let e = "tick ` quote \""|} {|let e = "tick ` quote \""|};
  fmt_eq "a newline keeps the quoted form"
    {|let d = "quote \" break \n"|} {|let d = "quote \" break \n"|};
  fmt_eq "a literal percent-brace keeps the quoted form"
    {|let f = "hold \%{x} quote \""|} {|let f = "hold \%{x} quote \""|};
  assert_idempotent "backtick preference is a fixed point"
    {|let a = "say \"hi\""
let g = "greet \"%{a}\""|};
  ok_after_format "the converted value is unchanged"
    {|let a = "say \"hi\""
a|}
    {|say "hi"|}

(* Braces are the only map syntax; a pattern puns where the key names its
   variable, and neither form is disturbed by a reformat. *)
let test_maps_canonicalize_to_braces () =
  fmt_eq "a punnable pattern comes back punned"
    "let f {a = a, b = c} = a\n1" "let f {a, b = c} = a\n1";
  fmt_eq "Map.empty is left as written"
    "import Map\nlet e = Map.empty\ne" "import Map\nlet e = Map.empty\ne";
  assert_idempotent "brace maps are a fixed point"
    "let m = {x = 1}\nlet {x} = m\nx"

(* A single constructor that is the type saying its own name again prints
   as the shorthand the parser already reads: `type Foo(fields)`. *)
let test_single_ctor_shorthand () =
  fmt_eq "long form converts"
    "type Container = Container(name: String, ready: Bool)\n1"
    "type Container(name: String, ready: Bool)\n1";
  fmt_eq "shorthand stays"
    "type Pod(name: String)\n1"
    "type Pod(name: String)\n1";
  fmt_eq "a differently named constructor keeps the long form"
    "type Opt = Wrapped(v: Int)\n1"
    "type Opt = Wrapped(v: Int)\n1";
  fmt_eq "a positional payload keeps the long form"
    "type Point = Point Int Int\n1"
    "type Point = Point Int Int\n1";
  assert_idempotent "shorthand with a type parameter"
    "type Box 'a = Box(item: 'a)\n1";
  assert_idempotent "shorthand too wide for one line"
    "type Wide = Wide(alpha: String, beta: String, gamma: String, delta: String, epsilon: String, zeta: String)\n1";
  ok_after_format "construction and matching still run through the shorthand"
    "type Pair = Pair(a: Int, b: Int)\nlet p = Pair(a = 1, b = 2)\nmatch p with\n| Pair(a = x, b = y) -> x + y"
    "3"

let test_behavior_preserved () =
  ok_after_format "arithmetic" "1 + 2 * 3" "7";
  ok_after_format "multi-equation function"
    "let fact 0 = 1\nlet fact n = n * fact (n - 1)\nfact 5"
    "120";
  ok_after_format "nested app needs parens"
    "let add a b = a + b\nlet f g x = g (add x 1) 2\nf add 3"
    "6";
  ok_after_format "semicolon sequence values the last statement"
    "let f x = (x + 1; x * 2)\nf 3"
    "6";
  ok_after_format "match with guard"
    {|let f x = match x with
| n when n < 0 -> "neg"
| 0 -> "zero"
| _ -> "pos"
f (-5)|}
    "neg";
  ok_after_format "tuple destructure"
    "let (a, b) = (1, 2)\na + b"
    "3";
  ok_after_format "cons pattern"
    "let f [h : t] = h\nf [1, 2, 3]"
    "1";
  (* A match nested (unparenthesized in source) inside an outer match's
     case body: match cases only terminate at a non-`|` token, so an
     unparenthesized nested match here would swallow the outer match's
     remaining `| ...` cases into itself, changing the program's meaning. *)
  ok_after_format "match nested in match case body"
    {|let f x =
  match x with
  | Ok xs ->
    (match xs with
     | 1 -> "one"
     | _ -> "many")
  | Error _ -> "err"
f (Ok 1)|}
    "one";
  (* A recursive shorthand `let` (`let f n = ... f ... in ...`) is only
     recursive because of its exact surface syntax (see typechecker.ml's
     `Let (PVar name, Fn _, _)` special case) -- reformatting it as
     `let f = fn n -> ...` would drop that and break recursion. This is a
     regression guard for exactly that bug. *)
  ok_after_format "recursive local let stays recursive after formatting"
    "let f = fn t -> let fact n = if n <= 0 then 1 else n * fact (n - 1) in fact t\nf 5"
    "120";
  (* Local multi-equation clauses can repeat `let` (matching top-level
     syntax, parser.ml's `parse_fn_binding`) -- both clauses only give the
     right answer (120, via real 0/n dispatch) if genuinely merged into one
     recursive function; if the second `let fact` instead shadowed the first
     as a fresh nested binding, this would stack-overflow (no base case). *)
  ok_after_format "local multi-equation with repeated let stays merged after formatting"
    "let f = fn t -> let fact 0 = 1\nlet fact n = n * fact (n - 1)\nin fact t\nf 5"
    "120";
  (* `let x : T = e` reformatted via inline `e : T` syntax re-parses as
     "cons e onto T" (the parser's infix `:` in expression position always
     means cons, never ascription) rather than an annotated binding --
     `List Int` used as a bare expression additionally requires an import
     it never needed as a type, so this failed outright, not just silently. *)
  ok_after_format "value annotation survives formatting"
    "import List\nlet empty : List Int = []\nList.length empty"
    "0";
  (* Same ambiguity, at a function's return-type annotation
     (`let f x : T = body`) rather than a plain value binding. *)
  ok_after_format "function return-type annotation survives formatting"
    "let double x : Int = x * 2\ndouble 3"
    "6";
  (* A `match` nested inside another match's case is unambiguous only because
     it's parenthesized -- but the danger isn't limited to the case body being
     *directly* a Match: a `let ... in <tail match>` inside an case has the
     same "bare match at the end" shape once printed, since emit_let's
     fallback renders its tail completely unguarded. *)
  ok_after_format "match nested in a let's tail, inside another match's case"
    {|let f x =
  match x with
  | Ok xs ->
    let n = xs
    in (match n with
      | 1 -> "one"
      | _ -> "many")
  | Error _ -> "err"
f (Ok 1)|}
    "one";
  (* A constructor pattern used as a function parameter (`let f (Some n) = ..`)
     needs its parens kept -- printed bare, `Some n` reads as two separate
     parameters instead of one destructured one. *)
  ok_after_format "constructor pattern as a function parameter"
    "type Opt = None | Some Int\nlet f None = 0\nlet f (Some n) = n\nf (Some 42)"
    "42"

(* `Ok 42.0` reformatting to `Ok 42` runs fine and *displays* the same (both
   show as "42"), so a `ok_after_format`-style behavior check can't catch it --
   only re-typechecking the formatted source tells Float and Int apart. *)
let type_after_format label src expected =
  let formatted = fmt src in
  let ty =
    Lexer.tokenize formatted
    |> Parser.parse_expr
    |> Typechecker.infer_expr
    |> Result.map Typechecker.string_of_typ
  in
  match ty with
  | Ok t    -> Alcotest.(check string) label expected t
  | Error e -> Alcotest.failf "%s: formatted code failed to typecheck: %s\nformatted:\n%s" label e formatted

let test_float_literal_type_preserved () =
  type_after_format "integral float keeps its type" "42.0" "Float";
  type_after_format "integral float in a constructor" "Ok 42.0" "Result 'a Float";
  type_after_format "non-integral float unaffected" "3.14" "Float"

(* A bare constructor takes the next atom as its payload, so `f None x`
   means `f (None x)`. Parentheses around a constructor that is not the last
   argument are load-bearing, and dropping them changes what the program
   means -- which a formatter may never do. The final position is safe and
   stays bare, so formatted code does not fill up with parentheses. *)
let test_constructor_argument_keeps_its_parens () =
  (* Behaviour, not text: formatted, this still returns the first argument
     rather than applying the constructor to the second. *)
  ok_after_format "constructor before another argument"
    "type Opt = None | Some Int\nlet f a b = b\nf (None) 7"
    "7";
  ok_after_format "constructor as the last argument"
    "type Opt = None | Some Int\nlet f a b = a\nf 7 None"
    "7";
  (* And the parens appear only where they carry weight. *)
  Alcotest.(check string) "last argument stays bare"
    "let f a b = a\nlet x = f 1 None\n"
    (fmt "let f a b = a\nlet x = f 1 None");
  Alcotest.(check string) "earlier argument keeps its parens"
    "let f a b = b\nlet x = f (None) 1\n"
    (fmt "let f a b = b\nlet x = f (None) 1")

(* `else ()` is the empty branch written out, and the one-armed form is the
   same expression. The formatter prints the shorter one either way. *)
let test_one_armed_if () =
  Alcotest.(check string) "an explicit empty else is dropped"
    "let f c = if c then g ()\n"
    (fmt "let f c = if c then g () else ()");
  Alcotest.(check string) "and one already written that way is left alone"
    "let f c = if c then g ()\n"
    (fmt "let f c = if c then g ()");
  Alcotest.(check string) "a branch that is not empty keeps its else"
    "let f c = if c then 1 else 2\n"
    (fmt "let f c = if c then 1 else 2")

(* A `Map` is keyed by arbitrary strings, and the parser takes a key quoted
   when it is not an identifier. Printing one bare produced source that does
   not lex -- so every map with a real-world key was destroyed by running the
   formatter over it, which is why none existed to notice. *)
let test_map_keys_that_are_not_identifiers () =
  Alcotest.(check string) "a key that needs quoting keeps them"
    "let m = {\"content-type\" = 1, \"@type\" = 2, name = 3}\n"
    (fmt "let m = {\"content-type\" = 1, \"@type\" = 2, name = 3}");
  Alcotest.(check string) "an identifier key written quoted comes back bare"
    "let m = {name = 1}\n"
    (fmt "let m = {\"name\" = 1}");
  ok_after_format "and a pattern with one still matches"
    "let f x = match x with\n| {\"a-b\" = v} -> v\n| _ -> 0\nf {\"a-b\" = 7}"
    "7"

(* Width is measured from the column the text starts at, which is not the
   indent it wraps to: a case body is written after `| Some x -> ` and so
   begins some way right of the case's own indent. Measuring from the indent
   said everything fitted, and left lines half again over the margin. *)
let longest_line s =
  String.split_on_char '\n' s
  |> List.fold_left (fun acc l -> max acc (String.length l)) 0

let check_wraps label src =
  let out = fmt src in
  if longest_line out > 92 then
    Alcotest.failf "%s: %d columns, should have wrapped:\n%s" label (longest_line out) out

let test_width_is_measured_from_the_start_column () =
  check_wraps "a case body after a wide pattern"
    "let f x =\n  match x with\n  | Some averylongconstructorpattern ->      let y = someprettylongfunction averylongconstructorpattern in y\n  | None -> 0";
  check_wraps "a lambda body inside a constructor field"
    "let t label =\n  Testing(\n    ok = fn cond -> if cond then Pass label else Fail      \"%{label}: the assertion did not hold at all\"\n  )";
  (* And what it decides still runs the same. *)
  ok_after_format "wrapping a case body preserves it"
    "type Opt = None | Some Int\nlet plus n = n + 1\nlet f x =\n  match x with\n     | Some averylongconstructorpattern -> let y = plus averylongconstructorpattern in y\n     | None -> 0\nf (Some 41)"
    "42"

(* An `if` or `match` that starts mid-line -- after `x = ` or `fn a -> ` --
   owns none of the text to its left, so when it breaks, its `else` and its
   cases step in rather than landing flush with the line that introduced
   them. An else-if chain is one ladder: the clauses all land at that same
   depth, instead of each else stepping past the one before it. *)
let test_midline_breaks_step_in () =
  fmt_eq "a mid-line else and mid-line cases step in"
    "type TestOutcome = Pass String | Fail String\nlet make label = Testing(not_ok = fn cond -> if cond then Fail \"%{label}: expected the assertion to fail here\" else Pass label, raises = fn thunk -> match try thunk () with | Ok _ -> Fail \"%{label}: expected a raise, but it completed normally\" | Error _ -> Pass label)"
    "type TestOutcome = Pass String | Fail String\nlet make label =\n  Testing(\n    not_ok = fn cond -> if cond then Fail \"%{label}: expected the assertion to fail here\"\n      else Pass label,\n    raises = fn thunk -> match try thunk () with\n      | Ok _ -> Fail \"%{label}: expected a raise, but it completed normally\"\n      | Error _ -> Pass label\n  )";
  fmt_eq "a ladder that starts its own line stays flush"
    "let grade score = let describe s = if s > 90 then \"an excellent score, top marks all around\" else if s > 75 then \"a good score, comfortably above the line\" else \"a score that needs another attempt\" in describe score"
    "let grade score =\n  let describe s =\n    if s > 90 then \"an excellent score, top marks all around\"\n    else if s > 75 then \"a good score, comfortably above the line\"\n    else \"a score that needs another attempt\"\n  in describe score";
  fmt_eq "a mid-line ladder steps in once and holds"
    "let pick = (fn kind -> if kind == \"circle\" then \"a shape with no corners at all\" else if kind == \"rect\" then \"a shape with four of them\" else \"a shape nobody here has heard of\")"
    "let pick =\n  fn kind -> if kind == \"circle\" then \"a shape with no corners at all\"\n    else if kind == \"rect\" then \"a shape with four of them\"\n    else \"a shape nobody here has heard of\""

(* A value that carries its own opening bracket keeps it on the line that
   introduces it, and the items carry the break. Given a line of its own the
   bracket says nothing -- the items sit at the same column either way --
   while costing a line at the top of every list, map and tuple wide enough
   to wrap. All three bracket forms follow the rule. *)
let test_bracketed_values_cuddle_their_opener () =
  fmt_eq "a list opens on the binding's line"
    "let a_list = [\"a considerable string here\", \"another considerable string\", \"and a third one\"]"
    "let a_list = [\n  \"a considerable string here\",\n  \"another considerable string\",\n  \"and a third one\"\n]";
  fmt_eq "a map does too"
    "let a_map = {alpha = \"a considerable string\", beta = \"another considerable one\", gamma = \"third\"}"
    "let a_map = {\n  alpha = \"a considerable string\",\n  beta = \"another considerable one\",\n  gamma = \"third\"\n}";
  fmt_eq "and a tuple"
    "let a_tuple = (\"a considerable string here\", \"another considerable string\", \"and a third one\")"
    "let a_tuple = (\n  \"a considerable string here\",\n  \"another considerable string\",\n  \"and a third one\"\n)";
  (* The two positions a group body puts it in: after `in`, and as the
     body of a trailing lambda. *)
  fmt_eq "a bracketed tail after `in`, and a trailing lambda's bracketed body"
    "import String\nlet build = group \"the report\" (fn () -> let lines = String.lines report in [check \"a considerable assertion here\", check \"another considerable one\"])"
    "import String\nlet build =\n  group \"the report\" (fn () ->\n    let lines = String.lines report in [\n      check \"a considerable assertion here\",\n      check \"another considerable one\"\n    ])"

(* An item is placed two columns in, so that is the indent it wraps to.
   Rendered at the sequence's own indent, an item's continuation lines
   landed to the left of the item itself. *)
let test_sequence_items_wrap_to_their_own_column () =
  fmt_eq "a match inside a tuple keeps its arms under it"
    "let tally first_err line = (1, match first_err with | Some e -> Some e | None -> if String.contains? \"ERROR\" line then Some line else None)"
    "let tally first_err line = (\n  1,\n  match first_err with\n  | Some e -> Some e\n  | None -> if String.contains? \"ERROR\" line then Some line else None\n)"

(* A binding's value may run onto the next line, but not as a bare
   application: the definition ends at the first line, loudly at the top
   level and silently inside a `let ... in`. Every other wrapped form carries
   an operator or a bracket that says it is not finished, so only this one
   needs the parentheses put back. *)
let test_a_wrapped_application_keeps_its_brackets () =
  ok_after_format "a top-level binding still binds what it looks like"
    "let g a b c = a + b + c\nlet x =\n  (g\n     100000\n     200000\n     300000)\nx"
    "600000";
  ok_after_format "and a local one"
    "let g a b c = a + b + c\nlet outer =\n  let x =\n    (g\n       100000\n       200000\n       300000)\n  in x\nouter"
    "600000";
  (* A form that carries its own continuation is left alone. *)
  Alcotest.(check string) "a wrapped match gains no brackets"
    "let f x =\n  match x with\n  | 0 -> \"zero\"\n  | _ -> \"other\"\n"
    (fmt "let f x =\n  match x with\n  | 0 -> \"zero\"\n  | _ -> \"other\"")

(* ── Comment preservation ────────────────────────────────────────────────── *)

let contains haystack needle =
  let hn = String.length haystack and nn = String.length needle in
  if nn = 0 then true
  else if nn > hn then false
  else begin
    let found = ref false in
    for i = 0 to hn - nn do
      if String.sub haystack i nn = needle then found := true
    done;
    !found
  end

let assert_contains label out needle =
  if not (contains out needle) then
    Alcotest.failf "%s: expected to find %S in output:\n%s" label needle out

let test_comments_preserved () =
  let src = "(* a leading comment *)\nlet x = 1\nx + 1" in
  assert_contains "leading comment" (fmt src) "a leading comment";
  let src2 = "let x = 1 (* trailing note *)\nlet y = 2\nx + y" in
  assert_contains "same-line comment" (fmt src2) "trailing note";
  let src3 = "(** a doc comment *)\nlet x = 1\nx" in
  assert_contains "doc comment" (fmt src3) "a doc comment"

(* A comment inside an item's own span (between multi-equation clauses,
   or inside a function body) must stay where it was, not get silently
   relocated to after the whole item -- verified by checking the comment
   still precedes the text that followed it in the original source. *)
let assert_appears_before label out needle_before needle_after =
  let find s =
    let n = String.length out and m = String.length s in
    let pos = ref (-1) in
    (try
       for i = 0 to n - m do
         if String.sub out i m = s then (pos := i; raise Exit)
       done
     with Exit -> ());
    !pos
  in
  let before_pos = find needle_before and after_pos = find needle_after in
  if before_pos < 0 then Alcotest.failf "%s: %S not found in output:\n%s" label needle_before out;
  if after_pos < 0 then Alcotest.failf "%s: %S not found in output:\n%s" label needle_after out;
  if not (before_pos < after_pos) then
    Alcotest.failf "%s: expected %S before %S, got:\n%s" label needle_before needle_after out

let test_interior_comment_position () =
  let src = "let f 0 = \"zero\"\n(* second clause *)\nlet f n = \"other\"\nf 3" in
  let out = fmt src in
  assert_contains "comment between multi-equation clauses" out "second clause";
  assert_appears_before "comment stays between clauses, not after both"
    out "second clause" "let f n";
  let src2 = "let f x =\n  (* explain this *)\n  x + 1\nf 5" in
  let out2 = fmt src2 in
  assert_contains "comment inside function body" out2 "explain this";
  assert_appears_before "comment stays inside body, not after the function"
    out2 "explain this" "f 5"

(* A comment that follows an item on the same source line stays on that
   line. Pieces are ordered by source offset, so a comment before an item
   on the same line still introduces it. *)
let test_trailing_comment_stays_on_line () =
  let out = fmt "let x = 1  -- trailing\nlet y = 2\nx" in
  assert_contains "line comment kept" out "-- trailing";
  Alcotest.(check bool) "line comment stays on the binding's line" true
    (List.exists (fun l ->
       contains l "let x = 1" && contains l "-- trailing")
     (String.split_on_char '\n' out));
  let out2 = fmt "let x = 1  (* trailing *)\nlet y = 2\nx" in
  Alcotest.(check bool) "block comment stays on the binding's line" true
    (List.exists (fun l ->
       contains l "let x = 1" && contains l "(* trailing *)")
     (String.split_on_char '\n' out2));
  let out3 = fmt "(* lead *) let x = 1\nx" in
  assert_appears_before "a comment written before an item still precedes it"
    out3 "lead" "let x = 1"

(* A doc comment's continuation lines are indented under the opening
   delimiter. The lexer strips their indentation so `wand d` prints clean
   prose, which means the formatter has to put it back. *)
let test_doc_comment_continuation_indent () =
  let out = fmt "(** first line\n    second line *)\nlet x = 1\nx" in
  assert_contains "doc text preserved" out "second line";
  Alcotest.(check bool) "continuation is indented, not flush left" true
    (List.exists (fun l -> l = "    second line *)")
       (String.split_on_char '\n' out))

(* A verbatim item's slice runs to the next item, absorbing any comment
   between them; if its recorded extent ignores that, a blank line gets
   inserted between a doc comment and the binding it documents. `try` is one
   of the constructs that triggers the verbatim path. *)
let test_no_blank_between_doc_and_binding () =
  let out =
    fmt "let a =\n  match try (f ()) with\n  | Ok v -> v\n  | Error _ -> 0\n\n         (** doc *)\nlet b = 2\nb"
  in
  let lines = String.split_on_char '\n' out in
  let rec check = function
    | a :: b :: tl ->
      if contains a "(** doc *)" && String.trim b = "" then
        Alcotest.failf "blank line separates the doc comment from its binding:\n%s" out
      else check (b :: tl)
    | _ -> ()
  in
  check lines

(* A record-shaped type too wide for one line widens down the page instead of
   running past the margin. *)
let test_wide_type_definition_wraps () =
  let src =
    "type Testing 'a 'b = Testing(ok: (Bool -> Int), not_ok: (Bool -> Int),      eq: ('a -> 'a -> Int), not_eq: ('a -> 'a -> Int), raises: ((Unit -> 'b) -> Int))\n     let f x = x\nf 1"
  in
  let out = fmt src in
  List.iter (fun l ->
    if String.length l > 92 then
      Alcotest.failf "formatted line exceeds the 92-column margin (%d):\n%s"
        (String.length l) l)
    (String.split_on_char '\n' out);
  assert_contains "fields kept" out "raises:";
  (* And the result still parses back to the same shape. *)
  assert_idempotent "wrapped type definition" src

let test_blank_lines () =
  let src = "let x = 1\n\n\n\nlet y = 2\nx + y" in
  let out = fmt src in
  (* collapse to at most one blank line between items *)
  if contains out "\n\n\n" then
    Alcotest.failf "expected blank-line run to collapse to one, got:\n%s" out


(* ── The constructs that used to be copied verbatim ──────────────────────── *)

(* $(), $?(), try, contracts, handle and regex literals were re-emitted as
   source slices because they had no formatting rule. They have rules now,
   and these are the ways those rules can silently change a program. *)

let test_command_text_is_not_quoted () =
  (* $() holds a command, not a string. Quoting it hands the whole thing to
     the shell as one word, which is a working script turned broken. *)
  ok_after_format "a command survives formatting"
    "let out = $(echo hi)\nout"
    "hi";
  assert_contains "and is still written bare" (fmt "let x = $(git status)\nx")
    "$(git status)";
  ok_after_format "including its interpolations"
    "let n = 1\nlet out = $(echo %{n})\nout"
    "1"

let test_try_is_parenthesised_as_an_operand () =
  (* `try` reaches as far right as it can, so an operand printed bare
     swallows the operator: `(try e) == x` would become `try (e == x)`. *)
  ok_after_format "try on the left of a comparison"
    "let f () = 1\nlet r = (try (f ())) == Ok 1\nr"
    "true"

let test_contract_clauses_keep_their_indent () =
  let out = fmt "let half n =\n  requires n % 2 == 0\n  ensures result * 2 == n\n  n / 2\nhalf 10" in
  List.iter (fun needle ->
    Alcotest.(check bool)
      (Printf.sprintf "%S sits at the body's indent" needle) true
      (List.exists (fun l -> l = needle) (String.split_on_char '\n' out)))
    ["  requires n % 2 == 0"; "  ensures result * 2 == n"];
  ok_after_format "and the contract still holds" 
    "let half n =\n  requires n % 2 == 0\n  n / 2\nhalf 10"
    "5"

let test_handle_and_regex_round_trip () =
  ok_after_format "a handler"
    "let m () = handle $(git push) with\n| Shell!run c k -> k \"ok\"\nm ()"
    "ok";
  ok_after_format "a regex literal"
    "import Regex\nRegex.match? r/fix|bug/i \"FIXED\""
    "true"

(* A binding's later clauses line up under the first one's name, and the
   `in` closes the group from the keyword's own column -- so the shape says
   which lines belong to the binding and which one ends it. Both spellings
   of the source converge, since which was written is not in the AST. *)
let test_let_clause_alignment () =
  let lines ls = String.concat "\n" ls in
  let expected =
    lines [ "let answer =";
            "  let fib 0 = 0";
            "      fib 1 = 1";
            "      fib n = fib (n - 1) + fib (n - 2)";
            "  in fib 10";
            "";
            "answer" ]
  in
  let repeated_let =
    lines [ "let answer =";
            "  let fib 0 = 0";
            "  let fib 1 = 1";
            "  let fib n = fib (n - 1) + fib (n - 2)";
            "  in fib 10";
            "";
            "answer" ]
  in
  Alcotest.(check string) "from the repeated-let spelling"
    expected (String.trim (fmt repeated_let));
  Alcotest.(check string) "from the aligned spelling"
    expected (String.trim (fmt expected));
  assert_idempotent "the layout is a fixed point" repeated_let

(* A backtick string has to come back as one. Rendered as a quoted string it
   would return escaped -- the whole point of writing it was not to escape --
   and a newline inside it would not read back at all. *)

let raw_src =
  "let inline = `{\"hello\": \"world\"}`\n\
   let block = `\n\
   one\n\
   two\n\
   `\n\
   let re = `\\d+\\s*`\n\
   let who = \"ada\"\n\
   let interp = `{\"name\": \"%{who}\"}`\n\
   inline"

let test_raw_strings_round_trip () =
  let out = fmt raw_src in
  assert_contains "quotes stay unescaped" out "`{\"hello\": \"world\"}`";
  assert_contains "backslashes stay literal" out "`\\d+\\s*`";
  assert_contains "interpolation is kept" out "`{\"name\": \"%{who}\"}`";
  Alcotest.(check bool) "no backtick text was requoted as a string literal"
    false (contains out "\"{\\\"hello");
  assert_idempotent "raw strings are a fixed point" raw_src;
  (* The value has to survive the trip, not just the shape. *)
  (match Runner.run_string (out ^ "\n") with
   | Ok _ -> ()
   | Error m -> Alcotest.failf "formatted source no longer runs: %s" m)

(* A multi-line literal keeps its layout: the newline the lexer drops after
   the opening backtick is put back, or each pass would eat a line. *)
let test_raw_multiline_keeps_its_shape () =
  let out = fmt "let b = `\none\ntwo\n`\nb" in
  assert_contains "content still starts on its own line" out "`\none\ntwo\n`"

(* `$NAME` in a string is text, so the formatter has nothing to interpret:
   it comes back as written, and is not turned into an interpolation. An
   actual environment read is `%{$USER}`, and that round-trips as itself. *)
let test_env_var_interpolation () =
  assert_contains "text is left as text" (fmt "\"user=$USER\"") "user=$USER";
  Alcotest.(check bool) "and is not made an interpolation" false
    (contains (fmt "\"user=$USER\"") "%{$USER}");
  assert_contains "a real env read survives" (fmt "\"user=%{$USER}\"") "%{$USER}"

(* ── Suite ────────────────────────────────────────────────────────────────── *)


(* A wide application breaks rather than running past the margin. The common
   shape is a trailing lambda -- `test "..." (fn t -> ...)` -- which reads
   best with its body on the next line, where a person would have put it. *)
let test_wide_application_breaks () =
  let out = fmt "import Test\ntest \"a label long enough to push this line past the margin\" (fn t -> t.eq (f (g x)) [1, 2, 3])" in
  List.iter (fun l ->
    if String.length l > 92 then
      Alcotest.failf "line runs past the margin (%d):\n%s" (String.length l) l)
    (String.split_on_char '\n' out);
  assert_contains "the lambda opens on the first line" out "(fn t ->";
  (* And the meaning survives the break. *)
  ok_after_format "a broken application still runs"
    "let apply f x = f x\nlet add a b = a + b\napply (fn n -> add n 1) 41"
    "42"

(* ── Canonicalization ────────────────────────────────────────────────────── *)

let golden = Alcotest.(check string)

let test_manifest_canonicalized () =
  golden "labels in display order, binaries sorted"
    "uses {Env, FS.Write, Shell(git, rsync)}\nlet x = 1\nx\n"
    (fmt "uses {Shell(rsync, git), FS.Write, Env}\nlet x = 1\nx");
  (* The typechecker's suggested line is already what fmt emits. *)
  golden "a suggested manifest is a fixed point"
    "uses {FS.Write}\nlet x = 1\nx\n"
    (fmt "uses {FS.Write}\nlet x = 1\nx")

let test_manifest_wraps_past_the_budget () =
  let src =
    "uses {Shell(zz-very-long-binary-name-one, yy-very-long-binary-name-two, \
     xx-very-long-binary-name-three, ww-very-long-binary-name-four), FS.Read, \
     FS.Write, Env, IO, Proc}\nlet x = 1\nx"
  in
  let out = fmt src in
  Alcotest.(check bool) "one label per line" true
    (String.length out > 0 &&
     Lint.contains out "uses {\n  Env,\n  FS.Read,\n  FS.Write,\n  IO,\n  Proc,\n  Shell(\n");
  Alcotest.(check bool) "one binary per line" true
    (Lint.contains out "    ww-very-long-binary-name-four,\n");
  assert_idempotent "wrapped manifest" src;
  (match Runner.typecheck_source ~path:"wand_fmt_wrap.wand" out with
   | Ok _ -> ()
   | Error d -> Alcotest.failf "wrapped manifest does not parse: %s" (Diag.legacy d))

let test_leading_imports_sorted () =
  golden "plain imports alphabetized, let-imports after, in source order"
    "import Env\nimport FS\nimport String\n\
     let u = import CSV\nlet {test} = import Test\nlet x = 1\nx\n"
    (fmt "import String\nlet u = import CSV\nimport FS\n\
          let {test} = import Test\nimport Env\nlet x = 1\nx");
  (* Let-imports are ordinary bindings: two binding the same name rebind,
     and their order is program meaning. *)
  golden "rebinding order kept"
    "let {parse} = import CSV\nlet {parse} = import TOML\nparse \"x = 1\"\n"
    (fmt "let {parse} = import CSV\nlet {parse} = import TOML\nparse \"x = 1\"");
  (* Imports past the leading region stay where they are. *)
  golden "only the leading region"
    "import String\nlet x = 1\nimport FS\nx\n"
    (fmt "import String\nlet x = 1\nimport FS\nx")

let test_import_region_with_comment_left_alone () =
  golden "a comment pins the region"
    "import String\n-- FS does the writing\nimport FS\nlet x = 1\nx\n"
    (fmt "import String\n-- FS does the writing\nimport FS\nlet x = 1\nx")

let () =
  Alcotest.run "Formatter" [
    "idempotency", [
      Alcotest.test_case "snippets" `Quick test_idempotent_snippets;
      Alcotest.test_case "stdlib"   `Quick test_idempotent_stdlib;
    ];
    "canonicalization", [
      Alcotest.test_case "escaped quotes prefer backticks" `Quick test_escaped_quotes_prefer_backticks;
      Alcotest.test_case "single-constructor shorthand" `Quick test_single_ctor_shorthand;
      Alcotest.test_case "maps canonicalize to braces" `Quick test_maps_canonicalize_to_braces;
      Alcotest.test_case "manifest order"    `Quick test_manifest_canonicalized;
      Alcotest.test_case "manifest wrapping" `Quick test_manifest_wraps_past_the_budget;
      Alcotest.test_case "import block"      `Quick test_leading_imports_sorted;
      Alcotest.test_case "comment pins it"   `Quick test_import_region_with_comment_left_alone;
    ];
    "behavior preserved", [
      Alcotest.test_case "behavior" `Quick test_behavior_preserved;
      Alcotest.test_case "float literal type" `Quick test_float_literal_type_preserved;
      Alcotest.test_case "constructor argument parens" `Quick test_constructor_argument_keeps_its_parens;
      Alcotest.test_case "one-armed if" `Quick test_one_armed_if;
      Alcotest.test_case "map keys needing quotes" `Quick test_map_keys_that_are_not_identifiers;
      Alcotest.test_case "width from the start column" `Quick test_width_is_measured_from_the_start_column;
      Alcotest.test_case "mid-line breaks step in" `Quick test_midline_breaks_step_in;
      Alcotest.test_case "bracketed values cuddle" `Quick test_bracketed_values_cuddle_their_opener;
      Alcotest.test_case "sequence item wrap column" `Quick test_sequence_items_wrap_to_their_own_column;
      Alcotest.test_case "wrapped application brackets" `Quick test_a_wrapped_application_keeps_its_brackets;
    ];
    "formerly verbatim", [
      Alcotest.test_case "command text"     `Quick test_command_text_is_not_quoted;
      Alcotest.test_case "try as operand"   `Quick test_try_is_parenthesised_as_an_operand;
      Alcotest.test_case "contract indent"  `Quick test_contract_clauses_keep_their_indent;
      Alcotest.test_case "handle and regex" `Quick test_handle_and_regex_round_trip;
      Alcotest.test_case "env interpolation" `Quick test_env_var_interpolation;
      Alcotest.test_case "let clause layout" `Quick test_let_clause_alignment;
      Alcotest.test_case "raw strings" `Quick test_raw_strings_round_trip;
      Alcotest.test_case "raw layout" `Quick test_raw_multiline_keeps_its_shape;
      Alcotest.test_case "wide application"  `Quick test_wide_application_breaks;
    ];
    "comments", [
      Alcotest.test_case "preserved"  `Quick test_comments_preserved;
      Alcotest.test_case "interior position" `Quick test_interior_comment_position;
      Alcotest.test_case "blank lines" `Quick test_blank_lines;
      Alcotest.test_case "trailing stays on line" `Quick test_trailing_comment_stays_on_line;
      Alcotest.test_case "doc continuation indent" `Quick test_doc_comment_continuation_indent;
      Alcotest.test_case "no blank after doc" `Quick test_no_blank_between_doc_and_binding;
      Alcotest.test_case "wide type wraps" `Quick test_wide_type_definition_wraps;
    ];
  ]
