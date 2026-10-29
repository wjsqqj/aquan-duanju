import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder, Uint8List;

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

import 'package:aquan_duanju/core/sources/config_decoder.dart';
import 'package:aquan_duanju/core/sources/source_adapter.dart';

void main() {
  group('ConfigDecoder 六形态解码链', () {
    const config = '{"sites":[{"key":"a","name":"A","type":1,'
        '"api":"http://x/api.php/provide/vod"}]}';

    test('明文 JSON', () {
      final out = ConfigDecoder.decode(config);
      expect((out['sites'] as List).length, 1);
    });

    test('<pre> 包裹', () {
      final out = ConfigDecoder.decode('<html><pre>$config</pre></html>');
      expect(out.containsKey('sites'), isTrue);
    });

    test('** 标记 Base64（8 位标记 + ** + 负载）', () {
      final payload = base64Encode(utf8.encode(config));
      final out = ConfigDecoder.decode('abcd1234**$payload');
      expect(out.containsKey('sites'), isTrue);
    });

    test('整体 Base64（含 URL-safe 与缺省 padding）', () {
      final bytes = utf8.encode(config);
      final b64 = base64Url.encode(bytes).replaceAll('=', '');
      final out = ConfigDecoder.decode(b64);
      expect(out.containsKey('sites'), isTrue);
    });

    test('宽松 JSON（注释 + 尾逗号 + 无引号 key + 单引号）', () {
      const lenient = '''
{
  // 行注释
  /* 块注释 */
  sites: [
    {key:'a', name:'A', type:1, api:'http://x/api',},
  ], // 尾逗号
}
''';
      final out = ConfigDecoder.decode(lenient);
      expect((out['sites'] as List).length, 1);
    });

    test('链式：整体 Base64 包着 2423 加密配置', () {
      final encrypted = _encrypt2423(config, key: 'testkey');
      final b64 = base64Encode(utf8.encode(encrypted));
      final out = ConfigDecoder.decode(b64);
      expect(out.containsKey('sites'), isTrue);
    });

    test('真实 Jsnzkpg 加密配置样本（test/sources/fixtures）', () {
      final file = File('test/sources/fixtures/jsnzkpg_raw.txt');
      if (!file.existsSync()) {
        return; // 夹具缺失时跳过（CI 无外网时不阻塞）。
      }
      final out = ConfigDecoder.decode(file.readAsStringSync());
      expect(out, isNotEmpty);
      expect(
        out.containsKey('sites') || out.containsKey('lives') ||
            out.containsKey('spider'),
        isTrue,
        reason: '解出的应为 TVBox 配置对象',
      );
    });

    test('全链失败抛 decodeFailed', () {
      expect(
        () => ConfigDecoder.decode('这不是任何已知格式的内容'),
        throwsA(isA<SourceException>().having(
            (e) => e.code, 'code', SourceExceptionCode.decodeFailed)),
      );
    });

    test('空内容抛 decodeFailed', () {
      expect(() => ConfigDecoder.decode('   '),
          throwsA(isA<SourceException>()));
    });
  });
}

/// 用与 Decoder 相同的布局构造 2423 样本：
/// hex( utf8("$#key#$") + 密文原始字节 + utf8(13字节尾部) )。
/// 解密端 IV 取文件末 13 字节（即 [ivTail] 补 '0' 到 16），密钥取 `$#…#$` 之间文本。
String _encrypt2423(String plain, {required String key}) {
  const ivTail = 'v1.0.0tsong00'; // 恰好 13 字节尾部（v1.0.0tsong0 是 12，别再踩）。
  final k = key.padRight(16, '0');
  final iv = ivTail.padRight(16, '0');
  final impl = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
    ..init(
        true,
        PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
            ParametersWithIV(
                KeyParameter(Uint8List.fromList(k.codeUnits)),
                Uint8List.fromList(iv.codeUnits)),
            null));
  final cipher = impl.process(Uint8List.fromList(utf8.encode(plain)));

  final bytes = BytesBuilder()
    ..add(utf8.encode('\$#$key#\$'))
    ..add(cipher)
    ..add(utf8.encode(ivTail));
  final out = StringBuffer();
  for (final b in bytes.takeBytes()) {
    out.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}
