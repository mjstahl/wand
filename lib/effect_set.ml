(* Effect sets.

   An effect set describes what evaluating something does to the outside
   world. A set is either closed -- exactly these effects and no others --
   or open, meaning these effects plus whatever an effect variable stands
   for. The open case is what lets a function written in wand stay honest
   without being over-committed: `List.map` performs whatever the function
   it is given performs, so what it performs is a variable, not a fixed set.

   The effects are fixed and few on purpose. A script cannot define new
   ones, so an effect set is always a subset of these seven, and a reader of
   a signature has a finite vocabulary to learn. One is added when something
   can actually perform it: network access reaches the outside world through
   a command today, and so reports as Shell.

   This module knows nothing about types; `Typechecker` puts an effect set
   on the arrow and unifies it alongside them.

   (The representation is an open record of labels, which type theory calls
   a row. The word is not used here or anywhere else: it names the encoding
   rather than the idea, and a reader of this compiler does not need it.) *)

type eff =
  | Shell     (* runs a subprocess *)
  | FsRead    (* reads from the filesystem *)
  | FsWrite   (* creates, changes or removes something on disk *)
  | Env       (* reads or changes environment variables *)
  | IO        (* reads or writes the program's own streams *)
  | Proc      (* ends the process; nothing catches this *)
  | Raise     (* can raise instead of returning *)

(* Alphabetical by rendered name. This list is the one definition of
   display order: it governs rendered effect sets, manifests, and the suggestion
   path alike (through the `EffSet` compare below), so a suggested
   manifest is always already in canonical form and a reader can predict
   where a label sits without knowing any convention beyond the
   alphabet. *)
let all = [Env; FsRead; FsWrite; IO; Proc; Raise; Shell]

let name_of = function
  | Shell   -> "Shell"
  | FsRead  -> "FS.Read"
  | FsWrite -> "FS.Write"
  | Env     -> "Env"
  | IO      -> "IO"
  | Proc    -> "Proc"
  | Raise   -> "Raise"

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

type evar = {
  id          : int;
  mutable def : t option;
}

(* Labels known to be present, plus an optional tail standing for "and
   possibly more". `Set (s, None)` is closed at exactly `s`. *)
and t = Set of EffSet.t * evar option

exception Mismatch of string

let next_id = ref 0

let fresh_var () =
  let v = { id = !next_id; def = None } in
  incr next_id;
  v

(* An open set with no known effects: what something whose effects are
   not yet determined. *)
let unknown () = Set (EffSet.empty, Some (fresh_var ()))

let pure = Set (EffSet.empty, None)

let of_list es = Set (EffSet.of_list es, None)

let single e = Set (EffSet.singleton e, None)

(* Follow bound effect variables, and flatten: a tail that has been bound
   to another set contributes its effects here. *)
let rec repr (Set (labels, tail) as r) =
  match tail with
  | None -> r
  | Some v ->
    (match v.def with
     | None -> r
     | Some inner ->
       let (Set (inner_labels, inner_tail)) = repr inner in
       Set (EffSet.union labels inner_labels, inner_tail))

let labels_of r = let (Set (l, _)) = repr r in l
let tail_of   r = let (Set (_, t)) = repr r in t

let is_closed r = tail_of r = None

let mem e r = EffSet.mem e (labels_of r)

(* The set with `e` added. Used when seeding a builtin, and when a raise
   escapes an expression. *)
let add e r =
  let (Set (l, t)) = repr r in
  Set (EffSet.add e l, t)

(* The set with `e` removed, for `try` discharging Raise and a handler
   discharging what it intercepts. Only meaningful on the labels actually
   known here; an open tail may still supply it, which is why discharge
   closes the set it is applied to (see `close`). *)
let remove e r =
  let (Set (l, t)) = repr r in
  Set (EffSet.remove e l, t)

let union a b =
  let (Set (la, ta)) = repr a in
  let (Set (lb, tb)) = repr b in
  let labels = EffSet.union la lb in
  match ta, tb with
  | None, None -> Set (labels, None)
  | Some v, None | None, Some v -> Set (labels, Some v)
  | Some _, Some _ ->
    (* Two open tails: the union is open, standing for either. A fresh
       variable would over-generalize, so reuse the first. *)
    Set (labels, ta)

(* Whether `v` appears in `r`'s tail, so unification cannot build a set that
   contains itself. `tail_of` goes through `repr`, which flattens every
   bound tail away, so the variable it answers with is always unbound --
   one comparison decides. *)
let occurs v r =
  match tail_of r with
  | None -> false
  | Some v' -> v'.id = v.id

let bind v r =
  if occurs v r then
    raise (Mismatch "an effect set cannot contain itself");
  v.def <- Some r

let to_string r =
  let (Set (labels, tail)) = repr r in
  let names = EffSet.elements labels |> List.map name_of in
  match names, tail with
  | [], None    -> "{}"
  | [], Some _  -> "{..}"
  | ns, None    -> "{" ^ String.concat ", " ns ^ "}"
  | ns, Some _  -> "{" ^ String.concat ", " ns ^ " | ..}"

(* Unify two effect sets, in the three cases that arise:

   - closed against closed: the label sets must already agree, since neither
     side can grow;
   - open against closed: the variable takes on whatever the closed side has
     that the open side does not, and the open side must not claim anything
     the closed side lacks;
   - open against open: both tails are bound to a shared fresh tail carrying
     the labels each side is missing, so later information reaches both. *)
let unify a b =
  let (Set (la, ta) as ra) = repr a in
  let (Set (lb, tb) as rb) = repr b in
  match ta, tb with
  | None, None ->
    if not (EffSet.equal la lb) then
      raise (Mismatch (Printf.sprintf "cannot unify effects %s with %s"
        (to_string ra) (to_string rb)))
  | Some v, None ->
    if not (EffSet.subset la lb) then
      raise (Mismatch (Printf.sprintf "cannot unify effects %s with %s"
        (to_string ra) (to_string rb)));
    bind v (Set (EffSet.diff lb la, None))
  | None, Some v ->
    if not (EffSet.subset lb la) then
      raise (Mismatch (Printf.sprintf "cannot unify effects %s with %s"
        (to_string ra) (to_string rb)));
    bind v (Set (EffSet.diff la lb, None))
  | Some va, Some vb ->
    if va.id = vb.id then begin
      (* One variable on both sides, carrying different labels. This is not
         a conflict but a recursive equation -- `p = {IO} + p` -- and it is
         how a function that calls itself arrives here: performing an effect
         puts it in the ambient set, the recursive call contributes the same
         tail without it, and the two meet.

         Solved rather than rejected. Binding the variable to the labels the
         two sides disagree on leaves both reading `la + lb + p'`, which is
         the least set satisfying the equation. Without this a recursive
         function could perform no effect of its own: it typechecked only
         while every effect it had came from a function it was passed, which
         is why `List.each` is fine and a loop that prints is not. *)
      if not (EffSet.equal la lb) then
        bind va (Set (EffSet.union (EffSet.diff la lb) (EffSet.diff lb la),
                      Some (fresh_var ())))
    end else begin
      let shared = fresh_var () in
      bind va (Set (EffSet.diff lb la, Some shared));
      bind vb (Set (EffSet.diff la lb, Some shared))
    end

(* Record that `l` is performed inside a scope whose effects so far are
   `ambient`, returning the extended ambient.

   Two things happen. The labels `l` is known to carry are added, which is
   the easy half. The harder half is `l`'s tail: if what the callee does is
   still undetermined, whatever it turns out to do must also reach the
   enclosing signature, so its tail becomes the ambient's tail. Joining the
   two sets by union instead would keep only one tail and silently drop
   the other call's effects.

   Tying the tails together over-approximates -- two different callees in
   one body end up sharing the scope's unknown effects, so an effect proved
   for one is attributed to both. That is the safe direction: a signature
   may name an effect the function does not always perform, but it can never
   omit one it does. *)
let absorb ~ambient l =
  let (Set (la, ta)) = repr ambient in
  let (Set (ll, tl)) = repr l in
  (match tl, ta with
   | Some vl, Some va when vl.id <> va.id ->
     bind vl (Set (EffSet.empty, Some va))
   | Some vl, None ->
     (* The scope's effects are already fixed, so the callee adds nothing
        beyond what it is known to carry. *)
     bind vl (Set (EffSet.empty, None))
   | _ -> ());
  Set (EffSet.union la ll, ta)

(* Rebuild `r` with its effect variables replaced according to `subst`. A
   polymorphic function's effect variable must be freshened at each use, or
   every caller shares one and the first caller to perform an effect
   attributes it to all of them. *)
let subst subst r =
  let (Set (labels, tail)) = repr r in
  match tail with
  | None -> Set (labels, None)
  | Some v ->
    (match List.assoc_opt v.id subst with
     | Some v' -> Set (labels, Some v')
     | None    -> Set (labels, Some v))

(* Every effect variable reachable from `r`, so schemes can quantify them. The
   tail `tail_of` answers with is always unbound (see `occurs`), so it is
   the one free variable a set can have. *)
let free_vars r =
  match tail_of r with
  | None -> []
  | Some v -> [v.id]
