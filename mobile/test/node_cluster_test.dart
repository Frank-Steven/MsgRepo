import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/ui/schedule/layout.dart';

/// U11 回归：时间几乎重合的节点要聚成一组（画一个点 + 合并标题）。
void main() {
  List<NodePos> nodes(List<(String, double, double)> raw) => [
        for (final (id, x, y) in raw) (id: id, x: x, y: y),
      ];

  test('两个点几乎重合 → 合成一组', () {
    final groups = clusterOverlappingNodes(nodes([
      ('a', 100.0, 50.0),
      ('b', 102.0, 50.5),
    ]));
    expect(groups.length, 1);
    expect(groups.single, ['a', 'b']);
  });

  test('相距较远 → 各自成组', () {
    final groups = clusterOverlappingNodes(nodes([
      ('a', 100.0, 50.0),
      ('b', 200.0, 50.0),
    ]));
    expect(groups.length, 2);
  });

  test('同一时刻但不同泳道（y 差大）→ 不合并', () {
    final groups = clusterOverlappingNodes(nodes([
      ('a', 100.0, 50.0),
      ('b', 100.0, 80.0),
    ]));
    expect(groups.length, 2);
  });

  test('三个点一簇，组内保持输入顺序、组间按 x 升序', () {
    final groups = clusterOverlappingNodes(nodes([
      ('b', 300.0, 10.0),
      ('a1', 100.0, 10.0),
      ('a2', 103.0, 11.0),
    ]));
    expect(groups.length, 2);
    expect(groups[0], ['a1', 'a2']);
    expect(groups[1], ['b']);
  });

  test('空输入安全', () {
    expect(clusterOverlappingNodes(const []), isEmpty);
  });
}
