import 'dart:io';

import 'package:aquan_duanju/core/player/mpv_list_encoding.dart';
import 'package:flutter_test/flutter_test.dart';

/// mpv 对路径列表条目的切分语义（parse_str_list / get_nextsep）：
/// 未转义的分隔符切条目，「\ + 分隔符」还原成字面量。测试按同一规则
/// 复算切出的条目数，而不是简单 split（转义后的 `\:` 里仍有裸 `:` 字符）。
int _unescapedSepCount(String value, String sep) {
  var count = 0;
  for (var i = 0; i < value.length; i++) {
    if (value[i] == sep && (i == 0 || value[i - 1] != '\\')) count++;
  }
  return count;
}

void main() {
  group('mpvListEntry', () {
    test('空串原样返回（清列表必须改用 change-list clr，不允许直接设置）', () {
      expect(mpvListEntry(''), '');
    });

    test('URL 中的平台分隔符被转义，mpv 切分后是且仅是一个条目', () {
      final sep = Platform.isWindows ? ';' : ':';
      const url = 'https://v11-hgweb.qznovelvod.com/media-audio-und-mp4a/?x=1';
      final encoded = mpvListEntry(url);
      // 转义后不再存在「未转义」的分隔符 → parse_str_list 恰好产出 1 条。
      expect(_unescapedSepCount(encoded, sep), 0, reason: encoded);
      // mpv 解码（去掉「\ + 分隔符」中的反斜杠）后必须还原为原 URL。
      expect(encoded.replaceAll('\\$sep', sep), url);
    });

    test('Android 现场形态：:// 不再被切碎（非 Windows 平台转义冒号）', () {
      if (Platform.isWindows) {
        // Windows 分隔符是 ';'，URL 不含 ';'，原样透传（与既有行为一致）。
        expect(mpvListEntry('https://host/a.mp4'), 'https://host/a.mp4');
      } else {
        expect(mpvListEntry('https://host/a.mp4'), 'https\\://host/a.mp4');
      }
    });

    test('URL 含多个分隔符时全部转义', () {
      if (Platform.isWindows) {
        // Windows 分隔符是 ';'：只转义 ';'，'://' 原样保留。
        expect(mpvListEntry('https://h/a;b?c'), 'https://h/a\\;b?c');
      } else {
        expect(mpvListEntry('https://h/a:b?c'), 'https\\://h/a\\:b?c');
      }
    });
  });

  group('mpvClearPathListCommand', () {
    test('change-list clr 命令形态（OP_CLR 忽略 param，直接释放列表）', () {
      expect(
        mpvClearPathListCommand('audio-files'),
        ['change-list', 'audio-files', 'clr', ''],
      );
    });
  });

  group('lavfProtocolWhitelist', () {
    test('网络流集合 → protocol_whitelist=%35% 引用（35 为 UTF-8 字节数）', () {
      expect(
        lavfProtocolWhitelist(protocols: kMpvLavfNetworkProtocols),
        'protocol_whitelist=%35%http,https,tcp,tls,crypto,data,file',
      );
    });

    test('本地集合（file 优先）→ 完整 key=value 片段', () {
      expect(
        lavfProtocolWhitelist(protocols: kMpvLavfLocalProtocols),
        'protocol_whitelist=%35%file,http,https,tcp,tls,crypto,data',
      );
    });

    test('长度按 UTF-8 字节数计算（防御非 ASCII 协议名）', () {
      // 「你好」是 2 个 Dart code unit、6 个 UTF-8 字节。
      expect(
        lavfProtocolWhitelist(protocols: <String>['你好']),
        'protocol_whitelist=%6%你好',
      );
    });

    test('白名单集合与既有内联字面量一致（替换不改行为）', () {
      expect(kMpvLavfNetworkProtocols,
          ['http', 'https', 'tcp', 'tls', 'crypto', 'data', 'file']);
      expect(kMpvLavfLocalProtocols,
          ['file', 'http', 'https', 'tcp', 'tls', 'crypto', 'data']);
    });
  });
}
