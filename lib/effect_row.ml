(* Effect rows.

   An effect row describes what evaluating something does to the outside
   world. Rows are either closed -- exactly these effects and no others -- or
   open, meaning these effects plus whatever a row variable stands for. The
   open case is what lets a function written in wand stay honest without
   being over-committed: `List.map` performs whatever the function it is
   given performs, so its row is a variable, not a fixed set.

   The label set is fixed and small on purpose. A script cannot define new
   effects, so a row is always a subset of these seven, and a reader of a
   signature has a finite vocabulary to learn.

   This module knows nothing about types; `Typechecker` puts a row on the
   arrow and unifies it alongside them. *)

type eff =
  | Shell     (* runs a subprocess *)
  | FsRead    (* reads from the filesystem *)
  | FsWrite   (* creates, changes or removes something on disk *)
  | Net       (* talks to the network *)
  | Env       (* reads or changes process environment *)
  | Proc      (* touches the process itself: stdio, exit *)
  | Raise     (* can raise instead of returning *)

let all = [Shell; FsRead; FsWrite; Net; Env; Proc; Raise]

let name_of = function
  | Shell   -> "Shell"
  | FsRead  -> "FS.Read"
  | FsWrite -> "FS.Write"
  | Net     -> "Net"
  | Env     -> "Env"
  | Proc    -> "Proc"
  | Raise   -> "Raise"

(* Display order is fixed rather than alphabetical, so the same row always
   prints the same way and two signatures can be compared by eye. *)
let display_order e =
  let rec index i = function
    | []      -> i
    | x :: tl -> if x = e then i else index (i + 1) tl
  in
  index 0 all

module EffSet = Set.Make (struct
  type t = eff
  let compare a b = compare (display_order a) (display_order b)
end)

type rowvar = {
  rid          : int;
  mutable rdef : row option;
}

(* Labels known to be present, plus an optional tail standing for "and
   possibly more". `Row (s, None)` is closed at exactly `s`. *)
and row = Row of EffSet.t * rowvar option

exception RowError of string

let next_rid = ref 0

let fresh_rowvar () =
  let v = { rid = !next_rid; rdef = None } in
  incr next_rid;
  v

(* An open row with no known labels: the row of something whose effects are
   not yet determined. *)
let fresh_row () = Row (EffSet.empty, Some (fresh_rowvar ()))

let pure = Row (EffSet.empty, None)

let of_list es = Row (EffSet.of_list es, None)

let single e = Row (EffSet.singleton e, None)

(* Follow bound row variables, and flatten: a tail that has been bound to
   another row contributes its labels here. *)
let rec repr (Row (labels, tail) as r) =
  match tail with
  | None -> r
  | Some v ->
    (match v.rdef with
     | None -> r
     | Some inner ->
       let (Row (inner_labels, inner_tail)) = repr inner in
       Row (EffSet.union labels inner_labels, inner_tail))

let labels_of r = let (Row (l, _)) = repr r in l
let tail_of   r = let (Row (_, t)) = repr r in t

let is_closed r = tail_of r = None

let mem e r = EffSet.mem e (labels_of r)

(* The row with `e` added. Used when seeding a builtin, and when a raise
   escapes an expression. *)
let add e r =
  let (Row (l, t)) = repr r in
  Row (EffSet.add e l, t)

(* The row with `e` removed, for `try` discharging Raise and a handler
   discharging what it intercepts. Only meaningful on the labels actually
   known here; an open tail may still supply it, which is why discharge
   closes the row it is applied to (see `close`). *)
let remove e r =
  let (Row (l, t)) = repr r in
  Row (EffSet.remove e l, t)

let union a b =
  let (Row (la, ta)) = repr a in
  let (Row (lb, tb)) = repr b in
  let labels = EffSet.union la lb in
  match ta, tb with
  | None, None -> Row (labels, None)
  | Some v, None | None, Some v -> Row (labels, Some v)
  | Some _, Some _ ->
    (* Two open tails: the union is open, standing for either. A fresh
       variable would over-generalize, so reuse the first. *)
    Row (labels, ta)

(* Whether `v` appears in `r`'s tail, so unification cannot build a row that
   contains itself. *)
let rec occurs v r =
  match tail_of r with
  | None -> false
  | Some v' ->
    v'.rid = v.rid ||
    (match v'.rdef with None -> false | Some inner -> occurs v inner)

let bind v r =
  if occurs v r then
    raise (RowError "effect row refers to itself");
  v.rdef <- Some r

let string_of_row r =
  let (Row (labels, tail)) = repr r in
  let names = EffSet.elements labels |> List.map name_of in
  match names, tail with
  | [], None    -> "{}"
  | [], Some _  -> "{..}"
  | ns, None    -> "{" ^ String.concat ", " ns ^ "}"
  | ns, Some _  -> "{" ^ String.concat ", " ns ^ " | ..}"

(* Unify two rows, in the three cases that arise:

   - closed against closed: the label sets must already agree, since neither
     side can grow;
   - open against closed: the variable takes on whatever the closed side has
     that the open side does not, and the open side must not claim anything
     the closed side lacks;
   - open against open: both tails are bound to a shared fresh tail carrying
     the labels each side is missing, so later information reaches both. *)
let unify a b =
  let (Row (la, ta) as ra) = repr a in
  let (Row (lb, tb) as rb) = repr b in
  match ta, tb with
  | None, None ->
    if not (EffSet.equal la lb) then
      raise (RowError (Printf.sprintf "cannot unify effects %s with %s"
        (string_of_row ra) (string_of_row rb)))
  | Some v, None ->
    if not (EffSet.subset la lb) then
      raise (RowError (Printf.sprintf "cannot unify effects %s with %s"
        (string_of_row ra) (string_of_row rb)));
    bind v (Row (EffSet.diff lb la, None))
  | None, Some v ->
    if not (EffSet.subset lb la) then
      raise (RowError (Printf.sprintf "cannot unify effects %s with %s"
        (string_of_row ra) (string_of_row rb)));
    bind v (Row (EffSet.diff la lb, None))
  | Some va, Some vb ->
    if va.rid = vb.rid then begin
      if not (EffSet.equal la lb) then
        raise (RowError (Printf.sprintf "cannot unify effects %s with %s"
          (string_of_row ra) (string_of_row rb)))
    end else begin
      let shared = fresh_rowvar () in
      bind va (Row (EffSet.diff lb la, Some shared));
      bind vb (Row (EffSet.diff la lb, Some shared))
    end

(* Every row variable reachable from `r`, so schemes can quantify them. *)
let rec free_rowvars r =
  match tail_of r with
  | None -> []
  | Some v ->
    (match v.rdef with
     | None       -> [v.rid]
     | Some inner -> free_rowvars inner)
