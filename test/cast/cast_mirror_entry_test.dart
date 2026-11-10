import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_feature_flags.dart';

/// 镜像入口隐藏（11-10，任务 11-10-hide-cast-mirror-entry）。
///
/// 面板/播放器是重依赖 AppScope 的整页组件，为「藏一个入口」搭全套 store 夹具
/// 得不偿失；这里改守两条真正会回归的事实：
/// 1. 开关常量为 false（默认隐藏）；
/// 2. 两处入口文案都在 `kCastMirrorEntryEnabled` 门控之内——有人把 if 删掉
///    或改成无条件渲染，测试立刻红。
List<String> _lines(String path) =>
    File(path).readAsLinesSync().map((l) => l.trimRight()).toList();

/// 该行是否在「门控行之后 [window] 行内」。
bool guardedWithin(List<String> lines, int index, {int window = 12}) {
  final from = index - window < 0 ? 0 : index - window;
  for (var i = from; i <= index; i++) {
    if (lines[i].contains('kCastMirrorEntryEnabled')) return true;
  }
  return false;
}

void main() {
  test('默认隐藏镜像入口（常量 false）', () {
    expect(kCastMirrorEntryEnabled, isFalse,
        reason: '恢复镜像入口需要真机证据支持，不能悄悄打开');
  });

  test('面板「镜像屏幕」控件在门控内', () {
    final lines = _lines('lib/widgets/cast_panel.dart');
    final hits = <int>[
      for (var i = 0; i < lines.length; i++)
        if (lines[i].contains("'镜像屏幕'")) i,
    ];
    expect(hits, isNotEmpty, reason: '实现需保留（隐藏而非删除）');
    for (final i in hits) {
      expect(guardedWithin(lines, i), isTrue,
          reason: '第 ${i + 1} 行「镜像屏幕」缺少 kCastMirrorEntryEnabled 门控');
    }
    // initialMirrorMode 不能再无条件打开镜像预检（AC-2）。
    expect(
      lines.any((l) => l.contains('initialMirrorMode && kCastMirrorEntryEnabled')),
      isTrue,
    );
  });

  test('播放器「切换镜像」动作与文案在门控内', () {
    final lines = _lines('lib/screens/player_screen.dart');
    for (final needle in <String>["'切换镜像'", '镜像屏幕投屏']) {
      final hits = <int>[
        for (var i = 0; i < lines.length; i++)
          if (lines[i].contains(needle)) i,
      ];
      expect(hits, isNotEmpty, reason: '$needle 应保留（恢复用）');
      for (final i in hits) {
        expect(guardedWithin(lines, i), isTrue,
            reason: '第 ${i + 1} 行「$needle」缺少 kCastMirrorEntryEnabled 门控');
      }
    }
  });
}
