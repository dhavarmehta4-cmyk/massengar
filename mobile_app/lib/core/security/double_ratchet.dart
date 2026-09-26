// ================================================================
// Massengar Flutter - Double Ratchet E2EE Engine (Dart)
// Signal Protocol implementation for the Flutter client
// ================================================================

import "dart:convert";
import "dart:math";
import "dart:typed_data";
import "package:cryptography/cryptography.dart";
import "package:pointycastle/export.dart" as pc;
import "package:convert/convert.dart";

// -- Key Pair ------------------------------------------------------

class DhKeyPair {
  final Uint8List publicKey;
  final Uint8List privateKey;
  const DhKeyPair({required this.publicKey, required this.privateKey});
}

// -- Ratchet State (persisted to SQLCipher) ------------------------

class RatchetState {
  DhKeyPair dhSendingKey;
  Uint8List? dhReceivingKey;
  Uint8List rootKey;
  Uint8List? chainKeySend;
  Uint8List? chainKeyRecv;
  int sendingIndex;
  int receivingIndex;
  int prevSendingCount;
  Map<String, Uint8List> skippedMessageKeys;

  RatchetState({
    required this.dhSendingKey,
    this.dhReceivingKey,
    required this.rootKey,
    this.chainKeySend,
    this.chainKeyRecv,
    this.sendingIndex = 0,
    this.receivingIndex = 0,
    this.prevSendingCount = 0,
    Map<String, Uint8List>? skippedMessageKeys,
  }) : skippedMessageKeys = skippedMessageKeys ?? {};
}

// -- Encrypted Message Wire Format ---------------------------------

class EncryptedMessage {
  final String dhPublicKey;       // Base64
  final int prevChainCount;
  final int messageIndex;
  final String ciphertext;        // Base64
  final String iv;                // Base64
  final String mac;               // Base64

  const EncryptedMessage({
    required this.dhPublicKey,
    required this.prevChainCount,
    required this.messageIndex,
    required this.ciphertext,
    required this.iv,
    required this.mac,
  });

  Map<String, dynamic> toJson() => {
    "header": {
      "dhPublicKey": dhPublicKey,
      "prevChainCount": prevChainCount,
      "messageIndex": messageIndex,
    },
    "ciphertext": ciphertext,
    "iv": iv,
    "mac": mac,
  };

  factory EncryptedMessage.fromJson(Map<String, dynamic> json) => EncryptedMessage(
    dhPublicKey: json["header"]["dhPublicKey"] as String,
    prevChainCount: json["header"]["prevChainCount"] as int,
    messageIndex: json["header"]["messageIndex"] as int,
    ciphertext: json["ciphertext"] as String,
    iv: json["iv"] as String,
    mac: json["mac"] as String,
  );
}

// -- Double Ratchet Engine ------------------------------------------

class DoubleRatchetEngine {
  static const int _maxSkip = 1000;
  static final Uint8List _kdfInfoRoot = Uint8List.fromList(utf8.encode("MassengarRootChain"));
  static final Uint8List _kdfInfoX3dh = Uint8List.fromList(utf8.encode("MassengarX3DH"));

  // -- HKDF --------------------------------------------------------

  static Future<Uint8List> _hkdf(Uint8List ikm, Uint8List salt, Uint8List info, int length) async {
    final algorithm = Hkdf(hmac: Hmac.sha256(), outputLength: length);
    final secretKey = SecretKey(ikm);
    final derivedKey = await algorithm.deriveKey(
      secretKey: secretKey,
      nonce: salt,
      info: info,
    );
    return Uint8List.fromList(await derivedKey.extractBytes());
  }

  // -- KDF Chain ----------------------------------------------------

  static Future<({Uint8List nextChainKey, Uint8List messageKey})> _kdfChainKey(Uint8List chainKey) async {
    final hmac = Hmac.sha256();
    final mk = await hmac.calculateMac([0x01], secretKey: SecretKey(chainKey));
    final ck = await hmac.calculateMac([0x02], secretKey: SecretKey(chainKey));
    return (
      nextChainKey: Uint8List.fromList(ck.bytes),
      messageKey: Uint8List.fromList(mk.bytes),
    );
  }

  static Future<({Uint8List newRootKey, Uint8List chainKey})> _kdfRootKey(Uint8List rootKey, Uint8List dhOutput) async {
    final derived = await _hkdf(dhOutput, rootKey, _kdfInfoRoot, 64);
    return (
      newRootKey: derived.sublist(0, 32),
      chainKey: derived.sublist(32, 64),
    );
  }

  // -- X25519 DH ----------------------------------------------------

  static DhKeyPair generateKeyPair() {
    final random = Random.secure();
    final privateKey = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      privateKey[i] = random.nextInt(256);
    }
    // Clamp for Curve25519
    privateKey[0] &= 248;
    privateKey[31] &= 127;
    privateKey[31] |= 64;

