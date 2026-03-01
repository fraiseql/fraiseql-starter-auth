# FraiseQL Auth Starter

**`@inject`, RLS tenant isolation, and structured mutation errors. The most-asked security pattern.**

Focus: JWT claim injection, PostgreSQL row-level security, and typed mutation errors. Not a full framework template.

## Files

- **`schema.py`** — Types, queries, mutations, and `@inject` declarations
- **`fraiseql.toml`** — Database, server, security, and PKCE/OIDC configuration
- **`schema.sql`** — PostgreSQL tables, views, RLS policies, and mutation functions
- **`EXAMPLES.md`** — Detailed walkthroughs of each pattern

## The Three Key Patterns

### 1. Server-Side Context Injection (@inject)

```python
@fraiseql.query(
    sql_source="v_user",
    inject={"user_id": "jwt:sub", "tenant_id": "jwt:tenant_id"},
)
def current_user() -> User:
    """Parameters come from JWT, user cannot override."""
    pass
```

**What happens**:
- User sends GraphQL query (no user_id/tenant_id args — they are not exposed)
- Server decodes JWT: `{"sub": "user-123", "tenant_id": "tenant-456"}`
- Server fills user_id="user-123" and tenant_id="tenant-456"
- User cannot pass different values (validated at execution time)

**Security**: User can only access their own data.

---

### 2. Row-Level Security (RLS)

```sql
CREATE POLICY tenant_isolation ON users
    USING (tenant_id = current_setting('app.tenant_id')::UUID);
```

**What happens**:
- Before each query, server sets: `SET app.tenant_id = '<from-jwt>'`
- PostgreSQL RLS policy automatically filters: `WHERE tenant_id = <from-jwt>`
- User cannot see data from other tenants

**Security**: Even if code is compromised, database enforces isolation.

---

### 3. Structured Mutation Errors

```python
# Error types are plain @fraiseql.type definitions.
# The SQL function populates them via the metadata JSONB column.
@fraiseql.type
class CreatePostError:
    code: str
    message: str

@fraiseql.mutation(
    sql_source="fn_create_post",
    operation="CREATE",
    inject={"user_id": "jwt:sub", "tenant_id": "jwt:tenant_id"},
)
def create_post(title: str, content: str) -> Post:
    pass
```

When mutation fails:

```json
{
  "data": {
    "createPost": {
      "post": null,
      "error": {
        "code": "duplicate_title",
        "message": "Post with this title already exists"
      }
    }
  }
}
```

**Benefit**: Structured error responses without exposing SQL errors.

---

## How They Work Together

1. **@inject** — Parameters come from JWT (non-bypassable)
2. **RLS** — Database enforces tenant filtering (non-bypassable)
3. **Error types** — Mutations return structured errors with error fields

**Result**: Complete multi-tenant isolation even if any single layer fails.

---

## Setup

### 1. Copy and configure environment

```bash
cp .env.example .env
# Edit .env: set DATABASE_URL and JWT_SECRET
```

### 2. Install FraiseQL

```bash
pip install fraiseql
```

### 3. Generate schema.json from Python schema

```bash
python schema.py
# Output: schema.json
```

### 4. Compile to schema.compiled.json

```bash
fraiseql compile
# Reads fraiseql.toml and schema.json automatically
# Output: schema.compiled.json
```

### 5. Start the stack

```bash
docker compose up
# PostgreSQL initialises from schema.sql on first run
# FraiseQL server starts on :8080
```

### Optional: PKCE / OIDC

To enable server-managed OAuth routes (`/auth/start`, `/auth/callback`), set:

```bash
OIDC_CLIENT_SECRET=your-oidc-client-secret
FRAISEQL_STATE_ENCRYPTION_KEY=$(openssl rand -hex 32)
```

Then set `enabled = true` under `[security.pkce]` and `[security.state_encryption]` in `fraiseql.toml`.

---

## Schema vs TOML: What Goes Where

| Concern | File |
|---------|------|
| Types, queries, mutations | `schema.py` |
| `@inject` JWT claim mapping | `schema.py` (per-query) |
| Database URL and pool size | `fraiseql.toml` |
| Server host/port | `fraiseql.toml` |
| Rate limiting, error sanitization | `fraiseql.toml` |
| PKCE / OIDC auth routes | `fraiseql.toml` |
| RLS policies, stored functions | `schema.sql` |

**Note on global inject**: There is no global inject mechanism — each query and
mutation explicitly declares which JWT claims it injects. This is intentional:
security boundaries are visible and auditable at the definition site.

---

## Key Files to Understand

| File | What It Shows |
|------|---------------|
| `schema.py` | `@inject`, error types, multi-tenant queries |
| `schema.sql` | RLS policies, stored procedures, mutation functions |
| `EXAMPLES.md` | Real queries/responses for each pattern |

---

## See Also

- **FraiseQL Docs**: https://docs.fraiseql.rs
- **PostgreSQL RLS**: https://www.postgresql.org/docs/current/ddl-rowsecurity.html
- **OAuth2 PKCE**: https://datatracker.ietf.org/doc/html/rfc7636

## Questions?

See `EXAMPLES.md` for detailed walkthroughs of each pattern.
