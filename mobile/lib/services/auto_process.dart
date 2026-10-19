import 'package:shared_preferences/shared_preferences.dart';

/// 未处理消息达到该数量时自动提交 AI 处理。
///
/// 默认 400；用户可在设置里改（合作者 2026-10-18：「这个参数其实可以放出来给用户调」）。
/// 上限 500 = 消息页单次加载上限，超过它页面根本数不到那么多未处理。
const int kAutoProcessThreshold = 400;
const int kAutoProcessThresholdMin = 100;
const int kAutoProcessThresholdMax = 500;

/// 每轮自动处理的消息上限。
///
/// 不能一次把几千条全塞给模型：单轮耗时与额度都不可控，且失败面更大。
/// 与消息页单次加载上限（500）解耦——积压再多，一轮也只处理这么多，
/// 冷却结束后下一轮接着清（最早优先）。
const int kAutoProcessBatchSize = 500;

/// 把阈值夹到合法区间（设置页与读取处共用，便于单测）。
int clampAutoProcessThreshold(int value) =>
    value.clamp(kAutoProcessThresholdMin, kAutoProcessThresholdMax);

/// 两次自动处理之间的最小间隔：避免「处理完又堆到 400」时反复触发。
const Duration kAutoProcessCooldown = Duration(minutes: 10);

/// 是否应该自动提交处理（纯函数，便于单测）。
///
/// 条件：未处理数 ≥ 阈值、当前没有在处理、距上次自动触发已过冷却时间。
bool shouldAutoProcess({
  required int pendingCount,
  required bool alreadyProcessing,
  required int? lastAutoAtMs,
  required int nowMs,
  int threshold = kAutoProcessThreshold,
  Duration cooldown = kAutoProcessCooldown,
}) {
  if (pendingCount < threshold) return false;
  if (alreadyProcessing) return false;
  if (lastAutoAtMs != null && nowMs - lastAutoAtMs < cooldown.inMilliseconds) {
    return false;
  }
  return true;
}

/// 自动处理的触发时间（持久化，避免重启 App 后立刻重复触发）。
class AutoProcessState {
  static const _key = 'auto_process_last_at';
  static const _keyEnabled = 'auto_process_enabled';
  static const _keyThreshold = 'auto_process_threshold';

  /// 自动处理总开关（默认开）。
  static Future<bool> enabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyEnabled) ?? true;
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnabled, value);
  }

  /// 未处理阈值（默认 400，范围 100~500）。
  static Future<int> threshold() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt(_keyThreshold);
    return clampAutoProcessThreshold(v ?? kAutoProcessThreshold);
  }

  static Future<void> setThreshold(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyThreshold, clampAutoProcessThreshold(value));
  }

  static Future<int?> lastRunAt() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_key);
  }

  static Future<void> markRun(int nowMs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, nowMs);
  }
}
