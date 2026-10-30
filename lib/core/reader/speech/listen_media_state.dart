/// 听书媒体会话的纯数据契约（design §2）：命令枚举 + 状态模型。
///
/// 这里**不 import 任何平台/插件**，因此可以在 Windows 单测里直接断言映射；
/// 平台实现见 `listen_media_session.dart`，派发见 `listen_media_bridge.dart`。
library;

/// 媒体会话能下发的命令。两处宿主（控制器 / 独立听书页）都只实现这一套。
enum ListenMediaCommand {
  play,
  pause,
  toggle,
  nextChapter,
  prevChapter,
  stop,

  /// 跳到某个位置；`position` 必须同时给出，缺省时桥会丢弃该命令。
  seekTo,

  /// 上一句 / 下一句：通知栏的「后退/快进」键用的就是这两个（听书场景按句
  /// 比按章自然）。
  prevSentence,
  nextSentence,

  /// 瞬时降低音量（来电/其他 App 短提示），不要暂停。
  duck,

  /// 恢复被 [duck] 降低的音量。
  unduck,
}

/// 一次播放状态的快照：宿主在播放/暂停/切章/位置变化时组一份丢给桥。
class ListenMediaState {
  const ListenMediaState({
    required this.mediaId,
    required this.title,
    required this.chapterTitle,
    this.artUri,
    required this.playing,
    this.buffering = false,
    this.finished = false,
    this.position = Duration.zero,
    this.total,
    this.speed = 1.0,
    this.chapterIndex = 0,
    this.chapterCount = 0,
    this.canNext = false,
    this.canPrev = false,
  });

  /// 章节 id。**只在它变化时重建 MediaItem**，否则每帧都会刷新通知。
  final String mediaId;

  /// 书名（通知第一行）。
  final String title;

  /// 章节名（通知第二行）。
  final String chapterTitle;

  /// 封面直链；为空时不传，通知用默认图标。
  final String? artUri;

  final bool playing;

  /// 合成/缓冲中：`processingState` 用 `buffering`，UI 才能显示转圈。
  final bool buffering;

  /// 会话已结束（`close()`）：会话层据此发 `idle`，系统才会撤前台通知。
  /// 没有它就只能一直挂着「可继续」的假通知，点播放却没人接。
  final bool finished;

  final Duration position;

  /// `null` = 时长未知（Edge 首帧到达前就是 null，别拿 0 冒充总长）。
  final Duration? total;

  /// 播放倍速，进 `PlaybackState.speed`（锁屏进度才走得对）。
  final double speed;

  final int chapterIndex;
  final int chapterCount;
  final bool canNext;
  final bool canPrev;
}
