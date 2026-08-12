let levenshtein a b =
  let m = String.length a and n = String.length b in
  let d = Array.make_matrix (m + 1) (n + 1) 0 in
  for i = 0 to m do d.(i).(0) <- i done;
  for j = 0 to n do d.(0).(j) <- j done;
  for i = 1 to m do
    for j = 1 to n do
      d.(i).(j) <-
        if a.[i-1] = b.[j-1] then d.(i-1).(j-1)
        else 1 + min d.(i-1).(j) (min d.(i).(j-1) d.(i-1).(j-1))
    done
  done;
  d.(m).(n)

let suggest name candidates =
  let threshold = max 2 (String.length name / 3) in
  candidates
  |> List.filter_map (fun c ->
      let d = levenshtein name c in
      if d > 0 && d <= threshold then Some (d, c) else None)
  |> List.sort (fun (a, _) (b, _) -> compare a b)
  |> (function (_, best) :: _ -> Some best | [] -> None)

let hint name candidates =
  match suggest name candidates with
  | Some s -> Printf.sprintf " (did you mean '%s'?)" s
  | None   -> ""

let has_loc_prefix msg =
  let n = String.length msg in
  let i = ref 0 in
  while !i < n && msg.[!i] >= '0' && msg.[!i] <= '9' do incr i done;
  !i > 0 && !i < n && msg.[!i] = ':'

(* Drop a leading "line:col: " stamp. An error that becomes a value -- the
   payload of a `try` -- describes what went wrong, not where: the position
   belongs to whichever frame raised, which for a stdlib call is a line
   inside the stdlib and means nothing to the caller holding the Result. *)
let strip_loc_prefix msg =
  let n = String.length msg in
  let i = ref 0 in
  while !i < n && msg.[!i] >= '0' && msg.[!i] <= '9' do incr i done;
  if !i = 0 || !i >= n || msg.[!i] <> ':' then msg
  else begin
    let j = ref (!i + 1) in
    while !j < n && msg.[!j] >= '0' && msg.[!j] <= '9' do incr j done;
    if !j = !i + 1 || !j >= n || msg.[!j] <> ':' then msg
    else begin
      let k = ref (!j + 1) in
      while !k < n && msg.[!k] = ' ' do incr k done;
      String.sub msg !k (n - !k)
    end
  end
