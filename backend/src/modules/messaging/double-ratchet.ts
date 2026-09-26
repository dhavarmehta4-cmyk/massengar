/**
 * Double Ratchet Algorithm Implementation
 * Implements the Signal Protocol E2EE encryption engine.
 * 
 * Based on: https://signal.org/docs/specifications/doubleratchet/
 * 
 * Key operations:
 * - X3DH key agreement (Extended Triple Diffie-Hellman)
 * - KDF Chain for deriving message keys  
 * - Symmetric-key ratchet + Diffie-Hellman ratchet
 * - AES-256-GCM for message encryption
 */

import crypto from "crypto";

// -- Types ---------------------------------------------------------

export interface KeyPair {
  publicKey: Buffer;
  privateKey: Buffer;
}

export interface RatchetState {
  // DH Ratchet
  dhSendingKey: KeyPair;
  dhReceivingKey: Buffer | null;
  // Chain keys
  rootKey: Buffer;
  chainKeySend: Buffer | null;
  chainKeyRecv: Buffer | null;
  // Message indices
  sendingIndex: number;
  receivingIndex: number;
  // Previous chain count
  prevSendingCount: number;
  // Skipped message keys
  skippedMessageKeys: Map<string, Buffer>;
}

export interface EncryptedMessage {
  header: {
    dhPublicKey: string;    // Base64 sender DH public key
    prevChainCount: number;
    messageIndex: number;
  };
  ciphertext: string;       // Base64 encrypted payload
  iv: string;               // Base64 IV
  mac: string;              // Base64 HMAC-SHA256 auth tag
}

export interface X3DHKeyBundle {
  identityKey: Buffer;
  signedPreKey: { id: number; publicKey: Buffer };
  oneTimePreKey?: { id: number; publicKey: Buffer };
}

// -- Constants -----------------------------------------------------

const MAX_SKIP = 1000; // Max skipped message keys
const KDF_INFO_ROOT = Buffer.from("MassengarRootChain");
const KDF_INFO_MSG = Buffer.from("MassengarMsgChain");
const KDF_INFO_X3DH = Buffer.from("MassengarX3DH");

// -- Utility: HKDF ------------------------------------------------

function hkdf(
  inputKeyMaterial: Buffer,
  salt: Buffer,
  info: Buffer,
  length: number
): Buffer {
  // HKDF-Extract
  const prk = crypto.createHmac("sha256", salt).update(inputKeyMaterial).digest();
  
  // HKDF-Expand
  const n = Math.ceil(length / 32);
  const okm = Buffer.alloc(n * 32);
  let prev = Buffer.alloc(0);
  
  for (let i = 0; i < n; i++) {
    const hmac = crypto.createHmac("sha256", prk);
    hmac.update(prev);
    hmac.update(info);
    hmac.update(Buffer.from([i + 1]));
    prev = hmac.digest();
    prev.copy(okm, i * 32);
  }
  
  return okm.subarray(0, length);
}

// -- KDF Chain ----------------------------------------------------

function kdfChainKey(chainKey: Buffer): { nextChainKey: Buffer; messageKey: Buffer } {
  const messageKey = crypto.createHmac("sha256", chainKey).update(Buffer.from([0x01])).digest();
  const nextChainKey = crypto.createHmac("sha256", chainKey).update(Buffer.from([0x02])).digest();
  return { nextChainKey, messageKey };
}

function kdfRootKey(
  rootKey: Buffer,
  dhOutput: Buffer
): { newRootKey: Buffer; chainKey: Buffer } {
  const derived = hkdf(dhOutput, rootKey, KDF_INFO_ROOT, 64);
  return {
    newRootKey: derived.subarray(0, 32),
    chainKey: derived.subarray(32, 64),
  };
}

// -- DH Key Generation --------------------------------------------

export function generateDHKeyPair(): KeyPair {
  const { privateKey, publicKey } = crypto.generateKeyPairSync("x25519", {
    publicKeyEncoding: { type: "spki", format: "der" },
    privateKeyEncoding: { type: "pkcs8", format: "der" },
  });
  // Extract raw 32-byte keys from DER encoding
  return {
    publicKey: publicKey.subarray(-32),
    privateKey: privateKey.subarray(-32),
  };
}

export function dhExchange(privateKey: Buffer, publicKey: Buffer): Buffer {
  const privObj = crypto.createPrivateKey({
    key: Buffer.concat([
      Buffer.from("302e020100300506032b656e04220420", "hex"), // PKCS8 header for X25519
      privateKey,
    ]),
    format: "der",
    type: "pkcs8",
  });
  const pubObj = crypto.createPublicKey({
    key: Buffer.concat([
      Buffer.from("302a300506032b656e032100", "hex"), // SPKI header for X25519
      publicKey,
    ]),
    format: "der",
    type: "spki",
  });
  return crypto.diffieHellman({ privateKey: privObj, publicKey: pubObj });
}

