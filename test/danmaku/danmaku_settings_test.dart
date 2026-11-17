import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('弹幕显示设置', () {
    late SettingsStore settings;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = SettingsStore(await SharedPreferences.getInstance());
    });

    test('默认值：4 行 / 8s / 16px / 不透明 / 顶部 / 描边 / 同句合并', () {
      expect(settings.danmakuRows, 4);
      expect(settings.danmakuSpeedMs, 8000);
      expect(settings.danmakuFontSize, 16);
      expect(settings.danmakuOpacity, 100);
      expect(settings.danmakuArea, 25);
      expect(settings.danmakuStroke, isTrue);
      expect(settings.danmakuMergeSame, isTrue);
      expect(settings.danmakuEnabled, isFalse);
    });

    test('越界值 clamp 到合法区间', () {
      settings.danmakuRows = 0;
      expect(settings.danmakuRows, 1);
      settings.danmakuRows = 99;
      expect(settings.danmakuRows, 10);

      settings.danmakuSpeedMs = 100;
      expect(settings.danmakuSpeedMs, 4000);
      settings.danmakuSpeedMs = 999999;
      expect(settings.danmakuSpeedMs, 16000);

      settings.danmakuFontSize = 1;
      expect(settings.danmakuFontSize, 12);
      settings.danmakuFontSize = 99;
      expect(settings.danmakuFontSize, 28);

      settings.danmakuOpacity = 0;
      expect(settings.danmakuOpacity, 40);
      settings.danmakuOpacity = 200;
      expect(settings.danmakuOpacity, 100);

      // 显示区域只认三档，其余回落默认「顶部」。
      settings.danmakuArea = 50;
      expect(settings.danmakuArea, 50);
      settings.danmakuArea = 77;
      expect(settings.danmakuArea, 25);
    });

    test('备份导出包含七项，导入可还原', () async {
      settings.danmakuRows = 6;
      settings.danmakuSpeedMs = 12000;
      settings.danmakuFontSize = 20;
      settings.danmakuOpacity = 80;
      settings.danmakuArea = 100;
      settings.danmakuStroke = false;
      settings.danmakuMergeSame = false;

      final Map<String, dynamic> backup = settings.exportBackup();
      expect(backup['player.danmakuRows'], 6);
      expect(backup['player.danmakuSpeedMs'], 12000);
      expect(backup['player.danmakuFontSize'], 20);
      expect(backup['player.danmakuOpacity'], 80);
      expect(backup['player.danmakuArea'], 100);
      expect(backup['player.danmakuStroke'], isFalse);
      expect(backup['player.danmakuMergeSame'], isFalse);

      SharedPreferences.setMockInitialValues({});
      final SettingsStore restored =
          SettingsStore(await SharedPreferences.getInstance());
      final applied = restored.importBackup(backup);
      expect(applied, greaterThan(0));
      expect(restored.danmakuRows, 6);
      expect(restored.danmakuSpeedMs, 12000);
      expect(restored.danmakuFontSize, 20);
      expect(restored.danmakuOpacity, 80);
      expect(restored.danmakuArea, 100);
      expect(restored.danmakuStroke, isFalse);
      expect(restored.danmakuMergeSame, isFalse);
    });
  });
}
