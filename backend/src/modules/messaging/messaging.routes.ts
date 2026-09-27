import { FastifyInstance } from "fastify";
import { authService } from "@/modules/auth/auth.service";
import { db } from "@/config/database";

function authenticate(req: any): string {
  const token = req.headers.authorization?.replace("Bearer ", "");
  if (!token) throw new Error("Unauthorized");
  return authService.verifyAccessToken(token).sub;
}

export async function messagingRoutes(app: FastifyInstance) {
  // Get conversations for user
  app.get("/conversations", async (req, reply) => {
    try {
      const userId = authenticate(req);
      const conversations = await db.query(
        `SELECT c.*, cm.last_read_at, cm.is_locked,
          (SELECT m.ciphertext FROM messages m WHERE m.conversation_id = c.id AND m.deleted_for_all=false ORDER BY m.created_at DESC LIMIT 1) as last_message_ciphertext,
          (SELECT m.created_at FROM messages m WHERE m.conversation_id = c.id ORDER BY m.created_at DESC LIMIT 1) as last_message_at,
          (SELECT COUNT(*) FROM messages m JOIN message_status ms ON ms.message_id=m.id WHERE m.conversation_id=c.id AND ms.user_id=$1 AND ms.status!='read') as unread_count
         FROM conversations c
         JOIN conversation_members cm ON cm.conversation_id=c.id AND cm.user_id=$1
         ORDER BY last_message_at DESC NULLS LAST`,
        [userId]
      );
      return reply.send({ success: true, conversations });
    } catch (err: any) {
      return reply.status(401).send({ success: false, error: err.message });
    }
  });

  // Get messages for conversation  
  app.get("/conversations/:conversationId/messages", async (req, reply) => {
    try {
      const userId = authenticate(req);
      const { conversationId } = req.params as { conversationId: string };
      const { before, limit = 50 } = req.query as { before?: string; limit?: number };
      
      const member = await db.queryOne("SELECT user_id FROM conversation_members WHERE conversation_id=$1 AND user_id=$2", [conversationId, userId]);
      if (!member) return reply.status(403).send({ error: "Not a member" });

      const messages = await db.query(
        `SELECT m.*, 
          json_agg(DISTINCT jsonb_build_object('userId',mr.user_id,'emoji',mr.emoji)) FILTER (WHERE mr.id IS NOT NULL) as reactions,
          json_agg(DISTINCT jsonb_build_object('userId',ms.user_id,'status',ms.status)) FILTER (WHERE ms.id IS NOT NULL) as statuses
         FROM messages m
         LEFT JOIN message_reactions mr ON mr.message_id=m.id
         LEFT JOIN message_status ms ON ms.message_id=m.id
         WHERE m.conversation_id=$1 AND m.deleted_for_all=false
         ${before ? "AND m.created_at < $3" : ""}
         GROUP BY m.id
         ORDER BY m.created_at DESC LIMIT $2`,
        before ? [conversationId, limit, before] : [conversationId, limit]
      );

      return reply.send({ success: true, messages: messages.reverse() });
    } catch (err: any) {
      return reply.status(400).send({ success: false, error: err.message });
    }
  });

  // Create direct conversation
  app.post("/conversations/direct", async (req, reply) => {
    try {
      const userId = authenticate(req);
      const { targetUserId } = req.body as { targetUserId: string };

      // Check if conversation already exists
      const existing = await db.queryOne(
        `SELECT c.id FROM conversations c
         JOIN conversation_members cm1 ON cm1.conversation_id=c.id AND cm1.user_id=$1
         JOIN conversation_members cm2 ON cm2.conversation_id=c.id AND cm2.user_id=$2
         WHERE c.type='direct'`,
        [userId, targetUserId]
      );
      if (existing) return reply.send({ success: true, conversation: existing });

      const conversation = await db.transaction(async (client) => {
        const convResult = await client.query(
          "INSERT INTO conversations (type, created_by) VALUES ('direct',$1) RETURNING *",
          [userId]
        );
        const conv = convResult.rows[0];
        await client.query(
          "INSERT INTO conversation_members (conversation_id, user_id) VALUES ($1,$2),($1,$3)",
          [conv.id, userId, targetUserId]
        );
        return conv;
      });
      return reply.status(201).send({ success: true, conversation });
    } catch (err: any) {
      return reply.status(400).send({ success: false, error: err.message });
    }
  });

  // Lock/unlock chat
  app.patch("/conversations/:conversationId/lock", async (req, reply) => {
    try {
      const userId = authenticate(req);
      const { conversationId } = req.params as { conversationId: string };
      const { isLocked } = req.body as { isLocked: boolean };
      await db.query(
        "UPDATE conversation_members SET is_locked=$1 WHERE conversation_id=$2 AND user_id=$3",
        [isLocked, conversationId, userId]
      );
      return reply.send({ success: true });
    } catch (err: any) {
      return reply.status(400).send({ success: false, error: err.message });
    }
  });
}
