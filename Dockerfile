# ── Stage 1: builder ──────────────────────────────────────────────────────
# Runs `python schema.py && fraiseql compile` to produce schema.compiled.json.
FROM ghcr.io/fraiseql/fraiseql:v2.0.0 AS builder
WORKDIR /build
COPY schema.py fraiseql.toml ./
RUN python schema.py && fraiseql compile

# ── Stage 2: runtime ─────────────────────────────────────────────────────
# Minimal image: only fraiseql binary, config, and compiled schema.
FROM ghcr.io/fraiseql/fraiseql:v2.0.0 AS runtime
WORKDIR /app
COPY fraiseql.toml ./
COPY --from=builder /build/schema.compiled.json ./schema.compiled.json
ENV DATABASE_URL=""
EXPOSE 8080
CMD ["fraiseql", "run"]
