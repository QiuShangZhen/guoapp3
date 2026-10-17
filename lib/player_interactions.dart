import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

import 'widgets.dart';

class PlayerInteractions extends ChangeNotifier {
  PlayerInteractions({
    required this.player,
    required this.available,
    required this.baseSpeed,
    required this.onTogglePlayback,
    required this.onFullscreen,
    required this.onEpisode,
    this.onSeek,
  }) {
    _playing = player.stream.playing.listen((playing) {
      if (!playing) cancel();
    });
  }

  final Player player;
  final bool Function() available;
  final double Function() baseSpeed;
  final VoidCallback onTogglePlayback;
  final VoidCallback onFullscreen;
  final String Function(int direction) onEpisode;
  final Future<void> Function(Duration)? onSeek;
  late final StreamSubscription<bool> _playing;
  Timer? _holdTimer;
  Timer? _hintTimer;
  Future<void> _rates = Future<void>.value();
  final Set<int> _pointers = {};
  int? _pointer;
  Offset? _origin;
  Offset? _lastPosition;
  Duration _started = Duration.zero;
  double _swipeThreshold = 70;
  bool _swipeEnabled = false;
  bool _moved = false;
  bool _held = false;
  bool _boosting = false;
  bool _keyboardHold = false;
  /// 长按借速三档：上滑 5 倍、默认 3 倍、下滑 2 倍。
  static const double _boostBaseRate = 3;
  static const double _boostMaxRate = 5;
  static const double _boostMinRate = 2;
  /// 上下滑多少像素切到极值档。
  static const double _boostUpThreshold = 40;
  static const double _boostDownThreshold = 40;
  /// 横向拖动进度用的画布宽度与预览目标。
  double _width = 1;
  bool _seeking = false;
  Duration? _seekTarget;
  double _boostRate = _boostBaseRate;
  bool _cancelUntilRelease = false;
  bool _disposed = false;
  double _unmutedVolume = 100;
  String _feedback = '';
  bool _quiet = false;
  DateTime _ignoreTapUntil = DateTime(2000);

  String get feedback => _feedback;
  bool get boosting => _boosting;
  double get boostRate => _boostRate;
  bool get quietFeedback => _quiet;
  bool get suppressTap => DateTime.now().isBefore(_ignoreTapUntil);
  Future<void> get pendingRates => _rates;

  void hint(String message, {bool persistent = false, bool quiet = false}) {
    if (_disposed) return;
    _hintTimer?.cancel();
    _quiet = quiet;
    if (_feedback != message) {
      _feedback = message;
      notifyListeners();
    }
    if (!persistent && message.isNotEmpty) {
      _hintTimer = Timer(const Duration(milliseconds: 1200), () {
        hint(
          _boosting ? '3 倍速 · 松开恢复' : '',
          persistent: true,
          quiet: _boosting,
        );
      });
    }
  }

  Future<void> applySpeed() => _setRate(baseSpeed());

  Future<void> _setRate(double value) {
    _rates = _rates
        .catchError((Object _) {})
        .then((_) => player.setRate(value));
    unawaited(
      _rates.catchError((Object _) {
        hint('倍速调整失败，请重试');
      }),
    );
    return _rates;
  }

  void _beginHold({bool keyboard = false}) {
    if (!available() || _holdTimer != null || _boosting) return;
    _keyboardHold = keyboard;
    _holdTimer = Timer(const Duration(milliseconds: 350), () {
      _holdTimer = null;
      if (_disposed ||
          !available() ||
          !player.state.playing ||
          player.state.completed) {
        return;
      }
      _boosting = true;
      _held = true;
      _boostRate = _boostBaseRate;
      unawaited(_setRate(_boostRate));
      hint('3 倍速 · 松开恢复', persistent: true, quiet: true);
    });
  }

