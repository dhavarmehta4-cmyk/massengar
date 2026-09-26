# Massengar - Architectural Plan & System Blueprint

## 1. System Overview

Massengar is a cross-platform, end-to-end encrypted real-time chat application providing:
- Direct & group messaging with Double Ratchet E2EE (Signal Protocol)
- 24-hour ephemeral Stories/Status
- WebRTC voice and video calling
- Biometric-protected chat vaults
- Disappearing messages with automated purge

---

## 2. High-Level Architecture

```
+---------------------------------------------------------------------+
¦                        MOBILE CLIENTS (Flutter)                     ¦
¦  +----------+  +----------+  +----------+  +--------------------+  ¦
¦  ¦ Auth     ¦  ¦ Chat     ¦  ¦ Stories  ¦  ¦ WebRTC Call Engine ¦  ¦
¦  ¦ (X3DH    ¦  ¦ (Double  ¦  ¦(Ephemeral¦  ¦(flutter_webrtc +   ¦  ¦
¦  ¦  Setup)  ¦  ¦ Ratchet) ¦  ¦  Media)  ¦  ¦ Coturn STUN/TURN)  ¦  ¦
¦  +----------+  +----------+  +----------+  +--------------------+  ¦
¦       ¦              ¦              ¦                   ¦            ¦
¦  +----?--------------?--------------?-------------------?---------+ ¦
¦  ¦      SQLCipher Local DB (AES-256) + FlutterSecureStorage        ¦ ¦
¦  +-----------------------------------------------------------------+ ¦
+---------------------------------------------------------------------+
                          ¦ HTTPS/WSS
+-------------------------?-------------------------------------------+
¦                     BACKEND (Node.js / Fastify)                     ¦
¦  +------------+  +--------------+  +----------+  +--------------+  ¦
¦  ¦ Auth API   ¦  ¦ Socket.IO    ¦  ¦ Media    ¦  ¦ Background   ¦  ¦
¦  ¦ (JWT+      ¦  ¦ Messaging    ¦  ¦ API (S3  ¦  ¦ Workers      ¦  ¦
¦  ¦  Refresh)  ¦  ¦ + Signaling  ¦  ¦ Presign) ¦  ¦ (Cron Jobs)  ¦  ¦
¦  +------------+  +--------------+  +----------+  +--------------+  ¦
¦       ¦                 ¦               ¦               ¦           ¦
¦  +----?-----------------?---------------?---------------?---------+ ¦
¦  ¦             PostgreSQL 16 + Redis 7 (Pub/Sub + Presence)        ¦ ¦
¦  +-----------------------------------------------------------------+ ¦
+---------------------------------------------------------------------+
                          ¦
+-------------------------?-------------------------------------------+
¦                     INFRASTRUCTURE                                  ¦
¦  +--------------+  +---------------+  +-------------------------+  ¦
¦  ¦ Coturn STUN/ ¦  ¦ S3-compatible ¦  ¦ Docker Compose           ¦  ¦
¦  ¦ TURN Server  ¦  ¦ Object Store  ¦  ¦ (Postgres+Redis+Coturn) ¦  ¦
¦  +--------------+  +---------------+  +-------------------------+  ¦
+---------------------------------------------------------------------+
```

---

## 3. Database Schema (PostgreSQL 16)

### 3.1 Entity Relationship Diagram

