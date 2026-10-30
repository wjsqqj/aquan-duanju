import 'dart:convert';
import 'dart:typed_data';

import 'package:aquan_duanju/core/tts/edge/edge_constants.dart';
import 'package:aquan_duanju/core/tts/edge/edge_frames.dart';
import 'package:flutter_test/flutter_test.dart';

/// 手工构造二进制帧：`hl` 就是**头部区长度**（不含两字节前缀），
/// 与解码侧 `head = f[2 .. 2+hl]`、`audio 从 2+hl 开始` 一一对应（说明书 §4.2）。
Uint8List binaryFrame(String head, List<int> body, {int? headerLength}) {
  final headBytes = utf8.encode(head);
  final hl = headerLength ?? headBytes.length;
  final out = Uint8List(2 + hl + body.length);
  out[0] = (hl >> 8) & 0xFF;
  out[1] = hl & 0xFF;
  out.setRange(2, 2 + headBytes.length, headBytes);
  out.setRange(2 + hl, out.length, body);
  return out;
}

/// 手工构造文本帧。
String textFrame(String head, String body) => '$head\r\n\r\n$body';

const String _audioHead =
    'Path:audio\r\nContent-Type:audio/mpeg\r\nX-Video-Format:audio/mpeg';

void main() {
  group('speech.config 帧逐字节', () {
    test('无 X-RequestId、boundary 开关是字符串、JSON 后还有一个 \\r\\n', () {
      final frame = encodeConfigFrame(
        wordBoundary: true,
        timestamp:
            'Wed Oct 15 2025 06:13:20 GMT+0000 (Coordinated Universal Time)',
      );
      expect(
        frame,
        'X-Timestamp:Wed Oct 15 2025 06:13:20 GMT+0000 '
        '(Coordinated Universal Time)\r\n'
        'Content-Type:application/json; charset=utf-8\r\n'
        'Path:speech.config\r\n\r\n'
        '{"context":{"synthesis":{"audio":{"metadataoptions":{'
        '"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"true"},'
        '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}\r\n',
      );
      expect(frame.contains('X-RequestId'), isFalse);
      expect(frame.contains('Content-Length'), isFalse);
      expect(
        frame.contains('"wordBoundaryEnabled":true'),
        isFalse,
      ); // 不是 JSON 布尔
      expect(frame.endsWith('}}}}\r\n'), isTrue);
    });

    test('关掉词级时两个开关互换（服务端要求互斥）', () {
      final frame = encodeConfigFrame(wordBoundary: false, timestamp: 'T');
      expect(frame.contains('"sentenceBoundaryEnabled":"true"'), isTrue);
      expect(frame.contains('"wordBoundaryEnabled":"false"'), isTrue);
    });

    test('config 帧可被自己解码回来（头部/正文边界一致）', () {
      final frame = encodeConfigFrame(wordBoundary: true, timestamp: 'T');
      final head = frame.substring(0, frame.indexOf('\r\n\r\n'));
      final decoded = decodeTextFrame(frame);
      expect(decoded.headers['Path'], 'speech.config');
      expect(decoded.headers['X-Timestamp'], 'T');
      expect(decoded.path, EdgePath.unknown); // speech.config 不是响应路径
      // 分隔符只跳前不跳后：body 里仍带着 JSON 之后那个 \r\n（上游同款）。
      expect(utf8.decode(decoded.body), endsWith('}}}}\r\n'));
      expect(head.contains('\r\n\r\n'), isFalse);
    });
  });

  group('ssml 帧逐字节', () {
    test('X-Timestamp 末尾多一个 Z（微软的 bug），body 之后不再加 \\r\\n', () {
      final frame = encodeSsmlFrame(
        requestId: 'abc123',
        timestamp:
            'Wed Oct 15 2025 06:13:20 GMT+0000 (Coordinated Universal Time)',
        ssml: '<speak>x</speak>',
      );
      expect(
        frame,
        'X-RequestId:abc123\r\n'
        'Content-Type:application/ssml+xml\r\n'
        'X-Timestamp:Wed Oct 15 2025 06:13:20 GMT+0000 '
        '(Coordinated Universal Time)Z\r\n'
        'Path:ssml\r\n\r\n'
        '<speak>x</speak>',
      );
      expect(frame.endsWith('<speak>x</speak>'), isTrue);
      expect(frame.endsWith('\r\n'), isFalse);
      expect(frame.contains('CV='), isFalse); // 7.3.1 没有 CV
      expect(frame.contains('Sec-MS-Blob'), isFalse);
    });
  });

  group('文本帧解码', () {
    test('audio.metadata：头部与正文分离，body 不含分隔符', () {
      final raw = textFrame(
        'X-RequestId:req\r\n'
            'Content-Type:application/json; charset=utf-8\r\n'
            'Path:audio.metadata',
        '{"Metadata":[]}',
      );
      final frame = decodeTextFrame(raw);
      expect(frame.path, EdgePath.audioMetadata);
      expect(frame.isMetadata, isTrue);
      expect(frame.headers['X-RequestId'], 'req');
      expect(utf8.decode(frame.body), '{"Metadata":[]}');
    });

    test('turn.end / turn.start / response 都能识别', () {
      expect(decodeTextFrame(textFrame('Path:turn.end', '')).isTurnEnd, isTrue);
      expect(
        decodeTextFrame(textFrame('Path:turn.start', '')).path,
        EdgePath.turnStart,
      );
      expect(
        decodeTextFrame(textFrame('Path:response', '{"ErrorCode":4000}')).path,
        EdgePath.response,
      );
    });

    test('没有 \\r\\n\\r\\n 的帧显式按心跳处理（不复刻负索引行为）', () {
      final frame = decodeTextFrame('HeartBeat');
      expect(frame.path, EdgePath.heartbeat);
      expect(frame.isHeartbeat, isTrue);
      expect(frame.headers, isEmpty);
      expect(utf8.decode(frame.body), 'HeartBeat');
      // 中文正文也不能把下标算歪：分隔符位置按字符找，不是按字节找。
      final multibyte = decodeTextFrame(textFrame('Path:turn.end', '尾部的中文'));
      expect(utf8.decode(multibyte.body), '尾部的中文');
    });

    test('未知 Path 不炸，原值留在 unknownPath 里供诊断', () {
      final frame = decodeTextFrame(textFrame('Path:something.new', '{}'));
      expect(frame.path, EdgePath.unknown);
      expect(frame.unknownPath, 'something.new');
    });

    test('头部按第一个冒号切，值里的冒号与空格被容忍', () {
      final frame = decodeTextFrame(
        textFrame('Content-Type: audio/mpeg; charset=utf-8\r\nPath:audio', 'x'),
      );
      expect(frame.headers['Content-Type'], 'audio/mpeg; charset=utf-8');
      expect(frame.path, EdgePath.audio);
    });

    test('畸形头部行（无冒号 / 空 key）被忽略而不是异常', () {
      final frame = decodeTextFrame(
        textFrame('garbage\r\n:noname\r\nPath:audio', 'b'),
      );
      expect(frame.headers.length, 1);
      expect(frame.headers['Path'], 'audio');
    });
  });

  group('二进制帧解码（比上游更干净）', () {
    test('头部区取 f[2..2+hl]，音频从 2+hl 开始', () {
      final payload = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
      final frame = decodeBinaryFrame(binaryFrame(_audioHead, payload));
      expect(frame.isAudio, isTrue);
      expect(frame.headers['Content-Type'], 'audio/mpeg');
      expect(frame.body, payload);
    });

    test('收尾帧：body 为空且无 Content-Type 是合法的', () {
      final frame = decodeBinaryFrame(binaryFrame('Path:audio', <int>[]));
      expect(frame.isAudio, isTrue);
      expect(frame.headers.containsKey('Content-Type'), isFalse);
      expect(frame.body, isEmpty);
    });

    test('hl == length-2 是边界内（上游的 hl > length 会宽放两字节）', () {
      final head = 'Path:audio';
      final frame = binaryFrame(head, <int>[]);
      expect(frame.length - 2, utf8.encode(head).length);
      expect(() => decodeBinaryFrame(frame), returnsNormally);
    });

    test('hl 越界（盖住 body）必须拒绝', () {
      final head = utf8.encode('Path:audio');
      final bad = Uint8List(2 + head.length + 3)
        ..[0] = 0
        ..[1] =
            (head.length + 4) &
            0xFF // hl 比头部区还长 4
        ..setRange(2, 2 + head.length, head);
      expect(() => decodeBinaryFrame(bad), throwsA(isA<EdgeFrameException>()));
    });

    test('不足两字节：缺头部长度', () {
      expect(
        () => decodeBinaryFrame(Uint8List.fromList(<int>[0x01])),
        throwsA(isA<EdgeFrameException>()),
      );
      expect(
        () => decodeBinaryFrame(Uint8List(0)),
        throwsA(isA<EdgeFrameException>()),
      );
    });

    test('二进制帧 Path 不是 audio 时原样返回，由上层决定', () {
      final frame = decodeBinaryFrame(binaryFrame('Path:strange', <int>[9]));
      expect(frame.path, EdgePath.unknown);
      expect(frame.unknownPath, 'strange');
    });
  });

  group('boundary 解析（全量收集）', () {
    String meta(List<Map<String, Object?>> items) =>
        '{"Metadata":${jsonEncode(items)}}';

    Map<String, Object?> word(
      int offset,
      int duration,
      String text, {
      String type = 'WordBoundary',
    }) => <String, Object?>{
      'Type': type,
      'Data': <String, Object?>{
        'Offset': offset,
        'Duration': duration,
        'text': <String, Object?>{'Text': text},
      },
    };

    test('一帧多条全部收（上游 __parse_metadata 只取第一条，是更弱的行为）', () {
      final body = utf8.encode(
        meta(<Map<String, Object?>>[
          word(0, 100000, '你'),
          word(100000, 200000, '好'),
          word(300000, 150000, '世'),
        ]),
      );
      final list = parseBoundaries(body);
      expect(list.length, 3);
      expect(list.map((b) => b.text).toList(), <String>['你', '好', '世']);
      // 100 纳秒 tick → 毫秒：ms = tick ~/ 10000。
      expect(list[0].offsetMs, 0);
      expect(list[0].durationMs, 10);
      expect(list[1].offsetMs, 10);
      expect(list[1].durationMs, 20);
      expect(list[2].offsetTicks, 300000);
      expect(list[2].offsetMs, 30);
      expect(list[2].durationMs, 15);
    });

    test('未知 Type 与 SessionEnd 跳过、不抛（服务端加类型不该让朗读失败）', () {
      final body = <String, Object?>{
        'Metadata': <Object?>[
          word(0, 100000, '你'),
          word(1, 2, '句', type: 'SessionEnd'),
          word(4, 5, '韵', type: 'ProsodyBoundary'),
          word(100000, 100000, '好'),
          'not-an-object',
          <String, Object?>{'Type': 'WordBoundary'}, // 缺 Data
        ],
      };
      final list = parseBoundaries(jsonEncode(body));
      expect(list.length, 2);
      expect(list.map((b) => b.text), <String>['你', '好']);
    });

    test('token 里的转义被还原（与发送侧成对，否则坐标漂移）', () {
      final list = parseBoundaries(
        meta(<Map<String, Object?>>[word(0, 10000, 'A &amp; B &lt; C')]),
      );
      expect(list.single.text, 'A & B < C');
    });

    test('Offset/Duration 可以是字符串数字；缺字段/坏 JSON 一律不炸', () {
      final list = parseBoundaries(
        '{"Metadata":[{"Type":"WordBoundary","Data":'
        '{"Offset":"20000","Duration":"30000","text":{"Text":"x"}}}]}',
      );
      expect(list.single.offsetMs, 2);
      expect(list.single.durationMs, 3);
      expect(parseBoundaries('not json'), isEmpty);
      expect(parseBoundaries('{}'), isEmpty);
      expect(parseBoundaries('{"Metadata":{}}'), isEmpty);
      expect(parseBoundaries(<int>[0xFF, 0xFE, 0x00]), isEmpty);
    });

    test('String 正文同样可解析', () {
      final list = parseBoundaries(
        meta(<Map<String, Object?>>[word(0, 1, '词')]),
      );
      expect(list.single.type, 'WordBoundary');
      expect(list.single.toString(), contains('WordBoundary'));
    });
  });

  group('头部解析工具', () {
    test('parseHeaderLines 不吞空行、不认没 key 的行', () {
      expect(parseHeaderLines(''), isEmpty);
      expect(parseHeaderLines('\r\n\r\n'), isEmpty);
      expect(parseHeaderLines('Path:audio')['Path'], 'audio');
    });

    test('常量表与说明书一致（改一处就要过全表）', () {
      expect(kEdgeTickDivisor, 10000);
      expect(kEdgeMaxChunkBytes, 4096);
      expect(kEdgeOutputFormat, 'audio-24khz-48kbitrate-mono-mp3');
      expect(kEdgeMp3BitrateBps, 48000);
    });
  });
}
