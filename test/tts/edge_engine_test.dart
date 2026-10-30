import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aquan_duanju/core/tts/edge/edge_constants.dart';
import 'package:aquan_duanju/core/tts/edge/edge_engine.dart';
import 'package:aquan_duanju/core/tts/edge/edge_ssml.dart';
import 'package:aquan_duanju/core/tts/edge/edge_stream.dart';
import 'package:aquan_duanju/core/tts/edge/edge_token.dart';
import 'package:aquan_duanju/core/tts/mp3_frames.dart';
import 'package:aquan_duanju/core/tts/speech_engine.dart';
import 'package:aquan_duanju/core/tts/tts_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一个词级 boundary（100 纳秒 tick）。
class Word {
  const Word(this.offset, this.duration, this.text);

  final int offset;
  final int duration;
  final String text;
}

final DateTime _fixedNow = DateTime.utc(2025, 10, 15, 6, 0, 0);

/// 服务端 `Date`：比 [_fixedNow] 快 800 秒 —— 纠偏后 skew 必须正好是 800s。
const String _fixedDate = 'Wed, 15 Oct 2025 06:13:20 GMT';

const int _skewSeconds = 800;

/// 造 [count] 个合法 MPEG-2 Layer III 48kbps 帧：每帧 144 字节 = 24ms。
///
/// 必须是真的可解析帧：引擎会把音频过一遍 `extractMp3AudioFrames`，随意字节会被
/// 洗掉，偏移补偿与 composer 的接缝就无从核对（与 tts_composer_test 同一套帧）。
Uint8List mp3Frames(int count) {
  final out = Uint8List(count * 144);
  for (var f = 0; f < count; f++) {
    final o = f * 144;
    out[o] = 0xFF;
    out[o + 1] = 0xF3;
    out[o + 2] = 0x64;
    out[o + 3] = 0x40;
    for (var j = 4; j < 144; j++) {
      out[o + j] = 0x20 + (j % 60);
    }
  }
  return out;
}

/// 二进制帧：`hl` = 头部区长度（说明书 §4.2 的干净口径，不含那两字节前缀）。
Uint8List binaryFrame(String head, List<int> body) {
  final headBytes = utf8.encode(head);
  final total = 2 + headBytes.length + body.length;
  final out = Uint8List(total)
    ..[0] = (headBytes.length >> 8) & 0xFF
    ..[1] = headBytes.length & 0xFF
    ..setRange(2, 2 + headBytes.length, headBytes)
    ..setRange(2 + headBytes.length, total, body);
  return out;
}

String textFrame(String head, String body) => '$head\r\n\r\n$body';

/// 音频帧（[chunks] > 1 时按帧拆开，验证跨帧拼接）。
List<dynamic> audioFrames(int frameCount, {int chunks = 1}) {
  final bytes = mp3Frames(frameCount);
  final per = bytes.length ~/ chunks;
  return <dynamic>[
    for (var i = 0; i < chunks; i++)
      binaryFrame(
        'Path:audio\r\nContent-Type:audio/mpeg',
        bytes.sublist(i * per, i == chunks - 1 ? bytes.length : (i + 1) * per),
      ),
  ];
}

/// 一条只有 Content-Type 缺失的音频帧（body 非空 = 非法）。
dynamic audioFrameWithoutContentType(int frameCount) {
  final bytes = mp3Frames(frameCount);
  return binaryFrame('Path:audio', bytes);
}

dynamic metadataFrame(List<Word> words, {String type = 'WordBoundary'}) {
  final items = <Map<String, Object?>>[
    for (final w in words)
      <String, Object?>{
        'Type': type,
        'Data': <String, Object?>{
          'Offset': w.offset,
          'Duration': w.duration,
          'text': <String, Object?>{'Text': w.text},
        },
      },
  ];
  return textFrame(
    'X-RequestId:feed\r\n'
    'Content-Type:application/json; charset=utf-8\r\n'
    'Path:audio.metadata',
    jsonEncode(<String, Object?>{'Metadata': items}),
  );
}

dynamic turnEnd() => textFrame('X-RequestId:feed\r\nPath:turn.end', '');

/// 一次连接要推送的完整脚本。
List<dynamic> script({
  int frames = 2,
  List<Word> words = const <Word>[],
  List<dynamic> extra = const <dynamic>[],
}) => <dynamic>[
  ...extra,
  ...audioFrames(frames),
  if (words.isNotEmpty) metadataFrame(words),
  turnEnd(),
];

