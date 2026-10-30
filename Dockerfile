# Super-Pi-BEAM release image.
#
#   docker build -t super-pi .
#   docker run --rm -e SUPER_PI_GATEWAY=true -e SUPER_PI_GATEWAY_BIND=0.0.0.0 -e SUPER_PI_GATEWAY_TOKEN=change-me \
#     -p 4000:4000 super-pi
#
# The image runs the release (`bin/super_pi start`). Migrations are a separate step:
#   docker run --rm -e SUPER_PI_STORAGE_BACKEND=postgres -e DATABASE_URL=... super-pi bin/super_pi eval "SuperPi.Release.migrate()"

ARG ELIXIR_TAG=1.20.4-otp-28

FROM elixir:${ELIXIR_TAG} AS build
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force

# Dependencies first, so a code change does not refetch them.
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile

COPY lib lib
COPY priv priv
COPY rel rel
RUN mix release super_pi

# The runtime image is the slim image of the same Elixir tag, so the C libraries match the build.
FROM elixir:${ELIXIR_TAG}-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends openssl ca-certificates git tini && rm -rf /var/lib/apt/lists/* \
  && useradd --create-home --uid 10001 superpi
WORKDIR /home/superpi
COPY --from=build --chown=superpi:superpi /app/_build/prod/rel/super_pi ./
USER superpi

# Gateway, epmd and the distribution port range (see rel/env.sh.eex).
EXPOSE 4000 4369 9100-9155
ENV LANG=C.UTF-8 SUPER_PI_GATEWAY=true

HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
  CMD bin/super_pi rpc "case :httpc.request(:get, {~c\"http://127.0.0.1:4000/health\", []}, [], []) do {:ok, {{_, 200, _}, _, _}} -> :ok; _ -> System.halt(1) end" || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["bin/super_pi", "start"]
