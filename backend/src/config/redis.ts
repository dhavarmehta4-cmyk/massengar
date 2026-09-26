import { Redis } from "ioredis";
import { config } from "@/config";
import pino from "pino";

const logger = pino({ level: "info" });

export class RedisClient {
  private static instance: RedisClient;
  private client: Redis;
  private subscriber: Redis;
  private publisher: Redis;

  private constructor() {
    const opts = {
      lazyConnect: true,
      retryStrategy: (times: number) => Math.min(times * 100, 3000),
      maxRetriesPerRequest: 3,
    };

    this.client = new Redis(config.redis.url, opts);
    this.subscriber = new Redis(config.redis.url, opts);
    this.publisher = new Redis(config.redis.url, opts);

    this.client.on("error", (err) => logger.error({ err }, "Redis client error"));
    this.subscriber.on("error", (err) => logger.error({ err }, "Redis subscriber error"));
    this.publisher.on("error", (err) => logger.error({ err }, "Redis publisher error"));
  }

  public static getInstance(): RedisClient {
    if (!RedisClient.instance) {
      RedisClient.instance = new RedisClient();
    }
    return RedisClient.instance;
  }

  public async connect(): Promise<void> {
    await Promise.all([
      this.client.connect(),
      this.subscriber.connect(),
      this.publisher.connect(),
    ]);
    logger.info("Redis connections established");
  }

  // -- Presence Engine ------------------------------------------

  public async setUserOnline(userId: string): Promise<void> {
    const key = `presence:${userId}`;
    await this.client.set(key, "online", "EX", config.redis.ttlPresence);
    await this.publisher.publish("presence", JSON.stringify({ userId, status: "online" }));
  }

  public async setUserOffline(userId: string): Promise<void> {
    const key = `presence:${userId}`;
    await this.client.del(key);
    const lastSeenKey = `last_seen:${userId}`;
    await this.client.set(lastSeenKey, Date.now().toString(), "EX", 60 * 60 * 24 * 7);
    await this.publisher.publish("presence", JSON.stringify({ userId, status: "offline", lastSeen: Date.now() }));
  }

  public async getUserPresence(userId: string): Promise<{ status: string; lastSeen?: number }> {
    const presence = await this.client.get(`presence:${userId}`);
    if (presence) return { status: "online" };
    const lastSeen = await this.client.get(`last_seen:${userId}`);
    return { status: "offline", lastSeen: lastSeen ? parseInt(lastSeen) : undefined };
  }

  // -- Typing Indicators -----------------------------------------

  public async setTyping(conversationId: string, userId: string): Promise<void> {
    const key = `typing:${conversationId}:${userId}`;
    await this.client.set(key, "1", "EX", 5);
    await this.publisher.publish(
      `conversation:${conversationId}`,
      JSON.stringify({ type: "typing", userId, isTyping: true })
    );
  }

  public async clearTyping(conversationId: string, userId: string): Promise<void> {
    await this.client.del(`typing:${conversationId}:${userId}`);
    await this.publisher.publish(
      `conversation:${conversationId}`,
      JSON.stringify({ type: "typing", userId, isTyping: false })
    );
  }

  // -- Message TTL / Disappearing Messages ----------------------

  public async scheduleMessageExpiry(messageId: string, expiresAt: Date): Promise<void> {
    const ttl = Math.max(0, Math.floor((expiresAt.getTime() - Date.now()) / 1000));
    await this.client.setex(`expiry:msg:${messageId}`, ttl, messageId);
    await this.client.zadd("expiring_messages", expiresAt.getTime(), messageId);
  }

  public async getExpiredMessages(cutoff: number): Promise<string[]> {
    return this.client.zrangebyscore("expiring_messages", "-inf", cutoff);
  }

  public async removeExpiredMessage(messageId: string): Promise<void> {
    await this.client.zrem("expiring_messages", messageId);
    await this.client.del(`expiry:msg:${messageId}`);
  }

  // -- Socket Mapping ---------------------------------------------

  public async mapUserToSocket(userId: string, socketId: string): Promise<void> {
    await this.client.sadd(`sockets:${userId}`, socketId);
    await this.client.expire(`sockets:${userId}`, config.redis.ttlPresence);
  }

  public async removeSocketMapping(userId: string, socketId: string): Promise<void> {
    await this.client.srem(`sockets:${userId}`, socketId);
  }

  public async getUserSocketIds(userId: string): Promise<string[]> {
    return this.client.smembers(`sockets:${userId}`);
  }

  // -- Pub/Sub ----------------------------------------------------

  public async subscribeToChannel(channel: string, handler: (message: string) => void): Promise<void> {
    await this.subscriber.subscribe(channel);
    this.subscriber.on("message", (ch, msg) => {
      if (ch === channel) handler(msg);
    });
  }

  public async publish(channel: string, message: string): Promise<void> {
    await this.publisher.publish(channel, message);
  }

  public getClient(): Redis {
    return this.client;
  }

  public async healthCheck(): Promise<boolean> {
    try {
      const pong = await this.client.ping();
      return pong === "PONG";
    } catch {
      return false;
    }
  }

  public async disconnect(): Promise<void> {
    await Promise.all([
      this.client.quit(),
      this.subscriber.quit(),
      this.publisher.quit(),
    ]);
  }
}

export const redis = RedisClient.getInstance();