```
users --------------------------------------------------------------
  id (PK, UUID)
  username (UNIQUE)
  phone_number (UNIQUE)
  email
  display_name
  avatar_url
  password_hash
  identity_public_key      ? Signal Protocol X25519 identity key
  signed_pre_key_id
  signed_pre_key_public
  signed_pre_key_signature
  registration_id
  is_verified, is_active, last_seen, created_at, updated_at

one_time_pre_keys --------------------------------------------------
  id (PK)
  user_id (FK ? users)
  key_id (INT)
  public_key
  is_used

conversations ------------------------------------------------------
  id (PK, UUID)
  type ('direct' | 'group')
  name, avatar_url, description
  created_by (FK ? users)
  disappearing_messages_enabled (BOOL)
  disappearing_messages_timer (INT, seconds)

conversation_members -----------------------------------------------
  id (PK)
  conversation_id (FK ? conversations)
  user_id (FK ? users)
  role ('admin' | 'member')
  is_locked (BOOL)          ? Per-user chat lock flag
  joined_at, last_read_at

messages -----------------------------------------------------------
  id (PK, UUID)
  conversation_id (FK ? conversations)
  sender_id (FK ? users)
  ciphertext (TEXT)         ? E2EE payload, server-opaque
  message_type
  reply_to_id (FK ? messages)
  is_view_once (BOOL)
  viewed_at
  expires_at                ? For disappearing messages
  deleted_for_all (BOOL)
  ratchet_epoch (INT)
  message_index (INT)
  created_at, updated_at

message_status -----------------------------------------------------
  message_id (FK ? messages)
  user_id (FK ? users)
  status ('sent' | 'delivered' | 'read')    ? ? ?? ??(blue)

message_reactions --------------------------------------------------
  message_id (FK ? messages)
  user_id (FK ? users)
  emoji (VARCHAR(10))

media_assets -------------------------------------------------------
  id (PK, UUID)
  uploader_id (FK ? users)
  message_id (FK ? messages)
  s3_key, s3_bucket, mime_type, file_size
  thumbnail_key
  encrypted_key             ? AES-256-GCM media key (E2EE)
  iv
  is_view_once, is_purged, purged_at

stories ------------------------------------------------------------
  id (PK, UUID)
  author_id (FK ? users)
  media_asset_id (FK ? media_assets)
  caption, background_color
  story_type ('image' | 'video' | 'text')
  privacy ('public' | 'contacts' | 'close_friends' | 'custom')
  view_count, expires_at (24h auto-expiry)

call_records -------------------------------------------------------
  id (PK, UUID)
  caller_id, callee_id (FK ? users)
  call_type ('audio' | 'video')
  status ('initiated' | 'ringing' | 'accepted' | 'rejected' | 'ended')
  started_at, ended_at, duration_secs

refresh_tokens -----------------------------------------------------
  user_id (FK ? users)
  token_hash (BCRYPT)
  expires_at, revoked
```

---

## 4. WebSocket Event Payload Formats (Socket.IO)

### 4.1 Message Events
```json
// Client ? Server: Send Message
{
  "event": "message:send",
  "payload": {
    "conversationId": "uuid",
    "ciphertext": "base64-encoded-E2EE-ciphertext",
    "messageType": "text|image|video|audio|document",
    "replyToId": "uuid|null",
    "isViewOnce": false,
    "mediaAssetId": "uuid|null",
    "ratchetEpoch": 0,
    "messageIndex": 42,
    "expiresIn": 86400
  }
}

// Server ? Client: New Message Broadcast
{
  "event": "message:new",
  "payload": {
    "id": "uuid",
    "conversationId": "uuid",
    "senderId": "uuid",
    "ciphertext": "base64-encoded-E2EE-ciphertext",
    "messageType": "text",
    "ratchetEpoch": 0,
    "messageIndex": 42,
    "createdAt": "ISO8601",
    "status": "sent"
  }
}

// Message Status Update: ? ?? ??(blue)
{
  "event": "message:status",
  "payload": {
    "messageId": "uuid",
    "conversationId": "uuid",
    "status": "delivered|read",
    "readBy": "userId"
  }
}

// Typing Indicator
{
  "event": "typing:update",
  "payload": {
    "conversationId": "uuid",
    "userId": "uuid",
    "username": "alice",
    "isTyping": true
  }
}

// Reaction
{
  "event": "message:reaction",
  "payload": {
    "messageId": "uuid",
    "userId": "uuid",
    "emoji": "??"
  }
}

// Disappearing Message Expiry
{
  "event": "message:expired",
  "payload": {
    "messageId": "uuid",
    "conversationId": "uuid"
  }
}
```

### 4.2 Presence Events
```json
// Presence Update
{
  "event": "presence:update",
  "payload": {
    "userId": "uuid",
    "status": "online|offline",
    "lastSeen": "ISO8601"
  }
}
```

