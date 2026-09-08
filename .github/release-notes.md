## 0.67.0 - 2026-09-08

wand reads YAML. Kubernetes manifests, docker-compose files, GitHub Actions
workflows — the formats the work is actually written in.

```ocaml
uses {FS.Read, IO}

import YAML

let docs = YAML.read_file_all! ./deploy.yaml
```

### It reads them the way they are written

The module follows the **YAML 1.2 core schema**, and that is not a detail.
Under 1.1, which is what most parsers still do, each of these reads as
something other than what the file says:

| written | 1.1 | wand |
|---|---|---|
| `on: push` | the key is the boolean `true` | the key is `"on"` |
| `- 2200:22` | base sixty, `132022` | the string `"2200:22"` |
| `restart: no` | the boolean `false` | the string `"no"` |
| `country: NO` | the boolean `false` | the string `"NO"` |

The first is every GitHub Actions workflow ever written. The second is why
the compose documentation tells people to quote their ports. For a language
whose pitch is that values carry their type, reading a workflow's `on:` key
as `true` would be indefensible.

Only `true` and `false` are booleans here. `yes`, `no`, `on` and `off` are
words. Quoting always makes a string, whatever the text looks like.

One row survives both schemas and still bites: `1.10` is a float, so a chart
version read unquoted arrives as `1.1` with a digit missing. Read it from a
quoted string, which is what the file should be writing.

### A manifest is many documents

```ocaml
YAML.parse "kind: Service\n---\nkind: Pod"
-- Error("this holds 2 documents. YAML.parse reads a file that holds one,
--        and YAML.parse_all reads them all")
```

`parse` refuses rather than truncates. Silently taking the first document is
how a script checks one third of a manifest and reports that everything
passed — and `kubectl apply -f` would have applied all three.

`parse_all` is what the policy checks want anyway, since they iterate.

### Anchors, aliases and merge keys

An `x-common` block merged into several services is the standard way a
compose file avoids repetition, so `&name`, `*name` and `<<:` all work. An
explicit key beats a merged one wherever it is written, and `<<: [*a, *b]`
takes the earlier one.

Expansion is capped at 100,000 nodes. A dozen lines of aliases can unfold
into gigabytes, and a script reading a file it did not write should not be
where that is discovered.

### It refuses rather than reads wrongly

An unknown tag is an error naming the tag. Ignoring `!Ref` would turn a
CloudFormation template into a document that parses, decodes, and means
something entirely different from what it says.

Reading is all it does. There is no `stringify` to pair with `JSON`'s and
`TOML`'s: emitting YAML means choosing among many equivalent spellings, and
the one job that would want it — editing a workflow in place — needs the
comments and the layout kept, which is a different data structure and a
different tool.

Helm charts are not YAML. A chart's templates are Go templates that happen
to produce it, so read the output of `helm template` rather than the chart.

### Nothing new to learn

`decode` takes the same `Decoder 'a` as `JSON.decode` and `TOML.decode`,
including the ones a type definition derives:

```ocaml
type Container(image: String, name: String)
type Spec(replicas: Int, containers: List Container)
```

### Where the parser comes from

libyaml does the syntax and wand does the meaning. Indentation, block and
flow context, quoting, line folding and escapes are the large, exacting part
of the format and are already written; reimplementing them would have added
errors to a solved problem. What wand supplies is the part where the answers
this domain needs differ: scalar resolution, alias expansion, merge keys and
document boundaries.

The `yaml` package vendors libyaml, so there is no system library to install
and the binary stays statically linked. It is about 12% larger.

### Also

`examples/ports/manifest-limits.wand` reports the containers in a manifest
that set no resource limits — including the ones that write `limits:` with
nothing under it, which a `yq` filter reads as identical to a missing key.
