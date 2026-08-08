import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 动作音效（轻提示音，播放失败静默）
enum SoundKind { add, complete, reopen, delete, click, drop, skip }

final soundServiceProvider = Provider<SoundService>(
  (ref) => SoundService.instance,
);

/// 音量分级（UX 改进计划第三批）：
/// 轻交互更轻、完成/拖放稍响，替代 v1 统一 0.9
const Map<SoundKind, double> _volumeOf = {
  SoundKind.add: 0.7,
  SoundKind.complete: 0.85,
  SoundKind.reopen: 0.7,
  SoundKind.delete: 0.6,
  SoundKind.click: 0.5,
  SoundKind.drop: 0.8,
  SoundKind.skip: 0.65,
};

/// 音效池大小：快速连续操作时轮换播放器，互不截断
const int _poolSize = 3;

class SoundService {
  SoundService._();

  static final SoundService instance = SoundService._();

  /// 测试环境关闭（widget 测试无插件）
  static bool enabled = true;

  /// 音效总开关（设置页可关，启动时从数据库加载）
  static bool soundsEnabled = true;

  /// 音效池：多个播放器轮换，避免单播放器前置 stop 截断快速连按的音效
  final List<AudioPlayer?> _pool = List.generate(
    _poolSize,
    (_) => _createPlayerSafely(),
  );
  int _roundRobin = 0;

  /// 惰性安全创建：无音频插件的环境（测试/桌面）创建失败时静默降级为 null，
  /// 并通过 stop() 同步挂接 creatingCompleter 的监听，避免创建失败成为
  /// 未处理异步错误
  static AudioPlayer? _createPlayerSafely() {
    try {
      final p = AudioPlayer();
      unawaited(p.stop().catchError((_) {}));
      return p;
    } catch (_) {
      return null;
    }
  }

  bool _disposed = false;

  static String _asset(SoundKind kind) => switch (kind) {
    SoundKind.add => 'sounds/add.wav',
    SoundKind.complete => 'sounds/complete.wav',
    SoundKind.reopen => 'sounds/reopen.wav',
    SoundKind.delete => 'sounds/delete.wav',
    SoundKind.click => 'sounds/click.wav',
    SoundKind.drop => 'sounds/drop.wav',
    SoundKind.skip => 'sounds/skip.wav',
  };

  Future<void> play(SoundKind kind) async {
    if (!enabled || !soundsEnabled || _disposed) return;
    final pool = _pool.whereType<AudioPlayer>().toList();
    if (pool.isEmpty) return;
    // 轮换取一个空闲播放器；不前置 stop（避免截断上一音）
    final player = pool[_roundRobin % pool.length];
    _roundRobin++;
    try {
      await player.play(
        AssetSource(_asset(kind)),
        volume: _volumeOf[kind] ?? 0.7,
      );
    } catch (_) {
      // 无声播放环境（测试/模拟器无声卡）静默
    }
  }

  void dispose() {
    _disposed = true;
    for (final p in _pool) {
      unawaited(p?.dispose());
    }
  }
}
