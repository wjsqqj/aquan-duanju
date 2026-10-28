import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// FFI 绑定：加载 Go 数据核心（Android 的 libaquan_core.so / Windows 的
/// aquan_core.dll），导出四个符号的阻塞调用。
///
/// 约定（与 native/bridge/core 的文档一致）：
/// - 每个函数返回 C 字符串 JSON，读完后必须 AquaFreeString 释放；
/// - AquaCall 阻塞直到请求结束，只能放在后台 isolate 里调用；
/// - 信封是 {"result": …} 或 {"error": {code, message, retryable, retryAfterMs}}。
class AquaLibrary {
  AquaLibrary._(this._lib) {
    _new = _lib
        .lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>),
            Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>('AquaNew');
    _call = _lib
        .lookupFunction<
            Pointer<Utf8> Function(IntPtr, Pointer<Utf8>, Pointer<Utf8>),
            Pointer<Utf8> Function(
                int, Pointer<Utf8>, Pointer<Utf8>)>('AquaCall');
    _version = _lib
        .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'AquaVersion');
    _free = _lib.lookupFunction<Void Function(Pointer<Utf8>),
        void Function(Pointer<Utf8>)>('AquaFreeString');
  }

  static AquaLibrary? _instance;

  final DynamicLibrary _lib;
  late final Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>) _new;
  late final Pointer<Utf8> Function(int, Pointer<Utf8>, Pointer<Utf8>) _call;
  late final Pointer<Utf8> Function() _version;
  late final void Function(Pointer<Utf8>) _free;

  /// 打开（或复用已打开的）核心库。静态缓存在各自 isolate 内有效。
  static AquaLibrary open() {
    final cached = _instance;
    if (cached != null) return cached;
    final DynamicLibrary lib;
    if (Platform.isWindows) {
      lib = DynamicLibrary.open(_desktopPath('aquan_core.dll') ?? 'aquan_core.dll');
    } else if (Platform.isAndroid) {
      lib = DynamicLibrary.open('libaquan_core.so');
    } else if (Platform.isLinux) {
      // Flutter Linux 包把原生库放在 bundle/lib（RPATH $ORIGIN/lib）。
      lib = DynamicLibrary.open(
          _desktopPath('lib/libaquan_core.so') ?? 'libaquan_core.so');
    } else if (Platform.isMacOS) {
      lib = DynamicLibrary.open(
          _desktopPath('libaquan_core.dylib') ?? 'libaquan_core.dylib');
    } else {
      throw UnsupportedError(
          'AquaLibrary: 平台 ${Platform.operatingSystem} 不支持');
    }
    return _instance = AquaLibrary._(lib);
  }

  /// 桌面端优先从可执行文件旁边加载，避免 dlopen 搜索路径差异。
  static String? _desktopPath(String relative) {
    try {
      final exe = Platform.resolvedExecutable;
      final file = File('${File(exe).parent.path}${Platform.pathSeparator}'
          '${relative.replaceAll('/', Platform.pathSeparator)}');
      return file.existsSync() ? file.path : null;
    } catch (_) {
      return null;
    }
  }

  /// AquaNew：创建客户端，返回 {"handle":N} 或 {"error":{…}}。
  String create(String profilePath, String configJson) =>
      _stringOf(_new(profilePath.toNativeUtf8(), configJson.toNativeUtf8()));

  /// AquaCall：阻塞执行一次方法调用。
  String call(int handle, String method, String argsJson) => _stringOf(
      _call(handle, method.toNativeUtf8(), argsJson.toNativeUtf8()));

  /// AquaVersion：核心版本号。
  String version() => _stringOf(_version());

  String _stringOf(Pointer<Utf8> p) {
    final s = p.toDartString();
    _free(p);
    return s;
  }
}
