import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/app_filter_service.dart';

/// v2.5：应用采集过滤三态（all/allowlist/blacklist）解析与放行判定。
/// 判定语义与 Kotlin NotificationCaptureService.isAllowed 镜像；
/// 配置缺失/损坏一律按全放行（向后兼容，绝不能让默认状态抓不到消息）。
void main() {
  group('AppFilterConfig 解析', () {
    test('缺省/损坏配置 → all 全放行', () {
      expect(const AppFilterConfig().mode, AppFilterConfig.modeAll);
      expect(AppFilterConfig.fromJson(const {}).mode, AppFilterConfig.modeAll);
      expect(AppFilterConfig.fromJson(const {'mode': 'weird'}).allows('a.b.c'),
          isTrue);
    });

    test('三态 round-trip 保持', () {
      for (final mode in [
        AppFilterConfig.modeAll,
        AppFilterConfig.modeAllowlist,
        AppFilterConfig.modeBlacklist,
      ]) {
        final cfg = AppFilterConfig(mode: mode, packages: const ['com.a']);
        final back = AppFilterConfig.fromJson(cfg.toJson());
        expect(back.mode, mode);
        expect(back.packages, ['com.a']);
      }
    });
  });

  group('allows 放行判定', () {
    const listed = AppFilterConfig(
        mode: AppFilterConfig.modeAllowlist,
        packages: ['com.tencent.mm', 'com.tencent.mobileqq']);
    const blocked = AppFilterConfig(
        mode: AppFilterConfig.modeBlacklist, packages: ['com.promo.app']);

    test('allowlist：名单内放行，名单外拦截；空名单全拦截', () {
      expect(listed.allows('com.tencent.mm'), isTrue);
      expect(listed.allows('com.other'), isFalse);
      expect(
          const AppFilterConfig(mode: AppFilterConfig.modeAllowlist)
              .allows('com.tencent.mm'),
          isFalse);
    });

    test('blacklist：名单内拦截，名单外放行；空名单全放行', () {
      expect(blocked.allows('com.promo.app'), isFalse);
      expect(blocked.allows('com.tencent.mm'), isTrue);
      expect(
          const AppFilterConfig(mode: AppFilterConfig.modeBlacklist)
              .allows('com.tencent.mm'),
          isTrue);
    });

    test('all：全放行', () {
      expect(const AppFilterConfig().allows('anything'), isTrue);
    });
  });
}