class _FakeSocket implements EdgeSocket {
  _FakeSocket(List<dynamic> events) {
    for (final event in events) {
      _controller.add(event);
    }
    // 单订阅控制器在有人监听前会缓冲事件，所以可以先灌数据再让会话去 await for。
    _controller.close();
  }

  final StreamController<dynamic> _controller = StreamController<dynamic>();
  final List<Object> sent = <Object>[];

  @override
  Stream<dynamic> get messages => _controller.stream;

  @override
  void add(Object data) => sent.add(data);

  @override
  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
  }
}

/// 假 WSS 工厂：按连接次序吐脚本，可编排「前 n 次连接直接 403」。
class _FakeWs {
  _FakeWs({this.scripts = const <List<dynamic>>[], this.failFirstWith});

  final List<List<dynamic>> scripts;

  /// 非 null 时：下标 < failFirstWith 的连接一律抛 403（**只重试一次**的判据靠它数）。
  final int? failFirstWith;

  final List<Uri> uris = <Uri>[];
  final List<Map<String, String>> headers = <Map<String, String>>[];
  final List<_FakeSocket> sockets = <_FakeSocket>[];

  int get calls => uris.length;

  Future<EdgeSocket> connect(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    EdgeHttpClient? client,
  }) async {
    final index = uris.length;
    uris.add(uri);
    this.headers.add(headers);
    // 字段不参与类型提升，先取到局部变量再判空。
    final limit = failFirstWith;
    if (limit != null && index < limit) {
      final token = generateSecMsGec(now: _fixedNow);
      throw EdgeConnectFailure(
        statusCode: 403,
        reason: 'rejected Sec-MS-GEC=$token',
      );
    }
    final events = index < scripts.length
        ? scripts[index]
        : (scripts.isEmpty ? <dynamic>[] : scripts.last);
    final socket = _FakeSocket(events);
    sockets.add(socket);
    return socket;
  }
}

/// 假 HTTP：状态码按调用序号编排；`Date` 头供时钟探针；音色列表正文可注入。
class _FakeHttp implements EdgeHttpClient {
  _FakeHttp({
    this.dateHeader = _fixedDate,
    this.voicesBody = '[]',
    this.statusFor,
  });

  String? dateHeader;
  String voicesBody;

  /// 入参是「第几次 GET（0 基）」，返回状态码。
  int Function(int index)? statusFor;

  final List<Uri> requested = <Uri>[];
  final List<EdgeHttpProfile> profiles = <EdgeHttpProfile>[];
  int closeCount = 0;

  /// 工厂入口：顺手登记 profile，让「代理/UA 只能经 customClient 生效」可被断言。
  EdgeHttpClient create(EdgeHttpProfile profile) {
    profiles.add(profile);
    return this;
  }

  @override
  HttpClient? get ioClient => null;

  @override
  Future<EdgeHttpResponse> get(Uri uri, {Map<String, String>? headers}) async {
    final index = requested.length;
    requested.add(uri);
    final status = statusFor == null ? HttpStatus.ok : statusFor!(index);
    return EdgeHttpResponse(
      statusCode: status,
      dateHeader: dateHeader,
      body: voicesBody,
    );
  }

  @override
  void close({bool force = false}) => closeCount++;
}

/// 一条完整的双桩环境。
class _Harness {
  _Harness({
    List<List<dynamic>> scripts = const <List<dynamic>>[],
    int? failFirstWith,
    String? dateHeader = _fixedDate,
    String voicesBody = '[]',
    int Function(int index)? statusFor,
    this.proxy = '',
    String rate = kEdgeDefaultRate,
    String volume = kEdgeDefaultVolume,
    String pitch = kEdgeDefaultPitch,
    EdgeEndpointPreset? preset,
  }) : ws = _FakeWs(scripts: scripts, failFirstWith: failFirstWith),
       http = _FakeHttp(
         dateHeader: dateHeader,
         voicesBody: voicesBody,
         statusFor: statusFor,
       ),
       clock = DrmClock() {
    engine = EdgeSpeechEngine(
      preset: preset,
      proxy: proxy,
      rate: rate,
      volume: volume,
      pitch: pitch,
      wsFactory: ws.connect,
      httpClientFactory: http.create,
      clock: clock,
      now: () => _fixedNow,
    );
  }

  final _FakeWs ws;
  final _FakeHttp http;
  final DrmClock clock;
  final String proxy;
  late final EdgeSpeechEngine engine;

