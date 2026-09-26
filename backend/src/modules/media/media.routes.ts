import { FastifyInstance } from "fastify";
import { z } from "zod";
import { mediaService } from "./media.service";
import { authService } from "@/modules/auth/auth.service";

function authenticate(req: any): string {
  const token = req.headers.authorization?.replace("Bearer ", "");
  if (!token) throw new Error("Unauthorized");
  const payload = authService.verifyAccessToken(token);
  return payload.sub;
}

export async function mediaRoutes(app: FastifyInstance) {
  app.post("/presign-upload", async (req, reply) => {
    try {
      const userId = authenticate(req);
      const body = req.body as any;
      const result = await mediaService.generateUploadUrl({
        uploaderId: userId,
        mimeType: body.mimeType,
        fileSize: body.fileSize,
        fileName: body.fileName,
        isViewOnce: body.isViewOnce,
        encryptedKey: body.encryptedKey,
        iv: body.iv,
      });
      return reply.send({ success: true, ...result });
    } catch (err: any) {
      return reply.status(401).send({ success: false, error: err.message });
    }
  });

  app.get("/download/:assetId", async (req, reply) => {
    try {
      const userId = authenticate(req);
      const { assetId } = req.params as { assetId: string };
      const url = await mediaService.generateDownloadUrl(assetId, userId);
      return reply.send({ success: true, url });
    } catch (err: any) {
      return reply.status(404).send({ success: false, error: err.message });
    }
  });

  app.post("/confirm-upload/:assetId", async (req, reply) => {
    try {
      const userId = authenticate(req);
      const { assetId } = req.params as { assetId: string };
      await mediaService.confirmUpload(assetId, userId);
      return reply.send({ success: true });
    } catch (err: any) {
      return reply.status(400).send({ success: false, error: err.message });
    }
  });
}
