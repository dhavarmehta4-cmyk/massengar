import { FastifyInstance } from "fastify";
import { authService } from "@/modules/auth/auth.service";
import { redis } from "@/config/redis";
import { db } from "@/config/database";

function authenticate(req: any): string {
  const token = req.headers.authorization?.replace("Bearer ", "");
  if (!token) throw new Error("Unauthorized");
  return authService.verifyAccessToken(token).sub;
}

export async function presenceRoutes(app: FastifyInstance) {
  app.get("/:userId", async (req, reply) => {
    try {
      authenticate(req);
      const { userId } = req.params as { userId: string };
      const presence = await redis.getUserPresence(userId);
      return reply.send({ success: true, ...presence });
    } catch (err: any) {
      return reply.status(401).send({ success: false, error: err.message });
    }
  });

  // TURN credentials endpoint for WebRTC
  app.get("/turn-credentials", async (req, reply) => {
    try {
      authenticate(req);
      const crypto = await import("crypto");
      const { config } = await import("@/config");
      const timestamp = Math.floor(Date.now() / 1000) + config.turn.usernameTtl;
      const username = `${timestamp}:massengar`;
      const credential = crypto.default.createHmac("sha1", config.turn.secret).update(username).digest("base64");
      return reply.send({
        success: true,
        iceServers: [
          { urls: "stun:stun.l.google.com:19302" },
          { urls: config.turn.serverUrl, username, credential },
        ],
      });
    } catch (err: any) {
      return reply.status(401).send({ success: false, error: err.message });
    }
  });
}
