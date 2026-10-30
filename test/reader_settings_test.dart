import 'package:aquan_duanju/core/reader/reader_click_action.dart';
import 'package:aquan_duanju/core/reader/reader_settings.dart';
import 'package:aquan_duanju/core/reader/reader_theme.dart';
import 'package:aquan_duanju/core/reader/reader_typography.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ReaderTypography', () {
    test('行高按字号倍数换算', () {
      const t = ReaderTypography(fontSize: 20, lineHeight: 1.8);
      expect(t.lineHeightPx(), closeTo(36, 0.001));
      expect(t.lineHeightPx(textScaler: const TextScaler.linear(2)), closeTo(72, 0.001));
    });

    test('copyWith 支持显式清空字体', () {
      const t = ReaderTypography(fontFamily: 'LXGWWenKai', fontFilePath: '/a.ttf');
      expect(t.copyWith().fontFamily, 'LXGWWenKai');
      expect(t.copyWith(fontFamily: null).fontFamily, isNull);
      expect(t.copyWith(fontFamily: null).fontFilePath, '/a.ttf');
      expect(t.copyWith(fontFilePath: null).fontFilePath, isNull);
    });

    test('数值越界被 clamp', () {
      const t = ReaderTypography();
      expect(t.copyWith(fontSize: 99).fontSize, ReaderTypography.maxFontSize);
      expect(t.copyWith(fontSize: 1).fontSize, ReaderTypography.minFontSize);
      expect(t.copyWith(lineHeight: 9).lineHeight, ReaderTypography.maxLineHeight);
      expect(t.copyWith(paragraphSpacing: -5).paragraphSpacing, 0);
      expect(t.copyWith(paddingLeft: 999).paddingLeft, ReaderTypography.maxPadding);
      expect(t.copyWith(fontWeight: 1000).fontWeight, 900);
    });

    test('JSON 往返保持一致', () {
      const t = ReaderTypography(
        fontSize: 22,
        fontWeight: 600,
        italic: true,
        fontFamily: 'LXGWWenKai',
        letterSpacing: 0.2,
        lineHeight: 2.0,
        paragraphSpacing: 18,
        paragraphIndent: '　',
        paddingLeft: 30,
      );
      final restored = ReaderTypography.fromJson(t.toJson());
      expect(restored, t);
    });

    test('缺字段与非法字段回退默认', () {
      final t = ReaderTypography.fromJson(<String, dynamic>{
        'font_size': 'huge',
        'line_height': null,
        'italic': 'yes',
      });
      expect(t.fontSize, 19);
      expect(t.lineHeight, 1.8);
      expect(t.italic, isFalse);
    });
  });

  group('ReaderThemeConfig', () {
    test('默认三套主题', () {
      final themes = defaultReaderThemes();
      expect(themes.length, 3);
      expect(themes.map((t) => t.id).toSet().length, 3);
      expect(themes.first.footerMiddle, ReaderTipValue.pageAndTotal);
    });

    test('颜色解析容错', () {
      expect(parseReaderColor('#FFF'), 0xFFFFFFFF);
      expect(parseReaderColor('#123456'), 0xFF123456);
      expect(parseReaderColor('#80123456'), 0x80123456);
      expect(parseReaderColor('oops'), 0xFF000000);
      expect(parseReaderColor('oops', fallback: null), isNull);
    });

    test('主题 JSON 往返（含枚举名与自定义模板）', () {
      final theme = defaultReaderThemes().first.copyWith(
        name: '我的纸张',
        headerLeft: ReaderTipValue.time,
        footerRight: ReaderTipValue.custom,
        footerCustomRight: '{BookName} {ChapterTitle}',
        backgroundKind: ReaderBackgroundKind.asset,
        backgroundAsset: 'assets/reader/backgrounds/paper.webp',
        headerMode: ReaderTipMode.always,
        footerMode: ReaderTipMode.never,
      );
      final restored = ReaderThemeConfig.fromJson(theme.toJson());
      expect(restored.name, '我的纸张');
      expect(restored.headerLeft, ReaderTipValue.time);
      expect(restored.footerRight, ReaderTipValue.custom);
      expect(restored.footerCustomRight, '{BookName} {ChapterTitle}');
      expect(restored.backgroundKind, ReaderBackgroundKind.asset);
      expect(restored.backgroundAsset, 'assets/reader/backgrounds/paper.webp');
      expect(restored.headerMode, ReaderTipMode.always);
      expect(restored.footerMode, ReaderTipMode.never);
    });

    test('tipAt / customAt 按槽位取值', () {
      final theme = defaultReaderThemes().first.copyWith(
        headerLeft: ReaderTipValue.time,
        headerCustomLeft: 'L',
        headerCustomMiddle: 'M',
      );
      expect(theme.tipAt(header: true, slot: 0), ReaderTipValue.time);
      expect(theme.customAt(header: true, slot: 0), 'L');
      expect(theme.customAt(header: true, slot: 1), 'M');
      expect(theme.customAt(header: true, slot: 9), '');
    });
  });

  group('ReaderSettings', () {
    test('默认 9 项点击动作与滚动模式', () {
      const s = ReaderSettings();
      expect(s.clickActions.length, 9);
      expect(s.mode, ReaderMode.scroll);
      expect(s.anim, ReaderPageAnim.slide);
      expect(s.actionAt(4), ReaderClickAction.menu);
      expect(s.actionAt(-1), ReaderClickAction.none);
      expect(s.actionAt(99), ReaderClickAction.none);
    });

    test('空主题回退预置，索引越界收敛', () {
      const s = ReaderSettings(activeTheme: 99);
      expect(s.effectiveThemes.length, 3);
      expect(s.activeThemeConfig.id, 'theme_night');
    });

    test('JSON 往返保持点击动作与动画', () {
      final s = const ReaderSettings().copyWith(
        clickActions: const <ReaderClickAction>[
          ReaderClickAction.nextPage,
          ReaderClickAction.nextPage,
          ReaderClickAction.menu,
          ReaderClickAction.nextPage,
          ReaderClickAction.menu,
          ReaderClickAction.prevPage,
          ReaderClickAction.directory,
          ReaderClickAction.addBookmark,
          ReaderClickAction.prevChapter,
        ],
        anim: ReaderPageAnim.curl,
        animSpeed: 3,
        mode: ReaderMode.paged,
        convert: ChineseConvert.t2s,
        zoneLayout: const ClickZoneLayout(edgeInset: 20),
        nightMode: true,
      );
      final restored = ReaderSettings.fromJson(s.toJson());
      expect(restored.clickActions[0], ReaderClickAction.nextPage);
      expect(restored.clickActions[6], ReaderClickAction.directory);
      expect(restored.anim, ReaderPageAnim.curl);
      expect(restored.animDurationMs, 480);
      expect(restored.mode, ReaderMode.paged);
      expect(restored.convert, ChineseConvert.t2s);
      expect(restored.zoneLayout.edgeInset, 20);
      expect(restored.nightMode, isTrue);
      expect(restored.effectiveThemes.length, 3);
    });

    test('点击动作数量不足时补齐到 9 项', () {
      final restored = ReaderSettings.fromJson(<String, dynamic>{
        'click_actions': <int>[1, 0],
      });
      expect(restored.clickActions.length, 9);
      expect(restored.clickActions[0], ReaderClickAction.nextPage);
      expect(restored.clickActions[1], ReaderClickAction.menu);
      expect(restored.clickActions[2], kDefaultClickActions[2]);
    });

    test('点击动作超量时截断到 9 项', () {
      final restored = ReaderSettings.fromJson(<String, dynamic>{
        'click_actions': List<int>.filled(20, 1),
      });
      expect(restored.clickActions.length, 9);
    });

    test('未知枚举名回退默认', () {
      final restored = ReaderSettings.fromJson(<String, dynamic>{
        'mode': 'horizontal',
        'anim': 'fly',
        'convert': 'klingon',
      });
      expect(restored.mode, ReaderMode.scroll);
      expect(restored.anim, ReaderPageAnim.slide);
      expect(restored.convert, ChineseConvert.off);
    });

    test('withActiveTheme 只替换当前主题', () {
      final s = const ReaderSettings();
      final changed = s.withActiveTheme(
        s.activeThemeConfig.copyWith(name: '改名'),
      );
      expect(changed.themes.length, 3);
      expect(changed.activeThemeConfig.name, '改名');
      expect(changed.themes[1].name, '护眼绿');
    });

    test('动画速度挡位被 clamp', () {
      const s = ReaderSettings(animSpeed: 99);
      expect(s.copyWith(animSpeed: 99).animSpeed, 3);
      expect(const ReaderSettings(animSpeed: 0).animDurationMs, 200);
    });
  });
}
