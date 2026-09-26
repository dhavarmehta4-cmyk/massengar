import { FastifyInstance } from "fastify";
import { authService } from "@/modules/auth/auth.service";
import { db } from "@/config/database";

function authenticate(req: any): string {
  const token = req.headers.authorization?.replace("Bearer ", "");
  if (!token) throw new Error("Unauthorized");
  return authService.verifyAccessToken(token).sub;
}

export async function storiesRoutes(app: FastifyInstance) {
  app.post("/", async (req, reply) => {
    try {
      const userId = authenticate(req);
      const body = req.body as any;
      const [story] = await db.query(
        `INSERT INTO stories (author_id, media_asset_id, caption, background_color, story_type, privacy)
         VALUES ($1,$2,$3,$4,$5,$6) RETURNING *`,
        [userId, body.mediaAssetId, body.caption, body.backgroundColor, body.storyType || "image", body.privacy || "contacts"]
      );
      return reply.status(201).send({ success: true, story });
    } catch (err: any) {
      return reply.status(400).send({ success: false, error: err.message });
    }
  });

  app.get("/feed", async (req, reply) => {
    try {
      const userId = authenticate(req);
      const stories = await db.query(
        `SELECT s.*, u.username, u.display_name, u.avatar_url,
          EXISTS(SELECT 1 FROM story_views sv WHERE sv.story_id=s.id AND sv.viewer_id=$1) as viewed
         FROM stories s
         JOIN users u ON u.id=s.author_id
         WHERE s.expires_at > NOW()
         AND (s.privacy='public' OR s.author_id=$1)
         ORDER BY s.created_at DESC`,
        [userId]
      );
      return reply.send({ success: true, stories });
    } catch (err: any) {
      return reply.status(400).send({ success: false, error: err.message });
    }
  });

  app.post("/:storyId/view", async (req, reply) => {
    try {
      const userId = authenticate(req);
      const { storyId } = req.params as { storyId: string };
      await db.query(
        "INSERT INTO story_views (story_id, viewer_id) VALUES ($1,$2) ON CONFLICT DO NOTHING",
        [storyId, userId]
      );
      await db.query("UPDATE stories SET view_count = view_count + 1 WHERE id=$1", [storyId]);
      return reply.send({ success: true });
    } catch (err: any) {
      return reply.status(400).send({ success: false, error: err.message });
    }
  });

  app.delete("/:storyId", async (req, reply) => {
    try {
      const userId = authenticate(req);
      const { storyId } = req.params as { storyId: string };
      await db.query("DELETE FROM stories WHERE id=$1 AND author_id=$2", [storyId, userId]);
      return reply.send({ success: true });
    } catch (err: any) {
      return reply.status(400).send({ success: false, error: err.message });
    }
  });
}
