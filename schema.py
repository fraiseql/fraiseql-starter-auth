"""
FraiseQL Auth Example Schema

Demonstrates:
- @inject: Server-side context from JWT claims
- Multi-tenant RLS: Row-level security via database policies
- Structured mutation errors via PostgreSQL function return types
"""

import fraiseql
from fraiseql.scalars import ID, UUID, DateTime


# ============================================================================
# Types
# ============================================================================

@fraiseql.type
class User:
    """User model with multi-tenant support."""
    id: ID                     # UUID v4 primary key
    email: str
    name: str
    tenant_id: UUID            # Tenant scoping for RLS
    role: str                  # "admin" | "user"
    created_at: DateTime


@fraiseql.type
class Post:
    """Post model with tenant isolation."""
    id: ID                     # UUID v4 primary key
    title: str
    content: str
    author_id: UUID
    tenant_id: UUID            # RLS enforces this
    published: bool
    created_at: DateTime


# Error types are regular @fraiseql.type definitions used as mutation error payloads.
# The SQL function returns status="failed:*" and populates the metadata JSONB field;
# the FraiseQL runtime copies those fields into the error type automatically.

@fraiseql.type
class CreatePostError:
    """Error payload for create_post mutations."""
    code: str                  # "unauthorized" | "invalid_input" | "conflict"
    message: str               # User-friendly error message


@fraiseql.type
class UpdatePostError:
    """Error payload for update_post mutations."""
    code: str
    message: str


# ============================================================================
# Queries — demonstrating @inject
# ============================================================================

@fraiseql.query(
    sql_source="v_user",
    inject={"user_id": "jwt:sub", "tenant_id": "jwt:tenant_id"},
)
def current_user() -> User:
    """
    Get the currently authenticated user.

    user_id and tenant_id are injected from the JWT token.
    Client cannot pass these values — they come from the verified JWT.

    Security:
    - user_id from jwt:sub (cannot be faked)
    - tenant_id from jwt:tenant_id (cannot be faked)
    - RLS policy enforces: WHERE tenant_id = current_setting('app.tenant_id')
    """
    pass


@fraiseql.query(
    sql_source="v_post",
    inject={"tenant_id": "jwt:tenant_id"},
    auto_params={"limit": True, "where": True},
)
def posts(
    limit: int = 20,
    published: bool | None = None,
) -> list[Post]:
    """
    List posts for the authenticated user's tenant.

    tenant_id is injected — client cannot escape tenant isolation.

    Security:
    - tenant_id injected (not from client)
    - RLS WHERE: tenant_id = tenant_id
    - Client WHERE: published = published (if provided)
    - Effective: WHERE published = ? AND tenant_id = tenant_id
    """
    pass


@fraiseql.query(
    sql_source="v_post",
    inject={"user_id": "jwt:sub", "tenant_id": "jwt:tenant_id"},
    auto_params={"limit": True},
)
def my_posts(limit: int = 20) -> list[Post]:
    """
    List posts written by the current user.

    Both user_id and tenant_id are injected — client has no control over filtering.
    """
    pass


# ============================================================================
# Mutations — demonstrating @inject and error handling
# ============================================================================

@fraiseql.mutation(
    sql_source="fn_create_post",
    operation="CREATE",
    inject={"user_id": "jwt:sub", "tenant_id": "jwt:tenant_id"},
)
def create_post(
    title: str,
    content: str,
) -> Post:
    """
    Create a new post.

    user_id and tenant_id are injected from JWT — not from client input.
    The stored procedure returns mutation_response; on failure the runtime
    populates CreatePostError fields from the metadata JSONB column.
    """
    pass


@fraiseql.mutation(
    sql_source="fn_update_post",
    operation="UPDATE",
    inject={"user_id": "jwt:sub", "tenant_id": "jwt:tenant_id"},
)
def update_post(
    post_id: ID,
    title: str | None = None,
    content: str | None = None,
    published: bool | None = None,
) -> Post:
    """
    Update a post (only the author can update).

    user_id injected to verify ownership. tenant_id injected for isolation.
    """
    pass


# ============================================================================
# Export schema
# ============================================================================

if __name__ == "__main__":
    fraiseql.export_schema("schema.json")
