import 'dart:convert';
import 'dart:typed_data' show Uint8List;

import 'package:pointycastle/export.dart';

import 'lenient_json.dart';
import 'source_adapter.dart';

/// TVBox 配置原文解码。
///
/// 真实接口站的配置存在多种载体，按手机端 `Decoder.verify` 的语义逐级尝试，
/// 任一步得到 JSON 对象/数组即成功；每种「变换型」解码成功后对产物**递归**走
/// 整条链（Base64 的产物可能还是加密配置，加密的产物可能是带注释的 JSON）：
///
/// 1. `<pre>` 包裹剥离；
/// 2. 严格 JSON；
/// 3. `**` 标记 Base64（`XXXXXXXX**`，标记后即负载）；
/// 4. `2423` hex 前缀 AES-CBC 加密配置（密文布局见 [_decrypt2423]）；
/// 5. 整体 Base64（含 URL-safe、去空白、padding 容错）；
/// 6. 宽松 JSON（注释/尾逗号/单引号/无引号 key）。
class ConfigDecoder {
  const ConfigDecoder._();

  /// 递归深度上限：防止极端构造下的无限变换。
  static const int _maxDepth = 3;

  static final RegExp _prePattern =
      RegExp(r'<pre[^>]*>([\s\S]*?)</pre>', caseSensitive: false);
  static final RegExp _markerPattern = RegExp(r'[A-Za-z0-9]{8}\*\*');

  /// 解码 [content]；全部路径失败抛 [SourceException]，[detail] 记录走到哪一步。
  static Map<String, dynamic> decode(String content) {
    var text = content.trim();
    if (text.startsWith(String.fromCharCode(0xFEFF))) {
      text = text.substring(1);
    }
    if (text.isEmpty) {
      throw SourceException(SourceExceptionCode.decodeFailed, '空内容');
    }
    final pre = _prePattern.firstMatch(text);
    if (pre != null) {
      final inner = pre.group(1)?.trim();
      if (inner != null && inner.isNotEmpty) text = inner;
    }
    final seen = <String>{};
    final result = _decodeInner(text, 0, seen);
    if (result == null) {
      throw SourceException(SourceExceptionCode.decodeFailed, '全链未命中');
    }
    return result;
  }

  static Map<String, dynamic>? _decodeInner(
      String text, int depth, Set<String> seen) {
    if (depth > _maxDepth || text.isEmpty || !seen.add(text)) return null;

    // 严格 JSON：结构必须是对象（配置顶层是对象；数组形态的仓列表也接受）。
    if (text.startsWith('{') || text.startsWith('[')) {
      try {
        final value = jsonDecode(text);
        if (value is Map) return Map<String, dynamic>.from(value);
      } catch (_) {
        // 继续尝试其它路径。
      }
    }

    // `**` 标记 Base64：标记后即负载，产物递归。
    if (text.contains('**')) {
      final decoded = _tryMarkerBase64(text);
      if (decoded != null) {
        final inner = _decodeInner(decoded, depth + 1, seen);
        if (inner != null) return inner;
      }
    }

    // `2423` 加密配置：产物递归（明文可能是宽松 JSON）。
    if (text.startsWith('2423')) {
      try {
        final plain = _decrypt2423(text.replaceAll(RegExp(r'\s+'), ''));
        final inner = _decodeInner(plain, depth + 1, seen);
        if (inner != null) return inner;
      } on SourceException catch (e) {
        if (e.detail.startsWith('2423')) rethrow;
        throw SourceException(
            SourceExceptionCode.decodeFailed, '2423 AES 解密失败: ${e.detail}');
      } catch (e) {
        throw SourceException(
            SourceExceptionCode.decodeFailed, '2423 AES 解密失败: $e');
      }
    }

    // 整体 Base64：产物递归。
    final whole = _tryWholeBase64(text);
    if (whole != null) {
      final inner = _decodeInner(whole, depth + 1, seen);
      if (inner != null) return inner;
    }

    // 宽松 JSON 兜底（顶层对象才算配置）。
    final lenient = LenientJson.tryParse(text);
    if (lenient is Map) return Map<String, dynamic>.from(lenient);
    return null;
  }