### 4.3 WebRTC Signaling Events
```json
// Offer
{
  "event": "webrtc:offer",
  "payload": {
    "callId": "uuid",
    "fromUserId": "uuid",
    "sdp": { "type": "offer", "sdp": "..." },
    "callType": "audio|video"
  }
}

// Answer
{
  "event": "webrtc:answer",
  "payload": {
    "callId": "uuid",
    "fromUserId": "uuid",
    "sdp": { "type": "answer", "sdp": "..." }
  }
}

// ICE Candidate
{
  "event": "webrtc:ice-candidate",
  "payload": {
    "callId": "uuid",
    "fromUserId": "uuid",
    "candidate": { "candidate": "...", "sdpMid": "0", "sdpMLineIndex": 0 }
  }
}

// Call End
{
  "event": "webrtc:call-end",
  "payload": {
    "callId": "uuid",
    "fromUserId": "uuid",
    "reason": "ended|rejected|busy|failed"
  }
}
```

---

## 5. E2EE Key Distribution Model (Signal Protocol)

### 5.1 X3DH Session Establishment

```
Alice                              Server                           Bob
  |                                  |                               |
  |-- GET /api/v1/auth/key-bundle/Bob --?¦                           |
  |                                  ¦-- SELECT one-time prekey --?  |
  |?-- { identityKey, signedPreKey,  ¦                               |
  |      signedPreKeySig, otpk }     ¦                               |
  |                                  |                               |
  |-- X3DH compute: ----------------------------------------------- |
  |   DH1 = IK_A × SPK_B            |                               |
  |   DH2 = EK_A × IK_B             |                               |
  |   DH3 = EK_A × SPK_B            |                               |
  |   DH4 = EK_A × OPK_B (optional) |                               |
  |   SK  = HKDF(DH1||DH2||DH3||DH4)|                               |
  |                                  |                               |
  |-- Init Double Ratchet (SK) ------------------------------------ |
  |   Root key = SK                  |                               |
  |   Alice sends first msg with DH ratchet step                     |
```

### 5.2 Double Ratchet Message Keys

Each message derives a unique symmetric key:
```
Root Key + DH Output --HKDF--? New Root Key + Chain Key
Chain Key --HKDF--? Next Chain Key + Message Key
Message Key --AES-256-GCM--? Encrypted Ciphertext
```

**Properties:**
- **Forward Secrecy**: Compromising future session state cannot reveal past messages
- **Break-in Recovery**: Each DH ratchet step renews all key material
- **Per-message unique keys**: No two messages share a key

### 5.3 Media Encryption
```
Original File
    ¦
    ?
AES-256-GCM (random 256-bit key + 96-bit nonce)
    ¦
    +-- Encrypted Blob ------? S3 (.enc extension)
    +-- media_key (encrypted with sender's session key) --? DB
```

---

## 6. Redis Data Structures

| Key Pattern               | Type     | TTL         | Purpose                    |
|---------------------------|----------|-------------|----------------------------|
| `presence:{userId}`       | STRING   | 300s        | Online presence flag        |
| `last_seen:{userId}`      | STRING   | 7 days      | Last seen timestamp         |
| `sockets:{userId}`        | SET      | 300s        | Socket ID mappings          |
| `typing:{convId}:{userId}`| STRING   | 5s          | Typing indicator TTL        |
| `expiring_messages`       | ZSET     | Persistent  | Sorted by expiry timestamp  |
| `expiry:msg:{msgId}`      | STRING   | Dynamic     | Per-message expiry key      |
| `conversation:{convId}`   | CHANNEL  | -           | Pub/Sub channel per chat    |
| `presence`                | CHANNEL  | -           | Global presence pub/sub     |

---

## 7. Flutter Clean Architecture Layers

