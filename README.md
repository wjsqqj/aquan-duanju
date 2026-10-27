# 阿圈短剧

一个基于 [openhongguo](https://github.com/beilunyang/openhongguo)（红果短剧逆向接口 SDK，
Apache-2.0）的 Flutter 短剧播放器，支持 **Android** 与 **Windows**。

> **免责声明**
>
> 本项目仅供学习与研究，禁止用于商业用途。应用内数据来自开源项目 openhongguo
> 逆向的红果短剧公开接口，所有短剧内容的版权归原平台及权利方所有。
> 请勿将本项目用于任何侵犯他人合法权益的用途；使用本项目即表示您同意上述条款。

## 功能

| 模块 | 说明 |
|---|---|
| 发现 | 推荐流、频道切换（新剧/热剧/漫剧…）、双列瀑布、分页加载 |
| 随机看 | 全屏竖滑 feed，上下滑随机换剧（红果「随机看」的交互） |
| 榜单 | 短剧榜单多内容多榜切换、类型筛选 |
| 搜索 | 热搜榜、猜你想搜、输入联想、结果分页 |
| 详情 | 简介、演员、分集网格、季与合集、相关推荐、续播 |
| 播放 | 清晰度切换、倍速（0.5–3.0x）、手势、双击快进退、自动连播、CENC 加密分集透明解密 |
| 本地 | 观看历史（秒级续播）、追剧收藏、深浅色主题、默认清晰度/倍速、重置匿名设备 |

架构：Flutter UI → Dart FFI → Go 核心（`native/bridge`，c-shared 动态库）→
openhongguo SDK（请求签名、匿名设备注册、播放地址与内容密钥）。
播放内核是 media_kit（libmpv），加密分集的 CENC 内容密钥通过
`demuxer-lavf-o` 的 `decryption_key` 交给 mpv 解密。

## 下载

在 [Releases](../../releases) 页面：

| 平台 | 产物 |
|---|---|
| Android | `aquan-arm64-v8a.apk`（主流 64 位手机）、`aquan-armeabi-v7a.apk`、`aquan-x86_64.apk` |
| Windows | `aquan-windows-x64-<版本>.zip`（解压即用，无需安装） |

Android 正式发布包使用 release 签名；未配置签名 Secrets 的构建回退 debug 签名，
安装时系统可能提示未知来源，允许即可。Windows 包未签名，SmartScreen 提示时选择
「仍要运行」。

## 从源码构建

要求：Flutter 3.47+、Go 1.22+；Windows 构建需 mingw-w64 gcc，Android 构建需 NDK。

```sh
# Windows
python scripts/build_windows.py --version 0.1.0 --zip

# Android
python scripts/build_android.py --ndk <NDK 路径> --version 0.1.0
```

也可以只构建原生库后用 `flutter build`：

```sh
python scripts/build_native.py --windows --version 0.1.0   # 或 --android --ndk ...
flutter build windows --release
flutter build apk --release --split-per-abi
```

构建后需要把 `build/aquan_core.dll`（Windows）或
`android/app/src/main/jniLibs/<abi>/libaquan_core.so`（Android）放进产物，
`scripts/build_windows.py` / `build_android.py` 已自动处理。

## 发布流程

1. 修改 `pubspec.yaml` 的 `version: X.Y.Z+N`，在 `CHANGELOG.md` 加 `## X.Y.Z (日期)` 小节。
2. 提交后打 tag：`git tag vX.Y.Z && git push origin vX.Y.Z`。
3. GitHub Actions 会校验 tag 与 `pubspec` 一致，然后构建 Android + Windows 并自动创建
   Release（release notes 取自 CHANGELOG 对应小节）。

## Android 签名

按优先级：

1. `android/key.properties`（本机，不入库）；
2. 环境变量（CI Secrets）：`ANDROID_KEYSTORE_PATH`、`ANDROID_KEYSTORE_PASSWORD`、
   `ANDROID_KEYSTORE_ALIAS`、`ANDROID_KEYSTORE_KEY_PASSWORD`；
3. 都没有时回退 debug 签名。

## 开发

```sh
flutter pub get
flutter analyze --fatal-infos
flutter test
cd native/bridge && go vet ./... && go test ./...
dart run tool/smoke.dart <构建产物目录>     # 全链路冒烟（真实接口）
```

## 致谢

- [openhongguo](https://github.com/beilunyang/openhongguo) — 红果短剧逆向接口的 Go SDK，
  本项目的数据核心；Apache-2.0。
- [media_kit](https://github.com/media-kit/media-kit) — libmpv 的 Flutter 绑定。
- Windows media_kit 崩溃补丁与播放链路参考了社区先行探索（`packages/` 内带补丁说明）。

## LICENSE

Apache License 2.0（见 [LICENSE](LICENSE)）。`native/bridge/vendor/` 内是 openhongguo
的 Apache-2.0 源码副本，版权归属其原作者。
