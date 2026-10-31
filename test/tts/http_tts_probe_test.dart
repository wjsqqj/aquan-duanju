import 'dart:convert';
import 'dart:typed_data';

import 'package:aquan_duanju/core/tts/http/http_tts_probe.dart';
import 'package:aquan_duanju/core/tts/http/http_tts_source.dart';
import 'package:aquan_duanju/core/tts/tts_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'speech_fakes.dart';

/// 调试台体检：成功/失败都要给出可判读的三段证据，且**绝不泄露 query 里的密钥**。
void main() {
  HttpTtsSource source({
    String url = 'http://h/tts?text={text}&voice={voice}&key=SECRET',
    HttpTtsResponseMode mode = HttpTtsResponseMode.audio,
    String audioField = '',
  }) =>
      HttpTtsSource(
        id: 'probe',
        name: 'probe',
        urlTemplate: url,
        mode: mode,
        audioField: audioField,
        voices: const [TtsVoice(id: 'zh-A')],
      );

  test('成功：状态码/请求数/字节/音频时长/句数都给到', () async {
    final frames = mp3Frames(2);
    final result = await HttpTtsProbe.run(
      source(),
      client: MockClient(
        (request) async => http.Response.bytes(frames, 200),
      ),
    );

    expect(result.ok, isTrue);
    expect(result.statusCode, 200);
    expect(result.requests, 1);
    expect(result.bytes, frames.length);
    expect(result.audioMs, greaterThan(0));
    expect(result.sentenceCount, 2, reason: '默认文本两句');
    expect(result.snippet, isEmpty, reason: '音频是二进制，不做摘要');
    expect(result.headline, contains('成功'));
  });

  test('requestLines 只记 host/path：query 里的密钥绝不上屏', () async {
    final result = await HttpTtsProbe.run(
      source(),
      client: MockClient(
        (request) async => http.Response.bytes(mp3Frames(1), 200),
      ),
    );
    expect(result.requestLines, isNotEmpty);
    for (final line in result.requestLines) {
      expect(line.contains('SECRET'), isFalse, reason: '密钥泄露到调试台');
      expect(line.contains('?'), isFalse, reason: '只记 host/path');
    }
  });

  test('403：带出服务端说了什么（摘要）+ 错误码', () async {
    final result = await HttpTtsProbe.run(
      source(),
      client: MockClient(
        (request) async => http.Response('{"error":"access denied"}', 403),
      ),
    );
    expect(result.ok, isFalse);
    expect(result.errorCode, 'authRejected');
    expect(result.statusCode, 403);
    expect(result.snippet, contains('access denied'));
    expect(result.headline, contains('失败'));
  });

  test('429 → rateLimited', () async {
    final result = await HttpTtsProbe.run(
      source(),
      client: MockClient((request) async => http.Response('slow down', 429)),
    );
    expect(result.errorCode, 'rateLimited');
  });

  test('返回不是 mp3 → emptyAudio（而不是显示成功）', () async {
    final result = await HttpTtsProbe.run(
      source(),
      client: MockClient(
        (request) async => http.Response.bytes(
          Uint8List.fromList(utf8.encode('not an mp3 at all')),
          200,
        ),
      ),
    );
    expect(result.ok, isFalse);
    expect(result.errorCode, 'emptyAudio');
  });

  test('jsonUrl 模式：正常就是两次请求', () async {
    final result = await HttpTtsProbe.run(
      source(
        mode: HttpTtsResponseMode.jsonUrl,
        audioField: 'data.audio',
      ),
      client: MockClient((request) async {
        if (request.url.path == '/tts') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'data': <String, dynamic>{'audio': 'http://h/a.mp3'},
            }),
            200,
          );
        }
        return http.Response.bytes(mp3Frames(1), 200);
      }),
    );
    expect(result.ok, isTrue);
    expect(result.requests, 2);
    expect(result.snippet, contains('a.mp3'), reason: '第一次响应摘要可判读');
  });

  test('响应摘要截断到 200 字并压平换行', () async {
    final long = 'x' * 400;
    final result = await HttpTtsProbe.run(
      source(mode: HttpTtsResponseMode.jsonBase64, audioField: 'audio'),
      client: MockClient(
        (request) async => http.Response(
          jsonEncode(<String, dynamic>{'audio': long, 'hint': 'a\nb'}),
          200,
        ),
      ),
    );
    expect(result.snippet.length, lessThanOrEqualTo(202));
    expect(result.snippet.endsWith('…'), isTrue);
    expect(result.snippet.contains('\n'), isFalse);
  });
}
