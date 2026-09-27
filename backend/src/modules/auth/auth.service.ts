import bcrypt from "bcrypt";
import jwt from "jsonwebtoken";
import { v4 as uuidv4 } from "uuid";
import { db } from "@/config/database";
import { config } from "@/config";
import { User, JwtPayload, SignalKeyBundle } from "@/shared/types";

const SALT_ROUNDS = 12;

export class AuthService {

  // -- Registration ---------------------------------------------

  async register(payload: {
    username: string;
    phoneNumber: string;
    email?: string;
    displayName: string;
    password: string;
    keyBundle: SignalKeyBundle;
  }): Promise<{ user: Partial<User>; accessToken: string; refreshToken: string }> {

    const passwordHash = await bcrypt.hash(payload.password, SALT_ROUNDS);

    const existing = await db.queryOne<User>(
      "SELECT id FROM users WHERE username = $1 OR phone_number = $2",
      [payload.username, payload.phoneNumber]
    );

    if (existing) {
      throw new Error("Username or phone number already registered");
    }

    const user = await db.queryOne<User>(
      `INSERT INTO users (
        username, phone_number, email, display_name, password_hash,
        identity_public_key, signed_pre_key_id, signed_pre_key_public,
        signed_pre_key_signature, registration_id, is_verified
      ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,true)
      RETURNING id, username, display_name, phone_number, email, avatar_url, is_verified, created_at`,
      [
        payload.username,
        payload.phoneNumber,
        payload.email ?? null,
        payload.displayName,
        passwordHash,
        payload.keyBundle.identityPublicKey,
        payload.keyBundle.signedPreKeyId,
        payload.keyBundle.signedPreKeyPublic,
        payload.keyBundle.signedPreKeySignature,
        payload.keyBundle.registrationId,
      ]
    );

    if (!user) throw new Error("Failed to create user");

    // Store one-time pre-keys
    for (const preKey of payload.keyBundle.oneTimePreKeys) {
      await db.query(
        "INSERT INTO one_time_pre_keys (user_id, key_id, public_key) VALUES ($1,$2,$3)",
        [user.id, preKey.id, preKey.publicKey]
      );
    }

    const { accessToken, refreshToken } = await this.generateTokens(user as User);
    return { user, accessToken, refreshToken };
  }

  // -- Login -----------------------------------------------------

  async login(
    usernameOrPhone: string,
    password: string
  ): Promise<{ user: Partial<User>; accessToken: string; refreshToken: string }> {

    const user = await db.queryOne<User & { password_hash: string; is_active: boolean }>(
      `SELECT id, username, display_name, phone_number, email, avatar_url,
              password_hash, is_active, is_verified
       FROM users
       WHERE username = $1 OR phone_number = $1`,
      [usernameOrPhone]
    );

    if (!user) throw new Error("Invalid credentials");
    if (!user.is_active) throw new Error("Account is deactivated");

    const isValid = await bcrypt.compare(password, user.password_hash);
    if (!isValid) throw new Error("Invalid credentials");

    // Update last_seen
    await db.query("UPDATE users SET last_seen = NOW() WHERE id = $1", [user.id]);

    const { accessToken, refreshToken } = await this.generateTokens(user);
    const { password_hash, ...safeUser } = user;
    return { user: safeUser, accessToken, refreshToken };
  }

  // -- Key Bundle (Signal Protocol) -----------------------------

  async getKeyBundle(userId: string): Promise<SignalKeyBundle | null> {
    const user = await db.queryOne<any>(
      `SELECT registration_id, identity_public_key, signed_pre_key_id,
              signed_pre_key_public, signed_pre_key_signature
       FROM users WHERE id = $1`,
      [userId]
    );

    if (!user) return null;

    const preKey = await db.queryOne<any>(
      `UPDATE one_time_pre_keys SET is_used = true
       WHERE id = (
         SELECT id FROM one_time_pre_keys
         WHERE user_id = $1 AND is_used = false
         ORDER BY key_id ASC LIMIT 1
       ) RETURNING key_id, public_key`,
      [userId]
    );

    return {
      registrationId: user.registration_id,
      identityPublicKey: user.identity_public_key,
      signedPreKeyId: user.signed_pre_key_id,
      signedPreKeyPublic: user.signed_pre_key_public,
      signedPreKeySignature: user.signed_pre_key_signature,
      oneTimePreKeys: preKey ? [{ id: preKey.key_id, publicKey: preKey.public_key }] : [],
    };
  }

  // -- Token Management -----------------------------------------

  async generateTokens(user: Pick<User, "id" | "username">): Promise<{
    accessToken: string;
    refreshToken: string;
  }> {
    const payload: Omit<JwtPayload, "iat" | "exp"> = {
      sub: user.id,
      username: user.username,
    };

    const accessToken = jwt.sign(payload, config.jwt.secret, {
      expiresIn: config.jwt.expiresIn,
    } as any);

    const refreshToken = jwt.sign(payload, config.jwt.refreshSecret, {
      expiresIn: config.jwt.refreshExpiresIn,
    } as any);

    // Store refresh token hash
    const tokenHash = await bcrypt.hash(refreshToken, 6);
    const expiresAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);

    await db.query(
      "INSERT INTO refresh_tokens (user_id, token_hash, expires_at) VALUES ($1,$2,$3)",
      [user.id, tokenHash, expiresAt]
    );

    return { accessToken, refreshToken };
  }

  verifyAccessToken(token: string): JwtPayload {
    return jwt.verify(token, config.jwt.secret) as JwtPayload;
  }

  async refreshAccessToken(refreshToken: string): Promise<{ accessToken: string }> {
    const payload = jwt.verify(refreshToken, config.jwt.refreshSecret) as JwtPayload;

    const tokens = await db.query<{ token_hash: string; revoked: boolean }>(
      "SELECT token_hash, revoked FROM refresh_tokens WHERE user_id = $1 AND revoked = false AND expires_at > NOW()",
      [payload.sub]
    );

    let isValid = false;
    for (const stored of tokens) {
      if (await bcrypt.compare(refreshToken, stored.token_hash)) {
        isValid = true;
        break;
      }
    }

    if (!isValid) throw new Error("Invalid refresh token");

    const accessToken = jwt.sign(
      { sub: payload.sub, username: payload.username },
      config.jwt.secret,
      { expiresIn: config.jwt.expiresIn } as any
    );

    return { accessToken };
  }

  async revokeAllTokens(userId: string): Promise<void> {
    await db.query("UPDATE refresh_tokens SET revoked = true WHERE user_id = $1", [userId]);
  }
}

export const authService = new AuthService();