  void _endHold({bool tap = false, bool silent = false}) {
    final wasKeyboard = _keyboardHold;
    final boosted = _boosting;
    _holdTimer?.cancel();
    _holdTimer = null;
    _keyboardHold = false;
    _boosting = false;
    _boostRate = _boostBaseRate;
    if (boosted) {
      unawaited(_setRate(baseSpeed()));
      if (!silent) hint('', quiet: true);
    } else if (tap && wasKeyboard) {
      seek(5);
    }
  }

  void cancel() {
    if (_disposed) return;
    if (_pointers.isNotEmpty) {
      _cancelUntilRelease = true;
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    }
    _pointer = null;
    _origin = null;
    _lastPosition = null;
    _seeking = false;
    _seekTarget = null;
    _endHold(silent: true);
    hint('');
  }

  void pointerDown(
    PointerDownEvent event, {
    required bool swipeEnabled,
    required double height,
    required double width,
  }) {
    _pointers.add(event.pointer);
    if (_pointers.length != 1 || _cancelUntilRelease) {
      cancel();
      return;
    }
    if (!available() || event.buttons != kPrimaryButton) return;
    _pointer = event.pointer;
    _origin = _lastPosition = event.localPosition;
    _started = event.timeStamp;
    _swipeEnabled = swipeEnabled && event.kind == PointerDeviceKind.touch;
    _swipeThreshold = math.max(56, math.min(100, height * .1));
    _width = width;
    _seeking = false;
    _seekTarget = null;
    _moved = _held = false;
    _beginHold();
  }

  void pointerMove(PointerMoveEvent event) {
    if (_pointer != event.pointer || _origin == null) return;
    final delta = event.localPosition - _origin!;
    _lastPosition = event.localPosition;
    if (_boosting) {
      // 借速期间上下滑切档位，不再中断借速
      _adjustBoost(delta.dy);
      return;
    }
    if (!_seeking &&
        _swipeEnabled &&
        delta.dx.abs() > 24 &&
        delta.dx.abs() > delta.dy.abs() * 1.4) {
      // 横向为主：进入进度拖动，同时取消待触发的长按
      _seeking = true;
      _moved = true;
      _endHold();
    }
    if (_seeking) {
      _previewSeek(delta.dx);
      return;
    }
    if (delta.distance > 12) {
      _moved = true;
      _endHold();
    }
  }

  /// 横向拖动预览进度：满屏宽约合 120 秒（短剧一集刚好滑完），松手才真正跳转。
  void _previewSeek(double dx) {
    final duration = player.state.duration;
    if (duration <= Duration.zero) return;
    final width = _width.isFinite && _width > 0 ? _width : 1.0;
    final span = (duration.inSeconds * 0.5).clamp(30.0, 120.0).toDouble();
    final shift = (dx / width) * span;
    final target =
        player.state.position.inMilliseconds + (shift * 1000).round();
    final clamped = target.clamp(0, duration.inMilliseconds).toInt();
    _seekTarget = Duration(milliseconds: clamped);
    hint(
      '${shift >= 0 ? '快进至' : '后退至'} ${formatPosition(clamped / 1000)}',
      persistent: true,
      quiet: true,
    );
  }

  /// 三档借速：上滑到 5 倍、默认 3 倍、下滑到 2 倍。
  void _adjustBoost(double dy) {
    if (!_boosting) return;
    final double rate;
    if (dy <= -_boostUpThreshold) {
      rate = _boostMaxRate;
    } else if (dy >= _boostDownThreshold) {
      rate = _boostMinRate;
    } else {
      rate = _boostBaseRate;
    }
    if (rate == _boostRate) return;
    _boostRate = rate;
    unawaited(_setRate(rate));
    hint(
      '${formatBoostRate(rate)} 上滑加速 · 下滑减速',
      persistent: true,
      quiet: true,
    );
  }

  String formatBoostRate(double value) => value == value.roundToDouble()
      ? '${value.toStringAsFixed(0)}×'
      : '${value.toStringAsFixed(1)}×';

