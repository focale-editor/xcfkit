import 'dart:math' as math;
import 'dart:typed_data';

import 'package:xcfkit/src/exception.dart';
import 'package:xcfkit/src/model.dart';
import 'package:xcfkit/src/precision.dart';

/// Pixel access without applying ICC transforms, masks, opacity, or effects.
abstract final class XcfPixels {
  /// Expands a layer to RGBA8 in its existing transfer encoding and profile.
  ///
  /// This is an explicitly lossy preview conversion: floating samples are
  /// clamped to [0, 1]. It is not the composited GIMP appearance. Exact editing
  /// should retain [XcfRaster.bytes] and [XcfDocument.precision] instead.
  static Uint8List rgba8(XcfDocument document, XcfLayer layer) {
    final XcfRaster? raster = layer.raster;
    if (raster == null) {
      throw const XcfUnsupportedException('Layer has no cached raster');
    }
    final int stride = document.precision.bytesPerComponent;
    if (raster.bytesPerPixel != layer.type.components * stride) {
      throw const XcfFormatException('Inconsistent raster sample layout');
    }
    final Uint8List result = Uint8List(raster.width * raster.height * 4);
    final ByteData input = ByteData.sublistView(raster.bytes);
    final Uint8List palette = document.palette;
    for (int pixel = 0; pixel < raster.width * raster.height; pixel++) {
      final int source = pixel * raster.bytesPerPixel;
      final int target = pixel * 4;
      if (layer.type.colorMode == XcfColorMode.indexed) {
        final int index = input.getUint8(source) * 3;
        if (index + 2 >= palette.length) {
          throw const XcfFormatException('Pixel references an absent palette entry');
        }
        result.setRange(target, target + 3, palette, index);
      } else if (layer.type.colorMode == XcfColorMode.grayscale) {
        final int value = _byte(readSample(input, source, document.precision));
        result[target] = value;
        result[target + 1] = value;
        result[target + 2] = value;
      } else {
        for (int channel = 0; channel < 3; channel++) {
          result[target + channel] = _byte(readSample(input, source + channel * stride, document.precision));
        }
      }
      result[target + 3] = layer.type.hasAlpha ? _byte(readSample(input, source + (layer.type.components - 1) * stride, document.precision)) : 255;
    }
    return result;
  }

  /// Quantizes only the preview, with an explicit policy for non-finite values.
  static int _byte(double value) => value.isNaN ? 0 : (value.clamp(0.0, 1.0) * 255).round();

  /// Reads one normalized integer or IEEE floating sample in XCF byte order.
  ///
  /// [offset] addresses a component in a raster or a bounded region. This
  /// preserves floating HDR and non-finite samples without applying a profile
  /// or transfer curve. Out-of-range component reads throw [RangeError].
  static double readSample(ByteData data, int offset, XcfPrecision precision) {
    RangeError.checkValidRange(offset, offset + precision.bytesPerComponent, data.lengthInBytes);

    if (!precision.isFloatingPoint) {
      return switch (precision.bytesPerComponent) {
        1 => data.getUint8(offset) / 255,
        2 => data.getUint16(offset) / 65535,
        _ => data.getUint32(offset) / 4294967295,
      };
    }
    if (precision.bytesPerComponent == 4) {
      return data.getFloat32(offset);
    }
    if (precision.bytesPerComponent == 8) {
      return data.getFloat64(offset);
    }
    final int bits = data.getUint16(offset);
    final int exponent = (bits >> 10) & 31;
    final int fraction = bits & 1023;
    final double sign = bits & 0x8000 == 0 ? 1 : -1;
    if (exponent == 31) {
      return fraction == 0 ? sign * double.infinity : double.nan;
    }
    return sign * (exponent == 0 ? fraction * math.pow(2, -24) : (1 + fraction / 1024) * math.pow(2, exponent - 15));
  }
}
