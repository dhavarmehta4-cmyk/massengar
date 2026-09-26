import { Server, Socket } from "socket.io";
import { authService } from "@/modules/auth/auth.service";
import { redis } from "@/config/redis";
import { db } from "@/config/database";
import {
  WsPayloadSendMessage, WsPayloadTyping, WsPayloadMessageStatus,
  WsPayloadReaction, WsPayloadDeleteMessage,
  WsPayloadWebRtcOffer, WsPayloadWebRtcAnswer,
  WsPayloadIceCandidate, WsPayloadCallEnd,
} from "@/shared/types";
import pino from "pino";

const logger = pino({ level: "info" });

interface AuthenticatedSocket extends Socket {
  userId: string;
  username: string;
}

export function setupSocketHandlers(io: Server): void {

  // -- Auth Middleware -------------------------------------------
  io.use((socket, next) => {
    try {
      const token = socket.handshake.auth?.token || socket.handshake.headers?.authorization?.replace("Bearer ", "");
      if (!token) return next(new Error("Authentication required"));

      const payload = authService.verifyAccessToken(token);
      (socket as AuthenticatedSocket).userId = payload.sub;
      (socket as AuthenticatedSocket).username = payload.username;
      next();
    } catch {
      next(new Error("Invalid token"));
    }
  });

  io.on("connection", async (socket: Socket) => {
    const s = socket as AuthenticatedSocket;
    const { userId, username } = s;

    logger.info({ userId, username, socketId: s.id }, "User connected via WebSocket");

    // Register presence and socket mapping
    await redis.setUserOnline(userId);
    await redis.mapUserToSocket(userId, s.id);

    // Broadcast online status to conversation rooms
    const userConversations = await getUserConversationIds(userId);
    for (const convId of userConversations) {
      s.join(`conv:${convId}`);
    }
    s.join(`user:${userId}`);

    // Broadcast presence to all conversation rooms
    s.to(userConversations.map(id => `conv:${id}`)).emit("presence:update", {
      userId,
      status: "online",
    });

    // -- Message Events ------------------------------------------

    socket.on("message:send", async (payload: WsPayloadSendMessage, ack) => {
      try {
        const { conversationId, ciphertext, messageType, replyToId, isViewOnce, ratchetEpoch, messageIndex, expiresIn } = payload;

        // Verify user is in conversation
        const member = await db.queryOne(
          "SELECT user_id FROM conversation_members WHERE conversation_id = $1 AND user_id = $2",
          [conversationId, userId]
        );
        if (!member) throw new Error("Not a member of this conversation");

        // Calculate expiry
        let expiresAt: Date | null = null;
        if (expiresIn && expiresIn > 0) {
          expiresAt = new Date(Date.now() + expiresIn * 1000);
        }

        // Persist encrypted message (ciphertext is already E2EE - server never sees plaintext)
        const [message] = await db.query<any>(
          `INSERT INTO messages (conversation_id, sender_id, ciphertext, message_type, reply_to_id, is_view_once, expires_at, ratchet_epoch, message_index)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
           RETURNING id, conversation_id, sender_id, ciphertext, message_type, reply_to_id, is_view_once, expires_at, ratchet_epoch, message_index, created_at`,
          [conversationId, userId, ciphertext, messageType || "text", replyToId || null, isViewOnce || false, expiresAt, ratchetEpoch, messageIndex]
        );

        // Record sent status
        await db.query(
          "INSERT INTO message_status (message_id, user_id, status) VALUES ($1,$2,'sent') ON CONFLICT (message_id,user_id) DO NOTHING",
          [message.id, userId]
        );

        // Schedule expiry in Redis if disappearing
        if (expiresAt) {
          await redis.scheduleMessageExpiry(message.id, expiresAt);
        }

        // Broadcast to all members of conversation (encrypted - server passes through)
        s.to(`conv:${conversationId}`).emit("message:new", {
          ...message,
          status: "sent",
        });

        // Update delivered status for online recipients
        const memberIds = await getConversationMemberIds(conversationId);
        for (const memberId of memberIds) {
          if (memberId === userId) continue;
          const socketIds = await redis.getUserSocketIds(memberId);
          if (socketIds.length > 0) {
            io.to(`user:${memberId}`).emit("message:status", {
              messageId: message.id,
              conversationId,
              status: "delivered",
            });
            await db.query(
              "INSERT INTO message_status (message_id, user_id, status) VALUES ($1,$2,'delivered') ON CONFLICT (message_id,user_id) DO UPDATE SET status='delivered'",
              [message.id, memberId]
            );
          }
        }

        ack?.({ success: true, messageId: message.id });
        logger.info({ userId, conversationId, messageId: message.id }, "Message sent");
      } catch (err: any) {
        logger.error({ err, userId }, "Error sending message");
        ack?.({ success: false, error: err.message });
      }
    });

    // -- Message Status ------------------------------------------

    socket.on("message:read", async (payload: WsPayloadMessageStatus) => {
      try {
        const { messageId, conversationId } = payload;
        await db.query(
          "INSERT INTO message_status (message_id, user_id, status) VALUES ($1,$2,'read') ON CONFLICT (message_id,user_id) DO UPDATE SET status='read', updated_at=NOW()",
          [messageId, userId]
        );

        // Update last_read_at for conversation member
        await db.query(
          "UPDATE conversation_members SET last_read_at = NOW() WHERE conversation_id = $1 AND user_id = $2",
          [conversationId, userId]
        );

        // Notify sender
        const [msg] = await db.query<any>("SELECT sender_id FROM messages WHERE id = $1", [messageId]);
        if (msg) {
          io.to(`user:${msg.sender_id}`).emit("message:status", {
            messageId,
            conversationId,
            status: "read",
            readBy: userId,
          });
        }
      } catch (err) {
        logger.error({ err, userId }, "Error marking message as read");
      }
    });

    // -- Typing Indicators ---------------------------------------

    socket.on("typing:start", async (payload: WsPayloadTyping) => {
      await redis.setTyping(payload.conversationId, userId);
      s.to(`conv:${payload.conversationId}`).emit("typing:update", {
        conversationId: payload.conversationId,
        userId,
        username,
        isTyping: true,
      });
    });

    socket.on("typing:stop", async (payload: WsPayloadTyping) => {
      await redis.clearTyping(payload.conversationId, userId);
      s.to(`conv:${payload.conversationId}`).emit("typing:update", {
        conversationId: payload.conversationId,
        userId,
        isTyping: false,
      });
    });

    // -- Reactions -----------------------------------------------

    socket.on("message:react", async (payload: WsPayloadReaction) => {
      try {
        await db.query(
          "INSERT INTO message_reactions (message_id, user_id, emoji) VALUES ($1,$2,$3) ON CONFLICT (message_id,user_id) DO UPDATE SET emoji = $3",
          [payload.messageId, userId, payload.emoji]
        );
        io.to(`conv:${payload.conversationId}`).emit("message:reaction", {
          messageId: payload.messageId,
          userId,
          emoji: payload.emoji,
        });
      } catch (err) {
        logger.error({ err }, "Error adding reaction");
      }
    });

    socket.on("message:unreact", async (payload: WsPayloadReaction) => {
      try {
        await db.query("DELETE FROM message_reactions WHERE message_id = $1 AND user_id = $2", [payload.messageId, userId]);
        io.to(`conv:${payload.conversationId}`).emit("message:reaction:remove", {
          messageId: payload.messageId,
          userId,
        });
      } catch (err) {
        logger.error({ err }, "Error removing reaction");
      }
    });

    // -- Delete for Everyone -------------------------------------

    socket.on("message:delete", async (payload: WsPayloadDeleteMessage) => {
      try {
        const [msg] = await db.query<any>("SELECT sender_id FROM messages WHERE id = $1", [payload.messageId]);
        if (!msg || msg.sender_id !== userId) throw new Error("Unauthorized");

        if (payload.deleteForAll) {
          await db.query(
            "UPDATE messages SET deleted_for_all = true, ciphertext = '', deleted_at = NOW() WHERE id = $1",
            [payload.messageId]
          );
          io.to(`conv:${payload.conversationId}`).emit("message:deleted", {
            messageId: payload.messageId,
            conversationId: payload.conversationId,
            deleteForAll: true,
          });
        }
      } catch (err) {
        logger.error({ err }, "Error deleting message");
      }
    });

    // -- WebRTC Signaling ----------------------------------------

    socket.on("webrtc:offer", async (payload: WsPayloadWebRtcOffer) => {
      logger.info({ from: userId, to: payload.targetUserId, callId: payload.callId }, "WebRTC offer");
      
      // Create call record
      await db.query(
        "INSERT INTO call_records (id, caller_id, callee_id, call_type, status) VALUES ($1,$2,$3,$4,'ringing')",
        [payload.callId, userId, payload.targetUserId, payload.callType]
      );

      io.to(`user:${payload.targetUserId}`).emit("webrtc:offer", {
        callId: payload.callId,
        fromUserId: userId,
        sdp: payload.sdp,
        callType: payload.callType,
      });
    });

    socket.on("webrtc:answer", async (payload: WsPayloadWebRtcAnswer) => {
      logger.info({ from: userId, callId: payload.callId }, "WebRTC answer");
      await db.query(
        "UPDATE call_records SET status='accepted', started_at=NOW() WHERE id=$1",
        [payload.callId]
      );
      io.to(`user:${payload.targetUserId}`).emit("webrtc:answer", {
        callId: payload.callId,
        fromUserId: userId,
        sdp: payload.sdp,
      });
    });

    socket.on("webrtc:ice-candidate", async (payload: WsPayloadIceCandidate) => {
      io.to(`user:${payload.targetUserId}`).emit("webrtc:ice-candidate", {
        callId: payload.callId,
        fromUserId: userId,
        candidate: payload.candidate,
      });
    });

    socket.on("webrtc:call-end", async (payload: WsPayloadCallEnd) => {
      logger.info({ userId, callId: payload.callId, reason: payload.reason }, "Call ended");
      const statusMap = { ended: "ended", rejected: "rejected", busy: "rejected", failed: "failed" };
      await db.query(
        "UPDATE call_records SET status=$1, ended_at=NOW(), duration_secs=EXTRACT(EPOCH FROM (NOW()-started_at))::int WHERE id=$2",
        [statusMap[payload.reason] || "ended", payload.callId]
      );
      io.to(`user:${payload.targetUserId}`).emit("webrtc:call-end", {
        callId: payload.callId,
        fromUserId: userId,
        reason: payload.reason,
      });
    });

    // -- Disconnect ----------------------------------------------

    socket.on("disconnect", async (reason) => {
      logger.info({ userId, reason }, "User disconnected");
      await redis.removeSocketMapping(userId, s.id);

      // Check if user has other active sockets
      const remaining = await redis.getUserSocketIds(userId);
      if (remaining.length === 0) {
        await redis.setUserOffline(userId);
        await db.query("UPDATE users SET last_seen = NOW() WHERE id = $1", [userId]);

        s.to(userConversations.map(id => `conv:${id}`)).emit("presence:update", {
          userId,
          status: "offline",
          lastSeen: new Date().toISOString(),
        });
      }
    });
  });
}

// -- Helpers --------------------------------------------------------

async function getUserConversationIds(userId: string): Promise<string[]> {
  const rows = await db.query<{ conversation_id: string }>(
    "SELECT conversation_id FROM conversation_members WHERE user_id = $1",
    [userId]
  );
  return rows.map(r => r.conversation_id);
}

async function getConversationMemberIds(conversationId: string): Promise<string[]> {
  const rows = await db.query<{ user_id: string }>(
    "SELECT user_id FROM conversation_members WHERE conversation_id = $1",
    [conversationId]
  );
  return rows.map(r => r.user_id);
}
