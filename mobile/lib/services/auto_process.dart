import 'package:shared_preferences/shared_preferences.dart';

/// 未处理消息达到该数量时自动提交 AI 处理（用户 2026-10-18 指定）。
const int kAutoProcessThreshold = 400;

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

  static Future<int?> lastRunAt() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_key);
  }

  static Future<void> markRun(int nowMs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, nowMs);
  }
}
