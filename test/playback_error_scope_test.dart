import 'package:aquan_duanju/core/playback_error_scope.dart';
import 'package:flutter_test/flutter_test.dart';

/// 11-21 真机事故回放（任务 11-19-webplay-ep15-open-fail）。
///
/// 错误行取自 Android 真机日志的原始形态；日志里的省略号按同形态补全成
/// 完整合成 URL（host/路径结构与真机一致）。
void main() {
  // webplay 尝试（DASH 双轨）：视频流 + 外挂音轨。
  const webplayVideoUrl =
      'https://v26-hgweb.qznovelvod.com/0b3/video/tos/cn/tos-cn-v-6fcc8e/x/'
      'media-v-6fcc8e/x.mp4?a=8662&ch=0';
  const webplayAudioUrl =
      'https://v11-hgweb.qznovelvod.com/0b37d9215adf94d7f9e1fdae101ef572/'
      '6b01ad4c/video/tos/cn/tos-cn-v-6fcc8e/6989bb7201054dc08b9d90044bbd0f44/'
      'media-audio-und-mp4a/?a=8662&ch=0&cr=0&dr=3&er=1&cd=0';
  // v5 重解析后的尝试：无外挂音轨（audio=false）。
  const v5VideoUrl =
      'https://v5-reading-video-y.qznovelvod.com/0b3/video/tos/cn/'
      'tos-cn-v-6fcc8e/6989bb7201054dc08b9d90044bbd0f44/media-v-6fcc8e/'
      'x.m3u8?dur=102';
  // 路径列表切分后半条目的协议相对形态（`https:` 前缀被切掉剩下的部分）。
  final v11ProtoRelative = webplayAudioUrl.substring('https:'.length);
  // mpv 打开失败的三种文案形态（带切坏的协议相对条目）。
  final errCannotOpenFragment = "Cannot open file '$v11ProtoRelative'";
  final errFailedOpenFragment = 'Failed to open $v11ProtoRelative';
  final errExternalOpenFragment =
      'Can not open external file $v11ProtoRelative';
  // 裸 `https` 片段（切分前半条目，无 host 可归因）的三种文案形态。
  const bareHttpsErrors = [
    "Cannot open file 'https': No such file or directory",
    'Failed to open https.',
    'Can not open external file https.',
  ];

  group('PlaybackErrorScope · 11-21 换线风暴事故回放（AC1）', () {
    test('webplay 尝试期间：音轨拆分错误全部判「当前」（它的音轨确实坏了）', () {
      final scope = PlaybackErrorScope();
      scope.beginAttempt(videoUrl: webplayVideoUrl, audioUrl: webplayAudioUrl);
      for (final error in [
        ...bareHttpsErrors,
        errCannotOpenFragment,
        errFailedOpenFragment,
        errExternalOpenFragment,
      ]) {
        expect(
          scope.isStale(error),
          isFalse,
          reason: 'webplay 尝试自己的音轨故障必须如实上报，换线才能继续',
        );
      }
    });

    test('v5 尝试期间：旧 webplay 残留错误（裸片段 + 退役 host）全部判残留', () {
      final scope = PlaybackErrorScope();
      scope.beginAttempt(videoUrl: webplayVideoUrl, audioUrl: webplayAudioUrl);
      scope.beginAttempt(videoUrl: v5VideoUrl);
      for (final error in [
        ...bareHttpsErrors,
        errCannotOpenFragment,
        errFailedOpenFragment,
        errExternalOpenFragment,
      ]) {
        expect(
          scope.isStale(error),
          isTrue,
          reason: '可证明来自退役 webplay 尝试的错误不得打死健康的 v5 线路',
        );
      }
    });

    test('v5 尝试期间：当前视频自身错误 / 无 URL 错误 / 未知 host 错误不判残留', () {
      final scope = PlaybackErrorScope();
      scope.beginAttempt(videoUrl: webplayVideoUrl, audioUrl: webplayAudioUrl);
      scope.beginAttempt(videoUrl: v5VideoUrl);
      // host 命中当前尝试（路径/query 与登记值不同也算当前）。
      expect(
        scope.isStale(
          'Failed to open https://v5-reading-video-y.qznovelvod.com/0b3/'
          'video/tos/cn/tos-cn-v-6fcc8e/6989bb7201054dc08b9d90044bbd0f44/'
          'x.m3u8',
        ),
        isFalse,
        reason: 'v5 自身的打开失败必须走既有分类',
      );
      // 无任何 URL 的错误：保守缺省。
      expect(scope.isStale('error decoding audio'), isFalse);
      // URL 属于未知第三方 host：无证据不拦。
      expect(
        scope.isStale('Failed to open https://unknown-cdn.example.com/v.mp4'),
        isFalse,
      );
    });
  });

  group('PlaybackErrorScope · 同音轨换线（AC2 host 优先级）', () {
    test('第二次尝试复用同一音轨 host（query 不同）：旧形态错误不判残留', () {
      final scope = PlaybackErrorScope();
      scope.beginAttempt(videoUrl: webplayVideoUrl, audioUrl: webplayAudioUrl);
      // 换线后音轨仍落在 v11-hgweb host 上，只是 query 换了。
      const sameHostAudioUrl =
          'https://v11-hgweb.qznovelvod.com/0b37d9215adf94d7f9e1fdae101ef572/'
          '6b01ad4c/video/tos/cn/tos-cn-v-6fcc8e/6989bb7201054dc08b9d90044bbd0f44/'
          'media-audio-und-mp4a/?a=9999&ch=0&cr=0&dr=3&er=1&cd=0';
      scope.beginAttempt(videoUrl: v5VideoUrl, audioUrl: sameHostAudioUrl);
      // 错误里的协议相对 URL 精确等于退役那条（旧 query），但 host 同当前
      // 音轨一致——归「当前」优先于归「退役」。
      expect(scope.isStale(errCannotOpenFragment), isFalse);
      expect(scope.isStale(errFailedOpenFragment), isFalse);
    });
  });

  group('PlaybackErrorScope · 有界性（AC2）', () {
    test('20 次换线后退役集合裁剪到上界，最近残留仍可拦、最旧已放行', () {
      final scope = PlaybackErrorScope();
      for (var i = 1; i <= 20; i++) {
        scope.beginAttempt(
          videoUrl:
              'https://h${i.toString().padLeft(2, '0')}.example.com/'
              'v$i.mp4',
        );
      }
      expect(
        scope.retiredUrlCount,
        lessThanOrEqualTo(PlaybackErrorScope.retiredLimit),
      );
      expect(
        scope.retiredHostCount,
        lessThanOrEqualTo(PlaybackErrorScope.retiredLimit),
      );
      // 恰好顶到上界（每次退役 1 条 URL + 1 个 host）。
      expect(scope.retiredUrlCount, PlaybackErrorScope.retiredLimit);
      expect(scope.retiredHostCount, PlaybackErrorScope.retiredLimit);
      // 最近一次退役的尝试（第 19 次，第 20 次是当前）仍判残留。
      expect(
        scope.isStale('Failed to open https://h19.example.com/v19.mp4'),
        isTrue,
      );
      // 第 1 次尝试的 host 已被 FIFO 裁剪掉：保守判非残留（不抛异常）。
      expect(
        scope.isStale('Failed to open https://h01.example.com/v1.mp4'),
        isFalse,
      );
    });
  });

  group('PlaybackErrorScope · 裸片段特判不误伤', () {
    test('当前 videoUrl 是无 scheme 的坏地址：裸 https 错误如实上报', () {
      final scope = PlaybackErrorScope();
      scope.beginAttempt(videoUrl: 'not-a-valid-url');
      expect(
        scope.isStale('Failed to open https.'),
        isFalse,
        reason: '坏地址场景的错误必须走既有分类，不允许被特判吞掉',
      );
      expect(
        scope.isStale("Cannot open file 'https': No such file or directory"),
        isFalse,
      );
    });

    test('当前 videoUrl 非 http(s) scheme：裸 https 错误同样如实上报', () {
      final scope = PlaybackErrorScope();
      scope.beginAttempt(videoUrl: 'ftp://files.example.com/v.mp4');
      expect(scope.isStale('Failed to open https.'), isFalse);
    });
  });
}