  /// `XXXXXXXX**` 标记之后即 Base64 负载（手机端 `Decoder.base64`）。
  static String? _tryMarkerBase64(String text) {
    final marker = _markerPattern.firstMatch(text);
    if (marker == null) return null;
    final payload = text.substring(marker.end).replaceAll(RegExp(r'\s+'), '');
    if (payload.isEmpty) return null;
    try {
      return utf8.decode(base64Decode(payload), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  static String? _tryWholeBase64(String text) {
    final normalized =
        text.replaceAll('\n', '').replaceAll('\r', '').replaceAll(' ', '');
    if (normalized.isEmpty || normalized.length < 8) return null;
    try {
      return utf8.decode(_base64Decode(normalized), allowMalformed: false);
    } catch (_) {
      return null;
    }
  }

  /// URL-safe 与缺省 padding 容错的 Base64 解码。
  static Uint8List _base64Decode(String input) {
    var s = input.replaceAll('-', '+').replaceAll('_', '/');
    final mod = s.length % 4;
    if (mod == 2) s += '==';
    if (mod == 3) s += '=';
    if (mod == 1) s = s.substring(0, s.length - 1);
    return base64Decode(s);
  }

  /// `2423` 加密配置（对齐 TV `catvod/utils/Decoder.java#cbc`）。
  ///
  /// 文件本体是一段 hex：`hex("$#") + key + hex("#$") + hex(密文) + hex(iv 13 字节)`，
  /// 其中 `2423`/`2324` 就是 `$#`/`#$` 的 hex；密钥取 `$#…#$` 之间文本、IV 取
  /// 文件末 13 字节，两者都用 `'0'` 右补齐到 16 字节后做 AES-CBC/PKCS7 解密。
  static String _decrypt2423(String data) {
    Uint8List fileBytes;
    try {
      fileBytes = _hex2bytes(data);
    } catch (_) {
      throw SourceException(SourceExceptionCode.decodeFailed, '2423 非 hex 内容');
    }
    final decoded = utf8.decode(fileBytes, allowMalformed: true).toLowerCase();
    final keyStart = decoded.indexOf(r'$#');
    final keyEnd = decoded.indexOf(r'#$');
    if (keyStart < 0 || keyEnd <= keyStart + 2) {
      throw SourceException(SourceExceptionCode.decodeFailed, '2423 缺密钥标记');
    }
    final key = _padEnd(decoded.substring(keyStart + 2, keyEnd));
    if (fileBytes.length < 26) {
      throw SourceException(SourceExceptionCode.decodeFailed, '2423 内容过短');
    }
    // 密文从闭合标记 `#$`（hex 2324）之后开始，末尾 13 字节（26 hex）是 IV。
    final closeMarker = data.indexOf('2324');
    if (closeMarker <= 0 || data.length - 26 <= closeMarker + 4) {
      throw SourceException(SourceExceptionCode.decodeFailed, '2423 布局不完整');
    }
    final cipher = _hex2bytes(data.substring(closeMarker + 4, data.length - 26));
    final iv = _padEnd(decoded.substring(decoded.length - 13));
    return utf8.decode(_aesCbcDecrypt(cipher, key.codeUnits, iv.codeUnits),
        allowMalformed: true);
  }

  static String _padEnd(String s) =>
      s + '0000000000000000'.substring(s.length.clamp(0, 16));

  static Uint8List _aesCbcDecrypt(
      Uint8List cipher, List<int> key, List<int> iv) {
    final impl = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
      ..init(
          false,
          PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
              ParametersWithIV(
                  KeyParameter(Uint8List.fromList(key)),
                  Uint8List.fromList(iv)),
              null));
    return impl.process(cipher);
  }

  static Uint8List _hex2bytes(String hex) {
    final clean = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (clean.length.isOdd) {
      throw const FormatException('奇数长度 hex');
    }
    final out = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
