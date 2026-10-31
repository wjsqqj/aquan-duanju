/// 块 B 接线验收（implement.md 步骤 4）：`SleepTimer` / `ChapterPrefetcher`
/// 接进 `ReaderSpeechController` 后的**行为顺序与失效点**，全部跑假件、零网络。
///
/// 钉住的契约（PRD 验收标准）：
/// - 定时到点：先落听书进度、再 pause（保留会话），fire 后自动落回 off；
/// - 「本章播完停」只抑制当次连播，绝不改写 `listen.autoNext` 持久化偏好；
/// - 预取在阈值处只发生一次；产物落盘后切章零合成命中；
/// - `close()` / 换音色后 invalidate 生效；`listen.prefetch=false` 时零预取。
///
/// 两条写法上的约束：
/// - 合成次数一律用**相对基线**断言，不写死数字：一章被切成几个 chunk 由
///   `TtsComposer._groupChunks`（unit 边界 + 长度上限）决定，那是合成层的自由，
///   不是接线契约，这里只关心「有没有多打一次引擎」；
/// - 失效点之后的预取断言必须**持续喂位置**（[_feedUntil]）：上一会话迟到的
///   预取任务还占着 `ChapterPrefetcher` 的并发 1 闸门时，本次 tick 会被
///   `shouldTrigger` 判 false，只有下一个位置事件才重试 —— 真实播放本来就以
///   250ms～1s 的节奏发位置，只喂一条等于赌调度时序，并发跑整套时会假失败。
library;

import 'dart:io';

import 'package:aquan_duanju/core/player/player_engine.dart';
import 'package:aquan_duanju/core/reader/reader_listen_settings.dart';
import 'package:aquan_duanju/core/reader/reader_speech_controller.dart';
import 'package:aquan_duanju/core/reader/speech/sleep_timer.dart';
import 'package:aquan_duanju/core/tts/speech_engine.dart';
import 'package:aquan_duanju/core/tts/tts_composer.dart';
import 'package:aquan_duanju/models/audio.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'speech_fakes.dart';

/// 与 [_OrderedPlayer] 共享同一条事件流，断言「落进度 → 暂停」的**先后**。
class _OrderedStore extends RecordingStore {
  _OrderedStore(this.events);

  final List<String> events;

  @override
  Future<void> record({
    required String bookId,
    required String title,
    required String coverUrl,
    required String chapterId,
    required String chapterTitle,
    required int chapterIndex,
    required int chapters,
    required int toneId,
    required int positionMs,
  }) async {
    events.add('save');
    await super.record(
      bookId: bookId,
      title: title,
      coverUrl: coverUrl,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      chapterIndex: chapterIndex,
      chapters: chapters,
      toneId: toneId,
      positionMs: positionMs,
    );
  }
}

class _OrderedPlayer extends FakePlayer {
  _OrderedPlayer(this.events);

  final List<String> events;

  @override
  Future<void> pause() async => events.add('pause');
}

/// 用自定义 player/store 复用 harness 的 api、缓存目录与统一 dispose。
ReaderSpeechController _buildWith(
  SpeechHarness h,
  PlayerEngine player,
  ListenProgressStore store,
  SpeechEngine tts, {
  int Function()? clockMs,
}) {
  final controller = ReaderSpeechController(
    api: h.api,
    store: store,
    engine: player,
    ttsEngine: tts,
    ttsCache: h.cache,
    ttsComposer: TtsComposer(),
    clockMs: clockMs,
    // 定时到点会走 3 秒淡出：单测注入即时返回，不为一条断言干等。
    fadeSleep: (_) async {},
  );
  h.controllers.add(controller);
  return controller;
}

