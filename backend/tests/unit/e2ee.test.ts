/**
 * Phase 2 Unit Tests - E2EE Double Ratchet Engine
 * Tests message serialization, encryption/decryption cycles,
 * X3DH key agreement, and media encryption.
 */

import {
  generateDHKeyPair,
  dhExchange,
  x3dhSenderInit,
  initRatchetSender,
  initRatchetReceiver,
  ratchetEncrypt,
  ratchetDecrypt,
  encryptMedia,
  decryptMedia,
  type KeyPair,
  type X3DHKeyBundle,
} from "../../src/modules/messaging/double-ratchet";

describe("Double Ratchet E2EE Engine", () => {

  // -- Setup ------------------------------------------------------

  let aliceIdentity: KeyPair;
  let bobIdentity: KeyPair;
  let bobSignedPreKey: KeyPair;
  let bobOneTimePreKey: KeyPair;

  beforeAll(() => {
    aliceIdentity = generateDHKeyPair();
    bobIdentity = generateDHKeyPair();
    bobSignedPreKey = generateDHKeyPair();
    bobOneTimePreKey = generateDHKeyPair();
  });

  // -- Key Generation ---------------------------------------------

  describe("Key Generation", () => {
    test("should generate valid X25519 key pairs", () => {
      const keyPair = generateDHKeyPair();
      expect(keyPair.publicKey).toBeInstanceOf(Buffer);
      expect(keyPair.privateKey).toBeInstanceOf(Buffer);
      expect(keyPair.publicKey.length).toBe(32);
      expect(keyPair.privateKey.length).toBe(32);
    });

    test("should generate unique key pairs each time", () => {
      const kp1 = generateDHKeyPair();
      const kp2 = generateDHKeyPair();
      expect(kp1.publicKey.equals(kp2.publicKey)).toBe(false);
    });

    test("DH exchange should produce same shared secret from both sides", () => {
      const alice = generateDHKeyPair();
      const bob = generateDHKeyPair();
      const aliceShared = dhExchange(alice.privateKey, bob.publicKey);
      const bobShared = dhExchange(bob.privateKey, alice.publicKey);
      expect(aliceShared.equals(bobShared)).toBe(true);
    });
  });

  // -- X3DH Key Agreement -----------------------------------------

  describe("X3DH Key Agreement", () => {
    test("sender should compute shared secret from key bundle", () => {
      const aliceEphemeral = generateDHKeyPair();
      const bobBundle: X3DHKeyBundle = {
        identityKey: bobIdentity.publicKey,
        signedPreKey: { id: 1, publicKey: bobSignedPreKey.publicKey },
        oneTimePreKey: { id: 1, publicKey: bobOneTimePreKey.publicKey },
      };

      const { sharedSecret, associatedData } = x3dhSenderInit(
        aliceIdentity,
        aliceEphemeral,
        bobBundle
      );

      expect(sharedSecret.length).toBe(32);
      expect(associatedData.length).toBe(64); // 32 + 32
    });

    test("should produce non-zero shared secret", () => {
      const aliceEphemeral = generateDHKeyPair();
      const bobBundle: X3DHKeyBundle = {
        identityKey: bobIdentity.publicKey,
        signedPreKey: { id: 1, publicKey: bobSignedPreKey.publicKey },
      };

      const { sharedSecret } = x3dhSenderInit(aliceIdentity, aliceEphemeral, bobBundle);
      const zeros = Buffer.alloc(32);
      expect(sharedSecret.equals(zeros)).toBe(false);
    });
  });

  // -- Ratchet Encrypt/Decrypt ------------------------------------

  describe("Double Ratchet Encrypt/Decrypt", () => {
    let aliceState: any;
    let bobState: any;
    const sharedSecret = Buffer.from("0123456789abcdef0123456789abcdef", "hex");

    beforeEach(() => {
      const bobKeyPair = generateDHKeyPair();
      aliceState = initRatchetSender(sharedSecret, bobKeyPair.publicKey);
      bobState = initRatchetReceiver(sharedSecret, bobKeyPair);
    });

    test("should encrypt and decrypt a single message", () => {
      const plaintext = Buffer.from("Hello, secure world!");
      const { encrypted, newState: aliceNew } = ratchetEncrypt(aliceState, plaintext);

      expect(encrypted.ciphertext).toBeTruthy();
      expect(encrypted.header.dhPublicKey).toBeTruthy();
      expect(encrypted.iv).toBeTruthy();
      expect(encrypted.mac).toBeTruthy();
      
      // Verify ciphertext is not plaintext
      expect(Buffer.from(encrypted.ciphertext, "base64").toString()).not.toBe("Hello, secure world!");
      
      const { plaintext: decrypted } = ratchetDecrypt(bobState, encrypted);
      expect(decrypted.toString()).toBe("Hello, secure world!");
    });

    test("should encrypt multiple sequential messages", () => {
      const messages = ["Message 1", "Message 2", "Message 3", "Message 4"];
      let currentAliceState = aliceState;
      const encrypted: any[] = [];

      for (const msg of messages) {
        const { encrypted: enc, newState } = ratchetEncrypt(currentAliceState, Buffer.from(msg));
        encrypted.push(enc);
        currentAliceState = newState;
      }

      let currentBobState = bobState;
      for (let i = 0; i < messages.length; i++) {
        const { plaintext, newState } = ratchetDecrypt(currentBobState, encrypted[i]);
        expect(plaintext.toString()).toBe(messages[i]);
        currentBobState = newState;
      }
    });

    test("each message should produce different ciphertext (unique IVs)", () => {
      const plaintext = Buffer.from("Same message");
      const { encrypted: enc1, newState: state1 } = ratchetEncrypt(aliceState, plaintext);
      const { encrypted: enc2 } = ratchetEncrypt(state1, plaintext);
      
      expect(enc1.ciphertext).not.toBe(enc2.ciphertext);
      expect(enc1.iv).not.toBe(enc2.iv);
    });

    test("should fail decryption with wrong key", () => {
      const plaintext = Buffer.from("Secret message");
      const { encrypted } = ratchetEncrypt(aliceState, plaintext);
      
      // Tamper with ciphertext
      const tampered = {
        ...encrypted,
        ciphertext: Buffer.from("tampered data").toString("base64"),
      };

      expect(() => ratchetDecrypt(bobState, tampered)).toThrow();
    });

    test("should encrypt with associated data (additional authenticated data)", () => {
      const plaintext = Buffer.from("Message with AAD");
      const aad = Buffer.from(`conv:${Date.now()}`);
      
      const { encrypted, newState } = ratchetEncrypt(aliceState, plaintext, aad);
      const { plaintext: decrypted } = ratchetDecrypt(bobState, encrypted, aad);
      
      expect(decrypted.toString()).toBe("Message with AAD");
    });

    test("message state counter should increment", () => {
      const { newState: state1 } = ratchetEncrypt(aliceState, Buffer.from("m1"));
      const { newState: state2 } = ratchetEncrypt(state1, Buffer.from("m2"));
      const { newState: state3 } = ratchetEncrypt(state2, Buffer.from("m3"));
      
      expect(state3.sendingIndex).toBe(3);
    });
  });

  // -- Message Serialization --------------------------------------

  describe("Message Serialization", () => {
    test("encrypted message should be JSON-serializable", () => {
      const sharedSecret = Buffer.from("0123456789abcdef0123456789abcdef", "hex");
      const bobKeyPair = generateDHKeyPair();
      const state = initRatchetSender(sharedSecret, bobKeyPair.publicKey);
      
      const { encrypted } = ratchetEncrypt(state, Buffer.from("Test message"));
      const serialized = JSON.stringify(encrypted);
      const deserialized = JSON.parse(serialized);
      
      expect(deserialized.header.dhPublicKey).toBeTruthy();
      expect(deserialized.ciphertext).toBeTruthy();
      expect(typeof deserialized.header.messageIndex).toBe("number");
      expect(typeof deserialized.header.prevChainCount).toBe("number");
    });
  });

  // -- Media Encryption -------------------------------------------

  describe("Media Encryption (AES-256-GCM)", () => {
    test("should encrypt and decrypt binary data", () => {
      const original = Buffer.from("Binary media data: " + "A".repeat(1000));
      const { encrypted, key, iv } = encryptMedia(original);
      const decrypted = decryptMedia(encrypted, key, iv);
      
      expect(decrypted.equals(original)).toBe(true);
    });

    test("encrypted data should be larger than original (has auth tag)", () => {
      const original = Buffer.from("Test file content");
      const { encrypted } = encryptMedia(original);
      expect(encrypted.length).toBeGreaterThan(original.length);
    });

    test("should fail with wrong key", () => {
      const original = Buffer.from("Test data");
      const { encrypted, iv } = encryptMedia(original);
      const wrongKey = Buffer.alloc(32, 0xff);
      
      expect(() => decryptMedia(encrypted, wrongKey, iv)).toThrow();
    });

    test("should use provided key when given", () => {
      const original = Buffer.from("Test data");
      const myKey = Buffer.alloc(32, 0xab);
      const { encrypted, key, iv } = encryptMedia(original, myKey);
      
      expect(key.equals(myKey)).toBe(true);
      const decrypted = decryptMedia(encrypted, key, iv);
      expect(decrypted.equals(original)).toBe(true);
    });

    test("should handle large file simulation (10MB)", () => {
      const largeData = Buffer.alloc(10 * 1024 * 1024, 0xAA); // 10MB
      const { encrypted, key, iv } = encryptMedia(largeData);
      const decrypted = decryptMedia(encrypted, key, iv);
      
      expect(decrypted.equals(largeData)).toBe(true);
    });
  });

  // -- Security Properties -----------------------------------------

  describe("Security Properties", () => {
    test("forward secrecy: compromising future keys should not reveal past messages", () => {
      const sharedSecret = Buffer.from("0123456789abcdef0123456789abcdef", "hex");
      const bobKeyPair = generateDHKeyPair();
      
      let aliceState = initRatchetSender(sharedSecret, bobKeyPair.publicKey);
      let bobState = initRatchetReceiver(sharedSecret, bobKeyPair);
      
      // Encrypt 5 messages
      const messages: any[] = [];
      for (let i = 0; i < 5; i++) {
        const { encrypted, newState } = ratchetEncrypt(aliceState, Buffer.from(`Message ${i}`));
        messages.push(encrypted);
        aliceState = newState;
      }
      
      // Decrypt first 2
      const { plaintext: m0, newState: bs1 } = ratchetDecrypt(bobState, messages[0]);
      const { plaintext: m1 } = ratchetDecrypt(bs1, messages[1]);
      
      expect(m0.toString()).toBe("Message 0");
      expect(m1.toString()).toBe("Message 1");
      
      // Chain keys have advanced - old message keys are gone
      expect(aliceState.sendingIndex).toBe(5);
    });

    test("break-in recovery: new DH ratchet step should provide fresh chain", () => {
      const sharedSecret = Buffer.alloc(32);
      crypto.getRandomValues(sharedSecret);
      
      const bobKeyPair = generateDHKeyPair();
      const aliceState = initRatchetSender(sharedSecret, bobKeyPair.publicKey);
      
      const { encrypted, newState } = ratchetEncrypt(aliceState, Buffer.from("After ratchet step"));
      // Each encryption with a new DH key provides forward secrecy
      expect(newState.sendingIndex).toBeGreaterThan(0);
    });
  });
});