// -- X3DH: Session Initialization --------------------------------

/**
 * Sender-side X3DH: Creates a shared secret from receiver's key bundle.
 */
export function x3dhSenderInit(
  senderIdentityKey: KeyPair,
  senderEphemeralKey: KeyPair,
  receiverBundle: X3DHKeyBundle
): { sharedSecret: Buffer; associatedData: Buffer } {
  const dh1 = dhExchange(senderIdentityKey.privateKey, receiverBundle.signedPreKey.publicKey);
  const dh2 = dhExchange(senderEphemeralKey.privateKey, receiverBundle.identityKey);
  const dh3 = dhExchange(senderEphemeralKey.privateKey, receiverBundle.signedPreKey.publicKey);
  
  let dhConcat = Buffer.concat([dh1, dh2, dh3]);
  if (receiverBundle.oneTimePreKey) {
    const dh4 = dhExchange(senderEphemeralKey.privateKey, receiverBundle.oneTimePreKey.publicKey);
    dhConcat = Buffer.concat([dhConcat, dh4]);
  }
  
  const sharedSecret = hkdf(dhConcat, Buffer.alloc(32), KDF_INFO_X3DH, 32);
  const associatedData = Buffer.concat([senderIdentityKey.publicKey, receiverBundle.identityKey]);
  
  return { sharedSecret, associatedData };
}

// -- Double Ratchet: Initialize State ----------------------------

export function initRatchetSender(sharedSecret: Buffer, receiverPublicKey: Buffer): RatchetState {
  const dhPair = generateDHKeyPair();
  const dhOutput = dhExchange(dhPair.privateKey, receiverPublicKey);
  const { newRootKey, chainKey } = kdfRootKey(sharedSecret, dhOutput);

  return {
    dhSendingKey: dhPair,
    dhReceivingKey: receiverPublicKey,
    rootKey: newRootKey,
    chainKeySend: chainKey,
    chainKeyRecv: null,
    sendingIndex: 0,
    receivingIndex: 0,
    prevSendingCount: 0,
    skippedMessageKeys: new Map(),
  };
}

export function initRatchetReceiver(sharedSecret: Buffer, myKeyPair: KeyPair): RatchetState {
  return {
    dhSendingKey: myKeyPair,
    dhReceivingKey: null,
    rootKey: sharedSecret,
    chainKeySend: null,
    chainKeyRecv: null,
    sendingIndex: 0,
    receivingIndex: 0,
    prevSendingCount: 0,
    skippedMessageKeys: new Map(),
  };
}

// -- Double Ratchet: Encrypt --------------------------------------

export function ratchetEncrypt(
  state: RatchetState,
  plaintext: Buffer,
  associatedData?: Buffer
): { encrypted: EncryptedMessage; newState: RatchetState } {
  if (!state.chainKeySend) throw new Error("Sending chain not initialized");

  const { nextChainKey, messageKey } = kdfChainKey(state.chainKeySend);
  const iv = crypto.randomBytes(12);
  
  const cipher = crypto.createCipheriv("aes-256-gcm", messageKey, iv);
  if (associatedData) cipher.setAAD(associatedData);
  
  const encrypted = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const authTag = cipher.getAuthTag();
  const ciphertext = Buffer.concat([encrypted, authTag]);

  const header = {
    dhPublicKey: state.dhSendingKey.publicKey.toString("base64"),
    prevChainCount: state.prevSendingCount,
    messageIndex: state.sendingIndex,
  };

  // HMAC over header + ciphertext for authenticity
  const macInput = Buffer.concat([
    Buffer.from(JSON.stringify(header)),
    ciphertext,
    associatedData ?? Buffer.alloc(0),
  ]);
  const mac = crypto.createHmac("sha256", messageKey).update(macInput).digest("base64");

  const newState: RatchetState = {
    ...state,
    chainKeySend: nextChainKey,
    sendingIndex: state.sendingIndex + 1,
    skippedMessageKeys: new Map(state.skippedMessageKeys),
  };

  return {
    encrypted: {
      header,
      ciphertext: ciphertext.toString("base64"),
      iv: iv.toString("base64"),
      mac,
    },
    newState,
  };
}

// -- Double Ratchet: Decrypt --------------------------------------

