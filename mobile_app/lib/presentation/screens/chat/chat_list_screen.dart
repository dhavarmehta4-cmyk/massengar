import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../widgets/glass_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/security/biometric_lock_service.dart';
import '../../../domain/entities/chat_entities.dart';
import '../../blocs/chat/chat_bloc.dart';
import 'chat_room_screen.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  final BiometricAuthService _biometricAuth = BiometricAuthService();

  @override
  void initState() {
    super.initState();
    // Kick off the conversation list load when the screen mounts.
    context.read<ChatBloc>().add(LoadConversations());
  }

  void _openChat(Conversation conv) async {
    if (conv.isLocked) {
      final auth = await _biometricAuth.authenticateToUnlockChat(conv.id);
      if (!auth) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Authentication failed to open locked chat.')),
        );
        return;
      }
    }

    if (!mounted) return;

    // Tell the BLoC we've entered this conversation before pushing the route.
    context.read<ChatBloc>().add(EnterConversation(conv.id));

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BlocProvider.value(
          value: context.read<ChatBloc>(),
          child: ChatRoomScreen(conversation: conv),
        ),
      ),
    ).then((_) {
      // When user pops back, release the active chat room from the BLoC.
      if (mounted) {
        context.read<ChatBloc>().add(LeaveConversation());
        context.read<ChatBloc>().add(LoadConversations());
      }
    });
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

          BlocBuilder<ChatBloc, ChatState>(
            buildWhen: (prev, curr) =>
                curr is ConversationsLoaded || curr is ChatLoading || curr is ChatError,
            builder: (context, state) {
              return CustomScrollView(
                slivers: [
                  SliverAppBar(
                    expandedHeight: 120.0,
                    floating: true,
                    pinned: true,
                    flexibleSpace: FlexibleSpaceBar(
                      title: const Text('Chats', style: TextStyle(fontWeight: FontWeight.bold)),
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
                                    backgroundImage: NetworkImage('https://i.pravatar.cc/150?img=${index + 10}'),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  index == 0 ? 'My Story' : 'User $index',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),

                  const SliverToBoxAdapter(child: SizedBox(height: 16)),

                  // Body: loading / error / list
                  if (state is ChatLoading)
                    const SliverFillRemaining(
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (state is ChatError)
                    SliverFillRemaining(
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.wifi_off, size: 48, color: AppTheme.textMuted),
                            const SizedBox(height: 12),
                            Text(state.message, style: const TextStyle(color: AppTheme.textMuted)),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: () => context.read<ChatBloc>().add(LoadConversations()),
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      ),
                    )
                  else if (state is ConversationsLoaded && state.conversations.isEmpty)
                    const SliverFillRemaining(
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.chat_bubble_outline, size: 64, color: AppTheme.textMuted),
                            SizedBox(height: 16),
                            Text(
                              'No conversations yet.\nTap the edit button to start a chat.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: AppTheme.textMuted),
                            ),
                          ],
                        ),
                      ),
                    )
                  else if (state is ConversationsLoaded)
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final conv = state.conversations[index];
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                            child: GlassContainer(
                              padding: const EdgeInsets.all(12),
                              onTap: () => _openChat(conv),
                              child: Row(
                                children: [
                                  Stack(
                                    children: [
                                      CircleAvatar(
                                        radius: 28,
                                        backgroundImage: NetworkImage(conv.avatarUrl),
                                      ),
                                      if (conv.isOnline)
                                        Positioned(
                                          bottom: 0,
                                          right: 0,
                                          child: Container(
                                            width: 12,
                                            height: 12,
                                            decoration: BoxDecoration(
                                              color: AppTheme.secondary,
                                              shape: BoxShape.circle,
                                              border: Border.all(color: AppTheme.background, width: 2),
                                            ),
                                          ),
                                        ),
                                    ],
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
                                                conv.name,
                                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            if (conv.isLocked)
                                              const Icon(Icons.lock_outline, size: 16, color: AppTheme.textMuted),
                                            const SizedBox(width: 8),
                                            Text(
                                              conv.formattedTime,
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: conv.unreadCount > 0 ? AppTheme.primary : AppTheme.textMuted,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 6),
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                conv.lastMessage,
                                                style: TextStyle(
                                                  color: AppTheme.textMuted,
                                                  fontWeight: conv.unreadCount > 0 ? FontWeight.bold : FontWeight.normal,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            if (conv.unreadCount > 0)
                                              Container(
                                                padding: const EdgeInsets.all(6),
                                                decoration: const BoxDecoration(
                                                  color: AppTheme.primary,
                                                  shape: BoxShape.circle,
                                                ),
                                                child: Text(
                                                  conv.unreadCount.toString(),
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
                        childCount: state.conversations.length,
                      ),
                    ),
                ],
              );
            },
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
