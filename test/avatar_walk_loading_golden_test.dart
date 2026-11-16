import 'package:aquan_duanju/widgets/ui/avatar_walk_loading.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('走路加载页渲染 golden', (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 500));
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.light(),
          home: AvatarWalkLoading(),
        ),
      ),
    );
    // 图片异步加载（AssetManifest I/O 在测试 FakeAsync 区不完成）→
    // 必须包 runAsync 放行真实 I/O，再 pump 推进动画帧。
    await tester.runAsync(() async {
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await expectLater(
      find.byType(AvatarWalkLoading),
      // 基准图入库到 test/goldens（build/ 被 gitignore，CI 上拿不到）。
      matchesGoldenFile('goldens/avatar_loading_golden.png'),
    );
  });
}