export function ratchetDecrypt(
  state: RatchetState,
  message: EncryptedMessage,
  associatedData?: Buffer
): { plaintext: Buffer; newState: RatchetState } {
  const newState: RatchetState = {
    ...state,
    skippedMessageKeys: new Map(state.skippedMessageKeys),
  };

  const dhPublicKey = Buffer.from(message.header.dhPublicKey, "base64");

  // Check skipped message keys first
  const skippedKey = `${message.header.dhPublicKey}:${message.header.messageIndex}`;
  const skippedMsgKey = newState.skippedMessageKeys.get(skippedKey);
  
  if (skippedMsgKey) {
    newState.skippedMessageKeys.delete(skippedKey);
    return { plaintext: decryptWithKey(skippedMsgKey, message, associatedData), newState };
  }

  // DH Ratchet step if new DH key
  const isDhRatchetStep = !newState.dhReceivingKey || 
    !dhPublicKey.equals(newState.dhReceivingKey);

  if (isDhRatchetStep) {
    // Skip ahead in current chain if needed
    if (newState.chainKeyRecv) {
      skipMessageKeys(newState, message.header.prevChainCount, dhPublicKey);
    }

    // Perform DH ratchet
    const dhOutput = dhExchange(newState.dhSendingKey.privateKey, dhPublicKey);
    const { newRootKey: rk1, chainKey: ck1 } = kdfRootKey(newState.rootKey, dhOutput);
    
    newState.dhReceivingKey = dhPublicKey;
    newState.rootKey = rk1;
    newState.chainKeyRecv = ck1;
    newState.prevSendingCount = newState.sendingIndex;
    newState.sendingIndex = 0;
    newState.receivingIndex = 0;

    // New DH sending ratchet
    const newDhPair = generateDHKeyPair();
    const dhOutput2 = dhExchange(newDhPair.privateKey, dhPublicKey);
    const { newRootKey: rk2, chainKey: ck2 } = kdfRootKey(rk1, dhOutput2);
    
    newState.dhSendingKey = newDhPair;
    newState.rootKey = rk2;
    newState.chainKeySend = ck2;
  }

  // Skip to the right message index
  skipMessageKeys(newState, message.header.messageIndex, dhPublicKey);

  if (!newState.chainKeyRecv) throw new Error("Receiving chain not initialized");

  const { nextChainKey, messageKey } = kdfChainKey(newState.chainKeyRecv);
  newState.chainKeyRecv = nextChainKey;
  newState.receivingIndex++;

  return { plaintext: decryptWithKey(messageKey, message, associatedData), newState };
}

function skipMessageKeys(state: RatchetState, until: number, dhKey: Buffer): void {
  if (!state.chainKeyRecv) return;
  
  while (state.receivingIndex < until) {
    if (state.skippedMessageKeys.size >= MAX_SKIP) {
      throw new Error("Too many skipped message keys");
    }
    const { nextChainKey, messageKey } = kdfChainKey(state.chainKeyRecv);
    const key = `${dhKey.toString("base64")}:${state.receivingIndex}`;
    state.skippedMessageKeys.set(key, messageKey);
    state.chainKeyRecv = nextChainKey;
    state.receivingIndex++;
  }
}

function decryptWithKey(
  messageKey: Buffer,
  message: EncryptedMessage,
  associatedData?: Buffer
): Buffer {
  const ciphertextWithTag = Buffer.from(message.ciphertext, "base64");
  const iv = Buffer.from(message.iv, "base64");
  
  const authTag = ciphertextWithTag.subarray(-16);
  const ciphertext = ciphertextWithTag.subarray(0, -16);
  
  const decipher = crypto.createDecipheriv("aes-256-gcm", messageKey, iv);
  decipher.setAuthTag(authTag);
  if (associatedData) decipher.setAAD(associatedData);
  
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]);
}

// -- Media Encryption (AES-256-GCM) ------------------------------

export function encryptMedia(
  data: Buffer,
  key?: Buffer
): { encrypted: Buffer; key: Buffer; iv: Buffer } {
  const mediaKey = key ?? crypto.randomBytes(32);
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", mediaKey, iv);
  const encrypted = Buffer.concat([cipher.update(data), cipher.final(), cipher.getAuthTag()]);
  return { encrypted, key: mediaKey, iv };
}

export function decryptMedia(encrypted: Buffer, key: Buffer, iv: Buffer): Buffer {
  const authTag = encrypted.subarray(-16);
  const ciphertext = encrypted.subarray(0, -16);
  const decipher = crypto.createDecipheriv("aes-256-gcm", key, iv);
  decipher.setAuthTag(authTag);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]);
}
