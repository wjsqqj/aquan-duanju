import 'package:flutter/widgets.dart';

/// 全局页面路由观察者：只关心 `PageRoute`（对话框 / 底部面板等 PopupRoute
/// 不算「页面被盖住」）。随机页靠它知道自己是否被搜索/详情/播放页压住，
/// 从而把声音让给上层页面。
final RouteObserver<PageRoute<dynamic>> appRouteObserver =
    RouteObserver<PageRoute<dynamic>>();