    final publicKey = _x25519BasePointMultiply(privateKey);
    return DhKeyPair(publicKey: publicKey, privateKey: privateKey);
  }

  static Uint8List dhExchange(Uint8List privateKey, Uint8List publicKey) {
    return _x25519Multiply(privateKey, publicKey);
  }

  // X25519 scalar multiplication (Montgomery ladder)
  static Uint8List _x25519BasePointMultiply(Uint8List scalar) {
    final basePoint = Uint8List(32)..[0] = 9;
    return _x25519Multiply(scalar, basePoint);
  }

  static Uint8List _x25519Multiply(Uint8List k, Uint8List u) {
    final kParam = pc.X25519().scalarBaseMult(k);
    // Use PointyCastle's X25519
    final params = pc.X25519()..init(false, pc.ParametersWithRandom(
      pc.ECDomainParameters("prime256v1"),
      pc.SecureRandom("Fortuna")..seed(pc.KeyParameter(k)),
    ));
    // Fallback: use raw field arithmetic
    return _montgomeryLadder(k, u);
  }

  static Uint8List _montgomeryLadder(Uint8List k, Uint8List u) {
    // Simplified X25519 - in production use package:x25519
    final scalar = _clampScalar(Uint8List.fromList(k));
    var x1 = _decodeLittleEndian(u);
    var x2 = BigInt.one;
    var z2 = BigInt.zero;
    var x3 = x1;
    var z3 = BigInt.one;
    var swap = BigInt.zero;
    
    final p = (BigInt.one << 255) - BigInt.from(19);
    
    for (int t = 254; t >= 0; t--) {
      final kt = (BigInt.from(scalar[(t >> 3)] >> (t & 7)) & BigInt.one);
      swap ^= kt;
      // Conditional swap
      if (swap != BigInt.zero) {
        final tmp2 = x2; x2 = x3; x3 = tmp2;
        final tmp3 = z2; z2 = z3; z3 = tmp3;
      }
      swap = kt;
      
      final A = (x2 + z2) % p;
      final AA = (A * A) % p;
      final B = (x2 - z2 + p) % p;
      final BB = (B * B) % p;
      final E = (AA - BB + p) % p;
      final C = (x3 + z3) % p;
      final D = (x3 - z3 + p) % p;
      final DA = (D * A) % p;
      final CB = (C * B) % p;
      x3 = ((DA + CB) % p).modPow(BigInt.two, p);
      z3 = (x1 * ((DA - CB + p) % p).modPow(BigInt.two, p)) % p;
      x2 = (AA * BB) % p;
      z2 = (E * (AA + BigInt.from(121665) * E % p)) % p;
    }
    
    if (swap != BigInt.zero) {
      final tmp2 = x2; x2 = x3; x3 = tmp2;
    }
    
    final result = (x2 * z2.modPow(p - BigInt.two, p)) % p;
    return _encodeLittleEndian(result);
  }

  static Uint8List _clampScalar(Uint8List s) {
    final clamped = Uint8List.fromList(s);
    clamped[0] &= 248;
    clamped[31] &= 127;
    clamped[31] |= 64;
    return clamped;
  }

  static BigInt _decodeLittleEndian(Uint8List bytes) {
    var result = BigInt.zero;
    for (int i = bytes.length - 1; i >= 0; i--) {
      result = (result << 8) | BigInt.from(bytes[i]);
    }
    return result;
  }

  static Uint8List _encodeLittleEndian(BigInt value) {
    final result = Uint8List(32);
    var v = value;
    for (int i = 0; i < 32; i++) {
      result[i] = (v & BigInt.from(0xff)).toInt();
      v >>= 8;
    }
    return result;
  }

  // -- X3DH Session Init --------------------------------------------

  static Future<({Uint8List sharedSecret, Uint8List associatedData})> x3dhSenderInit({
    required DhKeyPair senderIdentityKey,
    required DhKeyPair senderEphemeralKey,
    required Uint8List receiverIdentityKey,
    required ({int id, Uint8List publicKey}) receiverSignedPreKey,
    ({int id, Uint8List publicKey})? receiverOneTimePreKey,
  }) async {
    final dh1 = dhExchange(senderIdentityKey.privateKey, receiverSignedPreKey.publicKey);
    final dh2 = dhExchange(senderEphemeralKey.privateKey, receiverIdentityKey);
    final dh3 = dhExchange(senderEphemeralKey.privateKey, receiverSignedPreKey.publicKey);

    Uint8List dhConcat;
    if (receiverOneTimePreKey != null) {
      final dh4 = dhExchange(senderEphemeralKey.privateKey, receiverOneTimePreKey.publicKey);
      dhConcat = Uint8List.fromList([...dh1, ...dh2, ...dh3, ...dh4]);
    } else {
      dhConcat = Uint8List.fromList([...dh1, ...dh2, ...dh3]);
    }

    final sharedSecret = await _hkdf(dhConcat, Uint8List(32), _kdfInfoX3dh, 32);
    final associatedData = Uint8List.fromList([...senderIdentityKey.publicKey, ...receiverIdentityKey]);

    return (sharedSecret: sharedSecret, associatedData: associatedData);
  }

  // -- Init Ratchet (Sender) -----------------------------------------

  static Future<RatchetState> initRatchetSender(Uint8List sharedSecret, Uint8List receiverPublicKey) async {
    final dhPair = generateKeyPair();
    final dhOutput = dhExchange(dhPair.privateKey, receiverPublicKey);
    final (:newRootKey, :chainKey) = await _kdfRootKey(sharedSecret, dhOutput);

    return RatchetState(
      dhSendingKey: dhPair,
      dhReceivingKey: receiverPublicKey,
      rootKey: newRootKey,
      chainKeySend: chainKey,
    );
  }

  static RatchetState initRatchetReceiver(Uint8List sharedSecret, DhKeyPair myKeyPair) {
    return RatchetState(dhSendingKey: myKeyPair, rootKey: sharedSecret);
  }

  // -- Encrypt -------------------------------------------------------

  static Future<({EncryptedMessage encrypted, RatchetState newState})> ratchetEncrypt(
    RatchetState state,
    Uint8List plaintext, {
    Uint8List? associatedData,
  }) async {
    if (state.chainKeySend == null) throw Exception("Sending chain not initialized");

    final (:nextChainKey, :messageKey) = await _kdfChainKey(state.chainKeySend!);
    final iv = _randomBytes(12);

    // AES-256-GCM
    final algorithm = AesGcm.with256bits(nonceLength: 12);
    final secretKey = await algorithm.newSecretKeyFromBytes(messageKey);
    final secretBox = await algorithm.encrypt(
      plaintext,
      secretKey: secretKey,
      nonce: iv,
      aad: associatedData ?? Uint8List(0),
    );

    final ciphertextWithTag = Uint8List.fromList([...secretBox.cipherText, ...secretBox.mac.bytes]);

    // HMAC for additional authenticity
    final header = {
      "dhPublicKey": base64Encode(state.dhSendingKey.publicKey),
      "prevChainCount": state.prevSendingCount,
      "messageIndex": state.sendingIndex,
    };
    final macInput = Uint8List.fromList(utf8.encode(jsonEncode(header)) + ciphertextWithTag + (associatedData ?? Uint8List(0)));
    final hmac = Hmac.sha256();
    final mac = await hmac.calculateMac(macInput, secretKey: SecretKey(messageKey));

    final newState = RatchetState(
      dhSendingKey: state.dhSendingKey,
      dhReceivingKey: state.dhReceivingKey,
      rootKey: state.rootKey,
      chainKeySend: nextChainKey,
      chainKeyRecv: state.chainKeyRecv,
      sendingIndex: state.sendingIndex + 1,
      receivingIndex: state.receivingIndex,
      prevSendingCount: state.prevSendingCount,
      skippedMessageKeys: Map.from(state.skippedMessageKeys),
    );

    return (
      encrypted: EncryptedMessage(
        dhPublicKey: base64Encode(state.dhSendingKey.publicKey),
        prevChainCount: state.prevSendingCount,
        messageIndex: state.sendingIndex,
        ciphertext: base64Encode(ciphertextWithTag),
        iv: base64Encode(iv),
        mac: base64Encode(mac.bytes),
      ),
      newState: newState,
    );
  }

  // -- Decrypt -------------------------------------------------------

  static Future<({Uint8List plaintext, RatchetState newState})> ratchetDecrypt(
    RatchetState state,
    EncryptedMessage message, {
    Uint8List? associatedData,
  }) async {
    final newState = RatchetState(
      dhSendingKey: state.dhSendingKey,
      dhReceivingKey: state.dhReceivingKey,
      rootKey: state.rootKey,
      chainKeySend: state.chainKeySend,
      chainKeyRecv: state.chainKeyRecv,
      sendingIndex: state.sendingIndex,
      receivingIndex: state.receivingIndex,
      prevSendingCount: state.prevSendingCount,
      skippedMessageKeys: Map.from(state.skippedMessageKeys),
    );

    final dhPublicKey = base64Decode(message.dhPublicKey);

    // Check skipped keys
    final skippedKey = "${message.dhPublicKey}:${message.messageIndex}";
    if (newState.skippedMessageKeys.containsKey(skippedKey)) {
      final msgKey = newState.skippedMessageKeys[skippedKey]!;
      newState.skippedMessageKeys.remove(skippedKey);
      final pt = await _decryptWithKey(msgKey, message, associatedData: associatedData);
      return (plaintext: pt, newState: newState);
    }

    // DH Ratchet step
    final needsDhRatchet = newState.dhReceivingKey == null ||
      !_bytesEqual(dhPublicKey, newState.dhReceivingKey!);

    if (needsDhRatchet) {
      if (newState.chainKeyRecv != null) {
        await _skipMessageKeys(newState, message.prevChainCount, dhPublicKey);
      }

      final dhOutput = dhExchange(newState.dhSendingKey.privateKey, dhPublicKey);
      final (:newRootKey, chainKey: ck1) = await _kdfRootKey(newState.rootKey, dhOutput);

      newState.dhReceivingKey = dhPublicKey;
      newState.rootKey = newRootKey;
      newState.chainKeyRecv = ck1;
      newState.prevSendingCount = newState.sendingIndex;
      newState.sendingIndex = 0;
      newState.receivingIndex = 0;

      final newDhPair = generateKeyPair();
      final dhOutput2 = dhExchange(newDhPair.privateKey, dhPublicKey);
      final (:newRootKey: rk2, chainKey: ck2) = await _kdfRootKey(newRootKey, dhOutput2);

      newState.dhSendingKey = newDhPair;
      newState.rootKey = rk2;
      newState.chainKeySend = ck2;
    }

    await _skipMessageKeys(newState, message.messageIndex, dhPublicKey);

    final (:nextChainKey, :messageKey) = await _kdfChainKey(newState.chainKeyRecv!);
    newState.chainKeyRecv = nextChainKey;
    newState.receivingIndex++;

    final pt = await _decryptWithKey(messageKey, message, associatedData: associatedData);
    return (plaintext: pt, newState: newState);
  }

  static Future<void> _skipMessageKeys(RatchetState state, int until, Uint8List dhKey) async {
    if (state.chainKeyRecv == null) return;
    while (state.receivingIndex < until) {
      if (state.skippedMessageKeys.length >= _maxSkip) {
        throw Exception("Too many skipped message keys");
      }
      final (:nextChainKey, :messageKey) = await _kdfChainKey(state.chainKeyRecv!);
      final key = "${base64Encode(dhKey)}:${state.receivingIndex}";
      state.skippedMessageKeys[key] = messageKey;
      state.chainKeyRecv = nextChainKey;
      state.receivingIndex++;
    }
  }

  static Future<Uint8List> _decryptWithKey(
    Uint8List messageKey,
    EncryptedMessage message, {
    Uint8List? associatedData,
  }) async {
    final ciphertextWithTag = base64Decode(message.ciphertext);
    final iv = base64Decode(message.iv);

    final ciphertext = ciphertextWithTag.sublist(0, ciphertextWithTag.length - 16);
    final authTag = ciphertextWithTag.sublist(ciphertextWithTag.length - 16);

    final algorithm = AesGcm.with256bits(nonceLength: 12);
    final secretKey = await algorithm.newSecretKeyFromBytes(messageKey);
    final secretBox = SecretBox(ciphertext, nonce: iv, mac: Mac(authTag));

    return Uint8List.fromList(await algorithm.decrypt(
      secretBox,
      secretKey: secretKey,
      aad: associatedData ?? Uint8List(0),
    ));
  }

  // -- Media Encryption ---------------------------------------------

  static Future<({Uint8List encrypted, Uint8List key, Uint8List iv})> encryptMedia(Uint8List data) async {
    final key = _randomBytes(32);
    final iv = _randomBytes(12);
    final algorithm = AesGcm.with256bits(nonceLength: 12);
    final secretKey = await algorithm.newSecretKeyFromBytes(key);
    final secretBox = await algorithm.encrypt(data, secretKey: secretKey, nonce: iv);
    final encrypted = Uint8List.fromList([...secretBox.cipherText, ...secretBox.mac.bytes]);
    return (encrypted: encrypted, key: key, iv: iv);
  }

  static Future<Uint8List> decryptMedia(Uint8List encrypted, Uint8List key, Uint8List iv) async {
    final ciphertext = encrypted.sublist(0, encrypted.length - 16);
    final authTag = encrypted.sublist(encrypted.length - 16);
    final algorithm = AesGcm.with256bits(nonceLength: 12);
    final secretKey = await algorithm.newSecretKeyFromBytes(key);
    final secretBox = SecretBox(ciphertext, nonce: iv, mac: Mac(authTag));
    return Uint8List.fromList(await algorithm.decrypt(secretBox, secretKey: secretKey));
  }

  // -- Utilities -----------------------------------------------------

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
