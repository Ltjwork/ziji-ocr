import 'dart:collection';
import 'dart:io';
import 'dart:ui' as ui;

/// 页面缩略图 LRU 缓存：按当前解码宽度整批失效（格大小档位切换时）。
/// 逐出条目不主动 dispose——可见格子可能仍持有该 [ui.Image] 引用，
/// 快速滚动时立即释放会画到已释放纹理；未 dispose 的 image 由引擎
/// 终结器随 GC 回收，缩略图很小，峰值内存可控。
///
/// 全书网格总览与主区快设网格共用（页面图是 200DPI PNG、一本可达
/// 数百页，这里只做降采样解码 + 小容量缓存，绝不整图进内存）。
class PageThumbCache {
  final LinkedHashMap<int, ui.Image> _images = LinkedHashMap();
  final Map<int, Future<ui.Image?>> _inFlight = {};
  final Set<int> _failed = {};
  int _width = -1;
  static const _maxEntries = 48;

  Future<ui.Image?> get(int index, String path, int targetWidth) {
    if (targetWidth != _width) {
      _images.clear();
      _inFlight.clear();
      _failed.clear();
      _width = targetWidth;
    }
    final hit = _images.remove(index);
    if (hit != null) {
      _images[index] = hit; // touch LRU
      return Future.value(hit);
    }
    if (_failed.contains(index)) return Future.value();
    return _inFlight.putIfAbsent(index, () async {
      final image = await _decode(path, targetWidth);
      _inFlight.remove(index);
      if (image == null) {
        _failed.add(index);
        return null;
      }
      _images[index] = image;
      while (_images.length > _maxEntries) {
        _images.remove(_images.keys.first);
      }
      return image;
    });
  }

  Future<ui.Image?> _decode(String path, int targetWidth) async {
    try {
      final data = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(
        data,
        targetWidth: targetWidth,
      );
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _images.clear();
    _inFlight.clear();
    _failed.clear();
  }

  /// 失效某一页的缓存（校对摆正等就地改写页面文件后调用）：缓存键是
  /// 页号，不比对文件路径——不清的话格子会一直显示摆正前的旧图。
  void evict(int index) {
    _images.remove(index);
    _failed.remove(index);
    _inFlight.remove(index);
  }
}
