// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:fluffychat/utils/private_avatar_crop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/widgets/private_avatar_crop_page.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  for (final cancellation in ['Cancel', 'Close', 'system back']) {
    testWidgets(
      '$cancellation during encoding keeps profile open when encoding completes during reverse transition',
      (tester) async {
        final navigator = GlobalKey<NavigatorState>();
        final encoding = Completer<Uint8List>();
        final originalPhoto = Uint8List.fromList([42]);
        var photo = originalPhoto;
        Uint8List? result;
        var returned = false;
        var encodingStarted = false;
        final source = Uint8List.fromList(
          img.encodePng(img.Image(width: 8, height: 8)),
        );
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            locale: const Locale('en'),
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: const Scaffold(body: Text('Home route')),
          ),
        );
        await tester.pumpAndSettle();
        final profile = MaterialPageRoute<void>(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showPrivateAvatarCrop(
                  context,
                  source,
                  encoder: (image, crop) {
                    encodingStarted = true;
                    return encoding.future;
                  },
                );
                if (result != null) photo = result!;
                returned = true;
              },
              child: const Text('Profile route'),
            ),
          ),
        );
        unawaited(navigator.currentState!.push(profile));
        await tester.pumpAndSettle();
        await tester.runAsync(() => tester.tap(find.text('Profile route')));
        for (var i = 0; i < 5; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('private-avatar-crop-viewport')),
          findsOneWidget,
        );
        final editorContext = tester.element(
          find.byKey(const ValueKey('private-avatar-crop-viewport')),
        );
        final editor = ModalRoute.of(editorContext)!;
        await tester.tap(find.byType(FilledButton));
        await tester.pump();
        expect(encodingStarted, isTrue);
        if (cancellation == 'system back') {
          await tester.binding.handlePopRoute();
        } else if (cancellation == 'Close') {
          await tester.tap(find.byIcon(Icons.close));
        } else {
          await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));
        // Exercise the race while the dismissed editor is still mounted, not
        // after pumpAndSettle has disposed it.
        expect(editorContext.mounted, isTrue);
        expect(editor.animation!.status, AnimationStatus.reverse);
        expect(editor.isCurrent, isFalse);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        expect(returned, isTrue);
        expect(result, isNull);
        encoding.complete(Uint8List.fromList([1, 2, 3]));
        await tester.pump();
        await tester.pumpAndSettle();
        expect(profile.isCurrent, isTrue);
        expect(find.text('Profile route'), findsOneWidget);
        expect(find.text('Home route'), findsNothing);
        expect(navigator.currentState!.canPop(), isTrue);
        expect(result, isNull);
        expect(photo, same(originalPhoto));
        expect(tester.takeException(), isNull);
      },
    );
  }

  test(
    'initial crop is the largest centered square for portrait and landscape',
    () {
      expect(
        privateAvatarCropRect(const ui.Size(600, 400)),
        const ui.Rect.fromLTWH(100, 0, 400, 400),
      );
      expect(
        privateAvatarCropRect(const ui.Size(400, 600)),
        const ui.Rect.fromLTWH(0, 100, 400, 400),
      );
    },
  );
  test('zoom and panning keep the selected source point under the fingers', () {
    const size = ui.Size(600, 400);
    final start = privateAvatarCropRect(size);
    expect(
      privateAvatarGestureCrop(
        size,
        start: start,
        startFocal: const ui.Offset(100, 100),
        focal: const ui.Offset(100, 100),
        viewport: 200,
        scale: 2,
      ),
      const ui.Rect.fromLTWH(200, 100, 200, 200),
    );
    expect(
      privateAvatarGestureCrop(
        size,
        start: start,
        startFocal: const ui.Offset(100, 100),
        focal: const ui.Offset(150, 100),
        viewport: 200,
        scale: 2,
      ),
      const ui.Rect.fromLTWH(150, 100, 200, 200),
    );
    final edge = privateAvatarCropRect(
      size,
      zoom: 5,
      center: const ui.Offset(-500, 900),
    );
    expect(edge.left, 0);
    expect(edge.bottom, 400);
    expect(edge.width, 80);
  });
  test(
    'off-center pinch retains its source anchor while the focal point moves',
    () {
      const size = ui.Size(600, 400);
      final start = privateAvatarCropRect(size);
      const startFocal = ui.Offset(50, 60);
      const focal = ui.Offset(70, 80);
      final crop = privateAvatarGestureCrop(
        size,
        start: start,
        startFocal: startFocal,
        focal: focal,
        viewport: 200,
        scale: 2,
      );
      expect(crop, const ui.Rect.fromLTWH(130, 40, 200, 200));
      final sourceAnchor = start.topLeft + startFocal * (start.width / 200);
      expect(crop.topLeft + focal * (crop.width / 200), sourceAnchor);
    },
  );
  test('export is square PNG and preserves the actual selected area', () async {
    final source = img.Image(width: 8, height: 4);
    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        source.setPixelRgb(x, y, x < 4 ? 255 : 0, 0, x < 4 ? 0 : 255);
      }
    }
    final image = await decodePrivateAvatarCropImage(
      Uint8List.fromList(img.encodePng(source)),
    );
    try {
      final bytes = await encodePrivateAvatarCrop(
        image,
        const ui.Rect.fromLTWH(4, 0, 4, 4),
      );
      final result = img.decodePng(bytes)!;
      expect(result.width, 256);
      expect(result.height, 256);
      expect(result.getPixel(128, 128).b, 255);
      expect(result.getPixel(128, 128).r, 0);
      await expectLater(
        encodePrivateAvatarCrop(image, const ui.Rect.fromLTWH(-1, 0, 4, 4)),
        throwsArgumentError,
      );
    } finally {
      image.dispose();
    }
  });
  test('invalid encoded data is rejected before opening a crop page', () async {
    await expectLater(
      decodePrivateAvatarCropImage(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
  });
}
