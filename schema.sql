-- FraiseQL Auth Example: Multi-Tenant Schema with RLS
--
-- Security model:
-- 1. Each user belongs to exactly one tenant
-- 2. RLS policies enforce tenant_id filtering at database level
-- 3. Queries cannot escape tenant isolation even if code is compromised

-- ============================================================================
-- Users Table
--
-- Note on table naming: FraiseQL docs show a tb_* prefix convention (tb_user,
-- tb_post). This starter uses unprefixed names (users, posts) for clarity —
-- the prefix is optional and a project-level choice.
-- ============================================================================

CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    tenant_id UUID NOT NULL,
    role TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('admin', 'user')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- RLS: Users can only see other users in their tenant
ALTER TABLE users ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_users ON users
    USING (tenant_id = (current_setting('app.tenant_id')::UUID));

-- Index for RLS performance
CREATE INDEX idx_users_tenant_id ON users(tenant_id);


-- ============================================================================
-- Posts Table
--
-- Same naming note: posts rather than tb_post.
-- ============================================================================

CREATE TABLE posts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    author_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    tenant_id UUID NOT NULL,
    published BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- RLS: Users can only see posts from their tenant
ALTER TABLE posts ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_posts ON posts
    USING (tenant_id = (current_setting('app.tenant_id')::UUID));

-- Index for RLS performance
CREATE INDEX idx_posts_tenant_id ON posts(tenant_id);
CREATE INDEX idx_posts_author_id ON posts(author_id);


-- ============================================================================
-- Views for GraphQL Queries
-- ============================================================================

-- View for current_user query
CREATE VIEW v_user AS
SELECT
    id,
    email,
    name,
    tenant_id,
    role,
    created_at
FROM users;

-- View for posts query
CREATE VIEW v_post AS
SELECT
    id,
    title,
    content,
    author_id,
    tenant_id,
    published,
    created_at
FROM posts;


-- ============================================================================
-- Mutation Functions (Stored Procedures)
-- ============================================================================

-- Function return type for mutations
CREATE TYPE mutation_response AS (
    status TEXT,
    message TEXT,
    entity_id TEXT,
    entity_type TEXT,
    entity JSONB,
    updated_fields TEXT[],
    cascade JSONB,
    metadata JSONB
);


-- Create Post Mutation
CREATE OR REPLACE FUNCTION fn_create_post(
    p_title TEXT,
    p_content TEXT,
    p_author_id UUID,
    p_tenant_id UUID
) RETURNS mutation_response AS $$
DECLARE
    v_post_id UUID;
    v_author_exists BOOLEAN;
    v_response mutation_response;
BEGIN
    -- Verify author exists and belongs to tenant
    SELECT EXISTS(
        SELECT 1 FROM users
        WHERE id = p_author_id AND tenant_id = p_tenant_id
    ) INTO v_author_exists;

    IF NOT v_author_exists THEN
        RETURN ROW(
            'error',                                    -- status
            'Author not found in tenant',               -- message
            NULL,                                       -- entity_id
            'Post',                                     -- entity_type
            NULL,                                       -- entity
            ARRAY[]::TEXT[],                           -- updated_fields
            NULL,                                       -- cascade
            jsonb_build_object(                         -- metadata
                'code', 'author_not_found',
                'message', 'Author does not exist in this tenant'
            )
        )::mutation_response;
    END IF;

    -- Check for duplicate titles in tenant
    IF EXISTS(SELECT 1 FROM posts WHERE title = p_title AND tenant_id = p_tenant_id) THEN
        RETURN ROW(
            'conflict:duplicate_title',
            'Post with this title already exists',
            NULL,
            'Post',
            NULL,
            ARRAY[]::TEXT[],
            NULL,
            jsonb_build_object('code', 'duplicate_title')
        )::mutation_response;
    END IF;

    -- Create post
    INSERT INTO posts (title, content, author_id, tenant_id)
    VALUES (p_title, p_content, p_author_id, p_tenant_id)
    RETURNING id INTO v_post_id;

    -- Return success
    RETURN ROW(
        'success',
        'Post created successfully',
        v_post_id::TEXT,
        'Post',
        row_to_json(row(v_post_id, p_title, p_content, p_author_id, p_tenant_id, false, NOW())),
        ARRAY[]::TEXT[],
        NULL,
        NULL
    )::mutation_response;

