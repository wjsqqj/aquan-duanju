import 'package:aquan_duanju/core/player_gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('edgePanelShouldOpen', () {
    test('进入热区且未被手动关闭时打开', () {
      expect(edgePanelShouldOpen(hoverEdge: true, suppressed: false), isTrue);
    });

    test('指针不在热区不打开', () {
      expect(edgePanelShouldOpen(hoverEdge: false, suppressed: false), isFalse);
    });

    test('手动关闭后即使还在边缘也不自动重开', () {
      expect(edgePanelShouldOpen(hoverEdge: true, suppressed: true), isFalse);
    });
  });

  group('edgePanelShouldClose', () {
    test('离开热区与抽屉后收起', () {
      expect(
        edgePanelShouldClose(hoverEdge: false, hoverPanel: false),
        isTrue,
      );
    });

    test('还停在热区不收', () {
      expect(
        edgePanelShouldClose(hoverEdge: true, hoverPanel: false),
        isFalse,
      );
    });

    test('鼠标已移入抽屉不收（热区必然先退出）', () {
      expect(
        edgePanelShouldClose(hoverEdge: false, hoverPanel: true),
        isFalse,
      );
    });
  });

  test('热区宽度是参考实现的 16 逻辑像素', () {
    expect(kEdgePanelHotZoneWidth, 16);
  });
}
