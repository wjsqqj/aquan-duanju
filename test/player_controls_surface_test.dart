import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/widgets/player_controls_surface.dart';

/// 播放页分层的最小复刻：下层是视频手势层（`_onSurfaceTap` 的替身），
/// 上层是控制栏视觉层。
Widget _harness({
  required Widget overlay,
  required VoidCallback onSurfaceTap,
}) {
  return MaterialApp(
    home: Stack(
      fit: StackFit.expand,
      children: <Widget>[
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onSurfaceTap,
          child: const ColoredBox(color: Color(0xFF101010)),
        ),
        overlay,
      ],
    ),
  );
}

const _controlsBody = Column(
  children: <Widget>[
    SizedBox(height: 48, child: Text('顶栏')),
    Spacer(),
    SizedBox(height: 48, child: Text('底栏')),
  ],
);

void main() {
  // 11-17 回归（两次踩坑）：
  //  ① 13cff7c 去掉控制栏自带手势层后，scrim 用 `Container(color:)` 仍是
  //     opaque 命中层；
  //  ② 只把 scrim 改成 IgnorePointer 还不够——内层 MouseRegion 默认
  //     `opaque: true`，同样铺满全屏吃掉点击。
  // 两者都会让「双击全屏（桌面）/ 双击暂停（移动）」彻底失效。
  testWidgets('控制栏空白处点击穿透到下层视频手势层', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _harness(
        overlay: const PlayerControlsSurface(child: _controlsBody),
        onSurfaceTap: () => taps++,
      ),
    );

    final center = tester.getCenter(find.byType(PlayerControlsSurface));
    await tester.tapAt(center);
    await tester.pump();
    // 双击的第二下（≤350ms）同样必须落到视频层：双击判定靠它。
    await tester.tapAt(center);
    await tester.pump();

    expect(taps, 2, reason: '空白处单击/双击都应落到下层手势层');
  });

  testWidgets('鼠标在控制栏上 hover 仍要续期自动隐藏', (tester) async {
    final hovers = <PointerHoverEvent>[];
    await tester.pumpWidget(
      _harness(
        overlay: PlayerControlsSurface(
          onHover: hovers.add,
          child: _controlsBody,
        ),
        onSurfaceTap: () {},
      ),
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(400, 80));
    await gesture.moveTo(const Offset(400, 300));
    await tester.pump();

    expect(hovers, isNotEmpty, reason: 'opaque:false 不能把 hover 一起关掉');
  });

  testWidgets('控件按钮自己吃掉点击，不穿透到视频层', (tester) async {
    var surfaceTaps = 0;
    var buttonTaps = 0;
    await tester.pumpWidget(
      _harness(
        overlay: PlayerControlsSurface(
          child: Center(
            child: Material(
              child: TextButton(
                onPressed: () => buttonTaps++,
                child: const Text('播放'),
              ),
            ),
          ),
        ),
        onSurfaceTap: () => surfaceTaps++,
      ),
    );

    await tester.tap(find.text('播放'));
    await tester.pump();

    expect(buttonTaps, 1);
    expect(surfaceTaps, 0, reason: '按钮点击不能让下层手势层重复消费');
  });
}
