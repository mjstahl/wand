type t =
  (* Literals *)
  | Int of int
  | Float of float
  | String of string
  | Bool of bool
  (* Domain literals *)
  | Path of string
  | Date of string
  | Time of string
  | DateTime of string
  | Duration of string
  | Url of string
  | IPv4 of string
  | CIDR of string
  | Port of int
  | Version of string
  | Size of string
  (* Identifiers *)
  | Ident of string    (* lowercase — values, functions *)
  | Upper of string    (* uppercase — modules, types, constructors *)
  | Hole               (* ? *)
  (* Keywords *)
  | Let
  | LetStar            (* let* *)
  | In
  | Match
  | With
  | If
  | Then
  | Else
  | Type
  | Token
  | Import
  | Start
  | Requires
  | Ensures
  | Result
  | Fn
  | Of
  | For
  | Do
  | End
  | Class
  | Instance
  | Orphan
  | When
  | And                (* and — keyword, not && *)
  | Or                 (* or — keyword, not || *)
  (* Operators *)
  | Eq                 (* = *)
  | Arrow              (* -> *)
  | Pipe               (* | *)
  | PipeArrow          (* |> *)
  | Plus               (* + *)
  | Minus              (* - *)
  | Star               (* * *)
  | Slash              (* / *)
  | Dot                (* . *)
  | DotDot             (* .. *)
  | Colon              (* : *)
  | Comma              (* , *)
  | Underscore         (* _ *)
  | EqEq               (* == *)
  | BangEq             (* != *)
  | Lt                 (* < *)
  | Gt                 (* > *)
  | LtEq               (* <= *)
  | GtEq               (* >= *)
  | AmpAmp             (* && *)
  | PipePipe           (* || *)
  | Bang               (* ! *)
  (* Delimiters *)
  | LParen             (* ( *)
  | RParen             (* ) *)
  | LBracket           (* [ *)
  | RBracket           (* ] *)
  | LBrace             (* { *)
  | RBrace             (* } *)
  | Semicolon          (* ; *)
  (* Structure *)
  | Newline
  | EOF

type loc = { line: int; col: int }

let pp ppf tok =
  let s = match tok with
    | Int n      -> Printf.sprintf "Int(%d)" n
    | Float f    -> Printf.sprintf "Float(%g)" f
    | String s   -> Printf.sprintf "String(%S)" s
    | Bool b     -> Printf.sprintf "Bool(%b)" b
    | Path s     -> Printf.sprintf "Path(%s)" s
    | Date s     -> Printf.sprintf "Date(%s)" s
    | Time s     -> Printf.sprintf "Time(%s)" s
    | DateTime s -> Printf.sprintf "DateTime(%s)" s
    | Duration s -> Printf.sprintf "Duration(%s)" s
    | Url s      -> Printf.sprintf "Url(%s)" s
    | IPv4 s     -> Printf.sprintf "IPv4(%s)" s
    | CIDR s     -> Printf.sprintf "CIDR(%s)" s
    | Port n     -> Printf.sprintf "Port(%d)" n
    | Version s  -> Printf.sprintf "Version(%s)" s
    | Size s     -> Printf.sprintf "Size(%s)" s
    | Ident s    -> Printf.sprintf "Ident(%s)" s
    | Upper s    -> Printf.sprintf "Upper(%s)" s
    | Hole       -> "Hole"
    | Let        -> "let"    | LetStar    -> "let*"
    | In         -> "in"     | Match      -> "match"
    | With       -> "with"   | If         -> "if"
    | Then       -> "then"   | Else       -> "else"
    | Type       -> "type"   | Token      -> "token"
    | Import     -> "import" | Start      -> "start"
    | Requires   -> "requires" | Ensures  -> "ensures"
    | Result     -> "result" | Fn         -> "fn"
    | Of         -> "of"    | For        -> "for"
    | Do         -> "do"     | End        -> "end"
    | Class      -> "class"  | Instance   -> "instance"
    | Orphan     -> "orphan" | When       -> "when"
    | And        -> "and"   | Or         -> "or"
    | Eq         -> "="      | Arrow      -> "->"
    | Pipe       -> "|"      | PipeArrow  -> "|>"
    | Plus       -> "+"      | Minus      -> "-"
    | Star       -> "*"      | Slash      -> "/"
    | Dot        -> "."      | DotDot     -> ".."
    | Colon      -> ":"      | Comma      -> ","
    | Underscore -> "_"      | EqEq       -> "=="
    | BangEq     -> "!="     | Lt         -> "<"
    | Gt         -> ">"      | LtEq       -> "<="
    | GtEq       -> ">="     | AmpAmp     -> "&&"
    | PipePipe   -> "||"     | Bang       -> "!"
    | LParen     -> "("      | RParen     -> ")"
    | LBracket   -> "["      | RBracket   -> "]"
    | LBrace     -> "{"      | RBrace     -> "}"
    | Semicolon  -> ";"      | Newline    -> "\\n"
    | EOF        -> "EOF"
  in
  Format.pp_print_string ppf s

let equal a b = a = b
