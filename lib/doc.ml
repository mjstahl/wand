(* Text being built, held as the tree of pieces it was joined from rather
   than as one string.

   The emitters ask two things of a piece they have laid out: how wide it is,
   and what it ends with. Read from the characters, each answer costs the
   length of the piece, and a nested value asks at every level. Read from the
   tree, each is a field, and the characters are written once, into a buffer,
   at the end. *)

type t =
  | Empty
  | Leaf of string
  | Node of node

and node = {
  left    : t;
  right   : t;
  width   : int;
  newline : bool;
  (* Width of the text after the last newline, or of the whole when there is
     none. This is what a caller's column becomes. *)
  tail    : int;
  head    : char;
  (* One bracket, holding everything up to its own close. Set where the piece
     is built, because the text cannot be read back for it: a bracket inside a
     command or a backtick string is not one of these, and telling them apart
     means lexing what was just written. *)
  whole   : bool;
}

let empty = Empty

let text s = if s = "" then Empty else Leaf s

let spaces n = if n <= 0 then Empty else Leaf (String.make n ' ')

let width = function
  | Empty -> 0
  | Leaf s -> String.length s
  | Node n -> n.width

let has_newline = function
  | Empty -> false
  | Leaf s -> String.contains s '\n'
  | Node n -> n.newline

let tail_width = function
  | Empty -> 0
  | Leaf s ->
    (match String.rindex_opt s '\n' with
     | None -> String.length s
     | Some i -> String.length s - i - 1)
  | Node n -> n.tail

let head_char = function
  | Empty -> None
  | Leaf s -> if s = "" then None else Some s.[0]
  | Node n -> Some n.head

let is_empty d = width d = 0

let join_two a b =
  let wb = width b in
  let b_breaks = has_newline b in
  Node {
    left = a; right = b;
    width = width a + wb;
    newline = has_newline a || b_breaks;
    tail = if b_breaks then tail_width b else tail_width a + wb;
    head =
      (match head_char a with
       | Some c -> c
       | None -> (match head_char b with Some c -> c | None -> ' '));
    whole = false;
  }

let ( ^^ ) a b =
  match a, b with
  | Empty, d | d, Empty -> d
  | _ -> join_two a b

let rec join_all = function
  | [] -> Empty
  | [one] -> one
  | first :: rest -> first ^^ join_all rest

(* A piece that is one bracket by construction says so; nothing reads it back
   out of the text. A lone piece cannot be one, so it is left alone. *)
let as_whole = function
  | Node n -> Node { n with whole = true }
  | d -> d

let of_parts ~whole parts =
  let joined = join_all parts in
  if whole then as_whole joined else joined

let concat sep parts =
  match parts with
  | [] -> Empty
  | [one] -> one
  | _ ->
    let rec weave = function
      | [] -> Empty
      | [last] -> last
      | p :: rest -> p ^^ sep ^^ weave rest
    in
    weave parts

let rec add buf = function
  | Empty -> ()
  | Leaf s -> Buffer.add_string buf s
  | Node n -> add buf n.left; add buf n.right

let to_string = function
  | Empty -> ""
  | Leaf s -> s
  | Node n as d ->
    let buf = Buffer.create (n.width + 1) in
    add buf d;
    Buffer.contents buf

(* The first line alone, for a caller that counts brackets across it. Pieces
   after the first newline are never visited. *)
let first_line d =
  let buf = Buffer.create 64 in
  let rec go d =
    match d with
    | Empty -> true
    | Leaf s ->
      (match String.index_opt s '\n' with
       | None -> Buffer.add_string buf s; true
       | Some i -> Buffer.add_string buf (String.sub s 0 i); false)
    | Node n ->
      if not n.newline then (add buf d; true)
      else go n.left && go n.right
  in
  ignore (go d);
  Buffer.contents buf

let rec last_char = function
  | Empty -> None
  | Leaf s -> if s = "" then None else Some s.[String.length s - 1]
  | Node n ->
    (match last_char n.right with None -> last_char n.left | c -> c)

(* Walked from the right, and only as far as the suffix is long. *)
let ends_with d suffix =
  let want = String.length suffix in
  if want = 0 then true
  else if width d < want then false
  else begin
    let got = Bytes.create want in
    let need = ref want in
    let rec go d =
      if !need > 0 then
        match d with
        | Empty -> ()
        | Leaf s ->
          let take = min !need (String.length s) in
          Bytes.blit_string s (String.length s - take) got (!need - take) take;
          need := !need - take
        | Node n -> go n.right; go n.left
    in
    go d;
    !need = 0 && Bytes.to_string got = suffix
  end

let holds_all = function
  | Empty | Leaf _ -> false
  | Node n -> n.whole

(* `( ` rather than `(` where the content opens with `*`, which would
   otherwise read as the start of a comment. *)
let bracket d =
  let lead = match head_char d with Some '*' -> Leaf "( " | _ -> Leaf "(" in
  of_parts ~whole:(not (is_empty d)) [lead; d; Leaf ")"]

let whole_bracket parts = of_parts ~whole:true parts
