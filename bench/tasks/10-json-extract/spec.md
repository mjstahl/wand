Write a wand function `extract_name : String -> Result String String` that parses
its argument as JSON and returns the value of the top-level `"name"` field
as a string. If the input isn't valid JSON, or has no `"name"` field, or
that field isn't a string, return an `Error "..."` (any descriptive
message) instead of raising. Use the stdlib `JSON` module (`import JSON`).

Write only the function definition(s) needed (plus the `import`) — no
example calls, no top-level script.