/// 轮询等待（真实临时目录的异步落盘不是 microtask，`pumpEventQueue` 抽干也不
/// 代表文件已写完）。
Future<void> _waitFor(
  bool Function() condition, {
  required String reason,
}) async {
  for (var i = 0; i < 2000; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('等待超时：$reason');
}

/// 从 `fromSeconds` 起持续喂位置（每秒 +1）直到条件满足 —— 模拟真实播放的位置流。
Future<void> _feedUntil(
  FakePlayer player,
  bool Function() condition, {
  required int fromSeconds,
  required String reason,
}) async {
  for (var i = 0; i < 300; i++) {
    if (condition()) return;
    player.feed.positionCtrl.add(Duration(seconds: fromSeconds + i));
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('等待超时：$reason');
}

/// 本章合成产物：`<stem>.mp3` + 同名 `.jsonl`（成对，`reading-contract`）。
/// 排除 lru 台账，否则文件数会被一个与本章无关的记账文件污染。
int _cacheFileCount(Directory root) {
  final dir = Directory('${root.path}${Platform.pathSeparator}audio_cache');
  if (!dir.existsSync()) return 0;
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => !f.path.endsWith('tts_lru.json'))
      .length;
}

/// 让控制器拿到真实总时长（预取阈值需要 `total`；0 时按组件语义不触发）。
Future<void> _feedDuration(FakePlayer player, Duration total) async {
  player.feed.durationCtrl.add(total);
  await pumpEventQueue();
}

Future<void> _feedPosition(FakePlayer player, Duration p) async {
  player.feed.positionCtrl.add(p);
  await pumpEventQueue();
}

const Duration _total1000s = Duration(seconds: 1000);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('定时到点：先落进度再暂停，fire 后自动落回 off 且 prefs 同步', () async {
    final h = SpeechHarness('wiring_stop');
    final events = <String>[];
    final player = _OrderedPlayer(events);
    final store = _OrderedStore(events);
    // 定时按**播放中的墙钟**计：注入可控时钟才能造出“过了 1 分钟”，
    // 否则要么真等一分钟，要么退回旧的媒体时间轴语义（2 倍速会缩半）。
    var nowMs = 0;
    final controller = _buildWith(
      h,
      player,
      store,
      FakeTts(),
      clockMs: () => nowMs,
    );
    await h.start(controller);
    expect(controller.playing, isTrue);

    await controller.setSleepMode(SleepMode.minutes, minutes: 1);
    // 首次 tick 只建时钟基线；然后让墙钟走过 61 秒才判到点。
    await _feedPosition(player, Duration.zero);
    nowMs += 61000;
    await _feedPosition(player, const Duration(minutes: 1, seconds: 1));

    // 顺序即契约：save 必须在 pause 前（PRD「先落进度再停」）。
    expect(events, ['save', 'pause']);
    expect(store.positions, [61000]);
    expect(controller.playing, isFalse);
    expect(controller.chapterIndex, 0); // pause 保留会话，不是 stop 清空
    expect(controller.error, isNull);
    expect(controller.sleepMode, SleepMode.off); // 组件自动落回
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(ReaderListenSettings.sleepModeKey),
      isNull, // fire 后 prefs 同步 off，不跨会话复活
    );
    h.dispose();
  });

  test('本章播完停：只抑制当次连播，不改写 listen.autoNext', () async {
    SharedPreferences.setMockInitialValues({'listen.autoNext': true});
    final h = SpeechHarness('wiring_chapter_end');
    final controller = h.build(FakeTts());
    await h.start(controller);
    await controller.setSleepMode(SleepMode.endOfChapter);
    await h.pumpPosition(12000);
    final textCallsAtFire = h.api.chapterTextCalls;

    h.player.feed.completedCtrl.add(true);
    await pumpEventQueue();

    // 到点没有自动连播：仍停在第一章。
    expect(controller.chapterIndex, 0);
    expect(controller.playing, isFalse);
    expect(controller.sleepMode, SleepMode.off);
    final prefs = await SharedPreferences.getInstance();
    // 用户的连播偏好原样不动（PRD 硬约束）；定时档已消费。
    expect(prefs.getBool(ReaderSpeechController.autoNextKey), isTrue);
    expect(prefs.getString(ReaderListenSettings.sleepModeKey), isNull);

    // 抑制位读一次即清：下一次章尾恢复正常连播。
    h.player.feed.completedCtrl.add(true);
    await pumpEventQueue();
    await _waitFor(
      () => controller.chapterIndex == 1 && controller.playing,
      reason: '第二次 completed 应恢复正常连播',
    );
    expect(h.api.chapterTextCalls, greaterThan(textCallsAtFire));
    h.dispose();
  });

  test('预取在阈值处只发生一次；产物落盘后切章零合成命中', () async {
    final h = SpeechHarness('wiring_prefetch_once');
    final tts = FakeTts();
    final controller = h.build(tts);
    await h.start(controller);
    // 第一章开播：取正文 1 次，本章产物成对落盘。
    expect(h.api.chapterTextCalls, 1);
    final callsAtStart = tts.calls;
    expect(callsAtStart, greaterThan(0));
    await _waitFor(
      () => _cacheFileCount(h.root) >= 2,
      reason: '本章产物未成对落盘',
    );
    final filesAtStart = _cacheFileCount(h.root);
    expect(filesAtStart, 2);

    await _feedDuration(h.player, _total1000s);
    await _feedPosition(h.player, const Duration(seconds: 400)); // 40% > 35%
    // 预取第二章：正文（同源派生）+ 合成，且产物**成对**落盘后才允许切章。
    await _waitFor(
      () => h.api.chapterTextCalls >= 2 && tts.calls > callsAtStart,
      reason: '预取未取正文或未合成',
    );
    await _waitFor(
      () => _cacheFileCount(h.root) >= filesAtStart + 2,
      reason: '预取产物未成对落盘',
    );
    final callsAfterPrefetch = tts.calls;

    // 同章内继续推进位置：去重生效，一次都不许多发。
    await _feedPosition(h.player, const Duration(seconds: 500));
    await _feedPosition(h.player, const Duration(seconds: 900));
    expect(h.api.chapterTextCalls, 2);
    expect(tts.calls, callsAfterPrefetch);

    // 切到下一章：缓存命中 → 合成零新增（「零网络」指不再打 Edge 合成端点）。
    await controller.next();
    expect(controller.chapterIndex, 1);
    expect(controller.error, isNull);
    expect(tts.calls, callsAfterPrefetch);
    h.dispose();
  });

  test('close() 后 invalidate 生效：新会话重新预取（缓存命中不再合成）',
      () async {
    final h = SpeechHarness('wiring_close_invalidate');
    final tts = FakeTts();
    final controller = h.build(tts);
    await h.start(controller);
    await _feedDuration(h.player, _total1000s);
    await _feedPosition(h.player, const Duration(seconds: 400));
    await _waitFor(
      () => _cacheFileCount(h.root) >= 4,
      reason: '首次预取未落盘',
    );
    final textBeforeFirst = h.api.chapterTextCalls;
    final callsBefore = tts.calls; // 两章各合成一次

    await controller.close();
    await h.start(controller);
    // 新会话重开第一章：正文重新派生（等它，别假定 start 已抽干全部 await）。
    await _waitFor(
      () => h.api.chapterTextCalls > textBeforeFirst,
      reason: '新会话没有重新派生本章正文',
    );
    final textBefore = h.api.chapterTextCalls;
    // 音频命中缓存 → 合成零新增。
    expect(tts.calls, callsBefore);
    expect(controller.error, isNull);

    await _feedDuration(h.player, _total1000s);
    // 去重集已被 close()/start() 清空 → 预取重新发生一次（本章之后的下一章
    // 正文再取一次）；喂多个位置是为了跨过上一会话迟到任务的并发闸门。
    await _feedUntil(
      h.player,
      () => h.api.chapterTextCalls > textBefore,
      fromSeconds: 400,
      reason: 'close() 后 invalidate 未生效，预取没有重发',
    );
    // 第二章产物已在缓存里：只校验、不重合成。
    expect(tts.calls, callsBefore);
    h.dispose();
  });

  test('换音色后 invalidate 生效：新音色重新预取音轨', () async {
    final h = SpeechHarness('wiring_tone_invalidate');
    h.api.tones = const AudioTones(
      tones: <AudioTone>[
        AudioTone(id: 7, title: '男声'),
        AudioTone(id: 8, title: '女声'),
      ],
    );
    final controller = h.build(FakeTts());
    await h.start(controller);
    // 音轨路径开播：audioStream 恰好 1 次。
    expect(h.api.audioStreamCalls, 1);

    await _feedDuration(h.player, _total1000s);
    await _feedPosition(h.player, const Duration(seconds: 400));
    await _waitFor(
      () => h.api.audioStreamCalls >= 2,
      reason: '音轨预取未触发',
    );
    expect(h.api.audioStreamCalls, 2); // 阈值处只预取一次
    await _feedPosition(h.player, const Duration(seconds: 500));
    expect(h.api.audioStreamCalls, 2);

    // 换音色自身重开本章 +1；随后阈值处应**再次**预取（去重集已失效）。
    await controller.setToneById(8);
    expect(h.api.audioStreamCalls, 3);
    await _feedDuration(h.player, _total1000s);
    await _feedUntil(
      h.player,
      () => h.api.audioStreamCalls >= 4,
      fromSeconds: 500,
      reason: '换音色后 invalidate 未生效，预取没有重发',
    );
    h.dispose();
  });

  test('listen.prefetch=false 时零预取', () async {
    SharedPreferences.setMockInitialValues({'listen.prefetch': false});
    final h = SpeechHarness('wiring_prefetch_off');
    final tts = FakeTts();
    final controller = h.build(tts);
    await h.start(controller);
    expect(controller.prefetchEnabled, isFalse);
    expect(h.api.chapterTextCalls, 1);
    final callsAtStart = tts.calls;
    final filesAtStart = _cacheFileCount(h.root);

    await _feedDuration(h.player, _total1000s);
    await _feedPosition(h.player, const Duration(seconds: 400));
    await _feedPosition(h.player, const Duration(seconds: 900));
    // 只有本章开播的量：没有第二次正文获取，也没有预合成与新产物。
    expect(h.api.chapterTextCalls, 1);
    expect(tts.calls, callsAtStart);
    expect(filesAtStart, 2); // 只有本章的成对产物
    expect(_cacheFileCount(h.root), 2);
    h.dispose();
  });
}
