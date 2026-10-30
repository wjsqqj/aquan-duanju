import 'live_parser.dart';

/// 直播回看（catchup）URL 构造。
///
/// M3U 里回看的声明方式五花八门，这里统一成三类：
///
/// | 形态 | 判据 | 处理 |
/// |---|---|---|
/// | [CatchupKind.playseek] | 地址含 `/playseek=` | 把该段替换成 `起-止` 时间戳 |
/// | [CatchupKind.timeshift] | 地址含 `/timeshift/` 或 `catchup=xc` | 追加时间戳段 |
/// | [CatchupKind.template] | 有 `catchup-source` | 占位符替换 |
///
/// 占位符：`{utc}` `{utcend}` `{duration}`（秒）与 `${start}` `${end}`（秒）。
/// `catchup-correction` 支持 `+8h` / `-30m` / `+8` 三种写法。
class Catchup {
  Catchup._();

  /// 能否回看。没有声明也没有地址特征时为 false，UI 不应显示回看按钮。
  static bool canReplay(LiveChannel channel) {
    if (channel.catchupSource.isNotEmpty) return true;
    if (channel.catchup.isNotEmpty) return true;
    return channel.urls.any(
      (u) => u.url.contains('playseek') || u.url.contains('timeshift'),
    );
  }

  static CatchupKind kindOf(LiveChannel channel) {
    final declared = channel.catchup.toLowerCase();
    if (declared == 'shift' || declared == 'playseek') {
      return CatchupKind.playseek;
    }
    if (declared == 'xc' || declared == 'timeshift') {
      return CatchupKind.timeshift;
    }
    if (channel.catchupSource.isNotEmpty) return CatchupKind.template;
    for (final url in channel.urls) {
      if (url.url.contains('playseek')) return CatchupKind.playseek;
      if (url.url.contains('timeshift')) return CatchupKind.timeshift;
    }
    return CatchupKind.none;
  }

  /// 计算回看地址；不支持或模板不可用时返回 null。
  ///
  /// [start] 是节目开始时间，[end] 缺省按 [defaultDuration] 推算。
  static String? replayUrl(
    LiveChannel channel,
    DateTime start, {
    DateTime? end,
    Duration defaultDuration = const Duration(hours: 1),
  }) {
    if (!canReplay(channel)) return null;
    final finish = end ?? start.add(defaultDuration);
    if (!finish.isAfter(start)) return null;

    final correction = _parseCorrection(channel.catchupCorrection);
    final from = start.add(correction);
    final to = finish.add(correction);
    final startSec = from.millisecondsSinceEpoch ~/ 1000;
    final endSec = to.millisecondsSinceEpoch ~/ 1000;
    final duration = to.difference(from).inSeconds;

    final base = channel.urls.isEmpty ? '' : channel.urls.first.url;
    final template =
        channel.catchupSource.isNotEmpty ? channel.catchupSource : base;
    if (template.isEmpty) return null;

    final kind = kindOf(channel);
    var out = template;
    if (kind == CatchupKind.playseek) {
      if (out.contains('/playseek=')) {
        out = out.replaceAll(
          RegExp(r'/playseek=[^/?#]*'),
          '/playseek=$startSec-$endSec',
        );
        return _withDurationIfPlaceholder(out, duration);
      }
      // 没写 playseek 段：按惯例追加。
      return _withDurationIfPlaceholder(
        '$out${out.contains('?') ? '&' : '?'}playseek=$startSec-$endSec',
        duration,
      );
    }
    if (kind == CatchupKind.timeshift) {
      return _withDurationIfPlaceholder(
        '$out${out.contains('?') ? '&' : '/'}start=$startSec&end=$endSec',
        duration,
      );
    }

    out = out
        .replaceAll('{utc}', '$startSec')
        .replaceAll('{utcend}', '$endSec')
        .replaceAll('{duration}', '$duration')
        .replaceAll(r'${start}', '$startSec')
        .replaceAll(r'${end}', '$endSec');
    return out;
  }

  static String _withDurationIfPlaceholder(String url, int seconds) =>
      url.contains('{duration}')
          ? url.replaceAll('{duration}', '$seconds')
          : url;

  /// `+8h` → 8 小时；`-30m` → -30 分钟；`+8` → 8 小时（PureTV 惯例）。
  static Duration _parseCorrection(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return Duration.zero;
    final match =
        RegExp(r'^([+-]?)(\d+(?:\.\d+)?)\s*([smhd]?)$').firstMatch(text);
    if (match == null) return Duration.zero;
    final sign = match.group(1) == '-' ? -1 : 1;
    final value = double.tryParse(match.group(2) ?? '') ?? 0;
    final unit = match.group(3) ?? 'h';
    final factor = switch (unit) {
      's' => 1.0,
      'm' => 60.0,
      'd' => 86400.0,
      _ => 3600.0,
    };
    return Duration(seconds: (value * factor * sign).round());
  }
}

enum CatchupKind {
  none,
  template,
  playseek,
  timeshift,
}
