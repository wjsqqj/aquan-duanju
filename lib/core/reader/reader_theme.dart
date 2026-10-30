import 'dart:ui';

import 'reader_typography.dart';

/// 页眉页脚取值，对齐 legado `ReaderTipValueType` 的常用子集。
enum ReaderTipValue {
  none('无'),
  time('时间'),
  battery('电量'),
  chapterTitle('章节名'),
  pageIndex('页码'),
  totalProgress('总进度'),
  pageAndTotal('页码+进度'),
  bookPage('全书页码'),
  custom('自定义模板');

  const ReaderTipValue(this.label);

  final String label;

  static ReaderTipValue fromName(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return ReaderTipValue.none;
  }
}

/// 页眉页脚显示模式。
enum ReaderTipMode {
  followMenu('跟随菜单'),
  always('常显'),
  never('常隐');

  const ReaderTipMode(this.label);

  final String label;

  static ReaderTipMode fromIndex(Object? index) {
    if (index is num && index >= 0 && index < values.length) {
      return values[index.toInt()];
    }
    return ReaderTipMode.followMenu;
  }
}

/// 背景类型。
enum ReaderBackgroundKind {
  color('纯色'),
  asset('内置图'),
  file('本地图');

  const ReaderBackgroundKind(this.label);

  final String label;

  static ReaderBackgroundKind fromName(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return ReaderBackgroundKind.color;
  }
}

/// 一套排版主题：排版 + 配色 + 背景 + 页眉页脚。
class ReaderThemeConfig {
  const ReaderThemeConfig({
    required this.id,
    required this.name,
    this.typography = const ReaderTypography(),
    this.backgroundKind = ReaderBackgroundKind.color,
    this.backgroundColor = 0xFFF6F1E4,
    this.textColor = 0xFF2E2A24,
    this.backgroundColorNight = 0xFF121212,
    this.textColorNight = 0xFFC9C6C0,
    this.backgroundAsset,
    this.backgroundFile,
    this.backgroundAlpha = 1.0,
    this.darkStatusIcon = true,
    this.headerLeft = ReaderTipValue.none,
    this.headerMiddle = ReaderTipValue.chapterTitle,
    this.headerRight = ReaderTipValue.none,
    this.footerLeft = ReaderTipValue.none,
    this.footerMiddle = ReaderTipValue.pageAndTotal,
    this.footerRight = ReaderTipValue.none,
    this.headerCustomLeft = '',
    this.headerCustomMiddle = '',
    this.headerCustomRight = '',
    this.footerCustomLeft = '',
    this.footerCustomMiddle = '',
    this.footerCustomRight = '',
    this.showHeaderLine = false,
    this.showFooterLine = true,
    this.headerMode = ReaderTipMode.followMenu,
    this.footerMode = ReaderTipMode.always,
  });

  final String id;
  final String name;
  final ReaderTypography typography;

  final ReaderBackgroundKind backgroundKind;

  /// 0xAARRGGBB。
  final int backgroundColor;
  final int textColor;
  final int backgroundColorNight;
  final int textColorNight;

  /// 内置资源路径（`assets/reader/backgrounds/xxx.webp`）。
  final String? backgroundAsset;

  /// 本地图片路径。
  final String? backgroundFile;

  final double backgroundAlpha;
  final bool darkStatusIcon;

  final ReaderTipValue headerLeft;
  final ReaderTipValue headerMiddle;
  final ReaderTipValue headerRight;
  final ReaderTipValue footerLeft;
  final ReaderTipValue footerMiddle;
  final ReaderTipValue footerRight;

  final String headerCustomLeft;
  final String headerCustomMiddle;
  final String headerCustomRight;
  final String footerCustomLeft;
  final String footerCustomMiddle;
  final String footerCustomRight;

  final bool showHeaderLine;
  final bool showFooterLine;

  final ReaderTipMode headerMode;
  final ReaderTipMode footerMode;

  bool get needsImage =>
      backgroundKind != ReaderBackgroundKind.color &&
      (backgroundAsset != null || backgroundFile != null);

  ReaderTipValue tipAt({required bool header, required int slot}) {
    final list = header
        ? [headerLeft, headerMiddle, headerRight]
        : [footerLeft, footerMiddle, footerRight];
    return list[slot.clamp(0, 2)];
  }

  String customAt({required bool header, required int slot}) {
    final list = header
        ? [headerCustomLeft, headerCustomMiddle, headerCustomRight]
        : [footerCustomLeft, footerCustomMiddle, footerCustomRight];
    return list[slot.clamp(0, 2)];
  }

