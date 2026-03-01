# Set FRAISEQL_V2=true to compile the schema inside the image at build time.
# When false (default), schema.compiled.json must exist on the host before
# building — the file is copied from the build context.
ARG FRAISEQL_V2=false

# ── Stage 1: builder ──────────────────────────────────────────────────────
# Runs `python schema.py && fraiseql compile` to produce schema.compiled.json.
# When FRAISEQL_V2=false (pre-release), creates an empty placeholder so the
# COPY in the runtime stage still succeeds.
FROM ghcr.io/fraiseql/fraiseql:latest AS builder
ARG FRAISEQL_V2
WORKDIR /build
COPY schema.py fraiseql.toml ./
RUN if [ "$FRAISEQL_V2" = "true" ]; then \
      python schema.py && fraiseql compile; \
    else touch schema.compiled.json; fi

# ── Stage 2: runtime ─────────────────────────────────────────────────────
# Minimal image: only fraiseql binary, config, and compiled schema.
FROM ghcr.io/fraiseql/fraiseql:latest AS runtime
WORKDIR /app
COPY fraiseql.toml ./
COPY --from=builder /build/schema.compiled.json ./schema.compiled.json
ENV DATABASE_URL=""
EXPOSE 8080
CMD ["fraiseql", "run"]
