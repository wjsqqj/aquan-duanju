import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aquan_duanju/widgets/motion/redrawn_arrow.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 亮色像素数（箭头是白线画在深底上）。
///
/// 这个回归锁针对 11-16 用户实测 bug：`PathMetrics` 是**惰性**可迭代，
/// `fold` 求完总长后再 `for` 迭代只剩空序列——hover 擦除/重画两支都画不出
/// 任何东西，按钮「悬停就不见了」（还能点）。纯几何单测抓不到，只有真的
/// 渲染一遍像素才看得见。
Future<int> _lightPixels(WidgetTester tester, GlobalKey key) async {
  final RenderRepaintBoundary boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final ui.Image? image = await tester.runAsync<ui.Image>(boundary.toImage);
  final ByteData? data = await tester.runAsync<ByteData?>(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba));
  final Uint8List bytes = data!.buffer.asUint8List();
  var count = 0;
  for (var i = 0; i < bytes.length; i += 4) {
    if (bytes[i] > 170 && bytes[i + 1] > 170 && bytes[i + 2] > 170) count++;
  }
  return count;
}

Future<GlobalKey> _pump(WidgetTester tester) async {
  final GlobalKey key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        platform: TargetPlatform.windows,
        brightness: Brightness.light,
      ),
      home: Scaffold(
        backgroundColor: const Color(0xFF202020),
        body: Center(
          child: RepaintBoundary(
            key: key,
            child: IconButton(
              onPressed: () {},
              icon: const FxRedrawnArrow(
                color: Colors.white,
                icon: Icon(Icons.arrow_forward, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return key;
}

void main() {
  testWidgets('静态态画满箭头（idle 可见）', (tester) async {
    final GlobalKey key = await _pump(tester);
    expect(await _lightPixels(tester, key), greaterThan(0));
  });

  testWidgets('hover 擦除中途不出现空帧（旧箭头尚未擦净、新箭头已起笔）', (tester) async {
    final GlobalKey key = await _pump(tester);
    final TestGesture gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(FxRedrawnArrow)));

    // 擦除尾声 / 重画起笔的交界处最容易全空。
    await tester.pump(const Duration(milliseconds: 150));
    expect(await _lightPixels(tester, key), greaterThan(0));

    await tester.pumpAndSettle();
    expect(await _lightPixels(tester, key), greaterThan(0), reason: 'hover 落定仍可见');
  });

  testWidgets('hover 落定后箭头完整（重画跑到 1）', (tester) async {
    final GlobalKey key = await _pump(tester);
    final TestGesture gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(FxRedrawnArrow)));
    await tester.pumpAndSettle();

    final dynamic state = tester.state(find.byType(FxRedrawnArrow));
    expect(state.debugEraseT, 1.0);
    expect(state.debugShaftT, 1.0);
    expect(state.debugBarbT, 1.0);
    // 掉出 hover 后复位成静态满箭头，同样不能是空白。
    await gesture.moveTo(const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(await _lightPixels(tester, key), greaterThan(0));
  });
}
