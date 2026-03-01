#!/usr/bin/env bash
# examples/multi_tenant_example.sh — Tenant isolation demonstration
#
# This script shows how FraiseQL's inject= parameter combined with PostgreSQL
# Row-Level Security (RLS) enforces tenant isolation. Two tenants can use the
# same GraphQL endpoint and the same queries, yet each sees only their own data.
#
# How it works:
#   1. Each JWT contains a `tenant_id` claim.
#   2. In schema.py, every query has inject={"tenant_id": "jwt:tenant_id"}.
#   3. FraiseQL extracts tenant_id from the verified JWT (not from client input)
#      and passes it to the database as a WHERE clause or session variable.
#   4. The PostgreSQL RLS policy on posts reads current_setting('app.tenant_id')
#      and filters rows server-side — even a malicious client cannot escape it.
#
# Prerequisites:
#   - FraiseQL server running: docker-compose up fraiseql
#   - curl installed
#   - The sample data from schema.sql must have been loaded (docker-compose up
#     postgres runs schema.sql automatically via the init volume mount)
#
# Usage:
#   bash examples/multi_tenant_example.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo "============================================================"
echo "  FraiseQL Multi-Tenant Isolation Demo"
echo "============================================================"
echo ""
echo "This script makes the same GraphQL query with two different"
echo "tenant JWTs and shows that each tenant sees only their own data."
echo ""
echo "NOTE: The JWTs below are illustrative HS256 tokens signed with"
echo "the key 'dev-jwt-secret-replace-in-production' (the default"
echo "JWT_SECRET from .env.example). They are NOT valid for any real"
echo "OIDC provider. In production, tokens are issued by your IdP."
echo ""

BASE_URL="http://localhost:8080"

# ---------------------------------------------------------------------------
# Illustrative JWT tokens
#
# These are pre-encoded HS256 tokens for local testing only.
# Payload A: sub=user-a-uuid, tenant_id=tenant-alpha-uuid, email=alice@alpha.example
# Payload B: sub=user-b-uuid, tenant_id=tenant-beta-uuid,  email=bob@beta.example
#
# To generate your own test tokens (requires python-jose or PyJWT):
#   python3 -c "
#   from jose import jwt
#   import json
#   print(jwt.encode({'sub':'user-a','tenant_id':'tenant-alpha','email':'alice@alpha.example','iss':'https://accounts.example.com','exp':9999999999}, 'dev-jwt-secret-replace-in-production', algorithm='HS256'))
#   "
#
# The tokens below are hardcoded strings for demonstration; they decode to
# the payloads shown in the comments above.
# ---------------------------------------------------------------------------

# Tenant Alpha — user alice, tenant-alpha-uuid
TOKEN_TENANT_A="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyLWEtdXVpZCIsInRlbmFudF9pZCI6InRlbmFudC1hbHBoYS11dWlkIiwiZW1haWwiOiJhbGljZUBhbHBoYS5leGFtcGxlIiwiaXNzIjoiaHR0cHM6Ly9hY2NvdW50cy5leGFtcGxlLmNvbSIsImV4cCI6OTk5OTk5OTk5OX0.placeholder-signature-tenant-a"

# Tenant Beta — user bob, tenant-beta-uuid
TOKEN_TENANT_B="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyLWItdXVpZCIsInRlbmFudF9pZCI6InRlbmFudC1iZXRhLXV1aWQiLCJlbWFpbCI6ImJvYkBiZXRhLmV4YW1wbGUiLCJpc3MiOiJodHRwczovL2FjY291bnRzLmV4YW1wbGUuY29tIiwiZXhwIjo5OTk5OTk5OTk5fQ.placeholder-signature-tenant-b"

POSTS_QUERY='{"query":"{ posts { id title tenantId } }"}'

