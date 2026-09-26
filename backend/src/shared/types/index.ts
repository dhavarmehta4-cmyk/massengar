// ================================================================
// Massengar - Core Shared Types
// ================================================================

export interface User {
  id: string;
  username: string;
  phoneNumber: string;
  email?: string;
  displayName: string;
  avatarUrl?: string;
  bio?: string;
  isVerified: boolean;
  isActive: boolean;
  lastSeen: Date;
  createdAt: Date;
  identityPublicKey?: string;
  signedPreKeyId?: number;
  signedPreKeyPublic?: string;
  signedPreKeySignature?: string;
  registrationId?: number;
}

export interface Conversation {
  id: string;
  type: "direct" | "group";
  name?: string;
  avatarUrl?: string;
  description?: string;
  createdBy?: string;
  disappearingMessagesEnabled: boolean;
  disappearingMessagesTimer: number;
  createdAt: Date;
  updatedAt: Date;
}

export interface Message {
  id: string;
  conversationId: string;
  senderId: string;
  ciphertext: string;
  messageType: "text" | "image" | "video" | "audio" | "document" | "sticker" | "system";
  replyToId?: string;
  isViewOnce: boolean;
  viewedAt?: Date;
  expiresAt?: Date;
  deletedForAll: boolean;
  deletedAt?: Date;
  ratchetEpoch: number;
  messageIndex: number;
  createdAt: Date;
  updatedAt: Date;
}

export interface MessageStatus {
  messageId: string;
  userId: string;
  status: "sent" | "delivered" | "read";
  updatedAt: Date;
}

export interface MediaAsset {
  id: string;
  uploaderId: string;
  messageId?: string;
  s3Key: string;
  s3Bucket: string;
  mimeType: string;
  fileSize: number;
  fileName?: string;
  thumbnailKey?: string;
  encryptedKey?: string;
  iv?: string;
  isViewOnce: boolean;
  isPurged: boolean;
  purgedAt?: Date;
  durationSecs?: number;
  width?: number;
  height?: number;
  createdAt: Date;
}

export interface Story {
  id: string;
  authorId: string;
  mediaAssetId?: string;
  caption?: string;
  backgroundColor?: string;
  storyType: "image" | "video" | "text";
  privacy: "public" | "contacts" | "close_friends" | "custom";
  viewCount: number;
  expiresAt: Date;
  createdAt: Date;
}

export interface CallRecord {
  id: string;
  conversationId?: string;
  callerId: string;
  calleeId: string;
  callType: "audio" | "video";
  status: "initiated" | "ringing" | "accepted" | "rejected" | "missed" | "ended" | "failed";
  startedAt?: Date;
  endedAt?: Date;
  durationSecs?: number;
  createdAt: Date;
}

// -- WebSocket Event Payloads ------------------------------------

export interface WsPayloadSendMessage {
  conversationId: string;
  ciphertext: string;
  messageType: string;
  replyToId?: string;
  isViewOnce?: boolean;
  mediaAssetId?: string;
  ratchetEpoch: number;
  messageIndex: number;
  expiresIn?: number; // seconds, 0 = no expiry
}

export interface WsPayloadTyping {
  conversationId: string;
  isTyping: boolean;
}

export interface WsPayloadMessageStatus {
  messageId: string;
  conversationId: string;
  status: "delivered" | "read";
}

export interface WsPayloadReaction {
  messageId: string;
  conversationId: string;
  emoji: string;
}

export interface WsPayloadDeleteMessage {
  messageId: string;
  conversationId: string;
  deleteForAll: boolean;
}

// WebRTC Signaling
export interface WsPayloadWebRtcOffer {
  callId: string;
  targetUserId: string;
  sdp: RTCSessionDescriptionInit;
  callType: "audio" | "video";
}

export interface WsPayloadWebRtcAnswer {
  callId: string;
  targetUserId: string;
  sdp: RTCSessionDescriptionInit;
}

export interface WsPayloadIceCandidate {
  callId: string;
  targetUserId: string;
  candidate: RTCIceCandidateInit;
}

export interface WsPayloadCallEnd {
  callId: string;
  targetUserId: string;
  reason: "ended" | "rejected" | "busy" | "failed";
}

// -- Signal Protocol Key Bundle ----------------------------------

export interface SignalKeyBundle {
  registrationId: number;
  identityPublicKey: string;
  signedPreKeyId: number;
  signedPreKeyPublic: string;
  signedPreKeySignature: string;
  oneTimePreKeys: Array<{ id: number; publicKey: string }>;
}

// -- JWT Payload -------------------------------------------------

export interface JwtPayload {
  sub: string; // user id
  username: string;
  iat: number;
  exp: number;
}
