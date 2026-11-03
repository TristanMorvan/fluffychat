// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/private_avatar_crop.dart';
import 'package:material_ui/material_ui.dart';

/// Decode locally, then transfer image ownership to the editor route. Cancelling
/// returns null and never writes to the private store or to Matrix.
Future<Uint8List?> showPrivateAvatarCrop(
  BuildContext context,
  Uint8List bytes, {
  Future<Uint8List> Function(ui.Image, ui.Rect) encoder =
      encodePrivateAvatarCrop,
}) async {
  final image = await decodePrivateAvatarCropImage(bytes);
  if (!context.mounted) {
    image.dispose();
    return null;
  }
  try {
    return Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _PrivateAvatarCropPage(image: image, encoder: encoder),
      ),
    );
  } catch (_) {
    image.dispose();
    rethrow;
  }
}

class _PrivateAvatarCropPage extends StatefulWidget {
  final ui.Image image;
  final Future<Uint8List> Function(ui.Image, ui.Rect) encoder;
  const _PrivateAvatarCropPage({required this.image, required this.encoder});
  @override
  State<_PrivateAvatarCropPage> createState() => _PrivateAvatarCropPageState();
}

class _PrivateAvatarCropPageState extends State<_PrivateAvatarCropPage> {
  late final ui.Size _imageSize = ui.Size(
    widget.image.width.toDouble(),
    widget.image.height.toDouble(),
  );
  late ui.Rect _crop = privateAvatarCropRect(_imageSize);
  ui.Rect? _gestureStart;
  ui.Offset? _gestureFocal;
  bool _saving = false;
  bool _cancelled = false;
  bool _failed = false;
  double get _zoom =>
      math.min(_imageSize.width, _imageSize.height) / _crop.width;

  void _cancel() {
    _cancelled = true;
    if (ModalRoute.of(context)?.isCurrent == true) Navigator.of(context).pop();
  }

  Future<void> _save() async {
    if (_saving || _cancelled) return;
    final route = ModalRoute.of(context);
    setState(() {
      _saving = true;
      _failed = false;
    });
    // Keep a separate handle alive if the route is cancelled during encoding.
    final image = widget.image.clone();
    final crop = _crop;
    try {
      final bytes = await widget.encoder(image, crop);
      // A popped editor stays mounted through its reverse transition. Never
      // let late encoding completion pop the profile underneath it.
      if (mounted && !_cancelled && route?.isCurrent == true) {
        Navigator.of(context).pop(bytes);
      }
    } catch (_) {
      if (mounted && !_cancelled && route?.isCurrent == true)
        setState(() {
          _saving = false;
          _failed = true;
        });
    } finally {
      image.dispose();
    }
  }

  @override
  void dispose() {
    widget.image.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.privateAvatarCropTitle),
        leading: IconButton(
          tooltip: l10n.cancel,
          icon: const Icon(Icons.close),
          onPressed: _cancel,
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Text(
                l10n.privateAvatarCropHint,
                textAlign: TextAlign.center,
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final side = math.max(
                    1.0,
                    math.min(
                      560.0,
                      math.min(
                        constraints.maxWidth - 32,
                        constraints.maxHeight - 32,
                      ),
                    ),
                  );
                  return Center(
                    child: SizedBox.square(
                      dimension: side,
                      child: Semantics(
                        label: l10n.privateAvatarCropHint,
                        child: GestureDetector(
                          key: const ValueKey('private-avatar-crop-viewport'),
                          behavior: HitTestBehavior.opaque,
                          onScaleStart: _saving
                              ? null
                              : (details) {
                                  _gestureStart = _crop;
                                  _gestureFocal = details.localFocalPoint;
                                },
                          onScaleUpdate: _saving
                              ? null
                              : (details) {
                                  final start = _gestureStart;
                                  final focal = _gestureFocal;
                                  if (start == null || focal == null) return;
                                  setState(
                                    () => _crop = privateAvatarGestureCrop(
                                      _imageSize,
                                      start: start,
                                      startFocal: focal,
                                      focal: details.localFocalPoint,
                                      viewport: side,
                                      scale: details.scale,
                                    ),
                                  );
                                },
                          child: CustomPaint(
                            painter: _AvatarCropPainter(widget.image, _crop),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  const Icon(Icons.zoom_out),
                  Expanded(
                    child: Semantics(
                      label: l10n.privateAvatarCropZoom,
                      child: Slider(
                        label: '${_zoom.toStringAsFixed(1)}×',
                        min: 1,
                        max: 5,
                        value: _zoom.clamp(1, 5),
                        onChanged: _saving
                            ? null
                            : (zoom) => setState(
                                () => _crop = privateAvatarCropRect(
                                  _imageSize,
                                  zoom: zoom,
                                  center: _crop.center,
                                ),
                              ),
                      ),
                    ),
                  ),
                  const Icon(Icons.zoom_in),
                  SizedBox(
                    width: 42,
                    child: Text(
                      '${_zoom.toStringAsFixed(1)}×',
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
            ),
            if (_failed)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  l10n.privateAvatarFailed,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: _cancel, child: Text(l10n.cancel)),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.check),
                    label: Text(l10n.privateAvatarCropSave),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AvatarCropPainter extends CustomPainter {
  final ui.Image image;
  final ui.Rect crop;
  _AvatarCropPainter(this.image, this.crop);
  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawImageRect(
      image,
      crop,
      bounds,
      Paint()..filterQuality = FilterQuality.high,
    );
    final mask = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(bounds)
      ..addOval(bounds);
    canvas.drawPath(mask, Paint()..color = Colors.black54);
    canvas.drawOval(
      bounds.deflate(1),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _AvatarCropPainter old) =>
      old.image != image || old.crop != crop;
}