  void pointerUp(PointerUpEvent event) {
    _pointers.remove(event.pointer);
    if (_cancelUntilRelease) {
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
      if (_pointers.isEmpty) _cancelUntilRelease = false;
      return;
    }
    if (_pointer != event.pointer || _origin == null) return;
    if (_seeking) {
      final target = _seekTarget;
      _seeking = false;
      _seekTarget = null;
      _pointer = null;
      _origin = null;
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 400));
      hint('');
      if (target != null && available()) {
        unawaited((onSeek ?? player.seek)(target));
      }
      return;
    }
    final delta = (_lastPosition ?? event.localPosition) - _origin!;
    final swipe =
        _swipeEnabled &&
        !_held &&
        _moved &&
        delta.dy.abs() >= _swipeThreshold &&
        delta.dy.abs() > delta.dx.abs() * 1.5 &&
        event.timeStamp - _started < const Duration(milliseconds: 1500);
    if (_moved || _held) {
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    }
    _pointer = null;
    _origin = null;
    _endHold();
    if (swipe && available()) hint(onEpisode(delta.dy < 0 ? 1 : -1));
  }

  void pointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    cancel();
    _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    if (_pointers.isEmpty) _cancelUntilRelease = false;
  }

  void seek(int seconds) {
    if (!available() || player.state.duration <= Duration.zero) return;
    _endHold();
    final target = (player.state.position.inMilliseconds + seconds * 1000)
        .clamp(0, player.state.duration.inMilliseconds);
    unawaited((onSeek ?? player.seek)(Duration(milliseconds: target)));
    hint('${seconds > 0 ? '快进至' : '后退至'} ${formatPosition(target / 1000)}');
  }

  void changeVolume(double delta) {
    if (!available()) return;
    final volume = (player.state.volume + delta).clamp(0.0, 100.0);
    unawaited(player.setVolume(volume));
    if (volume > 0) _unmutedVolume = volume;
    hint(volume == 0 ? '已静音' : '音量 ${volume.round()}%');
  }

  void toggleMute() {
    if (!available()) return;
    final current = player.state.volume;
    if (current > 0) _unmutedVolume = current;
    final target = current > 0 ? 0.0 : _unmutedVolume;
    unawaited(player.setVolume(target));
    hint(target == 0 ? '已静音' : '音量 ${target.round()}%');
  }

  KeyEventResult key(KeyEvent event) {
    final key = event.logicalKey;
    if (event is KeyUpEvent) {
      if (key == LogicalKeyboardKey.arrowRight && _keyboardHold) {
        _endHold(tap: available());
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final hardware = HardwareKeyboard.instance;
    if (hardware.isAltPressed ||
        hardware.isMetaPressed ||
        hardware.isShiftPressed) {
      cancel();
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.f11 || key == LogicalKeyboardKey.keyF) {
      if (event is KeyDownEvent) {
        cancel();
        onFullscreen();
      }
      return KeyEventResult.handled;
    }
    if (hardware.isControlPressed || !available()) {
      return KeyEventResult.ignored;
    }
    if (key != LogicalKeyboardKey.arrowRight) _endHold();
    if (key == LogicalKeyboardKey.arrowRight) {
      if (event is KeyDownEvent) _beginHold(keyboard: true);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      seek(-5);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      changeVolume(5);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      changeVolume(-5);
    } else if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      if (event is KeyDownEvent) onTogglePlayback();
    } else if (key == LogicalKeyboardKey.keyM) {
      if (event is KeyDownEvent) toggleMute();
    } else if (key == LogicalKeyboardKey.mediaTrackNext ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      if (event is KeyDownEvent) {
        hint(onEpisode(key == LogicalKeyboardKey.mediaTrackNext ? 1 : -1));
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _disposed = true;
    _holdTimer?.cancel();
    _hintTimer?.cancel();
    if (_boosting) unawaited(_setRate(baseSpeed()));
    _boosting = false;
    _playing.cancel();
    _pointers.clear();
    super.dispose();
  }
}
