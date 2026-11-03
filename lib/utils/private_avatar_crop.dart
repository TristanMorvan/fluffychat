// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'private_contact_avatar.dart';

/// Source-pixel square shown in the avatar viewport. No blank margins.
ui.Rect privateAvatarCropRect(
  ui.Size imageSize, {
  double zoom = 1,
  ui.Offset? center,
}) {
  if (!imageSize.width.isFinite ||
      !imageSize.height.isFinite ||
      imageSize.width <= 0 ||
      imageSize.height <= 0 ||
      !zoom.isFinite) {
    throw ArgumentError('Invalid avatar crop geometry');
  }
  final side = math.min(imageSize.width, imageSize.height) / zoom.clamp(1, 5);
  final focus = center ?? ui.Offset(imageSize.width / 2, imageSize.height / 2);
  if (!focus.dx.isFinite || !focus.dy.isFinite)
    throw ArgumentError('Invalid crop center');
  final half = side / 2;
  return ui.Rect.fromCenter(
    center: ui.Offset(
      focus.dx.clamp(half, imageSize.width - half),
      focus.dy.clamp(half, imageSize.height - half),
    ),
    width: side,
    height: side,
  );
}

/// Keep the source point under the fingers fixed while scaling and dragging.
ui.Rect privateAvatarGestureCrop(
  ui.Size imageSize, {
  required ui.Rect start,
  required ui.Offset startFocal,
  required ui.Offset focal,
  required double viewport,
  required double scale,
}) {
  if (!viewport.isFinite || viewport <= 0 || !scale.isFinite || scale <= 0)
    throw ArgumentError('Invalid avatar gesture');
  final minDimension = math.min(imageSize.width, imageSize.height);
  final zoom = (minDimension / start.width * scale).clamp(1.0, 5.0);
  final side = minDimension / zoom;
  final anchor = start.topLeft + startFocal * (start.width / viewport);
  final center =
      anchor +
      (ui.Offset(viewport / 2, viewport / 2) - focal) * (side / viewport);
  return privateAvatarCropRect(imageSize, zoom: zoom, center: center);
}

/// Bound decoding before allocating the working bitmap. Keep enough detail for
/// a 5x crop without decoding a full camera-resolution image into the editor.
Future<ui.Image> decodePrivateAvatarCropImage(Uint8List bytes) async {
  if (bytes.isEmpty || bytes.length > PrivateContactAvatarStore.maxFileBytes)
    throw const FormatException('Invalid avatar image');
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width <= 0 ||
        descriptor.height <= 0 ||
        descriptor.width * descriptor.height > 40000000)
      throw const FormatException('Invalid avatar image');
    final factor = math.min(
      1.0,
      2048 / math.max(descriptor.width, descriptor.height),
    );
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (descriptor.width * factor).round()),
      targetHeight: math.max(1, (descriptor.height * factor).round()),
    );
    return (await codec.getNextFrame()).image;
  } catch (_) {
    throw const FormatException('Invalid avatar image');
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// Save precisely the square shown in the viewport as a metadata-free PNG.
/// The caller retains ownership of [image].
Future<Uint8List> encodePrivateAvatarCrop(ui.Image image, ui.Rect crop) async {
  if (![
        crop.left,
        crop.top,
        crop.right,
        crop.bottom,
      ].every((n) => n.isFinite) ||
      crop.width <= 0 ||
      (crop.width - crop.height).abs() > 0.0001 ||
      crop.left < 0 ||
      crop.top < 0 ||
      crop.right > image.width + 0.0001 ||
      crop.bottom > image.height + 0.0001) {
    throw ArgumentError('Crop must be a square inside the image');
  }
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawImageRect(
    image,
    crop,
    const ui.Rect.fromLTWH(0, 0, 256, 256),
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );
  final picture = recorder.endRecording();
  ui.Image? result;
  try {
    result = await picture.toImage(256, 256);
    final data = await result.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw const FormatException('Unable to crop avatar');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    result?.dispose();
    picture.dispose();
  }
}
