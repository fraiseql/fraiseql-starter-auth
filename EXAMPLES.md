# FraiseQL Auth Example - Query Patterns

This shows the key patterns demonstrated by the schema.

## 1. Injected Context (No User Override Possible)

### Query Definition (schema.py)
```python
@fraiseql.query(
    sql_source="v_user",
    inject={"user_id": "jwt:sub", "tenant_id": "jwt:tenant_id"},
)
def current_user() -> User:
    """Get the currently authenticated user."""
    pass
```

### GraphQL Query (Client)
```graphql
query {
  currentUser {
    id
    email
    name
  }
}
```

### Execution Flow
1. Client sends query (NO user_id or tenant_id in args — they are not exposed)
2. Server decodes JWT: `{"sub": "user-123", "tenant_id": "tenant-456", ...}`
3. Server resolves inject params:
   - `user_id` = "user-123" (from `jwt:sub`)
   - `tenant_id` = "tenant-456" (from `jwt:tenant_id`)
4. Executes query against `v_user` with injected WHERE conditions
5. Client cannot supply or override these values

**Security Guarantee**: User can only query themselves, even if they try to pass different parameters.

---

## 2. Filtered Query with Tenant Isolation

### Query Definition (schema.py)
```python
@fraiseql.query(
    sql_source="v_post",
    inject={"tenant_id": "jwt:tenant_id"},
    auto_params={"limit": True, "where": True},
)
def posts(
    limit: int = 20,
    published: bool | None = None,
) -> list[Post]:
    """List posts from the user's tenant."""
    pass
```

### GraphQL Query (Client)
```graphql
query {
  posts(limit: 10, published: true) {
    id
    title
  }
}
```

### Execution Flow
1. Client sends query with `limit` and `published` filters
2. Server decodes JWT: `{"tenant_id": "tenant-456", ...}`
3. Server resolves inject param:
   - `tenant_id` = "tenant-456" (from JWT)
4. Builds SQL WHERE clause:
   - Application WHERE: `published = true`
   - RLS WHERE: `tenant_id = 'tenant-456'`
   - Effective WHERE: `published = true AND tenant_id = 'tenant-456'`
5. User can filter by publish status but cannot see posts from other tenants

**Security**: RLS always wins. Client can filter within their tenant but never escape tenant isolation.

---

## 3. Error Handling in Mutations

### Type + Mutation Definition (schema.py)
```python
# Error types are plain @fraiseql.type definitions.
# The SQL function populates them via the metadata JSONB field.
@fraiseql.type
class CreatePostError:
    code: str
    message: str

@fraiseql.mutation(
    sql_source="fn_create_post",
    operation="CREATE",
    inject={"user_id": "jwt:sub", "tenant_id": "jwt:tenant_id"},
)
def create_post(
    title: str,
    content: str,
) -> Post:
    """Create a post."""
    pass
```

### GraphQL Mutation (Client)
```graphql
mutation {
  createPost(title: "Hello", content: "World") {
    post {
      id
      title
    }
    error {
      code
      message
    }
  }
}
```

### Success Response
```json
{
  "data": {
    "createPost": {
      "post": {
        "id": "post-uuid",
        "title": "Hello"
      },
      "error": null
    }
  }
}
```

### Conflict Response (Duplicate Title)
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

### Error Response (Author Not Found)
```json
{
  "data": {
    "createPost": {
      "post": null,
      "error": {
        "code": "author_not_found",
        "message": "Author does not exist in this tenant"
      }
    }
  }
}
```

---

## 4. Multi-Tenant Data Isolation

### Two Tenants, Different Data

**Tenant A (tenant_id = 10000000-0000-0000-0000-000000000001)**
- Users: Alice, Bob
- Posts: 2 posts

**Tenant B (tenant_id = 10000000-0000-0000-0000-000000000002)**
- Users: Charlie
- Posts: 1 post

### Query as Alice (Tenant A)
```graphql
query {
  posts(limit: 100) {
    id
    title
  }
}
```

**Response**: Only Alice's tenant posts (Tenant A posts)
```json
{
  "data": {
    "posts": [
      {"id": "post-1", "title": "Hello from Tenant A"},
      {"id": "post-2", "title": "Another post"}
    ]
  }
}
```

### Query as Charlie (Tenant B)
```graphql
query {
  posts(limit: 100) {
    id
    title
  }
}
```

**Response**: Only Charlie's tenant posts (Tenant B posts)
```json
{
  "data": {
    "posts": [
      {"id": "post-3", "title": "Hello from Tenant B"}
    ]
  }
}
```

**Key**: Same query, different results based on tenant_id from JWT. RLS is enforced by the database, not application code.

---

## 5. Authorization Failure

### Query as Unauthenticated User
```graphql
query {
  currentUser {
    id
    name
  }
}
```

**Error**: Validation error (inject params required but no auth)
```json
{
  "errors": [
    {
      "message": "Query requires authentication: inject parameter 'user_id' from 'jwt:sub' requires SecurityContext",
      "path": ["currentUser"]
    }
  ]
}
```

### Mutation as Non-Author

If Alice created a post and Bob tries to update it:

**Mutation**:
```graphql
mutation {
  updatePost(postId: "post-by-alice", title: "Hacked") {
    post { id }
    error { code message }
  }
}
```

**Response**: Unauthorized
```json
{
  "data": {
    "updatePost": {
      "post": null,
      "error": {
        "code": "unauthorized",
        "message": "Only the author can update this post"
      }
    }
  }
}
```

---

## 6. Raw SQL Views (Show What's Happening)

### View for queries
```sql
SELECT * FROM v_user WHERE tenant_id = current_setting('app.tenant_id')::UUID;
```

### Before RLS Check
```sql
SELECT * FROM users;  -- Would show ALL users
```

### After RLS Check (via FraiseQL)
```sql
SELECT * FROM users WHERE tenant_id = current_setting('app.tenant_id')::UUID;
```

The RLS policy makes the database enforce `tenant_id` filtering automatically, even if the application code is compromised.

---

## Testing the Examples

### 1. Set tenant_id in database session
```sql
SET app.tenant_id = '10000000-0000-0000-0000-000000000001';
SELECT * FROM users;  -- Shows only Tenant A users
```

### 2. Switch tenant
```sql
SET app.tenant_id = '10000000-0000-0000-0000-000000000002';
SELECT * FROM users;  -- Shows only Tenant B users
```

### 3. Try to bypass RLS (fails)
```sql
SET app.tenant_id = '10000000-0000-0000-0000-000000000001';
SELECT * FROM users WHERE tenant_id = '10000000-0000-0000-0000-000000000002';  -- Returns 0 rows
```

---

## Key Takeaways

| Pattern | Purpose | Security Level |
|---------|---------|-----------------|
| `inject` | Auto-fill from JWT | User cannot override |
| RLS policies | Database-level filtering | Cannot be bypassed, even with SQL injection |
| Error types | Structured error responses | Clear error codes without exposing internals |
| Multi-tenant views | Isolate data per tenant | Complete isolation at database level |
| Type safety | GraphQL schema validation | Prevents invalid queries |

**Bottom Line**: Even if application code is compromised, the database RLS policies ensure tenant isolation and the injected parameters ensure users cannot access other users' data.