EXCEPTION WHEN OTHERS THEN
    RETURN ROW(
        'error',
        'Unexpected error: ' || SQLERRM,
        NULL,
        'Post',
        NULL,
        ARRAY[]::TEXT[],
        NULL,
        jsonb_build_object('code', 'internal_error')
    )::mutation_response;
END;
$$ LANGUAGE plpgsql;


-- Update Post Mutation
CREATE OR REPLACE FUNCTION fn_update_post(
    p_post_id UUID,
    p_title TEXT,
    p_content TEXT,
    p_published BOOLEAN,
    p_author_id UUID,
    p_tenant_id UUID
) RETURNS mutation_response AS $$
DECLARE
    v_post_exists BOOLEAN;
    v_post_author UUID;
    v_response mutation_response;
BEGIN
    -- Check post exists and belongs to tenant
    SELECT author_id INTO v_post_author
    FROM posts
    WHERE id = p_post_id AND tenant_id = p_tenant_id;

    IF v_post_author IS NULL THEN
        RETURN ROW(
            'error',
            'Post not found',
            NULL,
            'Post',
            NULL,
            ARRAY[]::TEXT[],
            NULL,
            jsonb_build_object('code', 'not_found')
        )::mutation_response;
    END IF;

    -- Verify user is author
    IF v_post_author != p_author_id THEN
        RETURN ROW(
            'error',
            'Only the author can update this post',
            NULL,
            'Post',
            NULL,
            ARRAY[]::TEXT[],
            NULL,
            jsonb_build_object('code', 'unauthorized')
        )::mutation_response;
    END IF;

    -- Update post
    UPDATE posts
    SET
        title = COALESCE(p_title, title),
        content = COALESCE(p_content, content),
        published = COALESCE(p_published, published),
        updated_at = NOW()
    WHERE id = p_post_id;

    -- Return success
    RETURN ROW(
        'success',
        'Post updated successfully',
        p_post_id::TEXT,
        'Post',
        NULL,
        ARRAY['title', 'content', 'published'],
        NULL,
        NULL
    )::mutation_response;

EXCEPTION WHEN OTHERS THEN
    RETURN ROW(
        'error',
        'Unexpected error: ' || SQLERRM,
        NULL,
        'Post',
        NULL,
        ARRAY[]::TEXT[],
        NULL,
        jsonb_build_object('code', 'internal_error')
    )::mutation_response;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- Sample Data
-- ============================================================================

-- Create test tenants
INSERT INTO users (id, email, name, tenant_id, role) VALUES
    ('550e8400-e29b-41d4-a716-446655440001', 'alice@tenant-a.com', 'Alice', '10000000-0000-0000-0000-000000000001', 'admin'),
    ('550e8400-e29b-41d4-a716-446655440002', 'bob@tenant-a.com', 'Bob', '10000000-0000-0000-0000-000000000001', 'user'),
    ('550e8400-e29b-41d4-a716-446655440003', 'charlie@tenant-b.com', 'Charlie', '10000000-0000-0000-0000-000000000002', 'admin');

-- Create test posts
INSERT INTO posts (title, content, author_id, tenant_id, published) VALUES
    ('Hello from Tenant A', 'This is a post in tenant A', '550e8400-e29b-41d4-a716-446655440001', '10000000-0000-0000-0000-000000000001', true),
    ('Another post', 'More content from tenant A', '550e8400-e29b-41d4-a716-446655440002', '10000000-0000-0000-0000-000000000001', false),
    ('Hello from Tenant B', 'This is a post in tenant B', '550e8400-e29b-41d4-a716-446655440003', '10000000-0000-0000-0000-000000000002', true);