  ReaderThemeConfig copyWith({
    String? name,
    ReaderTypography? typography,
    ReaderBackgroundKind? backgroundKind,
    int? backgroundColor,
    int? textColor,
    int? backgroundColorNight,
    int? textColorNight,
    Object? backgroundAsset = _unset,
    Object? backgroundFile = _unset,
    double? backgroundAlpha,
    bool? darkStatusIcon,
    ReaderTipValue? headerLeft,
    ReaderTipValue? headerMiddle,
    ReaderTipValue? headerRight,
    ReaderTipValue? footerLeft,
    ReaderTipValue? footerMiddle,
    ReaderTipValue? footerRight,
    String? headerCustomLeft,
    String? headerCustomMiddle,
    String? headerCustomRight,
    String? footerCustomLeft,
    String? footerCustomMiddle,
    String? footerCustomRight,
    bool? showHeaderLine,
    bool? showFooterLine,
    ReaderTipMode? headerMode,
    ReaderTipMode? footerMode,
  }) =>
      ReaderThemeConfig(
        id: id,
        name: name ?? this.name,
        typography: typography ?? this.typography,
        backgroundKind: backgroundKind ?? this.backgroundKind,
        backgroundColor: backgroundColor ?? this.backgroundColor,
        textColor: textColor ?? this.textColor,
        backgroundColorNight: backgroundColorNight ?? this.backgroundColorNight,
        textColorNight: textColorNight ?? this.textColorNight,
        backgroundAsset: identical(backgroundAsset, _unset)
            ? this.backgroundAsset
            : backgroundAsset as String?,
        backgroundFile: identical(backgroundFile, _unset)
            ? this.backgroundFile
            : backgroundFile as String?,
        backgroundAlpha: (backgroundAlpha ?? this.backgroundAlpha).clamp(0.0, 1.0),
        darkStatusIcon: darkStatusIcon ?? this.darkStatusIcon,
        headerLeft: headerLeft ?? this.headerLeft,
        headerMiddle: headerMiddle ?? this.headerMiddle,
        headerRight: headerRight ?? this.headerRight,
        footerLeft: footerLeft ?? this.footerLeft,
        footerMiddle: footerMiddle ?? this.footerMiddle,
        footerRight: footerRight ?? this.footerRight,
        headerCustomLeft: headerCustomLeft ?? this.headerCustomLeft,
        headerCustomMiddle: headerCustomMiddle ?? this.headerCustomMiddle,
        headerCustomRight: headerCustomRight ?? this.headerCustomRight,
        footerCustomLeft: footerCustomLeft ?? this.footerCustomLeft,
        footerCustomMiddle: footerCustomMiddle ?? this.footerCustomMiddle,
        footerCustomRight: footerCustomRight ?? this.footerCustomRight,
        showHeaderLine: showHeaderLine ?? this.showHeaderLine,
        showFooterLine: showFooterLine ?? this.showFooterLine,
        headerMode: headerMode ?? this.headerMode,
        footerMode: footerMode ?? this.footerMode,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'typography': typography.toJson(),
        'background_kind': backgroundKind.name,
        'bg_color': backgroundColor,
        'text_color': textColor,
        'bg_color_night': backgroundColorNight,
        'text_color_night': textColorNight,
        if (backgroundAsset != null) 'bg_asset': backgroundAsset,
        if (backgroundFile != null) 'bg_file': backgroundFile,
        'bg_alpha': backgroundAlpha,
        'dark_status_icon': darkStatusIcon,
        'header_left': headerLeft.name,
        'header_middle': headerMiddle.name,
        'header_right': headerRight.name,
        'footer_left': footerLeft.name,
        'footer_middle': footerMiddle.name,
        'footer_right': footerRight.name,
        'header_custom_left': headerCustomLeft,
        'header_custom_middle': headerCustomMiddle,
        'header_custom_right': headerCustomRight,
        'footer_custom_left': footerCustomLeft,
        'footer_custom_middle': footerCustomMiddle,
        'footer_custom_right': footerCustomRight,
        'show_header_line': showHeaderLine,
        'show_footer_line': showFooterLine,
        'header_mode': headerMode.name,
        'footer_mode': footerMode.name,
      };

  factory ReaderThemeConfig.fromJson(Map<String, dynamic> json) {
    final typography = json['typography'];
    int color(Object? v, int fallback) {
      if (v is num) return v.toInt();
      if (v is String) {
        final parsed = parseReaderColor(v, fallback: null);
        if (parsed != null) return parsed;
      }
      return fallback;
    }

    const base = ReaderThemeConfig(id: '', name: '');
    return ReaderThemeConfig(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '未命名',
      typography: ReaderTypography.fromJson(
          typography is Map<String, dynamic> ? typography : null),
      backgroundKind:
          ReaderBackgroundKind.fromName(json['background_kind']),
      backgroundColor: color(json['bg_color'], base.backgroundColor),
      textColor: color(json['text_color'], base.textColor),
      backgroundColorNight:
          color(json['bg_color_night'], base.backgroundColorNight),
      textColorNight: color(json['text_color_night'], base.textColorNight),
      backgroundAsset: json['bg_asset'] as String?,
      backgroundFile: json['bg_file'] as String?,
      backgroundAlpha:
          (json['bg_alpha'] is num ? (json['bg_alpha'] as num).toDouble() : 1.0)
              .clamp(0.0, 1.0),
      darkStatusIcon: json['dark_status_icon'] is bool
          ? json['dark_status_icon'] as bool
          : true,
      headerLeft: ReaderTipValue.fromName(json['header_left']),
      headerMiddle: ReaderTipValue.fromName(json['header_middle']),
      headerRight: ReaderTipValue.fromName(json['header_right']),
      footerLeft: ReaderTipValue.fromName(json['footer_left']),
      footerMiddle: ReaderTipValue.fromName(json['footer_middle']),
      footerRight: ReaderTipValue.fromName(json['footer_right']),
      headerCustomLeft: json['header_custom_left'] as String? ?? '',
      headerCustomMiddle: json['header_custom_middle'] as String? ?? '',
      headerCustomRight: json['header_custom_right'] as String? ?? '',
      footerCustomLeft: json['footer_custom_left'] as String? ?? '',
      footerCustomMiddle: json['footer_custom_middle'] as String? ?? '',
      footerCustomRight: json['footer_custom_right'] as String? ?? '',
      showHeaderLine: json['show_header_line'] is bool
          ? json['show_header_line'] as bool
          : false,
      showFooterLine: json['show_footer_line'] is bool
          ? json['show_footer_line'] as bool
          : true,
      headerMode: _modeFromJson(json['header_mode'], ReaderTipMode.followMenu),
      footerMode: _modeFromJson(json['footer_mode'], ReaderTipMode.always),
    );
  }
}