```
mobile_app/lib/
+-- core/
¦   +-- network/        # HTTP client, Socket.IO client, interceptors
¦   +-- security/       # DoubleRatchetEngine, BiometricLockService,
¦   ¦                   # SQLCipher DB, ScreenSecurityService
¦   +-- storage/        # LocalDatabase (SQLCipher), SecureStorage
¦   +-- utils/          # Extensions, date helpers
¦
+-- data/
¦   +-- datasources/
¦   ¦   +-- remote/     # AuthRemoteDS, MessagingRemoteDS, MediaRemoteDS
¦   ¦   +-- local/      # MessagingLocalDS, UserLocalDS
¦   +-- models/         # UserModel, MessageModel, ConversationModel
¦   +-- repositories/  # Implementations of domain repositories
¦
+-- domain/
¦   +-- entities/       # User, Message, Conversation, Story, CallRecord
¦   +-- repositories/   # Abstract interfaces
¦   +-- usecases/
¦       +-- auth/       # Register, Login, Logout, GetKeyBundle
¦       +-- messaging/  # SendMessage, GetMessages, MarkRead, DeleteMessage
¦       +-- media/      # UploadMedia, DownloadMedia (view-once aware)
¦       +-- calls/      # WebRtcService, StartCall, EndCall
¦
+-- presentation/
    +-- blocs/          # AuthBloc, ChatBloc, CallsBloc (BLoC pattern)
    +-- screens/
    ¦   +-- auth/       # LoginScreen, RegisterScreen
    ¦   +-- chat/       # ChatListScreen, DirectMessageScreen,
    ¦   ¦               # LockedChatsScreen, BiometricUnlockScreen
    ¦   +-- stories/    # StoriesFeedScreen, StoryViewerScreen
    ¦   +-- calls/      # VoiceCallScreen, VideoCallScreen,
    ¦   ¦               # IncomingCallScreen
    ¦   +-- profile/    # ProfileScreen, SettingsScreen
    +-- widgets/        # MessageBubble, StoryRing, CallButton, etc.
    +-- theme/          # AppTheme (dark mode glassmorphism design)
```

---

## 8. Security Architecture Summary

| Layer               | Technology               | What It Protects                    |
|---------------------|--------------------------|-------------------------------------|
| Transport           | TLS 1.3 (HTTPS/WSS)     | In-transit encryption               |
| Message Encryption  | Signal Protocol/X3DH+DR  | Message content (E2EE)              |
| Media Encryption    | AES-256-GCM              | Files stored in S3                  |
| Local DB            | SQLCipher (AES-256)      | Local message cache on device       |
| Key Storage         | OS KeyStore/Keychain     | Encryption keys never leave TEE     |
| Chat Lock           | Biometrics (FaceID/FP)   | Individual conversation vaults      |
| Anti-Screenshot     | FLAG_SECURE / iOS Mask   | Prevents capture of locked content  |
| Auth Tokens         | JWT (RS256) + Refresh    | API authentication                  |
| TURN Auth           | HMAC-SHA1 Time-limited   | WebRTC relay credentials            |

---

## 9. Phase Implementation Status

| Phase | Feature                           | Status   |
|-------|-----------------------------------|----------|
| 1     | Project scaffold & Docker infra   | ? DONE  |
| 1     | PostgreSQL schema migrations      | ? DONE  |
| 1     | Redis configuration               | ? DONE  |
| 1     | TypeScript/ESLint setup           | ? DONE  |
| 2     | JWT auth + registration           | ? DONE  |
| 2     | Socket.IO messaging               | ? DONE  |
| 2     | Double Ratchet E2EE engine        | ? DONE  |
| 2     | Typing indicators, presence       | ? DONE  |
| 2     | Message status (? ?? ??blue)     | ? DONE  |
| 2     | Reactions, replies, delete-all    | ? DONE  |
| 2     | E2EE unit tests (19/19)           | ? DONE  |
| 3     | S3 presigned upload URLs          | ? DONE  |
| 3     | View-once media engine            | ? DONE  |
| 3     | Disappearing messages worker      | ? DONE  |
| 3     | Stories (24h ephemeral)           | ? DONE  |
| 4     | SQLCipher local database          | ? DONE  |
| 4     | Biometric authentication service  | ? DONE  |
| 4     | Chat lock / hidden vault          | ? DONE  |
| 4     | Anti-screenshot (FLAG_SECURE)     | ? DONE  |
| 5     | WebRTC signaling server           | ? DONE  |
| 5     | Flutter WebRTC call service       | ? DONE  |
| 5     | Coturn STUN/TURN configuration    | ? DONE  |
