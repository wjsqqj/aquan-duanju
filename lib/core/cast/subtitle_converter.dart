/// SRT → WebVTT 字幕转换（Chromecast 只认 VTT；DLNA 侧多数电视两者都能吃，
/// 统一转 VTT 走一条路径）。移植自 dart_cast subtitle_converter 的核心语义。
library;

/// 把 SRT 字幕文本转换为 WebVTT；输入不是合法 SRT 时尽力而为返回可用 VTT。
String srtToVtt(String srt) {
  final text = srt.replaceFirst('\ufeff', '').replaceAll('\r\n', '\n');
  final out = StringBuffer('WEBVTT\n');
  final cueClock = RegExp(
      r'^(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})');
  for (final line in text.split('\n')) {
    final m = cueClock.firstMatch(line.trim());
    if (m != null) {
      String hh(int g) => m.group(g)!.padLeft(2, '0');
      final ms1 = m.group(4)!.padRight(3, '0');
      final ms2 = m.group(8)!.padRight(3, '0');
      out.write('\n${hh(1)}:${hh(2)}:${hh(3)}.$ms1 --> '
          '${hh(5)}:${hh(6)}:${hh(7)}.$ms2\n');
      continue;
    }
    // 纯数字行是 SRT 序号；VTT 允许 cue id 但统一去掉最稳。
    if (line.trim().isEmpty) {
      continue;
    }
    if (RegExp(r'^\d+$').hasMatch(line.trim())) continue;
    out.write('${line.trim()}\n');
  }
  return out.toString();
}
