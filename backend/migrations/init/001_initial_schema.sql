-- ================================================================
-- Massengar DB Schema v1 - Initial Migration
-- ================================================================

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ================================================================
-- USERS
-- ================================================================
CREATE TABLE IF NOT EXISTS users (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  username        VARCHAR(50) UNIQUE NOT NULL,
  phone_number    VARCHAR(20) UNIQUE NOT NULL,
  email           VARCHAR(255) UNIQUE,
  display_name    VARCHAR(100) NOT NULL,
  avatar_url      TEXT,
  bio             TEXT,
  password_hash   TEXT NOT NULL,

  -- Signal Protocol Identity Keys (stored as base64)
  identity_public_key     TEXT,
  signed_pre_key_id       INTEGER,
  signed_pre_key_public   TEXT,
  signed_pre_key_signature TEXT,
  registration_id         INTEGER,

  -- Account status
  is_verified     BOOLEAN DEFAULT FALSE,
  is_active       BOOLEAN DEFAULT TRUE,
  last_seen       TIMESTAMPTZ DEFAULT NOW(),
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ================================================================
-- ONE-TIME PRE-KEYS (Signal Protocol)
-- ================================================================
CREATE TABLE IF NOT EXISTS one_time_pre_keys (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  key_id          INTEGER NOT NULL,
  public_key      TEXT NOT NULL,
  is_used         BOOLEAN DEFAULT FALSE,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(user_id, key_id)
);

-- ================================================================
-- CONVERSATIONS (Direct / Group)
-- ================================================================
CREATE TABLE IF NOT EXISTS conversations (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  type            VARCHAR(10) NOT NULL CHECK (type IN ('direct', 'group')),
  name            VARCHAR(100),
  avatar_url      TEXT,
  description     TEXT,
  created_by      UUID REFERENCES users(id) ON DELETE SET NULL,

  -- Disappearing messages config
  disappearing_messages_enabled BOOLEAN DEFAULT FALSE,
  disappearing_messages_timer   INTEGER DEFAULT 0, -- seconds (0 = off)

  -- Encryption session data
  sender_chain_key  TEXT,

  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ================================================================
-- CONVERSATION MEMBERS
-- ================================================================
CREATE TABLE IF NOT EXISTS conversation_members (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role            VARCHAR(10) DEFAULT 'member' CHECK (role IN ('admin', 'member')),

  -- Chat lock (per-user, per-chat)
  is_locked       BOOLEAN DEFAULT FALSE,

  joined_at       TIMESTAMPTZ DEFAULT NOW(),
  last_read_at    TIMESTAMPTZ,
  UNIQUE(conversation_id, user_id)
);

-- ================================================================
-- MESSAGES
-- ================================================================
CREATE TABLE IF NOT EXISTS messages (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  sender_id       UUID NOT NULL REFERENCES users(id) ON DELETE SET NULL,

  -- Encrypted payload (ciphertext from Double Ratchet)
  ciphertext      TEXT NOT NULL,
  message_type    VARCHAR(20) DEFAULT 'text' CHECK (message_type IN ('text', 'image', 'video', 'audio', 'document', 'sticker', 'system')),

  -- Thread / reply
  reply_to_id     UUID REFERENCES messages(id) ON DELETE SET NULL,

  -- Ephemeral
  is_view_once    BOOLEAN DEFAULT FALSE,
  viewed_at       TIMESTAMPTZ,
  expires_at      TIMESTAMPTZ, -- disappearing messages

  -- Deletion
  deleted_for_all BOOLEAN DEFAULT FALSE,
  deleted_at      TIMESTAMPTZ,

  -- Signal Protocol ratchet state (per message)
  ratchet_epoch   INTEGER DEFAULT 0,
  message_index   INTEGER DEFAULT 0,

  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_messages_conversation_id ON messages(conversation_id);
CREATE INDEX idx_messages_sender_id ON messages(sender_id);
CREATE INDEX idx_messages_expires_at ON messages(expires_at) WHERE expires_at IS NOT NULL;
CREATE INDEX idx_messages_created_at ON messages(created_at DESC);

-- ================================================================
-- MESSAGE STATUS
-- ================================================================
CREATE TABLE IF NOT EXISTS message_status (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  message_id      UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status          VARCHAR(10) NOT NULL CHECK (status IN ('sent', 'delivered', 'read')),
  updated_at      TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(message_id, user_id)
);

-- ================================================================
-- MESSAGE REACTIONS
-- ================================================================
CREATE TABLE IF NOT EXISTS message_reactions (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  message_id      UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  emoji           VARCHAR(10) NOT NULL,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(message_id, user_id)
);

-- ================================================================
-- MEDIA ASSETS
-- ================================================================
CREATE TABLE IF NOT EXISTS media_assets (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  uploader_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  message_id      UUID REFERENCES messages(id) ON DELETE SET NULL,

  s3_key          TEXT NOT NULL UNIQUE,
  s3_bucket       TEXT NOT NULL,
  mime_type       TEXT NOT NULL,
  file_size       BIGINT NOT NULL,
  file_name       TEXT,
  thumbnail_key   TEXT,

  -- Encryption
  encrypted_key   TEXT, -- media-level AES-256-GCM key, encrypted with sender's key
  iv              TEXT,

  -- Ephemeral
  is_view_once    BOOLEAN DEFAULT FALSE,
  is_purged       BOOLEAN DEFAULT FALSE,
  purged_at       TIMESTAMPTZ,

  duration_secs   INTEGER, -- for audio/video
  width           INTEGER,
  height          INTEGER,

  created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ================================================================
-- STORIES (Status / Ephemeral 24hr)
-- ================================================================
CREATE TABLE IF NOT EXISTS stories (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  author_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  media_asset_id  UUID REFERENCES media_assets(id) ON DELETE SET NULL,

  caption         TEXT,
  background_color VARCHAR(7),
  story_type      VARCHAR(10) DEFAULT 'image' CHECK (story_type IN ('image', 'video', 'text')),

  -- Privacy
  privacy         VARCHAR(10) DEFAULT 'contacts' CHECK (privacy IN ('public', 'contacts', 'close_friends', 'custom')),

  view_count      INTEGER DEFAULT 0,
  expires_at      TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '24 hours'),
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_stories_author_id ON stories(author_id);
CREATE INDEX idx_stories_expires_at ON stories(expires_at);

-- ================================================================
-- STORY VIEWS
-- ================================================================
CREATE TABLE IF NOT EXISTS story_views (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  story_id        UUID NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
  viewer_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  viewed_at       TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(story_id, viewer_id)
);

-- ================================================================
-- CALL RECORDS
-- ================================================================
CREATE TABLE IF NOT EXISTS call_records (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  conversation_id UUID REFERENCES conversations(id) ON DELETE SET NULL,
  caller_id       UUID NOT NULL REFERENCES users(id) ON DELETE SET NULL,
  callee_id       UUID NOT NULL REFERENCES users(id) ON DELETE SET NULL,
  call_type       VARCHAR(10) NOT NULL CHECK (call_type IN ('audio', 'video')),
  status          VARCHAR(15) NOT NULL CHECK (status IN ('initiated', 'ringing', 'accepted', 'rejected', 'missed', 'ended', 'failed')),
  started_at      TIMESTAMPTZ,
  ended_at        TIMESTAMPTZ,
  duration_secs   INTEGER,
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ================================================================
-- REFRESH TOKENS
-- ================================================================
CREATE TABLE IF NOT EXISTS refresh_tokens (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash      TEXT NOT NULL UNIQUE,
  device_info     TEXT,
  ip_address      INET,
  expires_at      TIMESTAMPTZ NOT NULL,
  revoked         BOOLEAN DEFAULT FALSE,
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ================================================================
-- TRIGGERS - auto-update updated_at
-- ================================================================
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_conversations_updated_at BEFORE UPDATE ON conversations FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_messages_updated_at BEFORE UPDATE ON messages FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
