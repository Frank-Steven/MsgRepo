import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/auto_process.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// U19 回归：未处理达到阈值时自动提交处理的判定规则。
void main() {
  const now = 1700000000000;

  bool check({
    required int pending,
    bool processing = false,
    int? lastAt,
  }) =>
      shouldAutoProcess(
        pendingCount: pending,
        alreadyProcessing: processing,
        lastAutoAtMs: lastAt,
        nowMs: now,
      );

  test('阈值默认 400', () {
    expect(kAutoProcessThreshold, 400);
  });

  test('399 条不触发、400 条触发（边界）', () {
    expect(check(pending: 399), isFalse);
    expect(check(pending: 400), isTrue);
    expect(check(pending: 1000), isTrue);
  });

  test('正在处理时不重复触发', () {
    expect(check(pending: 500, processing: true), isFalse);
  });

  test('冷却期内不重复触发，冷却结束后可再触发', () {
    const cooldown = 10 * 60 * 1000;
    expect(check(pending: 500, lastAt: now - 1000), isFalse);
    expect(check(pending: 500, lastAt: now - cooldown + 1), isFalse);
    expect(check(pending: 500, lastAt: now - cooldown), isTrue);
    expect(check(pending: 500, lastAt: now - cooldown - 1), isTrue);
  });

  test('从未触发过 → 只要够数就触发', () {
    expect(check(pending: 400, lastAt: null), isTrue);
  });

  test('阈值可注入（便于将来做成设置项）', () {
    expect(
        shouldAutoProcess(
          pendingCount: 10,
          alreadyProcessing: false,
          lastAutoAtMs: null,
          nowMs: now,
          threshold: 10,
        ),
        isTrue);
  });

  test('触发时间可持久化（重启后仍受冷却约束）', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await AutoProcessState.lastRunAt(), isNull);
    await AutoProcessState.markRun(now);
    expect(await AutoProcessState.lastRunAt(), now);
  });
}
