"""
tests/conftest.py — Shared pytest fixtures and configuration.

Integration tests in this directory communicate with a running FraiseQL server.
They are skipped automatically when the server is not reachable or when the
required environment variables are absent.

Required environment variables for integration tests:
    FRAISEQL_TEST_JWT_SECRET  — HS256 signing secret matching the server's JWT_SECRET.
                                 If absent, all integration tests are skipped.

Optional environment variables:
    FRAISEQL_TEST_BASE_URL    — Server base URL (default: http://localhost:8080).
    FRAISEQL_TEST_OIDC_ISSUER — Issuer claim embedded in test JWTs
                                 (default: https://accounts.example.com).
"""

import os
import time

import pytest


def pytest_configure(config):
    """Register custom markers so pytest does not warn about unknown marks."""
    config.addinivalue_line(
        "markers",
        "integration: marks tests as integration tests requiring a live server",
    )


# ---------------------------------------------------------------------------
# Shared fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session")
def jwt_secret() -> str:
    """
    Return the HS256 JWT signing secret.

    Skips the entire test session if FRAISEQL_TEST_JWT_SECRET is not set,
    preventing spurious failures in CI environments where no server is running.
    """
    secret = os.environ.get("FRAISEQL_TEST_JWT_SECRET", "")
    if not secret:
        pytest.skip(
            "FRAISEQL_TEST_JWT_SECRET not set — skipping integration tests. "
            "Set this env var to run against a live FraiseQL server."
        )
    return secret


@pytest.fixture(scope="session")
def base_url() -> str:
    """Base URL of the FraiseQL server under test."""
    return os.environ.get("FRAISEQL_TEST_BASE_URL", "http://localhost:8080")


@pytest.fixture(scope="session")
def oidc_issuer() -> str:
    """OIDC issuer claim to embed in test JWTs."""
    return os.environ.get(
        "FRAISEQL_TEST_OIDC_ISSUER", "https://accounts.example.com"
    )


def make_test_jwt(
    secret: str,
    issuer: str,
    sub: str = "test-user-uuid",
    tenant_id: str = "test-tenant-uuid",
    email: str = "test@example.com",
    exp_offset: int = 3600,
) -> str:
    """
    Mint an HS256 JWT for use in tests.

    Args:
        secret:     HS256 signing key (must match server's JWT_SECRET).
        issuer:     ``iss`` claim (must match server's oidc_issuer config).
        sub:        Subject (user UUID).
        tenant_id:  Tenant UUID injected into queries via inject=.
        email:      User email claim.
        exp_offset: Seconds from now until expiry (default 1 hour).

    Returns:
        Signed JWT string.
    """
    from jose import jwt

    payload = {
        "sub": sub,
        "tenant_id": tenant_id,
        "email": email,
        "iss": issuer,
        "iat": int(time.time()),
        "exp": int(time.time()) + exp_offset,
    }
    return jwt.encode(payload, secret, algorithm="HS256")


@pytest.fixture(scope="session")
def tenant_a_token(jwt_secret: str, oidc_issuer: str) -> str:
    """JWT for Tenant Alpha / user Alice."""
    return make_test_jwt(
        secret=jwt_secret,
        issuer=oidc_issuer,
        sub="user-a-uuid",
        tenant_id="tenant-alpha-uuid",
        email="alice@alpha.example",
    )


@pytest.fixture(scope="session")
def tenant_b_token(jwt_secret: str, oidc_issuer: str) -> str:
    """JWT for Tenant Beta / user Bob."""
    return make_test_jwt(
        secret=jwt_secret,
        issuer=oidc_issuer,
        sub="user-b-uuid",
        tenant_id="tenant-beta-uuid",
        email="bob@beta.example",
    )
