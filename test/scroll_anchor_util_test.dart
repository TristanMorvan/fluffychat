// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/utils/scroll_anchor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

Widget _tree(
  AutoScrollController controller,
  List<String> eventIds, {
  required void Function(BuildContext) captureContext,
}) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(
    data: const MediaQueryData(),
    child: Builder(
      builder: (context) {
        captureContext(context);
        return ListView.builder(
          reverse: true,
          controller: controller,
          itemCount: eventIds.length,
          itemBuilder: (context, i) => SizedBox(
            height: 100,
            child: AutoScrollTag(
              key: ValueKey(eventIds[i]),
              controller: controller,
              index: i,
              child: Text(eventIds[i]),
            ),
          ),
        );
      },
    ),
  ),
);

void main() {
  testWidgets(
    'a new event at the bottom jumps the reading position; '
    'anchor compensation restores it',
    (tester) async {
      final controller = AutoScrollController();
      addTearDown(controller.dispose);
      final anchors = ChatScrollAnchors();
      late BuildContext listContext;
      final eventIds = List.generate(30, (i) => '\$e$i');
      String? eventIdOfIndex(int i) =>
          i >= 0 && i < eventIds.length ? eventIds[i] : null;

      await tester.pumpWidget(
        _tree(controller, eventIds, captureContext: (c) => listContext = c),
      );
      // Scrolled up: 5 screens above the bottom of the reversed list.
      controller.jumpTo(500);
      await tester.pumpAndSettle();

      // The anchor is the newest laid-out message (lowest row on screen).
      final anchor = anchors.measure(
        listContext,
        controller,
        eventIdOfIndex: eventIdOfIndex,
      );
      expect(anchor, isNotNull);
      expect(anchor!.eventId, '\$e5');
      final topBefore = tester.getTopLeft(find.text('\$e5')).dy;
      expect(anchor.offsetInViewport, closeTo(topBefore, 1));

      // A newer event arrives (index 0 in the reversed list) while reading.
      eventIds.insert(0, r'$new');
      await tester.pumpWidget(
        _tree(controller, eventIds, captureContext: (c) => listContext = c),
      );
      await tester.pumpAndSettle();

      // Without compensation the reading position jumped: pixels never
      // changed but the anchored message moved up by the new event's height.
      expect(tester.getTopLeft(find.text('\$e5')).dy, closeTo(400, 1));

      // Compensating restores the exact reading position.
      expect(
        anchors.apply(
          listContext,
          anchor,
          controller,
          eventIdOfIndex: eventIdOfIndex,
        ),
        isTrue,
      );
      await tester.pumpAndSettle();

      final topRestored = tester.getTopLeft(find.text('\$e5')).dy;
      expect(topRestored, closeTo(topBefore, 1));
      final restored = anchors.measure(
        listContext,
        controller,
        eventIdOfIndex: eventIdOfIndex,
      );
      expect(restored!.eventId, '\$e5');
    },
  );

  testWidgets('anchor while pinned at the bottom is the newest event', (
    tester,
  ) async {
    final controller = AutoScrollController();
    addTearDown(controller.dispose);
    final anchors = ChatScrollAnchors();
    late BuildContext listContext;
    final eventIds = List.generate(30, (i) => '\$e$i');
    String? eventIdOfIndex(int i) =>
        i >= 0 && i < eventIds.length ? eventIds[i] : null;

    await tester.pumpWidget(
      _tree(controller, eventIds, captureContext: (c) => listContext = c),
    );
    controller.jumpTo(0);
    await tester.pumpAndSettle();

    // Pinned at the bottom: the chat layer must not compensate (it only
    // arms the anchor when scrolled up); the utility itself just reports
    // the newest laid-out tag.
    final anchor = anchors.measure(
      listContext,
      controller,
      eventIdOfIndex: eventIdOfIndex,
    );
    expect(anchor!.eventId, '\$e0');
  });
}
