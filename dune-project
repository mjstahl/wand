(lang dune 3.23)

(name wand)

(generate_opam_files true)

(source
 (github mjstahl/wand))

(authors "Mark Stahl <mark@technicallycorrect.company>")

(maintainers "Mark Stahl <mark@technicallycorrect.company>")

(license MIT)

(package
 (name wand)
 (synopsis "A typed ML-style scripting language for Human-AI collaboration")
 (description
  "wand is a typed, ML-style scripting language designed for Human-AI collaboration, with Hindley-Milner type inference, pattern matching, and Result-based error handling.")
 (depends
  ocaml
  linenoise
  yojson
  toml
  re
  digestif
  eqaf
  (alcotest :with-test))
 (tags
  ("scripting-language" "type-inference" "ml" "interpreter")))

; See the complete stanza docs at https://dune.readthedocs.io/en/stable/reference/dune-project/index.html
