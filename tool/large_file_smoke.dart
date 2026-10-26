import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xcfkit/xcfkit_io.dart';

/// Exercises a gigabyte of generated samples without owning a complete raster.
///
/// Compile to an executable for reproducible RSS measurements. The optional
/// argument is a multiple-of-64 side length; the default is 16384 (1 GiB RGBA8).
void main(List<String> arguments) {
  final int side = arguments.isEmpty ? 16384 : int.parse(arguments.single);
  if (side < 64 || side % 64 != 0 || side > 32768) {
    throw ArgumentError('Side must be a multiple of 64 between 64 and 32768');
  }
  final Directory directory = Directory.systemTemp.createTempSync('xcfkit-large-');
  final Stopwatch timer = Stopwatch()..start();
  final int baseline = ProcessInfo.currentRss;
  try {
    final XcfRaster raster = XcfRaster.tiled(
      width: side,
      height: side,
      bytesPerPixel: 4,
      maxReadBytes: 1024 * 1024,
      readTile: (column, row) {
        final Uint8List bytes = Uint8List(64 * 64 * 4);
        for (int i = 0; i < bytes.length; i += 4) {
          bytes[i] = column % 256;
          bytes[i + 1] = row % 256;
          bytes[i + 2] = 123;
          bytes[i + 3] = 255;
        }
        return bytes;
      },
    );
    final XcfDocument document = XcfDocument(
      width: side,
      height: side,
      layers: [XcfLayer(name: 'Generated tiles', width: side, height: side, raster: raster)],
    );
    final String path = '${directory.path}/large.xcf';
    final XcfFileOutput output = XcfFileOutput(path);
    int? length;
    try {
      length = XcfCodec.encodeTo(document, output);
    } finally {
      output.close(length: length);
    }
    final XcfFileInput input = XcfFileInput(path);
    try {
      final XcfDocument lazy = XcfCodec.open(
        input,
        options: XcfReadOptions(maxPixels: side * side, maxDecodedBytes: 1024 * 1024),
      );
      final Uint8List pixel = lazy.layers.single.raster!.readRegion(x: side - 1, y: side - 1, width: 1, height: 1);
      final int last = (side ~/ 64 - 1) % 256;
      if (pixel[0] != last || pixel[1] != last || pixel[2] != 123 || pixel[3] != 255) {
        throw StateError('Lazy pixel mismatch');
      }
      final XcfFileOutput second = XcfFileOutput('${directory.path}/rewritten.xcf');
      int? rewritten;
      try {
        rewritten = XcfCodec.encodeTo(lazy, second);
      } finally {
        second.close(length: rewritten);
      }
      if (rewritten != length || !_sameFiles(path, '${directory.path}/rewritten.xcf')) {
        throw StateError('Progressive round-trip size mismatch');
      }
    } finally {
      input.close();
    }
    stdout.writeln(
      jsonEncode({
        'side': side,
        'sample_bytes': side * side * 4,
        'encoded_bytes': length,
        'elapsed_ms': timer.elapsedMilliseconds,
        'baseline_rss': baseline,
        'peak_rss': ProcessInfo.maxRss,
        'lazy_read_limit': 1024 * 1024,
        'rewritten': true,
      }),
    );
  } finally {
    directory.deleteSync(recursive: true);
  }
}

/// Compares complete encoded files with two bounded buffers.
bool _sameFiles(String first, String second) {
  final RandomAccessFile a = File(first).openSync();
  final RandomAccessFile b = File(second).openSync();
  try {
    while (true) {
      final Uint8List left = a.readSync(64 * 1024);
      final Uint8List right = b.readSync(64 * 1024);
      if (left.length != right.length) {
        return false;
      }
      if (left.isEmpty) {
        return true;
      }
      for (int i = 0; i < left.length; i++) {
        if (left[i] != right[i]) {
          return false;
        }
      }
    }
  } finally {
    a.closeSync();
    b.closeSync();
  }
}
