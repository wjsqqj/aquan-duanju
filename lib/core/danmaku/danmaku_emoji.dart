import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'danmaku_emoji_catalog.dart';

/// 弹幕表情短码：内置图片 + 红果别名 + 按需解码缓存。
///
/// 资源随 exe 打包，绘制期同步取图；网络不可用时行为完全一致。
/// 参考 MyDouyin/internal/app/{danmaku.go,ui.go} 的图文混排模型：
/// 短码 → 对象占位 → 一次性排版 → 逐帧只贴图。
class DanmakuEmojiRegistry {
  DanmakuEmojiRegistry._();

  static final DanmakuEmojiRegistry instance = DanmakuEmojiRegistry._();

  final Map<String, ui.Image> _images = <String, ui.Image>{};
  final Set<String> _missing = <String>{};
  final Set<String> _inflight = <String>{};
  bool _loading = false;

  /// 图片就绪后通知 painter 重建排版缓存（首帧先文字、随后贴图）。
  final ValueNotifier<int> changed = ValueNotifier<int>(0);

  @visibleForTesting
  int get debugLoadedCount => _images.length;

  @visibleForTesting
  int get debugFailedCount => _missing.length;

  /// 红果 / 番茄短码 → 抖音官方短码（别名表未命中则原样）。
  String canonicalOf(String tag) => kDanmakuEmojiAliases[tag] ?? tag;

  /// 该短码（含别名）是否有内置图片。
  bool isKnown(String tag) => kDanmakuEmojiAssets.containsKey(canonicalOf(tag));

  /// 绘制期同步取图；未加载 / 解码失败返回 null，调用方按文字降级。
  ui.Image? imageFor(String tag) => _images[canonicalOf(tag)];

  /// 启动预加载全部内置表情（小尺寸解码，约 2MB 显存）。
  /// 幂等；失败项静默跳过，绝不阻塞启动。
  Future<void> preloadAll() async {
    if (_loading || _images.isNotEmpty) return;
    _loading = true;
    try {
      // 分批解码：一次性并发 214 张会把图片解码队列压垮（实测测试环境挂起）。
      final List<String> tags = kDanmakuEmojiAssets.keys.toList();
      const int batch = 16;
      for (var i = 0; i < tags.length; i += batch) {
        final int end = i + batch < tags.length ? i + batch : tags.length;
        await Future.wait<void>(tags.sublist(i, end).map(_load));
      }
    } catch (_) {
      // 单个资源失败已在 _load 内吞掉；这里只兜住意外异常。
    } finally {
      _loading = false;
      changed.value++;
    }
  }

  /// 供弹幕层调用；不等待完成（首次进播放器时通常已就绪）。
  void ensureLoaded() {
    if (_loading || _images.isNotEmpty) return;
    preloadAll();
  }

  Future<void> _load(String tag) async {
    final String canonical = canonicalOf(tag);
    if (_images.containsKey(canonical) ||
        _missing.contains(canonical) ||
        !_inflight.add(canonical)) {
      return;
    }
    final String? asset = kDanmakuEmojiAssets[canonical];
    if (asset == null) {
      _missing.add(canonical);
      _inflight.remove(canonical);
      return;
    }
    try {
      final ByteData data =
          await rootBundle.load('assets/danmaku_emoji/$asset');
      final ui.Codec codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(),
        targetWidth: 40,
      );
      final ui.Image image = (await codec.getNextFrame()).image;
      codec.dispose();
      _images[canonical] = image;
    } catch (_) {
      // 资源缺失 / 解码失败：该短码永久退化为文字，不影响其它表情。
      _missing.add(canonical);
    } finally {
      _inflight.remove(canonical);
    }
  }
}

/// 弹幕文本段：普通文字。
class DanmakuTextSegment {
  const DanmakuTextSegment(this.text);
  final String text;
}

/// 弹幕文本段：已识别的表情短码（[canonical] 为别名解析后的官方短码）。
class DanmakuStickerSegment {
  const DanmakuStickerSegment(this.tag, this.canonical);
  final String tag;
  final String canonical;
}

/// 一次性排版结果：展示文本（表情位是全角空格）+ 段 + 表情 x 偏移。
class DanmakuRichText {
  const DanmakuRichText({
    required this.displayText,
    required this.segments,
    required this.offsets,
    required this.stickers,
    required this.hasEmoji,
  });

  final String displayText;
  final List<Object> segments;
  final List<double> offsets;
  final List<DanmakuStickerSegment> stickers;
  final bool hasEmoji;
}

final RegExp _kTagPattern = RegExp(r'\[[^\[\]]{1,8}\]');

/// 把弹幕文本切成普通段与表情段；未收录短码原样保留为文字。
///
/// [measureText] 由 painter 提供（按当前 TextPainter 缓存测宽），只调用一次。
DanmakuRichText buildDanmakuRichText(
  String text, {
  required double emojiBoxWidth,
  required double Function(String) measureText,
}) {
  final DanmakuEmojiRegistry registry = DanmakuEmojiRegistry.instance;
  final List<Object> segments = <Object>[];
  final List<double> offsets = <double>[];
  final List<DanmakuStickerSegment> stickers = <DanmakuStickerSegment>[];
  final StringBuffer display = StringBuffer();
  double cursor = 0;
  int last = 0;
  for (final Match match in _kTagPattern.allMatches(text)) {
    final String tag = match.group(0)!;
    if (!registry.isKnown(tag)) continue;
    final String before = text.substring(last, match.start);
    if (before.isNotEmpty) {
      segments.add(DanmakuTextSegment(before));
      display.write(before);
      cursor += measureText(before);
    }
    final DanmakuStickerSegment sticker =
        DanmakuStickerSegment(tag, registry.canonicalOf(tag));
    segments.add(sticker);
    stickers.add(sticker);
    display.write('\u3000');
    offsets.add(cursor);
    cursor += emojiBoxWidth;
    last = match.end;
  }
  final String tail = text.substring(last);
  if (tail.isNotEmpty) {
    segments.add(DanmakuTextSegment(tail));
    display.write(tail);
  }
  return DanmakuRichText(
    displayText: display.toString(),
    segments: segments,
    offsets: offsets,
    stickers: stickers,
    hasEmoji: offsets.isNotEmpty,
  );
}
