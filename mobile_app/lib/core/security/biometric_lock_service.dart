// ================================================================
// Massengar - Biometric Lock & SQLCipher Security Service
// Phase 4: Chat Lock + Anti-Screenshot + Secure Local Storage
// ================================================================

import "package:flutter/foundation.dart";
import "package:flutter/services.dart";
import "package:local_auth/local_auth.dart";
import "package:flutter_secure_storage/flutter_secure_storage.dart";
import "package:sqflite_sqlcipher/sqflite.dart";
import "package:path/path.dart";
import "dart:convert";
import "dart:math";

// -- Biometric Authentication Service ------------------------------

class BiometricAuthService {
  static final BiometricAuthService _instance = BiometricAuthService._internal();
  factory BiometricAuthService() => _instance;
  BiometricAuthService._internal();

  final LocalAuthentication _localAuth = LocalAuthentication();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  // -- Check Biometric Availability ---------------------------------

  Future<bool> isBiometricsAvailable() async {
    try {
      final isAvailable = await _localAuth.isDeviceSupported();
      final canCheck = await _localAuth.canCheckBiometrics;
      return isAvailable && canCheck;
    } catch (e) {
      return false;
    }
  }

  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _localAuth.getAvailableBiometrics();
    } catch (e) {
      return [];
    }
  }

  // -- Authenticate -------------------------------------------------

  Future<bool> authenticate({
    String reason = "Authenticate to access locked chats",
    bool useErrorDialogs = true,
    bool stickyAuth = true,
  }) async {
    try {
      final bool didAuthenticate = await _localAuth.authenticate(
        localizedReason: reason,
        options: AuthenticationOptions(
          biometricOnly: false,
          useErrorDialogs: useErrorDialogs,
          stickyAuth: stickyAuth,
        ),
      );
      return didAuthenticate;
    } on PlatformException catch (e) {
      debugPrint("Biometric auth error: $e");
      return false;
    }
  }

  Future<bool> authenticateToUnlockChat(String chatId) async {
    return authenticate(
      reason: "Authenticate to open locked conversation",
      stickyAuth: true,
    );
  }

  // -- DB Encryption Key Management ---------------------------------

  static const String _dbKeyStorageKey = "massengar_db_cipher_key";

  Future<String> getOrCreateDatabaseKey() async {
    final existingKey = await _secureStorage.read(key: _dbKeyStorageKey);
    if (existingKey != null) return existingKey;

    // Generate a new 256-bit key backed by OS KeyStore/Keychain
    final random = Random.secure();
    final keyBytes = Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
    final keyBase64 = base64Encode(keyBytes);

    await _secureStorage.write(
      key: _dbKeyStorageKey,
      value: keyBase64,
      aOptions: const AndroidOptions(
        encryptedSharedPreferences: true,
        keyCipherAlgorithm: KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
        storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
      ),
      iOptions: const IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    );

    return keyBase64;
  }

  // -- Session Key for Locked Chat -----------------------------------

  Future<void> storeChatSessionKey(String chatId, String sessionKey) async {
    await _secureStorage.write(
      key: "chat_session_$chatId",
      value: sessionKey,
    );
  }

  Future<String?> getChatSessionKey(String chatId) async {
    return _secureStorage.read(key: "chat_session_$chatId");
  }

  Future<void> clearChatSessionKey(String chatId) async {
    await _secureStorage.delete(key: "chat_session_$chatId");
  }
}

// -- SQLCipher Local Database --------------------------------------

class LocalDatabase {
  static final LocalDatabase _instance = LocalDatabase._internal();
  factory LocalDatabase() => _instance;
  LocalDatabase._internal();

