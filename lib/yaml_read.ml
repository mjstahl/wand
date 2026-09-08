(* Reading YAML.

   libyaml does the syntax and this file does the meaning. That split is the
   whole design: indentation, block and flow context, quoting, line folding
   and escapes are the large, exacting part of the format and are already
   written; what a scalar's text *means* is small, and is where the answers
   this domain needs differ from what the library would give.

   The library's own `Yaml.of_string` resolves scalars the YAML 1.1 way, so
   `restart: no` comes back as the boolean false -- measured, not assumed.
   A docker-compose file read that way decodes wrongly and silently. So the
   event stream is what is consumed here, and every scalar is resolved
   against the 1.2 core schema below.

   Three things the event stream also gives that the value API does not: a
   document boundary, so a Kubernetes manifest is more than its first
   document; anchors and aliases, which the library preserves but does not
   expand; and the position of everything, which is what an error message
   is made of. *)

(* Expanding an alias copies the node it names, and a document can name a
   node that itself contains aliases. A dozen lines can become gigabytes --
   the billion laughs attack -- and a script reading a file it did not write
   should not be the place that discovers this. The cap is on nodes produced
   by expansion, not on document size: a large manifest is fine, a small one
   that unfolds into millions of nodes is not. *)
let alias_node_limit = 100_000

exception Bad of string

(* libyaml counts lines and columns from zero and people count from one. *)
let at (pos : Yaml.Stream.Event.pos) =
  Printf.sprintf "line %d, column %d"
    (pos.start_mark.line + 1) (pos.start_mark.column + 1)

let bad pos msg = raise (Bad (Printf.sprintf "%s: %s" (at pos) msg))

(* ── The 1.2 core schema ──────────────────────────────────────────────────

   The record settles on 1.2 core rather than 1.1, and these are the rows
   that decides:

     on: push        1.1 makes the key the boolean true; here it is "on"
     - 2200:22       1.1 reads base sixty; here it is the string
     country: NO     1.1 makes it false; here it is "NO"

   The first two are GitHub Actions and docker-compose, which are two of the
   three formats this module exists to read. *)

let digit c = c >= '0' && c <= '9'
let octal c = c >= '0' && c <= '7'
let hex c = digit c || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')

(* Every character from [i] on satisfies [p], and there is at least one. *)
let rest_all p s i =
  let n = String.length s in
  let rec go j = j >= n || (p s.[j] && go (j + 1)) in
  i < n && go i

let has_prefix p s =
  String.length s >= String.length p && String.sub s 0 (String.length p) = p

(* `[-+]? [0-9]+` or `0o [0-7]+` or `0x [0-9a-fA-F]+`. OCaml's own
   `int_of_string` is wider than this -- it takes `_` separators, `0b` and
   `0u` -- so the shape is checked here and only then handed over. *)
let core_int s =
  let shaped =
    if has_prefix "0o" s then rest_all octal s 2
    else if has_prefix "0x" s then rest_all hex s 2
    else if s <> "" && (s.[0] = '-' || s.[0] = '+') then rest_all digit s 1
    else rest_all digit s 0
  in
  if shaped then int_of_string_opt s else None

(* `[-+]? ( . [0-9]+ | [0-9]+ ( . [0-9]* )? ) ( [eE] [-+]? [0-9]+ )?`, plus
   the named values. `1.10` is a float under both schemas, which is why a
   chart version has to be read from a quoted string; the docs say so
   loudly rather than leaving it to be found in production. *)
let core_float s =
  match s with
  | ".inf" | ".Inf" | ".INF" | "+.inf" | "+.Inf" | "+.INF" -> Some infinity
  | "-.inf" | "-.Inf" | "-.INF" -> Some neg_infinity
  | ".nan" | ".NaN" | ".NAN" -> Some nan
  | _ ->
    let n = String.length s in
    let i = if n > 0 && (s.[0] = '-' || s.[0] = '+') then 1 else 0 in
    (* mantissa: digits, then optionally a dot and digits; or a dot then digits *)
    let rec digits j = if j < n && digit s.[j] then digits (j + 1) else j in
    let j = digits i in
    let mantissa_end =
      if j > i then (if j < n && s.[j] = '.' then digits (j + 1) else j)
      else if j < n && s.[j] = '.' then (let k = digits (j + 1) in if k > j + 1 then k else -1)
      else -1
    in
    if mantissa_end < 0 || mantissa_end = i then None
    else
      let k = mantissa_end in
      let e =
        if k < n && (s.[k] = 'e' || s.[k] = 'E') then
          let m = if k + 1 < n && (s.[k + 1] = '-' || s.[k + 1] = '+') then k + 2 else k + 1 in
          let d = digits m in
          if d > m then d else -1
        else k
      in
      if e = n then float_of_string_opt s else None

