# YAML, read-only

wand is for deploys, CI glue and cron jobs. In that domain the configuration
is YAML: Kubernetes manifests, docker-compose files, GitHub Actions
workflows. wand ships `JSON` and `TOML` and skips the format the work is
actually written in — the README tells people to run wand from a file wand
cannot read.

```yaml
- uses: mjstahl/setup-wand@v1
- run: wand ci/deploy.wand
```

This document is scoped by those three consumers rather than by the YAML
specification. It records what they require, what is settled, and states the
rest as questions to be answered rather than discovered. It is written
before the code and is not a specification.

- [What the scripts actually do](#what-the-scripts-actually-do)
- [What those three formats require](#what-those-three-formats-require)
- [The decoder vocabulary is already shared](#the-decoder-vocabulary-is-already-shared)
- [What is settled](#what-is-settled)
- [Questions](#questions)
- [Order](#order)

## What the scripts actually do

The operations that come up in this domain are narrow, and they are not the
ones a general YAML library is built for.

```
does every Deployment set resource limits?
is any image pinned to :latest?
does this compose file expose a port it should not?
which workflows still run on an unsupported runner?
what image tag is production on right now?
```

Every one of those reads a document, pulls a few fields, and reports. None
of them rewrites the file. That is the shape wand is good at — `wand t` on a
script that reads a manifest and checks a policy is a gate a CI job can run
— and it is the shape this module should serve.

A script that *edits* a workflow file is a different tool. It needs comments
and layout preserved, which needs a document model this design does not
have and should not grow.

## What those three formats require

| | multi-document | anchors and merge keys | tags | quirks that bite |
|---|---|---|---|---|
| Kubernetes | **constantly** | rare | rare | `1.10` in a chart version |
| docker-compose | no | **common** | no | unquoted `2200:22` ports |
| GitHub Actions | no | occasional | no | the `on:` key |

Two entries in that last column are the reason the schema question below is
not a matter of taste.

**GitHub Actions workflows start with `on:`.** Under YAML 1.1 the key `on`
is the boolean `true`, so a workflow file's most important key is not a
string. Every tool in that ecosystem has had to work around it.

**docker-compose port mappings can look like base 60.** YAML 1.1 reads
`2200:22` as sexagesimal — 2200 times sixty plus twenty-two, so `132022` —
which is why the compose documentation tells people to quote port mappings.
It bites only when the part after the colon is under sixty, so `2200:22`
becomes a number while `5432:5432` does not. A rule that applies to some of
your ports and not others is worse than one that applies to all of them.

**Kubernetes is multi-document by default.** `---` separators are how
manifests are written and how `kubectl apply -f` consumes them. This is a
hard requirement rather than a nicety, and it is the one thing neither
`JSON` nor `TOML` gives any precedent for.

One boundary worth stating: **Helm charts are not YAML.** A chart's
templates are Go templates that happen to produce YAML, so wand reads the
output of `helm template`, not the chart. The same is true of anything else
templated before it is applied. That is a limit of the format, not of this
module, and the doc should say it so nobody files it as a bug.

## The decoder vocabulary is already shared

This decides how large the job is.

```
JSON.decode : Decoder 'a -> JSON -> Result String 'a
TOML.decode : Decoder 'a -> TOML -> Result String 'a
```

A `Decoder 'a` is document-agnostic. `Decode.field "a" Decode.int` runs
against either document type, and only the entry point differs. So YAML
needs no third `Decode` module and no change to the decoders derived from a
type definition — which is what makes the policy-check shape above cheap:

```ocaml
type Container(image: String, name: String)
type Spec(replicas: Int, containers: List Container)
```

That is the whole reading layer for the questions at the top of this
document, and it already exists.

What YAML needs is a parser, an entry point, and an accessor surface. That
surface is the cost: `TOML` has eighteen members and `JSON` twenty-five, and
roughly fourteen would be said a third time.

## What is settled

**YAML 1.2 core schema, not 1.1.**

| written | YAML 1.1 | YAML 1.2 core |
|---|---|---|
| `on: push` | key is the boolean `true` | key is the string `"on"` |
| `- 2200:22` | sexagesimal, `132022` | the string `"2200:22"` |
| `country: NO` | the boolean `false` | the string `"NO"` |
| `version: 1.10` | the float `1.1` | the float `1.1` |

The first two rows are GitHub Actions and docker-compose respectively. For a
language whose pitch is that values carry their type, reading a workflow's
`on:` key as `true` would be indefensible.

The last row survives both schemas and has to be documented loudly, because
`Version` is a wand type and `1.10.0` in a chart is a float to every YAML
parser alive. A script reading a version out of YAML must read a quoted
string, and the doc should show that rather than leave it to be found in
production.

**Keys are strings.** Not a subset decision — the language decides it:

```
JSON.get_object : JSON -> Result String (Map JSON)
```

`Map` is keyed by `String`. Nothing in these three formats has a non-string
key, so the restriction costs the target domain nothing.

**Read-only.** Every operation at the top of this document reads. Emitting
YAML means choosing among many equivalent spellings, and the one job that
would want emitting — editing a workflow in place — needs comment and layout
preservation, which is a different data structure and a different project.
`JSON.stringify` and `TOML.stringify` having no YAML counterpart should be
explained in the docs rather than left looking like an oversight.

## Questions

**Q1. Its own `YAML` type, or parse into `JSON`?**

Restricted to string keys, YAML 1.2 core's value space *is* JSON's, so
`YAML.parse : String -> Result String JSON` would be honest, would cost one
function instead of fourteen, and would hand over every `JSON` accessor for
free. Against that, it means writing `JSON.get_object` on a Kubernetes
manifest, which reads as though wand converted the file.

The friction people will imagine — a script reading config from either
`.json` or `.yaml` needing two paths — is smaller than it looks, because
`Decoder 'a` is the common ground and both decode into the same record.

*Recommendation: its own type.* The document value is short-lived either
way, so the wrappers buy symmetry with `JSON` and `TOML` at a cost paid
once, and they leave room for the multi-document answer below to live in the
type rather than beside it.

**Q2. How do multiple documents surface?**

This is the Kubernetes question and the most important one in the document.

*Recommendation: `parse` for one document, `parse_all` for many, and `parse`
fails — does not truncate — when the input holds more than one.* Silently
taking the first document is how a script checks one third of a manifest and
reports that everything passed. The error names how many it found.

`parse_all` is what the policy checks want anyway, since they iterate:

```ocaml
YAML.parse_all! text |> List.filter (fn d -> kind_of d == "Deployment")
```

**Q3. Anchors, aliases and merge keys?**

`&name`, `*name` and `<<:` are ordinary in docker-compose — an `x-common`
block merged into several services is the standard way that file avoids
repetition. Rare in the other two.

Two consequences. Merge keys are not in the 1.2 core schema, so supporting
them makes the subset "1.2 core, plus merge keys" — a deviation the doc must
state, having just made a virtue of following the schema. And aliases bring
the expansion bomb: a dozen lines can expand to gigabytes, which is a denial
of service against a script reading a file it did not write.

*Recommendation: support them, with a hard cap on expanded nodes and an
error naming the cap.* Refusing them makes the module much less useful for
one of its three consumers. The cap is the price and it is small.

**Q4. What happens to tags?**

None of the three formats needs custom tags. CloudFormation does, heavily,
and it is adjacent enough to the domain that someone will try.

*Recommendation: reject an unknown tag, naming it.* Ignoring `!Ref` turns a
CloudFormation template into a document that parses, decodes, and means
something entirely different from what it says. Refusing to read a file
beats reading it wrongly. Standard `!!` tags for types the core schema
already resolves can be honoured.

**Q5. Where does the parser come from?**

`ocaml-yaml` binds libyaml, which puts a C library in the way of a static
musl build that already compiles dune from source and is retried three times
on the runners. A hand-written subset is plausibly six to nine hundred
lines.

Scoping to these three formats makes the hand-written option smaller than
it sounds. Block mappings, block sequences, scalars, flow collections,
multi-document separators, anchors and merge keys cover all of them.
Directives, complex keys, sets, ordered maps and most of the tag machinery
do not appear.

And the YAML test suite is public, so "documented subset" can be a list of
test identifiers — which it passes and which it deliberately rejects —
rather than a paragraph of prose.

*Leaning: hand-written, gated on that test suite.* The distribution story is
one file carrying its own standard library, and libyaml is the wrong thing
to trade it for. This is still the largest single piece of work on the
standard library list and deserves a second opinion.

**Q6. What happens to input the subset does not cover?**

*Recommendation: reject, naming the construct and the line.* A parser that
drops what it does not understand is worse than one that refuses, because a
manifest that half-parses still passes a policy check. Every rejection names
what it found, where, and the supported way to write the same thing when
there is one.

**Q7. What is the error-message budget?**

Indentation-sensitive parsing makes good messages hard, and wand spends real
effort on messages elsewhere — the manifest check suggests the exact line to
add, the arity error names the type that is wrong, `V-SHELL2` writes the
continuation for you.

`parse error at line 34` would be the worst diagnostics in the language.
Whatever is built has to name the construct it was reading and the column.

*No recommendation.* This is a question about implementation strategy, and
it should be answered by whoever writes Q5's parser, before they write it
rather than after.

## Order

Q5 first. A hand-written parser and a libyaml binding are different projects
with different schedules, and everything else is downstream of which one it
is.

Q2 next, because Kubernetes is the consumer with the hardest requirement and
multi-document support is the thing that decides whether this module serves
it at all. Then Q1, which is the module's shape.

Q3, Q4 and Q6 are parser behaviour and can be settled while it is written.
Q7 has to be answered before it is written, by the person writing it.
