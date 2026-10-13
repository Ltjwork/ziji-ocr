import 'dart:io';
import 'dart:ui' show Size, instantiateImageCodec;

/// 只读文件头取图像尺寸（PNG IHDR 快路径；其他格式兜底走一次 64px
/// 缩略解码，极少发生）。缩略图网格把主区/行/字框从页面像素坐标映射
/// 到格子时需要原始页面尺寸，不能为拿尺寸解码整页。失败返回 null。
Future<Size?> probeImageSize(String path) async {
  RandomAccessFile? raf;
  try {
    raf = File(path).openSync(mode: FileMode.read);
    final head = raf.readSync(24);
    if (head.length >= 24 &&
        head[0] == 0x89 &&
        head[1] == 0x50 &&
        head[2] == 0x4E &&
        head[3] == 0x47) {
      final w =
          (head[16] << 24) | (head[17] << 16) | (head[18] << 8) | head[19];
      final h =
          (head[20] << 24) | (head[21] << 16) | (head[22] << 8) | head[23];
      if (w > 0 && h > 0) return Size(w.toDouble(), h.toDouble());
    }
  } catch (_) {
    // 走下面的整图解码兜底。
  } finally {
    raf?.closeSync();
  }
  try {
    final data = await File(path).readAsBytes();
    final codec = await instantiateImageCodec(data, targetWidth: 64);
    final frame = await codec.getNextFrame();
    final size = Size(
      frame.image.width.toDouble(),
      frame.image.height.toDouble(),
    );
    frame.image.dispose();
    return size;
  } catch (_) {
    return null;
  }
}