  SpeechJob job(
    String text, {
    int offsetBaseMs = 0,
    String voice = 'zh-CN-XiaoxiaoNeural',
  }) => SpeechJob(
    text: text,
    voice: TtsVoice(id: voice),
    offsetBaseMs: offsetBaseMs,
    requestIndex: 7,
  );

  /// 引擎实际发出去的第 n 条报文（0=config，1=ssml）。
  Object sent(int chunk, int frame) => ws.sockets[chunk].sent[frame];

  String ssmlFrameOf(int chunk) => sent(chunk, 1) as String;

  /// 从 ssml 帧里取回真正被念的正文（验证分块与转义）。
  String spokenText(int chunk) {
    final frame = ssmlFrameOf(chunk);
    final ssml = frame.substring(frame.indexOf('\r\n\r\n') + 4);
    final start = ssml.indexOf('>', ssml.indexOf('<prosody')) + 1;
    return ssml.substring(start, ssml.indexOf('</prosody>'));
  }
}

/// 帧头里的 `X-Timestamp` 值（不含帧里追加的那个 `Z`）。
String _headerValue(String frame, String key) {
  final line = frame
      .split('\r\n')
      .firstWhere((l) => l.startsWith('$key:'), orElse: () => '');
  return line.isEmpty ? '' : line.substring(key.length + 1);
}

