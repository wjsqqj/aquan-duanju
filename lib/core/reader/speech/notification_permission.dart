/// Android 13+ 的通知权限（听书后台通知 / 锁屏控制的前提）。
///
/// 为什么自己开一条通道：[`permission_handler`] 为一个权限引入整套插件（含各平台实现与
/// 额外初始化）不划算；工程里只有这一个运行时权限，`MainActivity` 里 40 行 Kotlin 就够。
///
/// 铁律：**拿不到权限只影响通知显示，绝不阻塞播放** —— 所有失败路径返回 `false`，不抛。
library;

import 'dart:io';

import 'package:flutter/services.dart';

class NotificationPermission {
  const NotificationPermission._();

  static const MethodChannel channel = MethodChannel('aquan/notifications');

  /// 申请（已授予则直接 true）。[isAndroid] 仅供单测注入。
  static Future<bool> ensure({bool? isAndroid}) async {
    if (!(isAndroid ?? Platform.isAndroid)) return true;
    try {
      if (await channel.invokeMethod<bool>('hasPermission') == true) {
        return true;
      }
      return await channel.invokeMethod<bool>('requestPermission') == true;
    } on MissingPluginException {
      // 旧安装包 / 通道未注册：不阻塞。
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 只查不申请（设置页显示状态用）。[isAndroid] 仅供单测注入。
  static Future<bool> has({bool? isAndroid}) async {
    if (!(isAndroid ?? Platform.isAndroid)) return true;
    try {
      return await channel.invokeMethod<bool>('hasPermission') == true;
    } catch (_) {
      return false;
    }
  }
}