  Database? _db;
  final BiometricAuthService _biometricService = BiometricAuthService();

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDatabase();
    return _db!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, "massengar_local.db");
    final encryptionKey = await _biometricService.getOrCreateDatabaseKey();

    return openDatabase(
      path,
      password: encryptionKey, // SQLCipher AES-256 encryption
      version: 1,
      onCreate: _createTables,
      onUpgrade: _upgradeTables,
      onOpen: (db) async {
        // Enforce WAL journal mode for performance
        await db.execute("PRAGMA journal_mode=WAL");
        await db.execute("PRAGMA cipher_memory_security=ON");
        await db.execute("PRAGMA cipher_use_hmac=ON");
      },
    );
  }

  Future<void> _createTables(Database db, int version) async {
    // Local users cache
    await db.execute("""
      CREATE TABLE local_users (
        id TEXT PRIMARY KEY,
        username TEXT UNIQUE NOT NULL,
        display_name TEXT NOT NULL,
        avatar_url TEXT,
        is_online INTEGER DEFAULT 0,
        last_seen INTEGER,
        identity_public_key TEXT
      )
    """);

    // Local conversations cache
    await db.execute("""
      CREATE TABLE local_conversations (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        name TEXT,
        avatar_url TEXT,
        is_locked INTEGER DEFAULT 0,
        disappearing_timer INTEGER DEFAULT 0,
        last_message_preview TEXT,
        last_message_at INTEGER,
        unread_count INTEGER DEFAULT 0,
        updated_at INTEGER
      )
    """);

    // Local messages (ciphertext + ratchet state)
    await db.execute("""
      CREATE TABLE local_messages (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        ciphertext TEXT NOT NULL,
        message_type TEXT DEFAULT 'text',
        reply_to_id TEXT,
        is_view_once INTEGER DEFAULT 0,
        viewed INTEGER DEFAULT 0,
        expires_at INTEGER,
        deleted_for_all INTEGER DEFAULT 0,
        status TEXT DEFAULT 'sent',
        ratchet_epoch INTEGER DEFAULT 0,
        message_index INTEGER DEFAULT 0,
        created_at INTEGER NOT NULL,
        FOREIGN KEY (conversation_id) REFERENCES local_conversations(id) ON DELETE CASCADE
      )
    """);

    await db.execute("CREATE INDEX idx_lmsg_conv ON local_messages(conversation_id, created_at DESC)");

    // Ratchet states (per conversation, encrypted by DB key)
    await db.execute("""
      CREATE TABLE ratchet_states (
        conversation_id TEXT PRIMARY KEY,
        state_json TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    """);

    // Pending outbound messages (for offline queue)
    await db.execute("""
      CREATE TABLE pending_messages (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        ciphertext TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    """);

    // Media cache metadata (actual files in OS temp)
    await db.execute("""
      CREATE TABLE media_cache (
        asset_id TEXT PRIMARY KEY,
        local_path TEXT,
        mime_type TEXT,
        is_view_once INTEGER DEFAULT 0,
        is_purged INTEGER DEFAULT 0,
        cached_at INTEGER
      )
    """);
  }

  Future<void> _upgradeTables(Database db, int oldVersion, int newVersion) async {
    // Handle migrations in future versions
  }

  // -- Chat Lock Operations ------------------------------------------

  Future<void> setConversationLocked(String conversationId, bool locked) async {
    final db = await database;
    await db.update(
      "local_conversations",
      {"is_locked": locked ? 1 : 0},
      where: "id = ?",
      whereArgs: [conversationId],
    );
  }

  Future<bool> isConversationLocked(String conversationId) async {
    final db = await database;
    final result = await db.query(
      "local_conversations",
      columns: ["is_locked"],
      where: "id = ?",
      whereArgs: [conversationId],
    );
    if (result.isEmpty) return false;
    return result.first["is_locked"] == 1;
  }

  Future<List<Map<String, dynamic>>> getLockedConversations() async {
    final db = await database;
    return db.query(
      "local_conversations",
      where: "is_locked = 1",
      orderBy: "last_message_at DESC",
    );
  }

  // -- Ratchet State Persistence -------------------------------------

  Future<String?> getRatchetState(String conversationId) async {
    final db = await database;
    final result = await db.query(
      "ratchet_states",
      where: "conversation_id = ?",
      whereArgs: [conversationId],
    );
    if (result.isEmpty) return null;
    return result.first["state_json"] as String?;
  }

  Future<void> saveRatchetState(String conversationId, String stateJson) async {
    final db = await database;
    await db.insert(
      "ratchet_states",
      {
        "conversation_id": conversationId,
        "state_json": stateJson,
        "updated_at": DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // -- Message Operations --------------------------------------------

  Future<void> insertMessage(Map<String, dynamic> message) async {
    final db = await database;
    await db.insert("local_messages", message, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getMessages(String conversationId, {int limit = 50, int? before}) async {
    final db = await database;
    return db.query(
      "local_messages",
      where: before != null
        ? "conversation_id = ? AND created_at < ? AND deleted_for_all = 0"
        : "conversation_id = ? AND deleted_for_all = 0",
      whereArgs: before != null ? [conversationId, before] : [conversationId],
      orderBy: "created_at DESC",
      limit: limit,
    );
  }

  Future<void> markMessageRead(String messageId) async {
    final db = await database;
    await db.update("local_messages", {"status": "read"}, where: "id = ?", whereArgs: [messageId]);
  }

  Future<void> purgeExpiredMessages() async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      "local_messages",
      {"ciphertext": "", "deleted_for_all": 1},
      where: "expires_at IS NOT NULL AND expires_at < ? AND deleted_for_all = 0",
      whereArgs: [now],
    );
  }
}

// -- Anti-Screenshot / Screen Security Service ---------------------

class ScreenSecurityService {
  static const MethodChannel _channel = MethodChannel("massengar/screen_security");

  /// Enable FLAG_SECURE (Android) or screen masking (iOS)
  /// Call before rendering locked chat content
  static Future<void> enableSecureMode() async {
    try {
      await _channel.invokeMethod("enableSecureMode");
    } on PlatformException catch (e) {
      debugPrint("Screen security error: $e");
    }
  }

  static Future<void> enableSecureScreen() => enableSecureMode();

  /// Disable secure mode when leaving locked chat
  static Future<void> disableSecureMode() async {
    try {
      await _channel.invokeMethod("disableSecureMode");
    } on PlatformException catch (e) {
      debugPrint("Screen security error: $e");
    }
  }

  static Future<void> disableSecureScreen() => disableSecureMode();

  /// Blur app thumbnail in recent apps switcher (for locked chats)
  static Future<void> setAppSwitcherBlurred(bool blurred) async {
    try {
      await _channel.invokeMethod("setAppSwitcherBlurred", {"blurred": blurred});
    } on PlatformException catch (e) {
      debugPrint("App switcher blur error: $e");
    }
  }
}
