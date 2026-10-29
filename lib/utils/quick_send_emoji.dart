import 'dart:convert';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/adaptive_bottom_sheet.dart';
import 'package:flutter/material.dart';

// Fork: pouce rapide par conversation.
// Résolution : override de la pièce > réglage global > vide (= micro champ).
// Stockage : clé de réglage locale JSON map {roomId: emoji} — pas d'account
// data, pas de sync (choix produit : préférence purement locale).

/// Sentinelle renvoyée par [showQuickSendEmojiSheet] quand l'utilisateur
/// demande à revenir au réglage global pour cette conversation.
class QuickSendEmojiReset {
  const QuickSendEmojiReset();
}

Map<String, dynamic> _roomOverrides() {
  try {
    final raw = jsonDecode(AppSettings.quickSendEmojiRooms.value);
    if (raw is Map<String, dynamic>) return raw;
  } catch (_) {
    // réglage corrompu ⇒ on repart d'une carte vide
  }
  return {};
}

/// Emoji effectif pour la conversation [roomId] (override > global).
String resolveQuickSendEmoji(String roomId) {
  final override = _roomOverrides()[roomId];
  if (override is String && override.isNotEmpty) return override;
  return AppSettings.quickSendEmoji.value;
}

/// Fixe ([emoji] non vide) ou retire ([emoji] null/vide) l'override de la
/// conversation ; retourne true si le réglage a changé.
Future<bool> setQuickSendEmojiOverride(String roomId, String? emoji) async {
  final map = _roomOverrides();
  final before = map[roomId];
  if (emoji == null || emoji.isEmpty) {
    map.remove(roomId);
  } else {
    map[roomId] = emoji;
  }
  if (before == map[roomId]) return false;
  await AppSettings.quickSendEmojiRooms.setItem(jsonEncode(map));
  return true;
}

/// Emoji actuellement en override pour [roomId] ('' si aucun).
String quickSendEmojiOverride(String roomId) {
  final override = _roomOverrides()[roomId];
  return override is String ? override : '';
}

/// Bottom sheet de choix d'emoji du pouce rapide (picker partagé entre les
/// réglages globaux et l'appui long dans le composer).
/// Retourne l'emoji choisi, [QuickSendEmojiReset] si réinitialisation
/// conversation, sinon null (annulé).
Future<Object?> showQuickSendEmojiSheet(
  BuildContext context, {
  String? roomId,
}) async {
  final theme = Theme.of(context);
  return showAdaptiveBottomSheet<Object>(
    context: context,
    builder: (context) => Scaffold(
      appBar: AppBar(
        title: Text(
          roomId == null
              ? 'Emoji du pouce rapide'
              : 'Pouce rapide de cette conversation',
        ),
        leading: CloseButton(onPressed: () => Navigator.of(context).pop(null)),
        actions: [
          if (roomId != null && quickSendEmojiOverride(roomId).isNotEmpty)
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(const QuickSendEmojiReset()),
              child: const Text('Réinitialiser'),
            ),
        ],
      ),
      body: SizedBox(
        height: double.infinity,
        child: EmojiPicker(
          onEmojiSelected: (_, emoji) => Navigator.of(context).pop(emoji.emoji),
          config: Config(
            locale: Localizations.localeOf(context),
            emojiViewConfig: const EmojiViewConfig(
              backgroundColor: Colors.transparent,
            ),
            bottomActionBarConfig: const BottomActionBarConfig(enabled: false),
            categoryViewConfig: CategoryViewConfig(
              initCategory: Category.RECENT,
              backspaceColor: theme.colorScheme.primary,
              iconColor: theme.colorScheme.primary.withAlpha(128),
              iconColorSelected: theme.colorScheme.primary,
              indicatorColor: theme.colorScheme.primary,
              backgroundColor: theme.colorScheme.surface,
            ),
            skinToneConfig: SkinToneConfig(
              dialogBackgroundColor: Color.lerp(
                theme.colorScheme.surface,
                theme.colorScheme.primaryContainer,
                0.75,
              )!,
              indicatorColor: theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
    ),
  );
}
