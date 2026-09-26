import { Server } from "socket.io";
import cron from "node-cron";
import { redis } from "@/config/redis";
import { db } from "@/config/database";
import { mediaService } from "@/modules/media/media.service";
import pino from "pino";

const logger = pino({ level: "info" });

export function startDisappearingMessagesWorker(io: Server): void {
  // -- Disappearing Messages Purge (runs every 60s) -------------
  cron.schedule("* * * * *", async () => {
    try {
      const cutoff = Date.now();
      const expiredMessageIds = await redis.getExpiredMessages(cutoff);

      if (expiredMessageIds.length === 0) return;
      logger.info({ count: expiredMessageIds.length }, "Purging expired messages");

      for (const messageId of expiredMessageIds) {
        try {
          // Get message before deleting (to notify room)
          const [msg] = await db.query<any>(
            "SELECT id, conversation_id, sender_id FROM messages WHERE id=$1",
            [messageId]
          );

          // Purge associated media
          const [mediaAsset] = await db.query<any>(
            "SELECT id FROM media_assets WHERE message_id=$1",
            [messageId]
          );
          if (mediaAsset) {
            await mediaService.purgeAsset(mediaAsset.id);
          }

          // Wipe message content
          await db.query(
            "UPDATE messages SET ciphertext='', deleted_for_all=true, deleted_at=NOW() WHERE id=$1",
            [messageId]
          );

          // Notify conversation members
          if (msg) {
            io.to(`conv:${msg.conversation_id}`).emit("message:expired", {
              messageId,
              conversationId: msg.conversation_id,
            });
          }

          await redis.removeExpiredMessage(messageId);
          logger.debug({ messageId }, "Message expired and purged");
        } catch (err) {
          logger.error({ err, messageId }, "Error purging individual message");
        }
      }
    } catch (err) {
      logger.error({ err }, "Error in disappearing messages worker");
    }
  });

  // -- Stories Expiry (every 5 min) ------------------------------
  cron.schedule("*/5 * * * *", async () => {
    try {
      const expiredStories = await db.query<any>(
        "SELECT id, media_asset_id FROM stories WHERE expires_at <= NOW()",
      );
      
      for (const story of expiredStories) {
        if (story.media_asset_id) {
          await mediaService.purgeAsset(story.media_asset_id).catch(() => {});
        }
        await db.query("DELETE FROM stories WHERE id=$1", [story.id]);
        logger.debug({ storyId: story.id }, "Story expired and deleted");
      }

      if (expiredStories.length > 0) {
        logger.info({ count: expiredStories.length }, "Expired stories purged");
      }
    } catch (err) {
      logger.error({ err }, "Error in stories expiry worker");
    }
  });

  logger.info("Background workers initialized: disappearing-messages, stories-expiry");
}
