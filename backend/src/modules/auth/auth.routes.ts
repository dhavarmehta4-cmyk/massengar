import { FastifyInstance } from "fastify";
import { z } from "zod";
import { authService } from "./auth.service";

const registerSchema = z.object({
  username: z.string().min(3).max(50).regex(/^[a-zA-Z0-9_]+$/),
  phoneNumber: z.string().min(7).max(20),
  email: z.string().email().optional(),
  displayName: z.string().min(1).max(100),
  password: z.string().min(8),
  keyBundle: z.object({
    registrationId: z.number(),
    identityPublicKey: z.string(),
    signedPreKeyId: z.number(),
    signedPreKeyPublic: z.string(),
    signedPreKeySignature: z.string(),
    oneTimePreKeys: z.array(z.object({ id: z.number(), publicKey: z.string() })),
  }),
});

const loginSchema = z.object({
  usernameOrPhone: z.string(),
  password: z.string(),
});

export async function authRoutes(app: FastifyInstance) {

  app.post("/register", async (req, reply) => {
    try {
      const body = registerSchema.parse(req.body);
      const result = await authService.register(body);
      return reply.status(201).send({ success: true, ...result });
    } catch (err: any) {
      return reply.status(400).send({ success: false, error: err.message });
    }
  });

  app.post("/login", async (req, reply) => {
    try {
      const { usernameOrPhone, password } = loginSchema.parse(req.body);
      const result = await authService.login(usernameOrPhone, password);
      return reply.status(200).send({ success: true, ...result });
    } catch (err: any) {
      return reply.status(401).send({ success: false, error: err.message });
    }
  });

  app.post("/refresh", async (req, reply) => {
    try {
      const { refreshToken } = req.body as { refreshToken: string };
      const result = await authService.refreshAccessToken(refreshToken);
      return reply.status(200).send({ success: true, ...result });
    } catch (err: any) {
      return reply.status(401).send({ success: false, error: err.message });
    }
  });

  app.get("/key-bundle/:userId", async (req, reply) => {
    try {
      const { userId } = req.params as { userId: string };
      const bundle = await authService.getKeyBundle(userId);
      if (!bundle) return reply.status(404).send({ error: "User not found" });
      return reply.send({ success: true, keyBundle: bundle });
    } catch (err: any) {
      return reply.status(500).send({ success: false, error: err.message });
    }
  });

  app.post("/logout", async (req, reply) => {
    try {
      const auth = req.headers.authorization?.replace("Bearer ", "");
      if (auth) {
        const payload = authService.verifyAccessToken(auth);
        await authService.revokeAllTokens(payload.sub);
      }
      return reply.send({ success: true });
    } catch {
      return reply.send({ success: true }); // Always succeed logout
    }
  });
}