void main() {
  group('引擎契约元信息', () {
    test('id/caps 与硬契约 1 完全一致', () {
      final engine = _Harness().engine;
      expect(engine.id, 'edge');
      expect(engine.caps.wordBoundary, isTrue);
      expect(engine.caps.offline, isFalse);
      expect(engine.caps.needsApiKey, isFalse);
      expect(engine.caps.producesFile, isTrue);
    });

    test('默认端点是真源，降级顺序给出下一个（不在一次请求里静默换）', () {
      final engine = _Harness().engine;
      expect(engine.preset.name, 'bing-readaloud');
      expect(engine.fallbackPreset?.name, 'msedgeservices-tts');
      expect(engine.fallbackPreset?.keyParamName, 'Ocp-Apim-Subscription-Key');
      final last = _Harness(preset: kEdgeMsEdgeservicesTtsPreset).engine;
      expect(last.fallbackPreset, isNull);
    });

    test('非法韵律在构造期就抛（不等到拼 SSML 才发现）', () {
      expect(() => _Harness(rate: '10%'), throwsFormatException);
      expect(() => _Harness(pitch: '+3%'), throwsFormatException);
      expect(() => _Harness(volume: 'loud'), throwsFormatException);
    });

    test('dispose 之后仍可再次拉音色（没有常驻连接需要维护）', () async {
      final h = _Harness(voicesBody: '[{"ShortName":"zh-CN-XiaoxiaoNeural"}]');
      expect(await h.engine.voices(), hasLength(1));
      await h.engine.dispose();
      expect(await h.engine.voices(), hasLength(1));
      expect(h.http.requested.length, 2);
    });
  });

  group('连接与 URL（硬契约 3）', () {
    test('URL 只带四项，不发 CV / Sec-MS-Blob / Content-Length', () async {
      final h = _Harness(
        scripts: [
          script(words: [Word(0, 100000, '你')]),
        ],
      );
      await h.engine.synthesize(h.job('你'));
      final uri = h.ws.uris.single;
      expect(uri.scheme, 'wss');
      expect(uri.host, 'speech.platform.bing.com');
      expect(uri.path, '/consumer/speech/synthesize/readaloud/edge/v1');
      expect(uri.queryParameters.keys.toSet(), <String>{
        'TrustedClientToken',
        'ConnectionId',
        'Sec-MS-GEC',
        'Sec-MS-GEC-Version',
      });
      expect(uri.query, isNot(contains('CV')));
      expect(uri.query, isNot(contains('Sec-MS-Blob')));
      expect(
        uri.queryParameters['Sec-MS-GEC-Version'],
        kEdgeDefaultPreset.gecVersion,
      );
      expect(generateSecMsGec(now: _fixedNow).length, 81);
    });

    test('ConnectionId 是小写 32 hex，且每次连接新造', () async {
      final h = _Harness(
        scripts: [
          script(words: [Word(0, 100000, '啊')]),
          script(words: [Word(0, 100000, '啊')]),
        ],
      );
      await h.engine.synthesize(h.job('啊' * 2000));
      final ids = h.ws.uris
          .map((u) => u.queryParameters['ConnectionId'] ?? '')
          .toList();
      expect(ids, hasLength(h.ws.calls));
      for (final id in ids) {
        expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(id), isTrue, reason: id);
      }
      expect(ids.toSet().length, ids.length);
    });

    test('UA 不进 headers（避免 add 语义造成双 UA），muid 走 Cookie', () async {
      final h = _Harness(
        scripts: [
          script(words: [Word(0, 100000, '你')]),
        ],
      );
      await h.engine.synthesize(h.job('你'));
      final headers = h.ws.headers.single;
      expect(headers.containsKey('User-Agent'), isFalse);
      expect(headers.containsKey('Sec-WebSocket-Version'), isFalse);
      expect(headers['Origin'], kEdgeOrigin);
      expect(headers['Cookie'], matches(RegExp(r'^muid=[0-9A-F]{32};$')));
      // UA 与代理的唯一入口是 customClient。
      expect(h.http.profiles.first.userAgent, kEdgeUserAgent);
    });

    test('代理只从显式配置来，默认空串 = DIRECT', () async {
      expect(_Harness().engine.proxy, '');
      final h = _Harness(
        scripts: [
          script(words: [Word(0, 100000, '你')]),
        ],
        proxy: '127.0.0.1:7890',
      );
      await h.engine.synthesize(h.job('你'));
      expect(h.http.profiles.first.proxy, '127.0.0.1:7890');
      expect(h.ws.calls, 1);
    });
  });

  group('发出的报文（硬契约 4）', () {
    test('第一帧是 speech.config：无 X-RequestId，JSON 后还有一个 \\r\\n', () async {
      final h = _Harness(
        scripts: [
          script(words: [Word(0, 100000, '你')]),
        ],
      );
      await h.engine.synthesize(h.job('你'));
      final config = h.sent(0, 0) as String;
      expect(config.contains('X-RequestId'), isFalse);
      expect(config.contains('Path:speech.config\r\n\r\n'), isTrue);
      expect(config.contains('"wordBoundaryEnabled":"true"'), isTrue);
      expect(config.contains('"sentenceBoundaryEnabled":"false"'), isTrue);
      expect(config.endsWith('\r\n'), isTrue);
      expect(config.contains('audio-24khz-48kbitrate-mono-mp3'), isTrue);
    });

    test('第二帧是 ssml：时间戳多一个 Z，body 后不加 \\r\\n', () async {
      final h = _Harness(
        scripts: [
          script(words: [Word(0, 100000, '你')]),
        ],
      );
      await h.engine.synthesize(h.job('你'));
      final frame = h.ssmlFrameOf(0);
      expect(frame.startsWith('X-RequestId:'), isTrue);
      expect(
        RegExp(r'^[0-9a-f]{32}$').hasMatch(_headerValue(frame, 'X-RequestId')),
        isTrue,
      );
      expect(_headerValue(frame, 'X-Timestamp').endsWith('Z'), isTrue);
      expect(
        _headerValue(frame, 'X-Timestamp'),
        endsWith('(Coordinated Universal Time)Z'),
      );
      expect(frame.contains('Path:ssml\r\n\r\n'), isTrue);
      expect(frame.endsWith('</speak>'), isTrue);
      expect(frame.endsWith('\r\n'), isFalse);
      // 两处时间戳同源：config 与 ssml 用的是同一个基准串，
      // 差别只在 ssml 帧被微软那个 bug 多加了一个尾部 Z。
      final config = h.sent(0, 0) as String;
      expect(
        _headerValue(frame, 'X-Timestamp'),
        '${_headerValue(config, 'X-Timestamp')}Z',
      );
    });

    test('SSML 用 Azure 全名、单引号属性，正文被转义', () async {
      final h = _Harness(
        scripts: [
          script(words: [Word(0, 100000, '你')]),
        ],
      );
      await h.engine.synthesize(h.job('你 & 我'));
      final frame = h.ssmlFrameOf(0);
      expect(frame.contains(azureVoiceName('zh-CN-XiaoxiaoNeural')), isTrue);
      expect(frame.contains('xml:lang=\'en-US\''), isTrue);
      expect(h.spokenText(0), '你 &amp; 我');
      expect(frame.contains('express-as'), isFalse);
      // 一句短话哪怕带空格，也只能发一条连接（每块 = 一条新 WSS）。
      expect(h.ws.calls, 1);
    });

    test('音色缺省落到兜底女声，认不出的音色按未配置上报', () async {
      final h = _Harness(
        scripts: [
          script(words: [Word(0, 100000, '你')]),
        ],
      );
      await h.engine.synthesize(h.job('你', voice: '  '));
      expect(
        h.ssmlFrameOf(0).contains(azureVoiceName(kEdgeFallbackVoice)),
        isTrue,
      );

      final bad = _Harness();
      await expectLater(
        bad.engine.synthesize(bad.job('你', voice: 'not-a-voice')),
        throwsA(
          isA<TtsException>().having(
            (e) => e.code,
            'code',
            TtsErrorCode.notConfigured,
          ),
        ),
      );
      expect(bad.ws.calls, 0);
    });

    test('空白文本不发连接，直接 emptyAudio', () async {
      final h = _Harness();
      await expectLater(
        h.engine.synthesize(h.job('   \n  ')),
        throwsA(
          isA<TtsException>().having(
            (e) => e.code,
            'code',
            TtsErrorCode.emptyAudio,
          ),
        ),
      );
      expect(h.ws.calls, 0);
    });
  });

  group('音频与时间点（硬契约 1/5/7）', () {
    test('音频按帧顺序拼接，时间已加 offsetBaseMs，字符位相对 job.text', () async {
      final h = _Harness(
        scripts: [
          <dynamic>[
            ...audioFrames(2),
            metadataFrame(<Word>[
              Word(0, 200000, '你好'),
              Word(200000, 200000, '世界'),
            ]),
            turnEnd(),
          ],
        ],
      );
      final segment = await h.engine.synthesize(
        h.job('你好世界', offsetBaseMs: 1000),
      );
      expect(segment.audio, mp3Frames(2));
      expect(segment.bitrateKbps, kTtsMp3BitrateKbps);
      expect(segment.audioMs, mp3BytesToMs(288));
      expect(segment.audioMs, 48);
      // 两个双字 token → 逐字展开成 4 个点。
      expect(segment.points, hasLength(4));
      expect(segment.points.map((p) => p.charStart).toList(), <int>[
        0,
        1,
        2,
        3,
      ]);
      expect(segment.points.last.charEnd, 4);
      expect(segment.points.first.startMs, 1000);
      expect(segment.points[1].startMs, 1010);
      expect(segment.points[2].startMs, 1020);
      expect(segment.points.last.endMs, 1040);
      // 逐字展开后每个点自带那个字（下一任务的 `currentWord` 直接取字面用）。
      expect(segment.points.map((p) => p.text).toList(), <String>[
        '你',
        '好',
        '世',
        '界',
      ]);
      for (final p in segment.points) {
        expect(p.endMs, greaterThanOrEqualTo(p.startMs));
      }
    });

    test('心跳 / turn.start / 未知 Path / response 都不致命，且音频分包照样拼对', () async {
      final h = _Harness(
        scripts: [
          <dynamic>[
            'HeartBeat',
            textFrame('Path:turn.start', ''),
            ...audioFrames(2, chunks: 2),
            metadataFrame(<Word>[Word(0, 100000, '你')]),
            textFrame('Path:something.new', '{}'),
            textFrame('Path:response', '{"ErrorCode":"4000"}'),
            turnEnd(),
          ],
        ],
      );
      final segment = await h.engine.synthesize(h.job('你好世界'));
      expect(segment.audio, mp3Frames(2));
      expect(segment.points.first.charStart, 0);
      expect(segment.points.first.charEnd, 1);
    });

    test('SentenceBoundary 与未知 metadata 类型不进词表（未知类型也不抛）', () async {
      final h = _Harness(
        scripts: [
          <dynamic>[
            ...audioFrames(1),
            metadataFrame(<Word>[
              Word(0, 100000, '你好'),
            ], type: 'SentenceBoundary'),
            metadataFrame(<Word>[
              Word(0, 100000, '你'),
            ], type: 'ProsodyBoundary'),
            metadataFrame(<Word>[Word(100000, 100000, '好')]),
            turnEnd(),
          ],
        ],
      );
      final segment = await h.engine.synthesize(h.job('你好世界'));
      expect(segment.points, hasLength(1)); // 只有词级的「好」被展开成 1 点
      expect(segment.points.single.charStart, 1);
    });

    test('token 对不上原文时游标顺推，坐标仍 clamp 在本块内', () async {
      final h = _Harness(
        scripts: [
          <dynamic>[
            ...audioFrames(1),
            metadataFrame(<Word>[Word(0, 100000, '服务端改写过的长 token')]),
            turnEnd(),
          ],
        ],
      );
      final segment = await h.engine.synthesize(h.job('你好世界'));
      expect(segment.points, hasLength(4));
      expect(segment.points.first.charStart, 0);
      expect(segment.points.last.charEnd, 4);
    });

    test('一帧都没收到 → emptyAudio（协议漂移要可见）', () async {
      final h = _Harness(
        scripts: [
          <dynamic>[textFrame('Path:something.new', '{}'), turnEnd()],
        ],
      );
      await expectLater(
        h.engine.synthesize(h.job('你好')),
        throwsA(
          isA<TtsException>().having(
            (e) => e.code,
            'code',
            TtsErrorCode.emptyAudio,
          ),
        ),
      );
      final error = await h.engine
          .synthesize(h.job('你好'))
          .then<TtsException>((_) => throw StateError('不该成功'))
          .catchError((Object e) => e is TtsException ? e : throw e);
      expect(error.message, contains('something.new'));
    });

    test('有音频但没有一个时间点 → emptyAudio', () async {
      final h = _Harness(
        scripts: [
          <dynamic>[...audioFrames(1), turnEnd()],
        ],
      );
      await expectLater(
        h.engine.synthesize(h.job('你好')),
        throwsA(
          isA<TtsException>().having(
            (e) => e.message,
            'message',
            contains('WordBoundary'),
          ),
        ),
      );
    });

    test('Content-Type 只允许在 body 为空的收尾帧缺席', () async {
      final h = _Harness(
        scripts: [
          <dynamic>[audioFrameWithoutContentType(1), turnEnd()],
        ],
      );
      await expectLater(
        h.engine.synthesize(h.job('你好')),
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

  group('内部分块与偏移补偿（硬契约 8）', () {
    test('9000 字节文本切三块，块间按本地 CBR 字节累加平移时间点', () async {
      final text = '啊' * 3000; // 9000 字节
      final h = _Harness(
        scripts: <List<dynamic>>[
          <dynamic>[
            ...audioFrames(1),
            metadataFrame(<Word>[Word(0, 100000, '啊')]),
            turnEnd(),
          ],
          <dynamic>[
            ...audioFrames(1),
            metadataFrame(<Word>[Word(0, 100000, '啊')]),
            turnEnd(),
          ],
          <dynamic>[
            ...audioFrames(1),
            metadataFrame(<Word>[Word(0, 100000, '啊')]),
            turnEnd(),
          ],
        ],
      );
      final segment = await h.engine.synthesize(h.job(text, offsetBaseMs: 500));
      expect(h.ws.calls, 3);
      expect(segment.audio, mp3Frames(3));
      expect(segment.points, hasLength(3));
      // 块 1 落在 500ms；块 2/3 各自补上前面积压的 24ms / 48ms（144 字节 = 24ms）。
      expect(segment.points.map((p) => p.startMs).toList(), <int>[
        500,
        524,
        548,
      ]);
      // 字符位仍是 job.text 的绝对下标（块 2 从 1365 起，块 3 从 2730 起）。
      expect(segment.points.map((p) => p.charStart).toList(), <int>[
        0,
        1365,
        2730,
      ]);
      expect(segment.points[1].charEnd, 1366);
      expect(segment.audioMs, mp3BytesToMs(432));
    });

    test('每块正文都不超 4096 字节（上游的切块 bug 不复刻）', () async {
      final text = 'x' * 5000; // 无空格、无换行
      final h = _Harness(
        scripts: <List<dynamic>>[
          for (var i = 0; i < 2; i++)
            <dynamic>[
              ...audioFrames(1),
              metadataFrame(<Word>[Word(0, 100000, 'x')]),
              turnEnd(),
            ],
        ],
      );
      await h.engine.synthesize(h.job(text));
      expect(h.ws.calls, 2);
      for (var i = 0; i < h.ws.calls; i++) {
        expect(
          utf8.encode(h.spokenText(i)).length,
          lessThanOrEqualTo(kEdgeMaxChunkBytes),
        );
      }
    });

    test('音频帧里没有 mark/silence 补位：时间点连续覆盖到本块末尾', () async {
      final h = _Harness(
        scripts: [
          <dynamic>[
            ...audioFrames(2),
            metadataFrame(<Word>[
              Word(0, 240000, '你'),
              Word(240000, 240000, '好'),
            ]),
            turnEnd(),
          ],
        ],
      );
      final segment = await h.engine.synthesize(h.job('你好'));
      expect(segment.points.first.startMs, 0);
      expect(segment.points.last.endMs, 48); // 24ms + 24ms，正好等于音频时长
      expect(segment.audioMs, 48);
    });
  });

  group('403 与时钟纠偏（硬契约 10）', () {
    test('403 → 普通 GET 探针读 Date → 只重试一次就成功', () async {
      final h = _Harness(
        failFirstWith: 1,
        scripts: [
          script(words: [Word(0, 100000, '你')]),
        ],
      );
      final segment = await h.engine.synthesize(h.job('你'));
      expect(segment.audio, mp3Frames(2));
      expect(h.ws.calls, 2); // 恰好一次重试
      expect(h.http.requested.length, 1); // 探针只发一次
      expect(
        h.http.requested.single.toString(),
        kEdgeDefaultPreset.voiceListUri.toString(),
      );
      expect(h.clock.skew, const Duration(seconds: _skewSeconds));
    });

    test('纠偏后仍然 403 → authRejected，且总连接数不超过 2', () async {
      final h = _Harness(
        failFirstWith: 99,
        scripts: [
          script(words: [Word(0, 100000, '你')]),
        ],
      );
      await expectLater(
        h.engine.synthesize(h.job('你')),
        throwsA(
          isA<TtsException>().having(
            (e) => e.code,
            'code',
            TtsErrorCode.authRejected,
          ),
        ),
      );
      expect(h.ws.calls, 2);
      expect(h.http.requested.length, 1);
    });

    test('探针拿不到 Date → 不重试，直接 authRejected', () async {
      final h = _Harness(
        failFirstWith: 99,
        dateHeader: null,
        scripts: [
          script(words: [Word(0, 100000, '你')]),
        ],
      );
      await expectLater(
        h.engine.synthesize(h.job('你')),
        throwsA(
          isA<TtsException>().having(
            (e) => e.code,
            'code',
            TtsErrorCode.authRejected,
          ),
        ),
      );
      expect(h.ws.calls, 1);
      expect(h.http.requested.length, 1);
    });

    test('401 不做纠偏，直接 authRejected（探针一次都不发）', () async {
      Future<EdgeSocket> always401(
        Uri uri, {
        Map<String, String> headers = const <String, String>{},
        EdgeHttpClient? client,
      }) {
        throw const EdgeConnectFailure(statusCode: 401, reason: 'fake 401');
      }

      final h = _Harness(
        scripts: [
          script(words: [Word(0, 100000, '你')]),
        ],
      );
      final engine = EdgeSpeechEngine(
        wsFactory: always401,
        httpClientFactory: h.http.create,
        clock: DrmClock(),
        now: () => _fixedNow,
      );
      await expectLater(
        engine.synthesize(h.job('你')),
        throwsA(
          isA<TtsException>().having(
            (e) => e.code,
            'code',
            TtsErrorCode.authRejected,
          ),
        ),
      );
      // 上游只对 403 纠偏（说明书 §9.2）：401 直接判定，不浪费一次 GET。
      expect(h.http.requested, isEmpty);
    });

    test('429 → rateLimited 且标记可重试', () async {
      Future<EdgeSocket> always429(
        Uri uri, {
        Map<String, String> headers = const <String, String>{},
        EdgeHttpClient? client,
      }) {
        throw const EdgeConnectFailure(statusCode: 429, reason: 'fake 429');
      }

      final h = _Harness();
      final engine = EdgeSpeechEngine(
        wsFactory: always429,
        httpClientFactory: h.http.create,
        clock: DrmClock(),
        now: () => _fixedNow,
      );
      final error = await engine
          .synthesize(h.job('你'))
          .then<TtsException>((_) => throw StateError('不该成功'))
          .catchError((Object e) => e is TtsException ? e : throw e);
      expect(error.code, TtsErrorCode.rateLimited);
      expect(error.retryable, isTrue);
      expect(h.http.requested, isEmpty); // 429 不纠偏
    });

    test('socket 断连 → transport', () async {
      Future<EdgeSocket> socketDies(
        Uri uri, {
        Map<String, String> headers = const <String, String>{},
        EdgeHttpClient? client,
      }) {
        throw const SocketException('connect failed');
      }

      final engine = EdgeSpeechEngine(
        wsFactory: socketDies,
        httpClientFactory: _Harness().http.create,
        clock: DrmClock(),
        now: () => _fixedNow,
      );
      await expectLater(
        engine.synthesize(
          SpeechJob(
            text: '你',
            voice: const TtsVoice(id: 'zh-CN-XiaoxiaoNeural'),
            offsetBaseMs: 0,
            requestIndex: 0,
          ),
        ),
        throwsA(
          isA<TtsException>().having(
            (e) => e.code,
            'code',
            TtsErrorCode.transport,
          ),
        ),
      );
    });

    test('异常 message 与诊断里不出现 token 全值', () async {
      final h = _Harness(
        failFirstWith: 99,
        scripts: [
          script(words: [Word(0, 100000, '你')]),
        ],
      );
      final error = await h.engine
          .synthesize(h.job('你'))
          .then<TtsException>((_) => throw StateError('不该成功'))
          .catchError((Object e) => e is TtsException ? e : throw e);
      final fullToken = generateSecMsGec(now: _fixedNow);
      final shape = RegExp(r'[0-9A-F]{16}-[0-9A-F]{64}');
      expect(error.message.contains(fullToken), isFalse);
      // 连「形状」都不能剩下：说明 token 被换成了指纹而不是被截断。
      expect(shape.hasMatch(error.message), isFalse);
      expect(shape.hasMatch(error.toString()), isFalse);
      expect(error.message, contains('GEC(')); // 只留指纹
    });
  });

  group('音色列表（硬契约 11）', () {
    const voicesJson = '''
[
  {"Name":"Microsoft ... (zh-CN, XiaoxiaoNeural)","ShortName":"zh-CN-XiaoxiaoNeural",
   "Locale":"zh-CN","Gender":"Female","VoiceTag":{"ContentCategories":["General"],"VoicePersonalities":["Friendly"]}},
  {"ShortName":"en-US-GuyNeural","Locale":"en-US"},
  {"Locale":"zh-CN"},
  {"ShortName":""}
]''';

    test('带 DRM token + muid Cookie，字段缺失也不炸，只拉一次', () async {
      final h = _Harness(voicesBody: voicesJson);
      final first = await h.engine.voices();
      final second = await h.engine.voices();
      expect(identical(first, second), isTrue);
      expect(h.http.requested.length, 1);

      final uri = h.http.requested.single;
      expect(uri.scheme, 'https');
      expect(uri.queryParameters.keys.toSet(), <String>{
        'trustedclienttoken',
        'Sec-MS-GEC',
        'Sec-MS-GEC-Version',
      });
      expect(
        RegExp(r'^[0-9A-F]{16}-[0-9A-F]{64}$')
            .hasMatch(uri.queryParameters['Sec-MS-GEC']!),
        isTrue,
      );

      final cookie = h.http.profiles.single.headers['Cookie'];
      expect(cookie, matches(RegExp(r'^muid=[0-9A-F]{32};$')));
      expect(h.http.profiles.single.userAgent, kEdgeUserAgent);

      expect(first.map((v) => v.id).toList(), <String>[
        'zh-CN-XiaoxiaoNeural',
        'en-US-GuyNeural',
      ]); // 缺 ShortName 的被跳过
      expect(first.first.displayName, isNotEmpty);
      expect(first[1].displayName, 'en-US-GuyNeural'); // FriendlyName 缺失时兜短名
      expect(first[1].locale, 'en-US');
      expect(h.http.closeCount, greaterThan(0)); // 客户端用完即关
    });

    test('403 时同样只纠偏重试一次', () async {
      final h = _Harness(
        voicesBody: voicesJson,
        statusFor: (i) => i == 0 ? HttpStatus.forbidden : HttpStatus.ok,
      );
      final voices = await h.engine.voices();
      expect(voices, hasLength(2));
      expect(h.http.requested.length, 3); // 列表 → 探针 → 列表
      expect(h.clock.skew, const Duration(seconds: _skewSeconds));
    });

    test('服务端 5xx → transport，且不缓存失败结果', () async {
      final h = _Harness(
        voicesBody: voicesJson,
        statusFor: (i) =>
            i == 0 ? HttpStatus.internalServerError : HttpStatus.ok,
      );
      await expectLater(
        h.engine.voices(),
        throwsA(
          isA<TtsException>().having(
            (e) => e.code,
            'code',
            TtsErrorCode.transport,
          ),
        ),
      );
      final voices = await h.engine.voices(); // 上一次没钉住缓存
      expect(voices, hasLength(2));
    });
  });
}
