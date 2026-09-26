import { S3Client, PutObjectCommand, DeleteObjectCommand, GetObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { v4 as uuidv4 } from "uuid";
import { config } from "@/config";
import { db } from "@/config/database";
import pino from "pino";

const logger = pino({ level: "info" });

export class MediaService {
  private s3: S3Client;

  constructor() {
    this.s3 = new S3Client({
      endpoint: config.s3.endpoint,
      region: config.s3.region,
      credentials: {
        accessKeyId: config.s3.accessKey,
        secretAccessKey: config.s3.secretKey,
      },
      forcePathStyle: true, // Required for MinIO/custom S3
    });
  }

  // -- Presigned Upload URL --------------------------------------

  async generateUploadUrl(params: {
    uploaderId: string;
    mimeType: string;
    fileSize: number;
    fileName: string;
    isViewOnce?: boolean;
    encryptedKey?: string;
    iv?: string;
  }): Promise<{ uploadUrl: string; assetId: string; s3Key: string }> {

    const ext = params.fileName.split(".").pop() ?? "bin";
    const s3Key = `uploads/${params.uploaderId}/${uuidv4()}.${ext}.enc`; // .enc = encrypted

    // Register asset in DB before upload (status: pending)
    const [asset] = await db.query<{ id: string }>(
      `INSERT INTO media_assets (uploader_id, s3_key, s3_bucket, mime_type, file_size, file_name, is_view_once, encrypted_key, iv)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
       RETURNING id`,
      [
        params.uploaderId,
        s3Key,
        config.s3.bucket,
        params.mimeType,
        params.fileSize,
        params.fileName,
        params.isViewOnce ?? false,
        params.encryptedKey ?? null,
        params.iv ?? null,
      ]
    );

    const command = new PutObjectCommand({
      Bucket: config.s3.bucket,
      Key: s3Key,
      ContentType: "application/octet-stream", // Always binary (encrypted)
      ContentLength: params.fileSize,
      Metadata: {
        "x-massengar-asset-id": asset.id,
        "x-massengar-uploader": params.uploaderId,
        "x-massengar-encrypted": "true",
      },
    });

    const uploadUrl = await getSignedUrl(this.s3, command, {
      expiresIn: config.s3.presignedUrlExpiry,
    });

    logger.info({ assetId: asset.id, s3Key, uploaderId: params.uploaderId }, "Presigned upload URL generated");
    return { uploadUrl, assetId: asset.id, s3Key };
  }

  // -- Presigned Download URL ------------------------------------

  async generateDownloadUrl(assetId: string, requesterId: string): Promise<string> {
    const asset = await db.queryOne<any>(
      "SELECT * FROM media_assets WHERE id = $1 AND is_purged = false",
      [assetId]
    );

    if (!asset) throw new Error("Asset not found or already purged");

    // View-once: mark as viewed (purge after first full download)
    if (asset.is_view_once && asset.viewed_at) {
      throw new Error("View-once media has already been viewed");
    }

    const command = new GetObjectCommand({
      Bucket: asset.s3_bucket,
      Key: asset.s3_key,
    });

    const url = await getSignedUrl(this.s3, command, {
      expiresIn: 300, // 5 min for view-once, shorter window
    });

    if (asset.is_view_once) {
      // Mark as viewed - trigger background cleanup
      await db.query(
        "UPDATE media_assets SET viewed_at = NOW() WHERE id = $1",
        [assetId]
      );
      // Schedule deletion immediately after view window
      setTimeout(() => this.purgeAsset(assetId), 330 * 1000); // 330s = 5.5min
    }

    return url;
  }

  // -- Purge (View-once / Disappearing) -------------------------

  async purgeAsset(assetId: string): Promise<void> {
    const asset = await db.queryOne<any>(
      "SELECT s3_key, s3_bucket FROM media_assets WHERE id = $1 AND is_purged = false",
      [assetId]
    );
    if (!asset) return;

    try {
      await this.s3.send(new DeleteObjectCommand({
        Bucket: asset.s3_bucket,
        Key: asset.s3_key,
      }));

      await db.query(
        "UPDATE media_assets SET is_purged = true, purged_at = NOW(), encrypted_key = null, iv = null WHERE id = $1",
        [assetId]
      );
      logger.info({ assetId }, "Media asset purged from S3 and keys revoked");
    } catch (err) {
      logger.error({ err, assetId }, "Failed to purge media asset");
    }
  }

  // -- Confirm Upload Complete -----------------------------------

  async confirmUpload(assetId: string, uploaderId: string): Promise<void> {
    await db.query(
      "UPDATE media_assets SET file_size = file_size WHERE id = $1 AND uploader_id = $2",
      [assetId, uploaderId]
    );
    logger.info({ assetId, uploaderId }, "Media upload confirmed");
  }
}

export const mediaService = new MediaService();
