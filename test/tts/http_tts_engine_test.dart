import 'dart:convert';
import 'dart:typed_data';

import 'package:aquan_duanju/core/tts/http/http_tts_engine.dart';
import 'package:aquan_duanju/core/tts/http/http_tts_source.dart';
import 'package:aquan_duanju/core/tts/speech_engine.dart';
import 'package:aquan_duanju/core/tts/tts_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'speech_fakes.dart';

/// 第三方 HTTP TTS：配置解析、模板渲染、三种响应模式、错误分类、句级比例时间点。
void main() {
  HttpTtsSource audioSource({
    String id = 'local',
    String url = 'http://127.0.0.1:9880/tts?text={text}&voice={voice}',
    String method = 'GET',
    String body = '',
  }) =>
      HttpTtsSource(
        id: id,
        name: '本地 TTS',
        urlTemplate: url,
        method: method,
        bodyTemplate: body,
      );

  SpeechJob job({String text = '第一句。第二句！', int offsetBaseMs = 1000}) =>
      SpeechJob(
        text: text,
        voice: const TtsVoice(id: 'zh-A'),
        offsetBaseMs: offsetBaseMs,
        requestIndex: 1,
      );

  group('源配置解析', () {
    test('最小合法配置', () {
      final source = HttpTtsSource.tryParse('''
        {"id":"local","url":"http://127.0.0.1:9880/tts?text={text}","voices":["zh-A"]}
      ''');
      expect(source, isNotNull);
      expect(source!.id, 'local');
      expect(source.method, 'GET');
      expect(source.mode, HttpTtsResponseMode.audio);
      expect(source.voices.single.id, 'zh-A');
    });

    test('缺少 {text} / 非 http / 未知 mode / jsonUrl 缺 audioField 一律拒绝', () {
      expect(
        HttpTtsSource.tryParse('{"id":"a","url":"http://x/tts"}'),
        isNull,
        reason: '没有 {text} 占位符等于固定文本，无意义',
      );
      expect(
        HttpTtsSource.tryParse('{"id":"a","url":"ftp://x/?t={text}"}'),
        isNull,
      );
      expect(
        HttpTtsSource.tryParse(
          '{"id":"a","url":"http://x/?t={text}","mode":"weird"}',
        ),
        isNull,
      );
      expect(
        HttpTtsSource.tryParse(
          '{"id":"a","url":"http://x/?t={text}","mode":"jsonUrl"}',
        ),
        isNull,
        reason: 'jsonUrl 必须给 audioField',
      );
      expect(HttpTtsSource.tryParse('not json'), isNull);
    });
  });

  group('模板渲染', () {
    test('URL 里的 text 会被 percent-encode', () {
      final source = audioSource(url: 'http://h/tts?text={text}&v={voice}');
      final uri = source.buildUri(text: '你好 & bye/1', voice: 'zh A');
      expect(uri.queryParameters['text'], '你好 & bye/1');
      expect(uri.queryParameters['v'], 'zh A');
    });

    test('body 模板里的 text 做 JSON 转义（引号/换行不破坏 JSON）', () {
      final source = audioSource(
        method: 'POST',
        body: '{"text":"{text}","voice":"{voice}"}',
      );
      final body = source.buildBody(text: '他说"走"\n了', voice: 'zh-A');
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      expect(decoded['text'], '他说"走"\n了');
      expect(decoded['voice'], 'zh-A');
    });
  });

  group('三种响应模式', () {
    test('audio：响应体就是 mp3', () async {
      final frames = mp3Frames(2);
      final engine = HttpTtsEngine(
        source: audioSource(),
        client: MockClient((request) async => http.Response.bytes(frames, 200)),
      );
      final segment = await engine.synthesize(job());
      expect(segment.audio, frames);
      expect(segment.bitrateKbps, kTtsMp3BitrateKbps);
      // 只回音频 → 没有词级；句级比例时间点。
      expect(engine.caps.wordBoundary, isFalse);
      expect(segment.points, hasLength(2), reason: '两个句子两个点');
      expect(segment.points.first.startMs, 1000, reason: '时间已加 offsetBaseMs');
      expect(
        segment.points.last.endMs,
        1000 + segment.audioMs,
        reason: '最后一句必须收在音频末尾',
      );
      expect(segment.points[1].startMs, segment.points[0].endMs);
    });

    test('jsonUrl：先取 JSON 再下载音频直链', () async {
      final frames = mp3Frames(2);
      final urls = <String>[];
      final engine = HttpTtsEngine(
        source: HttpTtsSource.tryParse(
          '{"id":"j","url":"http://h/tts?text={text}","mode":"jsonUrl","audioField":"data.audio"}',
        )!,
        client: MockClient((request) async {
          urls.add(request.url.toString());
          if (request.url.path == '/tts') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'data': <String, dynamic>{'audio': 'http://h/a.mp3'},
              }),
              200,
            );
          }
          return http.Response.bytes(frames, 200);
        }),
      );
      final segment = await engine.synthesize(job());
      expect(segment.audio, frames);
      expect(urls, hasLength(2), reason: 'JSON 与音频各一次请求');
      expect(urls.last, endsWith('/a.mp3'));
    });

    test('jsonBase64：JSON 字段里是 base64 音频', () async {
      final frames = mp3Frames(1);
      final engine = HttpTtsEngine(
        source: HttpTtsSource.tryParse(
          '{"id":"b","url":"http://h/tts?text={text}","mode":"jsonBase64","audioField":"audio"}',
        )!,
        client: MockClient(
          (request) async => http.Response(
            jsonEncode(<String, dynamic>{'audio': base64Encode(frames)}),
            200,
          ),
        ),
      );
      final segment = await engine.synthesize(job(text: '一句话。'));
      expect(segment.audio, frames);
      expect(segment.points, hasLength(1));
    });

    test('POST：把模板渲染后的 body 发出去', () async {
      late String sentBody;
      final engine = HttpTtsEngine(
        source: audioSource(
          method: 'POST',
          body: '{"text":"{text}","voice":"{voice}"}',
        ),
        client: MockClient((request) async {
          sentBody = request.body;
          return http.Response.bytes(mp3Frames(1), 200);
        }),
      );
      await engine.synthesize(job(text: '你好。'));
      expect(jsonDecode(sentBody)['text'], '你好。');
    });
  });

  group('错误分类（UI 只认 TtsException.friendlyText）', () {
    Future<TtsException> catchOf(int status) async {
      final engine = HttpTtsEngine(
        source: audioSource(),
        client: MockClient(
          (request) async => http.Response('nope', status),
        ),
      );
      try {
        await engine.synthesize(job());
      } on TtsException catch (e) {
        return e;
      }
      fail('应当抛出 TtsException');
    }

    test('401/403 → authRejected', () async {
      expect((await catchOf(403)).code, TtsErrorCode.authRejected);
    });

    test('429 → rateLimited', () async {
      final e = await catchOf(429);
      expect(e.code, TtsErrorCode.rateLimited);
      expect(e.retryable, isTrue);
    });

    test('500 → transport 且可重试', () async {
      final e = await catchOf(500);
      expect(e.code, TtsErrorCode.transport);
      expect(e.retryable, isTrue);
    });

    test('空响应体 → emptyAudio', () async {
      final engine = HttpTtsEngine(
        source: audioSource(),
        client: MockClient((request) async => http.Response.bytes(
              Uint8List(0),
              200,
            )),
      );
      await expectLater(
        engine.synthesize(job()),
        throwsA(
          isA<TtsException>().having(
            (e) => e.code,
            'code',
            TtsErrorCode.emptyAudio,
          ),
        ),
      );
    });

    test('不是 mp3（帧头损坏）→ emptyAudio 而不是静默播空白', () async {
      final engine = HttpTtsEngine(
        source: audioSource(),
        client: MockClient(
          (request) async => http.Response.bytes(
            Uint8List.fromList(utf8.encode('hello world, not mp3')),
            200,
          ),
        ),
      );
      await expectLater(
        engine.synthesize(job()),
        throwsA(
          isA<TtsException>().having(
            (e) => e.code,
            'code',
            TtsErrorCode.emptyAudio,
          ),
        ),
      );
    });
  });
}
