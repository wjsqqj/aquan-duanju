import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/tv/tv_mode.dart';
import 'package:aquan_duanju/core/shelf/shelf_geometry.dart';
import 'package:aquan_duanju/widgets/shelf_3d.dart';
import 'package:aquan_duanju/widgets/motion/view_swap.dart';
import 'package:aquan_duanju/widgets/tv_scope.dart';

const ShelfMetrics _metrics = ShelfMetrics();

List<ShelfBook> _books(int n) => <ShelfBook>[
  for (int i = 0; i < n; i++)
    ShelfBook(id: 'b$i', title: '书名 $i', subtitle: '卷 $i'),
];

Widget _host(
  List<ShelfBook> books, {
  bool disableAnimations = false,
  bool tv = false,
  bool withDelete = false,
}) => MaterialApp(
  home: TvScope(
    formFactor: tv ? AppFormFactor.tv : AppFormFactor.phone,
    child: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(
        body: SizedBox(
          height: 300,
          child: Shelf3DView(
            books: books,
            onOpen: (_) {},
            onDelete: withDelete ? (ShelfBook _) {} : null,
          ),
        ),
      ),
    ),
  ),
);

dynamic _state(WidgetTester tester) => tester.state(find.byType(Shelf3DView));

/// 首本书中心（与 Shelf3DView 布局公式一致：左右留白 = max(24, half-65)）。
Offset _firstBookCenter(double viewportWidth) {
  final double half = viewportWidth / 2;
  final double left = half - _metrics.itemExtent / 2 > 24
      ? half - _metrics.itemExtent / 2
      : 24.0;
  final double x = left + _metrics.coverWidth / 2 + _metrics.spineWidth / 2;
  final double y = 18 + (_metrics.coverHeight + 22) / 2;
  return Offset(x, y);
}

void main() {
  testWidgets('首次进场：扇入播一次（总时长 ≤2.2s 编排豁免），完成后物理接管', (tester) async {
    await tester.pumpWidget(_host(_books(6)));
    expect(_state(tester).debugIntroActive, isTrue);
    expect(_state(tester).debugIntroPlayed, isTrue);
    // 总时长 = clamp(900 + 130×6, ≤2200) = 1680ms。
    expect(
      _state(tester).debugIntroDuration,
      const Duration(milliseconds: 1680),
    );

    // 进场中：书本带扇入位姿（首本弹入中）。
    expect(_state(tester).debugFanPoseActive(0), isTrue);

    await tester.pumpAndSettle();
    expect(_state(tester).debugIntroActive, isFalse);
    expect(_state(tester).debugFanPoseActive(0), isFalse); // 已归位
  });

  testWidgets('进场中 hover 旁路：弹入未完成不响应悬停（删除钮不出），完成后接管', (tester) async {
    await tester.pumpWidget(_host(_books(3), withDelete: true));
    final Offset center = _firstBookCenter(800);

    final TestGesture gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    // 进场中把指针压到书上：MouseRegion 的 onEnter 已被旁路。
    await gesture.moveTo(center);
    await tester.pump();
    expect(find.byTooltip('移出书架'), findsNothing);

    // 指针先移开（避免 onEnter 从 null 变回调后不补发既有指针的 enter）。
    await gesture.moveTo(const Offset(760, 560));
    await tester.pumpAndSettle();
    expect(_state(tester).debugIntroActive, isFalse);

    // 进场完成：物理接管，指针回到书上 → hover 正常（悬停删除钮出现）。
    await gesture.moveTo(center);
    await tester.pump();
    expect(find.byTooltip('移出书架'), findsOneWidget);
  });

  testWidgets('reduceMotion：静态直出（不装扇入时钟，AC20）', (tester) async {
    await tester.pumpWidget(_host(_books(6), disableAnimations: true));
    expect(_state(tester).debugIntroPlayed, isTrue);
    expect(_state(tester).debugIntroActive, isFalse);
    await tester.pumpAndSettle();
    expect(find.text('书名 0'), findsOneWidget);
  });

  testWidgets('TV：不启用扇入（焦点导航优先）', (tester) async {
    await tester.pumpWidget(_host(_books(6), tv: true));
    expect(_state(tester).debugIntroPlayed, isTrue);
    expect(_state(tester).debugIntroActive, isFalse);
  });

  testWidgets('与 FxViewSwap 互斥：切换进行中构建的 3D 书架不播扇入', (tester) async {
    final ValueNotifier<bool> mode = ValueNotifier<bool>(false);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(),
          child: Scaffold(
            body: FxViewSwap(
              listenable: mode,
              first: const Text('列表视图'),
              second: SizedBox(
                height: 300,
                child: Shelf3DView(books: _books(6), onOpen: (_) {}),
              ),
            ),
          ),
        ),
      ),
    );
    expect(FxViewSwap.swapInProgress, isFalse);

    mode.value = true; // 列表 → 3D，切换过渡启动
    await tester.pump();
    expect(FxViewSwap.swapInProgress, isTrue);
    // 入拍起 second 层才挂树（hold 拍空窗）：此刻扇入被互斥标志拦下。
    await tester.pump(const Duration(milliseconds: 700));
    expect(_state(tester).debugIntroPlayed, isTrue);
    expect(_state(tester).debugIntroActive, isFalse);

    await tester.pumpAndSettle();
    expect(find.text('书名 0'), findsOneWidget);
    // 收尾拍稳态重建会把 3D 子树卸壳重挂树：重挂载的 Shelf3DView 同样
    // 必须读到互斥标志（帧末才回落），扇入不得在过渡结束后补播。
    expect(FxViewSwap.swapInProgress, isFalse);
    expect(_state(tester).debugIntroRan, isFalse);
    expect(_state(tester).debugIntroActive, isFalse);
  });

  testWidgets('大书架：交错压缩保证末本书落进总时长（cap 2.2s）', (tester) async {
    await tester.pumpWidget(_host(_books(30)));
    // 总时长 clamp(900 + 130×30, ≤2200) = 2200ms。
    expect(
      _state(tester).debugIntroDuration,
      const Duration(milliseconds: 2200),
    );
    await tester.pumpAndSettle();
    expect(_state(tester).debugIntroActive, isFalse);
  });
}
