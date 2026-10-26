import 'dart:typed_data';

import 'package:xcfkit/src/binary.dart';
import 'package:xcfkit/src/exception.dart';
import 'package:xcfkit/src/precision.dart';
import 'package:zcodec/zcodec.dart' as z;

/// Decodes one bounded XCF tile and verifies its exact sample count.
Uint8List decodeXcfTile(XcfReader reader, int pixels, int stride, XcfCompression compression) {
  final int size = pixels * stride;
  switch (compression) {
    case XcfCompression.raw:
      return reader.take(size);
    case XcfCompression.rle:
      final Uint8List result = Uint8List(size);
      for (int component = 0; component < stride; component++) {
        int written = 0;
        while (written < pixels) {
          final int code = reader.u8();
          final int count = switch (code) {
            127 || 128 => reader.u8() * 256 + reader.u8(),
            < 127 => code + 1,
            _ => 256 - code,
          };
          if (count == 0 || count > pixels - written) {
            throw XcfFormatException('Invalid XCF RLE run length', offset: reader.offset);
          }
          if (code <= 127) {
            final int value = reader.u8();
            for (int i = 0; i < count; i++) {
              result[(written + i) * stride + component] = value;
            }
          } else {
            final Uint8List literal = reader.take(count);
            for (int i = 0; i < count; i++) {
              result[(written + i) * stride + component] = literal[i];
            }
          }
          written += count;
        }
      }
      return result;
    case XcfCompression.zlib:
      final int start = reader.offset;
      final int method = reader.u8();
      final int flags = reader.u8();
      if ((method & 15) != 8 || method >> 4 > 7 || (method * 256 + flags) % 31 != 0 || flags & 32 != 0) {
        throw XcfFormatException('Invalid XCF zlib header', offset: start);
      }
      try {
        final z.DeflateDecodeResult decoded = z.DeflateDecoder(maxOutputBytes: size).convertPrefix(reader.range(reader.offset, reader.end - reader.offset));
        reader.offset += decoded.bytesRead;
        if (decoded.data.length != size || reader.u32() != z.adler32(decoded.data)) {
          throw XcfFormatException('Invalid XCF zlib size or checksum', offset: start);
        }
        return decoded.data;
      } on z.ZCodecException catch (error) {
        throw XcfFormatException('Invalid XCF zlib tile: $error', offset: start);
      }
  }
}

/// Encodes interleaved tile samples using the selected XCF compression.
Uint8List encodeXcfTile(Uint8List bytes, int stride, XcfCompression compression) {
  switch (compression) {
    case XcfCompression.raw:
      return bytes;
    case XcfCompression.zlib:
      return const z.ZlibCodec().encode(bytes);
    case XcfCompression.rle:
      final int pixels = bytes.length ~/ stride;
      final XcfWriter writer = XcfWriter(bytes.length * 2 + stride * 3);
      for (int component = 0; component < stride; component++) {
        int position = 0;
        while (position < pixels) {
          int run = 1;
          while (position + run < pixels && bytes[(position + run) * stride + component] == bytes[position * stride + component]) {
            run++;
          }
          if (run >= 2) {
            if (run <= 127) {
              writer.u8(run - 1);
            } else {
              writer.u8(127);
              writer.u8(run >> 8);
              writer.u8(run & 255);
            }
            writer.u8(bytes[position * stride + component]);
            position += run;
          } else {
            final int start = position++;
            while (position < pixels) {
              if (position + 1 < pixels && bytes[position * stride + component] == bytes[(position + 1) * stride + component]) {
                break;
              }
              position++;
            }
            final int count = position - start;
            if (count <= 127) {
              writer.u8(256 - count);
            } else {
              writer.u8(128);
              writer.u8(count >> 8);
              writer.u8(count & 255);
            }
            for (int i = start; i < position; i++) {
              writer.u8(bytes[i * stride + component]);
            }
          }
        }
      }
      return writer.finish();
  }
}
