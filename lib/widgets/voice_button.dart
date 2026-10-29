import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/voice/stt.dart';
import '../core/voice/vad.dart';
import 'common.dart';

/// 搜索框语音按钮：点按开始 →（Android 系统识别流式出字 / 桌面录音+云 API）→
/// 文字填入搜索框（由调用方决定是否提交）。
///
/// 状态机：idle → listening（波纹动画 + 静音自动结束 1.5s）→ 填入结果。
class VoiceSearchButton extends StatefulWidget {
  const VoiceSearchButton({
    super.key,
    required this.onText,
    this.color,
  });

  final ValueChanged<String> onText;
  final Color? color;

  @override
  State<VoiceSearchButton> createState() => _VoiceSearchButtonState();
}

class _VoiceSearchButtonState extends State<VoiceSearchButton>
    with SingleTickerProviderStateMixin {
  bool _listening = false;
  String? _partial;
  String? _error;

  // Android 流式识别。
  StreamSubscription<SttResult>? _androidSub;
  // 桌面录音。
  VoiceRecorder? _recorder;
  StreamSubscription<double>? _levelSub;
  StreamSubscription<double>? _vadSub;
  double _level = -60;
  Timer? _noSpeechTimer;

  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _unlisten();
    _pulse.dispose();
    super.dispose();
  }

  void _unlisten() {
    _androidSub?.cancel();
    _androidSub = null;
    _levelSub?.cancel();
    _levelSub = null;
    _vadSub?.cancel();
    _vadSub = null;
    _noSpeechTimer?.cancel();
    _recorder?.cancel();
    _recorder = null;
  }

  Future<void> _toggle() async {
    if (_listening) {
      await _finishManual();
      return;
    }
    setState(() {
      _listening = true;
      _partial = null;
      _error = null;
    });
    try {
      if (Platform.isAndroid) {
        await _startAndroid();
      } else {
        await _startDesktop();
      }
    } on VoiceException catch (e) {
      if (!mounted) return;
      setState(() {
        _listening = false;
        _error = e.friendlyText;
        _listening = false;
      });
      _autoDismissError();
    }
  }

  Future<void> _startAndroid() async {
    final backend = AndroidSpeechBackend();
    var gotAny = false;
    _androidSub = backend.listen().listen(
      (result) {
        if (!mounted) return;
        if (result.text.isNotEmpty) {
          gotAny = true;
          setState(() => _partial = result.text);
        }
        if (result.isFinal && result.text.isNotEmpty) {
          _emit(result.text);
        } else if (result.isFinal && !gotAny) {
          setState(() {
            _listening = false;
            _error = '没听清内容，再说一次试试';
          });
          _autoDismissError();
        }
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _listening = false;
          _error = e is VoiceException ? e.friendlyText : '语音识别失败';
        });
        _autoDismissError();
      },
    );
  }

  Future<void> _startDesktop() async {
    final scope = AppScope.read(context);
    if (!scope.settings.voiceDesktopConfigured) {
      throw VoiceException(VoiceErrorCode.notConfigured);
    }
    final recorder = _recorder = VoiceRecorder();
    await recorder.start();
    _levelSub = recorder.level.listen((dbfs) {
      if (!mounted) return;
      setState(() => _level = dbfs);
    });
    // 静音自动结束：record 的电平流驱动 VAD（与 core 的 SilenceVad 同阈值）。
    final vad = SilenceVad();
    _vadSub = recorder.level.listen((dbfs) {
      if (vad.feed(dbfs, DateTime.now())) {
        _finishManual();
      }
    });
    // 从未出声的兜底：8s 无声自动取消。
    _noSpeechTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && _listening && !vad.heardSpeech) {
        _finishManual();
      }
    });
  }

  Future<void> _finishManual() async {
    if (!_listening) return;
    _noSpeechTimer?.cancel();
    if (Platform.isAndroid) {
      // Android：流式，最终结果由 onResult isFinal 给出；这里只停止拾音。
      setState(() => _listening = false);
      return;
    }
    final recorder = _recorder;
    _recorder = null;
    _levelSub?.cancel();
    _levelSub = null;
    _vadSub?.cancel();
    _vadSub = null;
    setState(() => _listening = false);
    if (recorder == null) return;
    final path = await recorder.stop();
    if (path == null || !mounted) return;
    final scope = AppScope.read(context);
    try {
      final text = await OpenAiSpeechBackend().transcribeFile(
        path,
        baseUrl: scope.settings.voiceBaseUrl!,
        apiKey: scope.settings.voiceApiKey!,
        model: scope.settings.voiceModel,
      );
      if (mounted && text.trim().isNotEmpty) {
        _emit(text.trim());
      } else if (mounted) {
        setState(() => _error = '没听清内容，再说一次试试');
        _autoDismissError();
      }
    } on VoiceException catch (e) {
      if (mounted) {
        setState(() => _error = e.friendlyText);
        _autoDismissError();
      }
    } finally {
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
  }

  void _emit(String text) {
    setState(() {
      _listening = false;
      _partial = null;
    });
    widget.onText(text.trim());
  }

  void _autoDismissError() {
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _error = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_error != null) {
      return Tooltip(
        message: _error,
        triggerMode: TooltipTriggerMode.tap,
        child: Icon(Icons.error_outline, size: 22, color: theme.colorScheme.error),
      );
    }
    if (_listening) {
      final loudness = (( _level + 60) / 60).clamp(0.15, 1.0);
      return Tooltip(
        message: _partial ?? '正在聆听…（静音 1.5 秒自动结束，再点一次立即结束）',
        triggerMode: TooltipTriggerMode.tap,
        child: GestureDetector(
          onTap: _toggle,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.85, end: 0.85 + loudness * 0.35)
                .animate(_pulse),
            child: Icon(Icons.graphic_eq,
                size: 24, color: theme.colorScheme.primary),
          ),
        ),
      );
    }
    return IconButton(
      tooltip: '语音输入',
      icon: Icon(Icons.mic_none, size: 22, color: widget.color),
      onPressed: _toggle,
    );
  }
}
