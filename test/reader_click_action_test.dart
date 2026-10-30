import 'dart:ui';

import 'package:aquan_duanju/core/reader/reader_click_action.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const size = Size(390, 844);
  const layout = ClickZoneLayout();

  test('九宫格基本命中：左上 / 正中 / 右下', () {
    expect(layout.indexFor(const Offset(10, 10), size), 0);
    expect(layout.indexFor(const Offset(195, 422), size), 4);
    expect(layout.indexFor(const Offset(380, 834), size), 8);
  });

  test('三列三行分别落在对应槽位', () {
    // 行中线的取样点：上区 / 中区 / 下区。
    const ys = <double>[50, 422, 800];
    const xs = <double>[50, 195, 340];
    expect(layout.indexFor(const Offset(50, 50), size), 0);
    expect(layout.indexFor(const Offset(195, 50), size), 1);
    expect(layout.indexFor(const Offset(340, 50), size), 2);
    expect(layout.indexFor(const Offset(50, 422), size), 3);
    expect(layout.indexFor(const Offset(195, 422), size), 4);
    expect(layout.indexFor(const Offset(340, 422), size), 5);
    expect(layout.indexFor(const Offset(50, 800), size), 6);
    expect(layout.indexFor(const Offset(195, 800), size), 7);
    expect(layout.indexFor(const Offset(340, 800), size), 8);
    expect(xs.length, 3);
    expect(ys.length, 3);
  });

  test('越界坐标收敛到角落，不抛异常', () {
    expect(layout.indexFor(const Offset(-50, -50), size), 0);
    expect(layout.indexFor(const Offset(9999, 9999), size), 8);
  });

  test('edgeInset 生效：内缩区的点击归到中列', () {
    const inset = ClickZoneLayout(edgeInset: 24);
    // 左列区域（dx < 390*0.33）但落在 24px 内缩带里 → 中列。
    expect(inset.indexFor(const Offset(10, 422), size), 4);
    // 越过内缩带仍属于左列。
    expect(inset.indexFor(const Offset(40, 422), size), 3);
    // 右侧对称。
    expect(inset.indexFor(const Offset(385, 422), size), 4);
    expect(inset.indexFor(const Offset(340, 422), size), 5);
  });

  test('edgeInset 为 0 时不产生内缩带', () {
    expect(layout.indexFor(const Offset(5, 422), size), 3);
    expect(layout.indexFor(const Offset(389, 422), size), 5);
  });

  test('极端参数不产生空行或负尺寸', () {
    const extreme = ClickZoneLayout(topRatio: 0.9, bottomRatio: 0.9, edgeInset: 999);
    final rects = extreme.rects(size);
    expect(rects.length, 9);
    for (final rect in rects) {
      expect(rect.width, greaterThanOrEqualTo(0));
      expect(rect.height, greaterThanOrEqualTo(0));
    }
    // 参数被 clamp 后仍能命中中行。
    expect(extreme.indexFor(const Offset(195, 422), size), 4);
  });

  test('rects 与 indexFor 一致：每格中心点命回自己', () {
    const custom = ClickZoneLayout(topRatio: 0.25, bottomRatio: 0.35, edgeInset: 12);
    final rects = custom.rects(size);
    for (var i = 0; i < 9; i++) {
      final center = rects[i].center;
      expect(custom.indexFor(center, size), i, reason: '槽位 $i 中心点命中错误');
    }
  });

  test('零尺寸退化为正中格，不除零', () {
    expect(layout.indexFor(const Offset(0, 0), Size.zero), 4);
    expect(layout.rects(Size.zero).length, 9);
  });

  test('动作 id 映射与默认值', () {
    expect(ReaderClickAction.fromId(-1), ReaderClickAction.none);
    expect(ReaderClickAction.fromId(0), ReaderClickAction.menu);
    expect(ReaderClickAction.fromId(2), ReaderClickAction.prevPage);
    expect(ReaderClickAction.fromId(13), ReaderClickAction.toggleSpeech);
    expect(ReaderClickAction.fromId(999), ReaderClickAction.none);
    expect(ReaderClickAction.fromId(null), ReaderClickAction.none);
    expect(ReaderClickAction.fromId('7'), ReaderClickAction.addBookmark);

    expect(kDefaultClickActions.length, 9);
    expect(kDefaultClickActions[0], ReaderClickAction.prevPage);
    expect(kDefaultClickActions[4], ReaderClickAction.menu);
    expect(kDefaultClickActions[8], ReaderClickAction.nextPage);
  });

  test('未实现的动作被标记为不可用', () {
    expect(ReaderClickAction.editContent.available, isFalse);
    expect(ReaderClickAction.toggleReplace.available, isFalse);
    expect(ReaderClickAction.searchContent.available, isFalse);
    expect(ReaderClickAction.syncProgress.available, isFalse);
    expect(ReaderClickAction.nextPage.available, isTrue);
    expect(ReaderClickAction.directory.available, isTrue);
  });

  test('layout JSON 往返与非法值回退', () {
    const original = ClickZoneLayout(topRatio: 0.28, bottomRatio: 0.4, edgeInset: 18);
    final restored = ClickZoneLayout.fromJson(original.toJson());
    expect(restored.topRatio, 0.28);
    expect(restored.bottomRatio, 0.4);
    expect(restored.edgeInset, 18);

    final broken = ClickZoneLayout.fromJson(<String, dynamic>{
      'top_ratio': 'x',
      'bottom_ratio': 9.0,
      'edge_inset': -5.0,
    });
    expect(broken.topRatio, 0.33);
    expect(broken.bottomRatio, ClickZoneLayout.maxBandRatio);
    expect(broken.edgeInset, 0);
  });
}
