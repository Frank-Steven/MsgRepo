import 'package:shared_preferences/shared_preferences.dart';

/// 未处理消息达到该数量时自动提交 AI 处理。
///
/// 默认 400；用户可在设置里改（合作者 2026-10-18：「这个参数其实可以放出来给用户调」）。
/// 上限 500 = 消息页单次加载上限，超过它页面根本数不到那么多未处理。
const int kAutoProcessThreshold = 400;
const int kAutoProcessThresholdMin = 100;
const int kAutoProcessThresholdMax = 500;

/// 单次自动触发最多取多少条（**等价于不限制**：20000 条远超实际积压）。
///
/// 用户 2026-10-20 明确要求去掉每批限制：触发一次就把所有未处理一次提交，
/// 由自动确认统一落库。真正的安全阀是 [kAutoProcessMaxBatches]（防计数不降死循环）。
const int kAutoProcessBatchSize = 20000;

/// 一次自动触发**连续处理**的防御性批数上限。
///
/// 触发一次会一直往下清（每批 kAutoProcessBatchSize 条），直到未处理数低于阈值；
/// 这个数字只是防止异常情况（比如计数不降）下无限跑，正常情况下远达不到：
/// 1000 批 × 500 条 = 50 万条，实际永远先因为「低于阈值」而停。
const int kAutoProcessMaxBatches = 1000;

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
