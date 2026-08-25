import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

/// 商品图片缓存：内存 LRU + 磁盘 + 共享连接池 + 并发控制
/// 查询显示时优先读缓存（秒开），未命中再走网络下载
class ProductImageCache {
  ProductImageCache._();

  /// 共享 HttpClient：复用 keep-alive 连接，避免每次下载新建连接
  static final HttpClient _client = _createClient();
  static HttpClient _createClient() {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    c.idleTimeout = const Duration(seconds: 30);
    return c;
  }

  /// 内存 LRU 缓存（约 40MB 上限）
  static final LinkedHashMap<String, Uint8List> _memory =
      LinkedHashMap<String, Uint8List>();
  static const int _memoryMaxBytes = 80 * 1024 * 1024;
  static int _memoryBytes = 0;

  /// 并发控制：同时最多 4 个网络下载
  static final _Semaphore _semaphore = _Semaphore(4);

  /// 进行中下载去重
  static final Map<String, Future<Uint8List?>> _inflight = {};

  /// 缓存目录（应用文档目录/product_images）
  static Future<Directory> _cacheDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}product_images');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static String _hashUrl(String url) {
    var h = 0x811c9dc5;
    for (final c in url.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16);
  }

  static String _ext(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.png')) return '.png';
    return '.jpg';
  }

  /// 已缓存的图片文件路径；未缓存返回 null
  static Future<String?> cachedPath(String url) async {
    try {
      final dir = await _cacheDir();
      final f = File('${dir.path}${Platform.pathSeparator}${_hashUrl(url)}${_ext(url)}');
      return f.existsSync() ? f.path : null;
    } catch (_) {
      return null;
    }
  }

  /// 保存图片到缓存（如本地上传成功后直接写入）
  static Future<void> cache(String url, List<int> bytes) async {
    if (bytes.isEmpty || url.isEmpty) return;
    final data = Uint8List.fromList(bytes);
    _putMemory(url, data);
    try {
      final dir = await _cacheDir();
      final file =
          File('${dir.path}${Platform.pathSeparator}${_hashUrl(url)}${_ext(url)}');
      await file.writeAsBytes(data, flush: true);
    } catch (_) {}
  }

  /// 读取图片字节：内存 → 磁盘 → 网络下载
  /// 返回 null 表示获取失败
  static Future<Uint8List?> loadBytes(String url) async {
    if (url.isEmpty) return null;
    // 1. 内存命中
    final mem = _memory[url];
    if (mem != null) return mem;
    // 2. 磁盘命中
    try {
      final dir = await _cacheDir();
      final file =
          File('${dir.path}${Platform.pathSeparator}${_hashUrl(url)}${_ext(url)}');
      if (file.existsSync()) {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) {
          _putMemory(url, bytes);
          return bytes;
        }
      }
    } catch (_) {}
    // 3. 网络下载（去重 + 并发限制）
    final inflight = _inflight[url];
    if (inflight != null) return inflight;
    final future = _download(url);
    _inflight[url] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(url);
    }
  }

  /// 后台预下载（fire-and-forget）
  static Future<void> preload(String url) async {
    try {
      await loadBytes(url);
    } catch (_) {}
  }

  /// 确保图片已下载，返回本地文件路径；失败返回 null
  static Future<String?> ensureDownloaded(String url) async {
    final bytes = await loadBytes(url);
    if (bytes == null) return null;
    try {
      final dir = await _cacheDir();
      final file =
          File('${dir.path}${Platform.pathSeparator}${_hashUrl(url)}${_ext(url)}');
      if (!file.existsSync()) {
        await file.writeAsBytes(bytes, flush: true);
      }
      return file.path;
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> _download(String url) async {
    await _semaphore.acquire();
    try {
      // 失败自动重试一次
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final req = await _client.getUrl(Uri.parse(url));
          final resp = await req.close().timeout(const Duration(seconds: 20));
          if (resp.statusCode != 200) return null;
          final bytes = <int>[];
          await for (final chunk in resp) {
            bytes.addAll(chunk);
          }
          if (bytes.isEmpty) return null;
          final data = Uint8List.fromList(bytes);
          _putMemory(url, data);
          unawaited(_persist(url, data));
          return data;
        } catch (_) {
          if (attempt == 1) return null;
        }
      }
      return null;
    } finally {
      _semaphore.release();
    }
  }

  static Future<void> _persist(String url, Uint8List bytes) async {
    try {
      final dir = await _cacheDir();
      final file =
          File('${dir.path}${Platform.pathSeparator}${_hashUrl(url)}${_ext(url)}');
      await file.writeAsBytes(bytes, flush: true);
    } catch (_) {}
  }

  /// LRU 写入内存缓存
  static void _putMemory(String url, Uint8List bytes) {
    final old = _memory.remove(url);
    if (old != null) _memoryBytes -= old.length;
    _memory[url] = bytes;
    _memoryBytes += bytes.length;
    while (_memoryBytes > _memoryMaxBytes && _memory.isNotEmpty) {
      final oldest = _memory.remove(_memory.keys.first);
      if (oldest != null) _memoryBytes -= oldest.length;
    }
  }

  static void clearMemory() {
    _memory.clear();
    _memoryBytes = 0;
  }
}

/// 轻量信号量（并发限制）
class _Semaphore {
  final int _max;
  int _used = 0;
  final List<Completer<void>> _queue = [];
  _Semaphore(this._max);

  Future<void> acquire() async {
    if (_used < _max) {
      _used++;
      return;
    }
    final c = Completer<void>();
    _queue.add(c);
    await c.future;
  }

  void release() {
    if (_queue.isNotEmpty) {
      _queue.removeAt(0).complete();
    } else if (_used > 0) {
      _used--;
    }
  }
}