/// `toJson` 存枚举名；同时兼容早期的整数下标。
ReaderTipMode _modeFromJson(Object? raw, ReaderTipMode fallback) {
  if (raw is String) {
    for (final mode in ReaderTipMode.values) {
      if (mode.name == raw) return mode;
    }
    return fallback;
  }
  return ReaderTipMode.fromIndex(raw);
}

/// 解析 `#RGB` / `#RRGGBB` / `#AARRGGBB`；解析失败返回 [fallback]。
int? parseReaderColor(String raw, {int? fallback = 0xFF000000}) {
  var text = raw.trim();
  if (text.startsWith('#')) text = text.substring(1);
  if (text.length == 3) {
    text = text.split('').map((c) => '$c$c').join();
  }
  if (text.length == 6) text = 'FF$text';
  if (text.length != 8) return fallback;
  final value = int.tryParse(text, radix: 16);
  return value ?? fallback;
}

/// 内置字体 family（`pubspec.yaml` 里声明）。
const String kReaderBuiltinFontFamily = 'LXGWWenKai';
const String kReaderBuiltinFontLabel = '霞鹜文楷';

/// 内置背景纹理资源。
class ReaderBackgroundAsset {
  const ReaderBackgroundAsset(this.path, this.label);

  final String path;
  final String label;
}

const List<ReaderBackgroundAsset> kReaderBackgrounds = <ReaderBackgroundAsset>[
  ReaderBackgroundAsset('assets/reader/backgrounds/paper.webp', '宣纸'),
  ReaderBackgroundAsset('assets/reader/backgrounds/wood.webp', '木纹'),
  ReaderBackgroundAsset('assets/reader/backgrounds/linen.webp', '亚麻'),
  ReaderBackgroundAsset('assets/reader/backgrounds/mist.webp', '薄雾'),
  ReaderBackgroundAsset('assets/reader/backgrounds/charcoal.webp', '炭黑'),
];

/// 预置三套主题：默认纸张 / 护眼绿 / 夜间。
List<ReaderThemeConfig> defaultReaderThemes() => const <ReaderThemeConfig>[
      ReaderThemeConfig(
        id: 'theme_default',
        name: '默认纸张',
        typography: ReaderTypography(),
        backgroundKind: ReaderBackgroundKind.asset,
        backgroundAsset: 'assets/reader/backgrounds/paper.webp',
        backgroundAlpha: 0.85,
        backgroundColor: 0xFFF6F1E4,
        textColor: 0xFF2E2A24,
        footerMiddle: ReaderTipValue.pageAndTotal,
      ),
      ReaderThemeConfig(
        id: 'theme_eye',
        name: '护眼绿',
        typography: ReaderTypography(fontSize: 19, lineHeight: 1.9),
        backgroundColor: 0xFFC7EDCC,
        textColor: 0xFF22331F,
        backgroundColorNight: 0xFF1A2418,
        textColorNight: 0xFFB9D3B2,
        footerMiddle: ReaderTipValue.pageAndTotal,
      ),
      ReaderThemeConfig(
        id: 'theme_night',
        name: '夜间',
        typography: ReaderTypography(fontSize: 19, lineHeight: 1.85),
        backgroundKind: ReaderBackgroundKind.asset,
        backgroundAsset: 'assets/reader/backgrounds/charcoal.webp',
        backgroundAlpha: 0.9,
        backgroundColor: 0xFF121212,
        textColor: 0xFFC9C6C0,
        backgroundColorNight: 0xFF121212,
        textColorNight: 0xFFC9C6C0,
        darkStatusIcon: false,
        footerMiddle: ReaderTipValue.pageAndTotal,
      ),
    ];

const Object _unset = Object();

/// 便捷：`Color` ← 0xAARRGGBB。
Color readerColor(int argb) => Color(argb);
