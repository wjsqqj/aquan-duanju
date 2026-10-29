import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xml/xml.dart';

/// XMLTV EPG 解析（webhtv EpgParser 契约，实现原创 Dart）。
///
/// 时间形态：`20261030080000 +0800` / `20261030080000` / `...Z`；
/// 频道匹配：tvg-id 优先，display-name 归一化后与频道名匹配兜底。
class EpgProgramme {
  const EpgProgramme({
    required this.start,
    required this.stop,
    required this.title,
    this.description = '',
  });

  final DateTime start;
  final DateTime stop;
  final String title;
  final String description;

  bool contains(DateTime at) =>
      !at.isBefore(start) && at.isBefore(stop);
}

/// 一份 EPG 节目单：channel 键 = tvg-id 与 display-name 归一化都登记。
class EpgGuide {
  EpgGuide();

  final Map<String, List<EpgProgramme>> _channels = {};

  void addChannelKey(String key, List<EpgProgramme> programmes) {
    if (key.isEmpty || programmes.isEmpty) return;
    _channels[key] = programmes;
  }

  bool get isEmpty => _channels.isEmpty;

  /// 当前节目：任一 [keys] 命中的频道里找 start <= at < stop。
  EpgProgramme? nowFor(Iterable<String> keys, DateTime at) {
    for (final key in keys) {
      final list = _channels[key];
      if (list == null) continue;
      for (final p in list) {
        if (p.contains(at)) return p;
      }
    }
    return null;
  }

  /// 下一个节目：start > at 的最早一条。
  EpgProgramme? nextFor(Iterable<String> keys, DateTime at) {
    EpgProgramme? best;
    for (final key in keys) {
      final list = _channels[key];
      if (list == null) continue;
      for (final p in list) {
        if (p.start.isAfter(at) &&
            (best == null || p.start.isBefore(best.start))) {
          best = p;
        }
      }
    }
    return best;
  }
}

/// 解析 XMLTV 文本。
EpgGuide parseEpgXml(String xmlText) {
  final guide = EpgGuide();
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xmlText);
  } catch (_) {
    return guide;
  }
  final byId = <String, List<EpgProgramme>>{};
  final byName = <String, List<EpgProgramme>>{};

  for (final channel in doc.rootElement.descendantElements) {
    if (channel.name.local != 'channel') continue;
    final id = channel.getAttribute('id') ?? '';
    if (id.isEmpty) continue;
    final names = <String>[];
    for (final e in channel.descendantElements) {
      if (e.name.local == 'display-name') {
        final n = e.innerText.trim();
        if (n.isNotEmpty) names.add(n);
      }
    }
    // 该频道的节目（programme@channel == id）。
    final programmes = <EpgProgramme>[];
    for (final programme in doc.rootElement.descendantElements) {
      if (programme.name.local != 'programme') continue;
      if (programme.getAttribute('channel') != id) continue;
      final start = _parseXmltvTime(programme.getAttribute('start') ?? '');
      final stop = _parseXmltvTime(programme.getAttribute('stop') ?? '');
      if (start == null || stop == null) continue;
      String? title;
      String? desc;
      for (final e in programme.descendantElements) {
        if (e.name.local == 'title') title ??= e.innerText.trim();
        if (e.name.local == 'desc') desc ??= e.innerText.trim();
      }
      programmes.add(EpgProgramme(
        start: start,
        stop: stop,
        title: title ?? '',
        description: desc ?? '',
      ));
    }
    if (programmes.isEmpty) continue;
    programmes.sort((a, b) => a.start.compareTo(b.start));
    byId[id] = programmes;
    // display-name 归一化登记（去空格/小写）。
    for (final n in names) {
      byName.putIfAbsent(_normKey(n), () => programmes);
    }
  }

  guide._channels.addAll(byId);
  for (final entry in byName.entries) {
    guide._channels.putIfAbsent(entry.key, () => entry.value);
  }
  return guide;
}

/// 原始字节 → 节目单：0x1f 0x8b 开头视为 gzip（xml.gz）自动解压。
EpgGuide parseEpgBytes(Uint8List bytes) {
  var text = '';
  if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
    try {
      text = utf8.decode(gzip.decode(bytes));
    } catch (_) {
      return EpgGuide();
    }
  } else {
    text = utf8.decode(bytes, allowMalformed: true);
  }
  return parseEpgXml(text);
}

/// `20261030080000 +0800` / `20261030080000Z` / `20261030080000` → UTC DateTime。
DateTime? _parseXmltvTime(String raw) {
  final text = raw.trim();
  if (text.length < 14) return null;
  final digits = text.substring(0, 14);
  if (int.tryParse(digits) == null) return null;
  var tzSuffix = text.substring(14).trim();
  DateTime naive;
  try {
    naive = DateTime.utc(
      int.parse(digits.substring(0, 4)),
      int.parse(digits.substring(4, 6)),
      int.parse(digits.substring(6, 8)),
      int.parse(digits.substring(8, 10)),
      int.parse(digits.substring(10, 12)),
      int.parse(digits.substring(12, 14)),
    );
  } on FormatException {
    return null;
  }
  if (tzSuffix == 'Z' || tzSuffix.isEmpty) {
    tzSuffix = tzSuffix.isEmpty ? '+0000' : tzSuffix;
  }
  final sign = tzSuffix.startsWith('-') ? -1 : 1;
  final tzBody = tzSuffix.replaceFirst(RegExp(r'^[+-]'), '');
  final parts = tzBody.split(':');
  var offsetMinutes = 0;
  if (parts.length == 2) {
    offsetMinutes =
        (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts[1]) ?? 0);
  } else if (tzBody.length == 4) {
    offsetMinutes = (int.tryParse(tzBody.substring(0, 2)) ?? 0) * 60 +
        (int.tryParse(tzBody.substring(2)) ?? 0);
  } else {
    return naive;
  }
  // 字面量按声明的时区折算成 UTC。
  return naive.subtract(Duration(minutes: sign * offsetMinutes));
}

String _normKey(String s) => s.replaceAll(RegExp(r'\s+'), '').toLowerCase();

/// 频道的候选匹配键：tvg-id（如有）+ 频道名归一化。
List<String> epgKeysFor({String? tvgId, required String channelName}) => [
      if (tvgId != null && tvgId.isNotEmpty) tvgId,
      _normKey(channelName),
    ];
