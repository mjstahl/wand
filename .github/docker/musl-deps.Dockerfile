# The dependencies for the static Linux build, as a layer that can be cached.
#
# The opam image ships no dune, so every release used to compile dune from
# source inside the build step -- around seventy seconds of the two minutes,
# for a build system that is not wand and does not change. It is also the
# step that has twice died with "Failed to allocate signal stack for domain
# 0" and taken a release with it.
#
# Built as its own image so the layer below can be cached between runs. On a
# hit nothing here runs at all.
FROM ocaml/opam:alpine-ocaml-5.4

RUN sudo apk add --no-cache musl-dev

# Only the two files that decide the dependency set. Every change to wand's
# own source leaves this layer alone, which is the whole point: the cache
# key must not be the source tree.
COPY --chown=opam:opam wand.opam dune-project /deps/
WORKDIR /deps

# Retried here rather than around the whole build, because this is where the
# flake lives and a retry that is part of the layer is cached with it. Three
# failures in a row are not the flake.
RUN set -eu; \
    n=1; \
    until opam install . --deps-only; do \
      if [ "$n" -ge 3 ]; then \
        echo "opam install failed $n times; that is not the flake" >&2; \
        exit 1; \
      fi; \
      echo "opam install failed (attempt $n), trying again" >&2; \
      n=$((n + 1)); \
    done

# A build that reaches the run step with dune missing would fail there in a
# way that reads as wand's fault. It is not, and this says so here.
RUN opam exec -- dune --version
