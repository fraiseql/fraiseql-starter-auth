#!/usr/bin/env bash
# examples/login_flow.sh — Full PKCE Authorization Code flow demonstration
#
# This script walks through every step of the OAuth2 PKCE flow supported by
# FraiseQL's built-in /auth/start and /auth/callback routes. Each step is
# explained inline so you can understand what is happening and why.
#
# Prerequisites:
#   - FraiseQL server running (docker-compose up fraiseql)
#   - openssl installed (brew install openssl / apt install openssl)
#   - curl installed
#   - jq installed for pretty-printing JSON (brew install jq / apt install jq)
#
# Usage:
#   bash examples/login_flow.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo "============================================================"
echo "  FraiseQL PKCE Authorization Code Flow — Step-by-Step Demo"
echo "============================================================"
echo ""
echo "This script demonstrates how a browser-based client would perform"
echo "the full OAuth2 PKCE flow against FraiseQL's auth routes."
echo "In production this flow is handled by a frontend SDK or browser;"
echo "the shell steps here are for learning and debugging only."
echo ""

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BASE_URL="http://localhost:8080"
CLIENT_ID="your-client-id"    # Replace with the client_id registered with your OIDC provider

echo "Configuration:"
echo "  BASE_URL  = $BASE_URL"
echo "  CLIENT_ID = $CLIENT_ID"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Generate the PKCE code_verifier and code_challenge
#
# RFC 7636 requires:
#   code_verifier  = random URL-safe string, 43-128 characters
#   code_challenge = BASE64URL(SHA-256(ASCII(code_verifier)))
# ---------------------------------------------------------------------------
echo "------------------------------------------------------------"
echo "Step 1: Generate PKCE code_verifier and code_challenge"
echo "------------------------------------------------------------"
echo ""
echo "The code_verifier is a secret random value known only to this client."
echo "The code_challenge is its SHA-256 hash, sent to the auth server so it"
echo "can verify the verifier when we exchange the code for tokens."
echo ""

# Generate a 32-byte random value, base64url-encode it (URL-safe alphabet).
CODE_VERIFIER=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')
echo "  code_verifier  = $CODE_VERIFIER"

# Derive the challenge: SHA-256 hash → binary → base64url, strip padding.
CODE_CHALLENGE=$(
  printf '%s' "$CODE_VERIFIER" \
    | openssl dgst -sha256 -binary \
    | openssl base64 \
    | tr '+/' '-_' \
    | tr -d '=\n'
)
echo "  code_challenge = $CODE_CHALLENGE"
echo ""

# ---------------------------------------------------------------------------
# Step 2: Build and display the authorization URL
#
# The user (or browser) visits this URL to authenticate with the OIDC provider.
# FraiseQL generates this URL internally when you call GET /auth/start, but
# here we show the components explicitly for educational purposes.
# ---------------------------------------------------------------------------
echo "------------------------------------------------------------"
echo "Step 2: Build the authorization URL"
echo "------------------------------------------------------------"
echo ""
echo "In a real flow, your frontend calls:"
echo "  GET $BASE_URL/auth/start"
echo ""
echo "FraiseQL generates a state token, stores it encrypted, and redirects"
echo "the browser to the OIDC provider with these parameters:"
echo ""

STATE="example-state-$(openssl rand -hex 8)"   # FraiseQL generates this internally
REDIRECT_URI="$BASE_URL/auth/callback"

AUTH_URL="${BASE_URL}/auth/start?client_id=${CLIENT_ID}&code_challenge=${CODE_CHALLENGE}&code_challenge_method=S256&state=${STATE}&redirect_uri=$(printf '%s' "$REDIRECT_URI" | python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read().strip()))')"

echo "  Authorization URL:"
echo "  $AUTH_URL"
echo ""
echo "Open the URL above in your browser, log in, and you will be redirected"
echo "to: $REDIRECT_URI?code=<authorization_code>&state=$STATE"
echo ""

# ---------------------------------------------------------------------------
# Step 3: Receive the authorization code
#
# After the user authenticates, the OIDC provider redirects back to
# /auth/callback with a one-time code. Here we prompt for it interactively.
# ---------------------------------------------------------------------------
echo "------------------------------------------------------------"
echo "Step 3: Paste the authorization code from the callback URL"
echo "------------------------------------------------------------"
echo ""
echo "After logging in, copy the 'code' query parameter from the URL your"
echo "browser was redirected to and paste it below."
echo "(Press ENTER with an empty value to use the placeholder 'demo-code')"
echo ""
read -rp "  Authorization code: " AUTH_CODE
AUTH_CODE="${AUTH_CODE:-demo-code}"
echo ""
echo "  Using code: $AUTH_CODE"
echo ""

# ---------------------------------------------------------------------------
# Step 4: Exchange the code for tokens
#
# POST to /auth/callback (or a token endpoint) with the code and code_verifier.
# FraiseQL verifies the code_verifier against the stored code_challenge and
# forwards the exchange to the OIDC provider.
# ---------------------------------------------------------------------------
echo "------------------------------------------------------------"
echo "Step 4: Exchange the authorization code for tokens"
echo "------------------------------------------------------------"
echo ""
echo "Sending the code + code_verifier to FraiseQL's callback handler..."
echo ""

TOKEN_RESPONSE=$(
  curl -sf -X POST "$BASE_URL/auth/callback" \
    -H "Content-Type: application/json" \
    -d "{
      \"code\":          \"$AUTH_CODE\",
      \"state\":         \"$STATE\",
      \"code_verifier\": \"$CODE_VERIFIER\"
    }" 2>&1 || echo '{"error":"Could not reach FraiseQL server — is it running?"}'
)

echo "Token response:"
echo "$TOKEN_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$TOKEN_RESPONSE"
echo ""

# Extract the access token if jq is available, else use a placeholder.
ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('access_token', 'YOUR_ACCESS_TOKEN_HERE'))
except Exception:
    print('YOUR_ACCESS_TOKEN_HERE')
")

# ---------------------------------------------------------------------------
# Step 5: Use the access token to make an authenticated GraphQL query
#
# The token contains sub (user UUID) and tenant_id claims. FraiseQL reads
# these via inject= and enforces RLS — the query only returns data belonging
# to the authenticated user's tenant.
# ---------------------------------------------------------------------------
echo "------------------------------------------------------------"
echo "Step 5: Make an authenticated GraphQL query"
echo "------------------------------------------------------------"
echo ""
echo "Using the access token to query currentUser..."
echo ""

QUERY='{"query":"{ currentUser { id email name tenantId role } }"}'

echo "Request:"
echo "  POST $BASE_URL/graphql"
echo "  Authorization: Bearer $ACCESS_TOKEN"
echo "  Body: $QUERY"
echo ""

GRAPHQL_RESPONSE=$(
  curl -sf -X POST "$BASE_URL/graphql" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -d "$QUERY" 2>&1 \
  || echo '{"errors":[{"message":"Could not reach FraiseQL server — is it running?"}]}'
)

echo "Response:"
echo "$GRAPHQL_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$GRAPHQL_RESPONSE"
echo ""
echo "============================================================"
echo "  Flow complete."
echo ""
echo "  Notice: the client never sent user_id or tenant_id in the"
echo "  GraphQL query body. FraiseQL injected them from the JWT,"
echo "  and the database RLS policy enforced tenant isolation."
echo "============================================================"