(* Only the tags the core schema already resolves are honoured. Anything
   else is refused by name: `!Ref` in a CloudFormation template would
   otherwise parse, decode, and mean something entirely different from what
   the file says, and refusing to read a file beats reading it wrongly. *)
let core_tag = "tag:yaml.org,2002:"

let tagged pos tag (v : string) : Yojson.Basic.t =
  if not (has_prefix core_tag tag) then
    bad pos
      (Printf.sprintf
         "the tag %s is not one this reads. Only the standard %sstr, int, \
          float, bool and null tags are understood" tag core_tag)
  else
    let suffix = String.sub tag (String.length core_tag)
        (String.length tag - String.length core_tag) in
    match suffix with
    | "str" -> `String v
    | "null" -> `Null
    | "bool" ->
      (match v with
       | "true" | "True" | "TRUE" -> `Bool true
       | "false" | "False" | "FALSE" -> `Bool false
       | _ -> bad pos (Printf.sprintf "%sbool, but %S is not true or false" core_tag v))
    | "int" ->
      (match core_int v with
       | Some n -> `Int n
       | None -> bad pos (Printf.sprintf "%sint, but %S is not an integer" core_tag v))
    | "float" ->
      (match core_float v with
       | Some f -> `Float f
       | None -> bad pos (Printf.sprintf "%sfloat, but %S is not a number" core_tag v))
    | _ ->
      bad pos
        (Printf.sprintf
           "the tag %s is not one this reads. Only str, int, float, bool and \
            null are understood" tag)

(* A quoted scalar is a string whatever it looks like -- that is what
   quoting it says, and it is how a compose file writes a port or a
   Kubernetes chart writes a version. Only a plain scalar is resolved. *)
