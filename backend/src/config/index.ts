import dotenv from "dotenv";
dotenv.config();

export const config = {
  nodeEnv: process.env.NODE_ENV || "development",
  port: parseInt(process.env.PORT || "3000"),
  wsPort: parseInt(process.env.WS_PORT || "3001"),

  jwt: {
    secret: process.env.JWT_SECRET!,
    expiresIn: process.env.JWT_EXPIRES_IN || "7d",
    refreshSecret: process.env.JWT_REFRESH_SECRET!,
    refreshExpiresIn: process.env.JWT_REFRESH_EXPIRES_IN || "30d",
  },

  database: {
    url: process.env.DATABASE_URL!,
    poolMin: parseInt(process.env.DB_POOL_MIN || "2"),
    poolMax: parseInt(process.env.DB_POOL_MAX || "10"),
  },

  redis: {
    url: process.env.REDIS_URL!,
    ttlPresence: parseInt(process.env.REDIS_TTL_PRESENCE || "300"),
    ttlSession: parseInt(process.env.REDIS_TTL_SESSION || "604800"),
  },

  s3: {
    endpoint: process.env.S3_ENDPOINT!,
    bucket: process.env.S3_BUCKET!,
    accessKey: process.env.S3_ACCESS_KEY!,
    secretKey: process.env.S3_SECRET_KEY!,
    region: process.env.S3_REGION || "us-east-1",
    presignedUrlExpiry: parseInt(process.env.S3_PRESIGNED_URL_EXPIRY || "3600"),
  },

  turn: {
    secret: process.env.TURN_SECRET!,
    serverUrl: process.env.TURN_SERVER_URL!,
    usernameTtl: parseInt(process.env.TURN_USERNAME_TTL || "86400"),
  },

  encryption: {
    appKey: process.env.APP_ENCRYPTION_KEY!,
  },

  features: {
    disappearingMessages: process.env.ENABLE_DISAPPEARING_MESSAGES === "true",
    disappearingWorkerInterval: parseInt(process.env.DISAPPEARING_MSG_WORKER_INTERVAL || "60000"),
  },
} as const;
