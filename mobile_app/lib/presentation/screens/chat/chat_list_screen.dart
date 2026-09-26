import 'package:flutter/material.dart';
import '../../widgets/glass_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/security/biometric_lock_service.dart';
import 'chat_room_screen.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  final BiometricAuthService _biometricAuth = BiometricAuthService();

  final List<Map<String, dynamic>> _mockChats = [
    {
      "id": "1",
      "name": "Alice Wonderland",
      "lastMsg": "The encryption works flawlessly! 🔐",
      "time": "12:30 PM",
      "unread": 2,
      "avatar": "https://i.pravatar.cc/150?u=alice",
      "isLocked": false,
    },
    {
      "id": "2",
      "name": "Bob Builder",
      "lastMsg": "Let's test the WebRTC call.",
      "time": "Yesterday",
      "unread": 0,
      "avatar": "https://i.pravatar.cc/150?u=bob",
      "isLocked": false,
    },
    {
      "id": "3",
      "name": "Secret Project Vault",
      "lastMsg": "This chat is locked.",
      "time": "2 days ago",
      "unread": 0,
      "avatar": "https://i.pravatar.cc/150?u=vault",
      "isLocked": true,
    }
  ];

  void _openChat(Map<String, dynamic> chat) async {
    if (chat["isLocked"] == true) {
      final auth = await _biometricAuth.authenticateToUnlockChat(chat["id"]);
      if (!auth) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Authentication failed to open locked chat.")),
        );
        return;
      }
    }

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatRoomScreen(chatData: chat)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Background Gradient
          Positioned(
            top: -50,
            left: -50,
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [AppTheme.secondary.withOpacity(0.3), Colors.transparent],
                ),
              ),
            ),
          ),
          
          CustomScrollView(
            slivers: [
              SliverAppBar(
                expandedHeight: 120.0,
                floating: true,
                pinned: true,
                flexibleSpace: FlexibleSpaceBar(
                  title: const Text("Chats", style: TextStyle(fontWeight: FontWeight.bold)),
                  background: Container(color: Colors.transparent),
                ),
                actions: [
                  IconButton(icon: const Icon(Icons.search), onPressed: () {}),
                  IconButton(icon: const Icon(Icons.more_vert), onPressed: () {}),
                ],
              ),

              // Stories Row
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 100,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: 6,
                    itemBuilder: (context, index) {
                      return Padding(
                        padding: const EdgeInsets.only(right: 16.0),
                        child: Column(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(3),
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: AppTheme.primaryGradient,
                              ),
                              child: CircleAvatar(
                                radius: 30,
                                backgroundImage: NetworkImage("https://i.pravatar.cc/150?img=${index + 10}"),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(index == 0 ? "My Story" : "User $index", style: const TextStyle(fontSize: 12)),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
              
              const SliverToBoxAdapter(child: SizedBox(height: 16)),

              // Chat List
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final chat = _mockChats[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                      child: GlassContainer(
                        padding: const EdgeInsets.all(12),
                        onTap: () => _openChat(chat),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 28,
                              backgroundImage: NetworkImage(chat["avatar"]),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          chat["name"],
                                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (chat["isLocked"])
                                        const Icon(Icons.lock_outline, size: 16, color: AppTheme.textMuted),
                                      const SizedBox(width: 8),
                                      Text(
                                        chat["time"],
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: chat["unread"] > 0 ? AppTheme.primary : AppTheme.textMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          chat["lastMsg"],
                                          style: TextStyle(
                                            color: AppTheme.textMuted,
                                            fontWeight: chat["unread"] > 0 ? FontWeight.bold : FontWeight.normal,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (chat["unread"] > 0)
                                        Container(
                                          padding: const EdgeInsets.all(6),
                                          decoration: const BoxDecoration(
                                            color: AppTheme.primary,
                                            shape: BoxShape.circle,
                                          ),
                                          child: Text(
                                            chat["unread"].toString(),
                                            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                  childCount: _mockChats.length,
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {},
        backgroundColor: AppTheme.primary,
        child: const Icon(Icons.edit, color: Colors.white),
      ),
    );
  }
}