let resolve pos (s : Yaml.scalar) : Yojson.Basic.t =
  match s.tag with
  | Some tag when tag <> "" -> tagged pos tag s.value
  | _ ->
    (match s.style with
     | `Plain | `Any ->
       (match s.value with
        | "" | "~" | "null" | "Null" | "NULL" -> `Null
        | "true" | "True" | "TRUE" -> `Bool true
        | "false" | "False" | "FALSE" -> `Bool false
        | v ->
          (match core_int v with
           | Some n -> `Int n
           | None -> (match core_float v with Some f -> `Float f | None -> `String v)))
     | `Single_quoted | `Double_quoted | `Literal | `Folded -> `String s.value)

(* ── Building documents ───────────────────────────────────────────────── *)

let rec size (j : Yojson.Basic.t) =
  match j with
  | `Assoc kvs -> List.fold_left (fun a (_, v) -> a + 1 + size v) 1 kvs
  | `List xs -> List.fold_left (fun a v -> a + size v) 1 xs
  | _ -> 1

(* A collection carries no tag this reads, so one that is there is refused
   the same way a scalar's is. *)
let collection_tag pos = function
  | Some t when t <> "" && t <> core_tag ^ "seq" && t <> core_tag ^ "map" ->
    bad pos
      (Printf.sprintf
         "the tag %s is not one this reads. A sequence and a mapping need no \
          tag" t)
  | _ -> ()

let documents_of (src : string) : Yojson.Basic.t list =
  match Yaml.Stream.parser src with
  | Error (`Msg m) -> raise (Bad m)
  | Ok p ->
    let next () =
      match Yaml.Stream.do_parse p with
      | Error (`Msg m) -> raise (Bad m)
      | Ok ev -> ev
    in
    (* Anchors are per document: `---` starts a new naming scope, so a
       manifest cannot alias into the document above it. *)
    let anchors : (string, Yojson.Basic.t) Hashtbl.t = Hashtbl.create 8 in
    let expanded = ref 0 in
    let charge pos v =
      expanded := !expanded + size v;
      if !expanded > alias_node_limit then
        bad pos
          (Printf.sprintf
             "expanding aliases here passes %d nodes, which is the limit. A \
              document that unfolds this far is usually a mistake or an attack"
             alias_node_limit)
    in
    let remember anchor v =
      match anchor with Some a -> Hashtbl.replace anchors a v | None -> ()
    in
    let rec node (ev, pos) : Yojson.Basic.t =
      match (ev : Yaml.Stream.Event.t) with
      | Scalar s ->
        let v = resolve pos s in
        remember s.anchor v; v
      | Alias { anchor } ->
        (match Hashtbl.find_opt anchors anchor with
         | Some v -> charge pos v; v
         | None ->
           bad pos
             (Printf.sprintf
                "*%s, but no &%s is anchored above it in this document"
                anchor anchor))
      | Sequence_start { anchor; tag; _ } ->
        collection_tag pos tag;
        let v = `List (items []) in
        remember anchor v; v
      | Mapping_start { anchor; tag; _ } ->
        collection_tag pos tag;
        let v = `Assoc (fields [] []) in
        remember anchor v; v
      | Sequence_end | Mapping_end | Document_end _ ->
        bad pos "a value was expected here, and the collection ended instead"
      | Document_start _ | Stream_start _ | Stream_end | Nothing ->
        bad pos "a value was expected here"
    and items acc =
      let (ev, pos) = next () in
      match ev with
      | Sequence_end -> List.rev acc
      | _ -> items (node (ev, pos) :: acc)
    (* Explicit keys and merged keys are kept apart until the mapping ends,
       because an explicit key wins over a merged one wherever it is
       written -- before the `<<` or after it. *)
    and fields explicit merged =
      let (ev, pos) = next () in
      match ev with
      | Mapping_end ->
        let ex = List.rev explicit in
        let rec keep seen = function
          | [] -> []
          | (k, v) :: tl ->
            if List.mem k seen || List.mem_assoc k ex then keep seen tl
            else (k, v) :: keep (k :: seen) tl
        in
        ex @ keep [] (List.rev merged)
      | Scalar ({ value = "<<"; style = `Plain; _ }) ->
        let (vev, vpos) = next () in
        let v = node (vev, vpos) in
        fields explicit (List.rev_append (merge_pairs vpos v) merged)
      | Scalar s -> (
          let k = s.value in
          let (vev, vpos) = next () in
          fields ((k, node (vev, vpos)) :: explicit) merged)
      | Mapping_start _ | Sequence_start _ ->
        bad pos
          "this mapping key is itself a mapping or a sequence. A key is a \
           string here, which is what these formats use"
      | Alias { anchor } ->
        bad pos
          (Printf.sprintf
             "*%s is used as a mapping key. A key is a string here" anchor)
      | _ -> bad pos "a mapping key was expected here"
    (* `<<: *base`, and `<<: [*a, *b]` where the earlier one wins. *)
    and merge_pairs pos v =
      match v with
      | `Assoc kvs -> kvs
      | `List items ->
        List.concat_map
          (function
            | `Assoc kvs -> kvs
            | _ ->
              bad pos
                "a merge key takes a mapping, or a sequence of mappings, and \
                 one of these is neither")
          items
      | _ ->
        bad pos
          "a merge key takes a mapping, or a sequence of mappings, and this \
           is neither"
    in
    let rec documents acc =
      let (ev, pos) = next () in
      match ev with
      | Stream_start _ -> documents acc
      | Stream_end -> List.rev acc
      | Document_start _ ->
        Hashtbl.reset anchors;
        let (nev, npos) = next () in
        let d =
          match nev with
          | Document_end _ -> `Null
          | _ ->
            let d = node (nev, npos) in
            (match next () with
             | Document_end _, _ -> ()
             | _, p -> bad p "the document should have ended here");
            d
        in
        documents (d :: acc)
      | _ -> bad pos "a document was expected here"
    in
    documents []

(* ── What the standard library calls ──────────────────────────────────── *)

let parse_all (src : string) : (Yojson.Basic.t list, string) result =
  try Ok (documents_of src) with
  | Bad m -> Error m
  | Failure m -> Error m

let parse (src : string) : (Yojson.Basic.t, string) result =
  match parse_all src with
  | Error e -> Error e
  | Ok [] -> Ok `Null
  | Ok [ d ] -> Ok d
  | Ok ds ->
    Error
      (Printf.sprintf
         "this holds %d documents. YAML.parse reads a file that holds one, \
          and YAML.parse_all reads them all" (List.length ds))
