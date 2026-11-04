// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/widgets.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

/// Reading-position anchor for the reversed chat timeline.
///
/// When new events are inserted at the bottom of a `ListView(reverse: true)`
/// the visible content jumps even though `ScrollPosition.pixels` never
/// changed — the message the user is reading moves off place. The recipe is:
/// [measure] before the timeline rebuild, then [apply] after the new layout
/// (post-frame): the scroll offset is shifted so that the anchor row returns
/// to the exact screen position it had.
///
/// Measurements walk the live element tree below the list context and read
/// the render boxes of the mounted `AutoScrollTag`s. The `tagMap` of
/// `AutoScrollController` keeps stale entries after index shifts and must
/// not be trusted for geometry.
class ScrollAnchorInfo {
  const ScrollAnchorInfo({
    required this.eventId,
    required this.offsetInViewport,
  });

  final String eventId;

  /// Top of the anchor row relative to the top of the screen (global dy).
  final double offsetInViewport;
}

/// Collects the on-screen rows of one chat timeline and restores the reading
/// position across timeline updates. One instance per open chat page.
class ChatScrollAnchors {
  /// Global dy of every laid-out event row, keyed by `AutoScrollTag` index.
  Map<int, double> _rowOffsets(BuildContext listContext) {
    final offsets = <int, double>{};
    void walk(Element element) {
      final state = element is StatefulElement ? element.state : null;
      if (state is AutoScrollTagState) {
        final renderObject = element.renderObject;
        if (renderObject is RenderBox && renderObject.hasSize) {
          offsets[state.widget.index] = renderObject.localToGlobal(
            Offset.zero,
          ).dy;
        }
        return;
      }
      element.visitChildren(walk);
    }

    (listContext as Element).visitChildren(walk);
    return offsets;
  }

  /// The newest laid-out event row (lowest top edge on screen): far enough
  /// from the bottom edge where new events are inserted to stay measurable
  /// across an insertion. Null when no event row is laid out.
  ///
  /// [eventIdOfIndex] maps an `AutoScrollTag` index to its event id (null
  /// for non-event rows such as the typing-indicator footer).
  ScrollAnchorInfo? measure(
    BuildContext listContext,
    ScrollController controller, {
    required String? Function(int index) eventIdOfIndex,
  }) {
    if (!controller.hasClients) return null;
    final viewportBottom = controller.position.viewportDimension;
    ScrollAnchorInfo? anchor;
    for (final entry in _rowOffsets(listContext).entries) {
      // Rows laid out in the cache extent below the screen are not anchors.
      if (entry.value >= viewportBottom) continue;
      final eventId = eventIdOfIndex(entry.key);
      if (eventId == null) continue;
      final candidate = ScrollAnchorInfo(
        eventId: eventId,
        offsetInViewport: entry.value,
      );
      if (anchor == null ||
          candidate.offsetInViewport > anchor.offsetInViewport) {
        anchor = candidate;
      }
    }
    return anchor;
  }

  /// Jumps [controller] so that [anchor] sits again at the viewport offset
  /// it had when measured. Returns true when a compensation jump happened.
  /// Does nothing when the anchor row is gone (timeline reloaded, list
  /// shorter than before) or when nothing moved.
  bool apply(
    BuildContext listContext,
    ScrollAnchorInfo anchor,
    ScrollController controller, {
    required String? Function(int index) eventIdOfIndex,
  }) {
    if (!controller.hasClients) return false;
    double? newOffset;
    for (final entry in _rowOffsets(listContext).entries) {
      if (eventIdOfIndex(entry.key) == anchor.eventId) {
        newOffset = entry.value;
        break;
      }
    }
    if (newOffset == null) return false;
    final delta = anchor.offsetInViewport - newOffset;
    if (delta == 0) return false;
    final position = controller.position;
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return false;
    position.jumpTo(target);
    return true;
  }
}
