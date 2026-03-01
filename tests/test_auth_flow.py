"""
tests/test_auth_flow.py — Integration tests for the FraiseQL auth example.

These tests communicate with a live FraiseQL server. They are automatically
skipped when the server is unreachable or when FRAISEQL_TEST_JWT_SECRET is
not set. See tests/conftest.py for fixture definitions and skip conditions.

Run with:
    FRAISEQL_TEST_JWT_SECRET=dev-jwt-secret-replace-in-production pytest tests/

To run only integration tests:
    pytest tests/ -m integration

To run only unit tests (no server required):
    pytest tests/ -m "not integration"
"""

import pytest
import httpx


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def graphql_post(base_url: str, query: str, token: str | None = None) -> httpx.Response:
    """
    Send a GraphQL POST request to the FraiseQL server.

    Args:
        base_url: Server base URL.
        query:    GraphQL query string.
        token:    Optional Bearer token. If None, no Authorization header is sent.

    Returns:
        httpx.Response from the server.
    """
    headers = {"Content-Type": "application/json"}
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"

    with httpx.Client(timeout=10.0) as client:
        return client.post(
            f"{base_url}/graphql",
            json={"query": query},
            headers=headers,
        )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.integration
def test_health_check(base_url: str) -> None:
    """
    GET /health returns HTTP 200 with {"status": "ok"}.

    This verifies the server is running and reachable before other tests
    attempt GraphQL queries.
    """
    with httpx.Client(timeout=10.0) as client:
        try:
            response = client.get(f"{base_url}/health")
        except httpx.ConnectError:
            pytest.skip(f"FraiseQL server not reachable at {base_url}")

    assert response.status_code == 200
    body = response.json()
    assert body.get("status") == "ok"


@pytest.mark.integration
def test_graphql_requires_auth(base_url: str) -> None:
    """
    POST /graphql without a token is rejected.

    fraiseql.toml sets default_policy = "authenticated", so FraiseQL rejects
    requests without a valid JWT before executing any SQL. The response must
    be either HTTP 401 or a GraphQL error response (HTTP 200 with errors[]).
    """
    try:
        response = graphql_post(base_url, "{ posts { id title } }", token=None)
    except httpx.ConnectError:
        pytest.skip(f"FraiseQL server not reachable at {base_url}")

    # FraiseQL may return 401 directly or a GraphQL error envelope.
    if response.status_code == 200:
        body = response.json()
        assert "errors" in body, (
            "Expected errors[] in GraphQL response when no token is provided, "
            f"but got: {body}"
        )
    else:
        assert response.status_code == 401, (
            f"Expected 401 Unauthorized, got {response.status_code}"
        )


@pytest.mark.integration
def test_graphql_with_valid_token(
    base_url: str,
    tenant_a_token: str,
) -> None:
    """
    POST /graphql with a valid JWT returns HTTP 200 with a data field.

    Uses the Tenant Alpha JWT (alice@alpha.example). The query asks for the
    list of posts visible to this tenant. A successful response has no top-level
    errors[] and contains a data.posts array (may be empty if no seed data).
    """
    try:
        response = graphql_post(base_url, "{ posts { id title } }", token=tenant_a_token)
    except httpx.ConnectError:
        pytest.skip(f"FraiseQL server not reachable at {base_url}")

    assert response.status_code == 200, (
        f"Expected 200 OK, got {response.status_code}: {response.text}"
    )
    body = response.json()
    assert "errors" not in body or body["errors"] is None, (
        f"Unexpected GraphQL errors with valid token: {body.get('errors')}"
    )
    assert "data" in body, f"Response missing 'data' field: {body}"
    assert "posts" in body["data"], f"Response data missing 'posts': {body['data']}"
    assert isinstance(body["data"]["posts"], list)


@pytest.mark.integration
def test_tenant_isolation(
    base_url: str,
    tenant_a_token: str,
    tenant_b_token: str,
) -> None:
    """
    The same query with different tenant JWTs returns disjoint result sets.

    This is the core multi-tenancy guarantee: inject={"tenant_id": "jwt:tenant_id"}
    in schema.py means the server reads tenant_id exclusively from the JWT, and
    PostgreSQL RLS enforces the WHERE at the database layer.

    With no seed data this test verifies structural isolation (both requests
    succeed and return lists). With seed data from schema.sql it can be
    extended to assert non-overlapping IDs.
    """
    try:
        response_a = graphql_post(base_url, "{ posts { id tenantId } }", token=tenant_a_token)
        response_b = graphql_post(base_url, "{ posts { id tenantId } }", token=tenant_b_token)
    except httpx.ConnectError:
        pytest.skip(f"FraiseQL server not reachable at {base_url}")

    # Both requests must succeed.
    assert response_a.status_code == 200, (
        f"Tenant A request failed: {response_a.status_code} {response_a.text}"
    )
    assert response_b.status_code == 200, (
        f"Tenant B request failed: {response_b.status_code} {response_b.text}"
    )

    body_a = response_a.json()
    body_b = response_b.json()

    assert "data" in body_a, f"Tenant A response missing 'data': {body_a}"
    assert "data" in body_b, f"Tenant B response missing 'data': {body_b}"

    posts_a = body_a["data"]["posts"]
    posts_b = body_b["data"]["posts"]

    assert isinstance(posts_a, list), f"Tenant A posts is not a list: {posts_a}"
    assert isinstance(posts_b, list), f"Tenant B posts is not a list: {posts_b}"

    # When seed data is present, verify no post IDs appear in both result sets.
    ids_a = {post["id"] for post in posts_a}
    ids_b = {post["id"] for post in posts_b}
    overlap = ids_a & ids_b
    assert not overlap, (
        f"Tenant isolation failure: {len(overlap)} post(s) visible to both tenants: {overlap}"
    )

    # Verify every returned post carries the correct tenant_id.
    for post in posts_a:
        assert post.get("tenantId") == "tenant-alpha-uuid", (
            f"Tenant A received post with wrong tenantId: {post}"
        )
    for post in posts_b:
        assert post.get("tenantId") == "tenant-beta-uuid", (
            f"Tenant B received post with wrong tenantId: {post}"
        )
