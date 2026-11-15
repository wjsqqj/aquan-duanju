import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import '../motion/decode_reveal.dart';
import '../motion/magnetic_field.dart';

/// 统一空态：图标 + 主文案 + 说明 + 可选操作。
///
/// 全站 14 处手写空态收敛到这一个实现（批次⑤），因此这里只留 4 个字段：
/// 图标、标题、说明、动作。空态永远垂直居中，上下各留 `s24`——
/// 之前各屏的留白从 8 到 40 不等，列表很短时「空」和「还在加载」分不开。
class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.title,
    this.description,
    this.action,
    this.icon,
    this.decodeTitle = true,
    this.magnetic = false,
  });

  /// 主文案（`title` 字阶）。这句话要回答「这里为什么是空的」。
  final String title;

  /// 说明（`caption` + 次要色），补充「怎么让它不空」。
  final String? description;

  /// 可选操作（重试 / 去发现 / 添加源）。
  final Widget? action;

  /// 可选图标；`null` 时不渲染图标。
  final IconData? icon;

  /// 标题是否走乱码解码入场（E4 [FxDecodeReveal]，默认 true）。
  ///
  /// 空态是瞬态一次性时刻——每次内容从无到有都值得一拍「解码」仪式；
  /// 「减少动效」时静态直出（不装 controller），解码完成后渲染与
  /// 普通 [Text] 逐像素一致。既有调用点零改动（默认值生效）。
  final bool decodeTitle;

  /// 是否启用背景磁力符号卡彩蛋（E5 [FxMagneticField]，默认 false）。
  ///
  /// **默认关**——避免全站空态都被打扰，只在挑选的空态面显式开启
  /// （discover / media_hub）。开启后磁力卡是背景装饰层（IgnorePointer，
  /// 不抢点击/重试手势），桌面指针靠近被推开、弹簧摆回；移动/TV 不构建
  /// （零开销），「减少动效」静态直出。
  final bool magnetic;

  /// 图标边长：56（= `s48 + s8`），沿用旧空态尺寸。
  static const double _iconSize = 56;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final String? descriptionText = description;
    final Widget? actionWidget = action;
    final IconData? iconData = icon;
    Widget content = Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.metrics.s24,
          vertical: tokens.metrics.s24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: tokens.metrics.s8,
          children: <Widget>[
            if (iconData != null)
              Icon(iconData, size: _iconSize, color: tokens.colors.textTertiary),
            decodeTitle
                ? FxDecodeReveal(
                    text: title,
                    style: tokens.title,
                    textAlign: TextAlign.center,
                  )
                : Text(title, textAlign: TextAlign.center, style: tokens.title),
            if (descriptionText != null)
              Text(
                descriptionText,
                textAlign: TextAlign.center,
                style: tokens.caption
                    .copyWith(color: tokens.colors.textSecondary),
              ),
            ?actionWidget,
          ],
        ),
      ),
    );
    // 磁力符号卡是背景装饰层（E5）：组件内部自门控（桌面 only /
    // reduceMotion 静态 / 移动 TV 零构建）。
    if (magnetic) {
      content = FxMagneticField(child: content);
    }
    return content;
  }
}
