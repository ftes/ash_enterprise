# Multi-stage build producing a self-contained Elixir release.
#
# The two stages exist so the runtime image carries no compiler, no build tools
# and no source: a smaller image with a much smaller attack surface. What ships
# is the release plus the ERTS it was built against.
#
# Versions are pinned to the pairing devenv.nix and CI use. If those three ever
# disagree, "works locally" stops being evidence of anything.

ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=27.3.4.19
ARG DEBIAN_VERSION=bookworm-20261027-slim

# Both images are pinned by digest as well as tag: the tag says what was meant,
# the digest is what is pulled. hexpm publishes four-part OTP versions (27.3.4.19,
# not 27.3.4), and the earlier tag here named an image that does not exist, which
# nothing noticed because nothing built this file. The supply-chain workflow's
# docker job now builds it. Refresh a digest with
#   docker pull <image:tag> && docker image inspect --format '{{index .RepoDigests 0}}' <image:tag>
# The apt packages installed below (build-essential, git, curl, the runtime
# libraries, libxml2-utils) are NOT pinned: they follow the Debian repository
# at build time.
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}@sha256:774e7999a0cc99f0f793c63b1c45ad2fc9d3d8da21cb6e71bdd3e0223d221da0"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3"
# The npm tree is installed by the Node release devenv and CI use, not by
# Debian's packaged npm (9.2), which refuses this lockfile.
ARG NODE_IMAGE="node:22.23.2-bookworm-slim@sha256:48e4b67d85f87bd551df43704e24d252f56cc5f8e9718841aace50f19948f0f9"

# --- assets (npm) ------------------------------------------------------------
FROM ${NODE_IMAGE} AS npm

WORKDIR /app/assets
COPY assets/package.json assets/package-lock.json ./
COPY assets/vendor vendor
# Only what the browser bundle ships: the dev dependencies are the browser
# test tooling.
RUN npm ci --omit=dev

# --- build -------------------------------------------------------------------
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y \
  && apt-get install -y build-essential git curl \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Dependencies are copied and fetched before the application source, so an
# application-only change reuses the cached dependency layer.
COPY mix.exs mix.lock ./
COPY telemetry telemetry
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# config/config.exs and config/prod.exs are compile-time; runtime.exs is not,
# and is copied later so that changing it does not invalidate the dependency
# compilation layer.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

# The npm packages come from the npm stage. esbuild and tailwind are fetched
# as binaries by their mix tasks, so the builder needs no Node toolchain.
COPY --from=npm /app/assets/node_modules assets/node_modules

# Compile before the asset build: compiling writes the colocated hooks and CSS
# (phoenix-colocated) that the tailwind and esbuild entry points import.
RUN mix compile
RUN mix assets.deploy

COPY config/runtime.exs config/
COPY rel rel
# The release copies the control file into its priv (`copy_control_file/1` in mix.exs):
# the freshness sweep and the audit package read it at run time.
COPY docs/controls.json docs/controls.json
RUN mix release

# --- runtime -----------------------------------------------------------------
FROM ${RUNNER_IMAGE}

# `libxml2-utils` provides `xmllint`, and it belongs in the RUNTIME stage rather
# than the builder: `boxic_dmn` (under `ash_decisions`) validates a DMN document
# against the normative XSD by shelling out to it, so it is needed when a model
# LOADS -- not when the release is compiled. Installed in the builder instead,
# every test passes, the image builds, and then every DMN model fails in
# production with `:schema_validator_unavailable`, which reads as "decisions are
# broken" rather than as a missing package.
#
# `AshEnterprise.Application` warns at boot if it is absent, so the failure is
# one line in the log rather than a hunt -- but a warning is not a substitute for
# shipping the dependency.
RUN apt-get update -y \
  && apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates libxml2-utils \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# The BEAM wants a UTF-8 locale; without it, string handling misbehaves in ways
# that are tedious to diagnose.
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

# Runs as a non-root user. A release needs no write access to its own files.
RUN chown nobody /app
ENV MIX_ENV="prod"
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/ash_enterprise ./
USER nobody

# Migrations are NOT run here. Running them from the application container means
# every replica races to migrate on rollout. Run them as a separate step:
#
#   bin/ash_enterprise eval "AshEnterprise.Release.migrate()"
#   bin/ash_enterprise eval "AshEnterprise.Release.seed_privileges()"
#
# See lib/ash_enterprise/release.ex.
CMD ["/app/bin/server"]
