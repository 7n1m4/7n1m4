// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/widgets.dart';

import 'chat_feed_event.dart';

/// Small feed affix that is present only while a gap blocks rendering.
///
/// With no open gap it is absent from the tree, not merely hidden, so callers
/// can treat `find.byKey` presence as the gap state.
class ChatFeedGapIndicator extends StatelessWidget {
  const ChatFeedGapIndicator({super.key, required this.gap});

  final ChatFeedGap? gap;

  @override
  Widget build(BuildContext context) {
    final current = gap;
    if (current == null || !current.isOpen) return const SizedBox.shrink();

    return KeyedSubtree(
      key: const Key('chat-feed-gap-indicator'),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Text('Waiting for ${current.missingSeqs.join(', ')}'),
      ),
    );
  }
}