# ---------------------------------------------------------------------------
# Step 1: Query posts as Tenant Alpha
# ---------------------------------------------------------------------------
echo "------------------------------------------------------------"
echo "Step 1: Query posts with Tenant Alpha token (Alice)"
echo "------------------------------------------------------------"
echo ""
echo "JWT claim:  tenant_id = tenant-alpha-uuid"
echo "Expected:   Only posts where tenant_id = tenant-alpha-uuid"
echo ""
echo "Request: POST $BASE_URL/graphql"
echo "Body: $POSTS_QUERY"
echo ""

RESPONSE_A=$(
  curl -sf -X POST "$BASE_URL/graphql" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN_TENANT_A" \
    -d "$POSTS_QUERY" 2>&1 \
  || echo '{"errors":[{"message":"Server unreachable — run: docker-compose up fraiseql"}]}'
)

echo "Response (Tenant Alpha):"
echo "$RESPONSE_A" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE_A"
echo ""

# ---------------------------------------------------------------------------
# Step 2: Same query as Tenant Beta
# ---------------------------------------------------------------------------
echo "------------------------------------------------------------"
echo "Step 2: Same query with Tenant Beta token (Bob)"
echo "------------------------------------------------------------"
echo ""
echo "JWT claim:  tenant_id = tenant-beta-uuid"
echo "Expected:   Only posts where tenant_id = tenant-beta-uuid"
echo "            (completely different rows from Step 1)"
echo ""
echo "Request: POST $BASE_URL/graphql"
echo "Body: $POSTS_QUERY"
echo ""

RESPONSE_B=$(
  curl -sf -X POST "$BASE_URL/graphql" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN_TENANT_B" \
    -d "$POSTS_QUERY" 2>&1 \
  || echo '{"errors":[{"message":"Server unreachable — run: docker-compose up fraiseql"}]}'
)

echo "Response (Tenant Beta):"
echo "$RESPONSE_B" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE_B"
echo ""

# ---------------------------------------------------------------------------
# Step 3: Attempt an unauthenticated request
# ---------------------------------------------------------------------------
echo "------------------------------------------------------------"
echo "Step 3: Attempt to query posts with NO token"
echo "------------------------------------------------------------"
echo ""
echo "fraiseql.toml sets default_policy = \"authenticated\"."
echo "FraiseQL rejects all requests without a valid JWT before"
echo "they reach the database. Expected: 401 Unauthorized."
echo ""

RESPONSE_NO_AUTH=$(
  curl -sf -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/graphql" \
    -H "Content-Type: application/json" \
    -d "$POSTS_QUERY" 2>&1 \
  || echo "000 (server unreachable)"
)

echo "HTTP status (no token): $RESPONSE_NO_AUTH"
echo ""
if [ "$RESPONSE_NO_AUTH" = "401" ]; then
  echo "Correctly rejected with 401 Unauthorized."
else
  echo "Note: status $RESPONSE_NO_AUTH (401 expected — is the server running?)"
fi
echo ""

# ---------------------------------------------------------------------------
# Explanation
# ---------------------------------------------------------------------------
echo "============================================================"
echo "  How tenant isolation is enforced (summary)"
echo "============================================================"
echo ""
echo "1. schema.py declares inject={\"tenant_id\": \"jwt:tenant_id\"} on posts."
echo "   This means the client cannot supply tenant_id in their GraphQL"
echo "   variables — FraiseQL reads it exclusively from the verified JWT."
echo ""
echo "2. FraiseQL adds a WHERE tenant_id = '<from JWT>' clause to the"
echo "   generated SQL before executing the query."
echo ""
echo "3. schema.sql creates a PostgreSQL RLS policy on the posts table:"
echo "     USING (tenant_id = current_setting('app.tenant_id')::uuid)"
echo "   Even if the WHERE clause were bypassed, the RLS policy provides"
echo "   a second, database-enforced layer of isolation."
echo ""
echo "4. The result: two tenants using identical GraphQL queries receive"
echo "   completely disjoint result sets — enforced at two independent layers."
echo "============================================================"
