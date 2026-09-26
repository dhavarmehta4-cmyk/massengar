import "dotenv/config";
import Fastify from "fastify";
import cors from "@fastify/cors";
import { createServer } from "http";
import { Server as SocketIOServer } from "socket.io";
import pino from "pino";

import { config } from "@/config";
import { db } from "@/config/database";
import { redis } from "@/config/redis";
import { setupSocketHandlers } from "@/modules/messaging/socket.handler";
import { authRoutes } from "@/modules/auth/auth.routes";
import { mediaRoutes } from "@/modules/media/media.routes";
import { messagingRoutes } from "@/modules/messaging/messaging.routes";
import { storiesRoutes } from "@/modules/stories/stories.routes";
import { presenceRoutes } from "@/modules/presence/presence.routes";
import { startDisappearingMessagesWorker } from "@/modules/messaging/disappearing.worker";

const logger = pino({
  level: config.nodeEnv === "production" ? "info" : "debug",
  transport: config.nodeEnv !== "production" ? { target: "pino-pretty" } : undefined,
});

async function bootstrap() {
  logger.info("Starting Massengar backend...");

  // -- HTTP / WebSocket Server -----------------------------------
  const app = Fastify({ logger: false });
  const httpServer = createServer(app.server);

  // -- CORS -------------------------------------------------------
  await app.register(cors, {
    origin: config.nodeEnv === "production" ? ["https://massengar.app"] : "*",
    credentials: true,
  });

  // -- Socket.IO --------------------------------------------------
  const io = new SocketIOServer(httpServer, {
    cors: {
      origin: config.nodeEnv === "production" ? ["https://massengar.app"] : "*",
      methods: ["GET", "POST"],
    },
    pingTimeout: 30000,
    pingInterval: 25000,
    transports: ["websocket", "polling"],
  });

  setupSocketHandlers(io);

  // -- REST API Routes ---------------------------------------------
  await app.register(authRoutes, { prefix: "/api/v1/auth" });
  await app.register(mediaRoutes, { prefix: "/api/v1/media" });
  await app.register(messagingRoutes, { prefix: "/api/v1/messages" });
  await app.register(storiesRoutes, { prefix: "/api/v1/stories" });
  await app.register(presenceRoutes, { prefix: "/api/v1/presence" });

  // -- Health Check ------------------------------------------------
  app.get("/health", async (req, reply) => {
    const [dbOk, redisOk] = await Promise.all([
      db.healthCheck(),
      redis.healthCheck(),
    ]);

    const status = dbOk && redisOk ? "healthy" : "degraded";
    return reply.status(dbOk && redisOk ? 200 : 503).send({
      status,
      version: "1.0.0",
      services: {
        database: dbOk ? "ok" : "error",
        redis: redisOk ? "ok" : "error",
      },
      timestamp: new Date().toISOString(),
    });
  });

  // -- Connect Services -------------------------------------------
  logger.info("Connecting to Redis...");
  await redis.connect();
  logger.info("Redis connected");

  logger.info("Verifying database connection...");
  const dbOk = await db.healthCheck();
  if (!dbOk) {
    logger.error("Database connection failed");
    process.exit(1);
  }
  logger.info("Database connected");

  // -- Background Workers -----------------------------------------
  if (config.features.disappearingMessages) {
    startDisappearingMessagesWorker(io);
    logger.info("Disappearing messages worker started");
  }

  // -- Start Listening --------------------------------------------
  await app.ready();
  httpServer.listen(config.port, "0.0.0.0", () => {
    logger.info(`Massengar backend running on port ${config.port}`);
    logger.info(`WebSocket server ready on port ${config.port}`);
    logger.info(`Environment: ${config.nodeEnv}`);
  });

  // -- Graceful Shutdown ------------------------------------------
  const shutdown = async (signal: string) => {
    logger.info({ signal }, "Received shutdown signal");
    try {
      await app.close();
      await redis.disconnect();
      await db.end();
      logger.info("Graceful shutdown complete");
      process.exit(0);
    } catch (err) {
      logger.error({ err }, "Error during shutdown");
      process.exit(1);
    }
  };

  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));
}

bootstrap().catch((err) => {
  console.error("Fatal startup error:", err);
  process.exit(1);
});
