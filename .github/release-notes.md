## 0.48.1 - 2026-08-25

Two faults, both found while writing a record that carries a decoder beside
the name of what it reads.

### Fixed

- A field could not hold a decoder. `type D(decoder: Decoder Pod)` could not
  be built from `Pod.decoder`. A field's type reader turned `List`, `Map` and
  `Result` into the forms the checker uses, and left `Decoder` as a plain
  application, so nothing could fill the field. The error said `Decoder Pod
  and Decoder Pod are not the same type`
- A written signature did not bind the parameters before the body was read:

      type Box 'a(v: 'a)
      let get : Box 'a -> 'a = fn b -> b.v
      -- field access requires a named type, got 'a

  The signature says what `b` is. It is applied to the parameters first now.
  A lambda with more parameters than the signature has arrows still infers
  whole, so a wrong signature is still caught
