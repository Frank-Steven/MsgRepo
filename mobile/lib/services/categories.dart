/// AI 评估提示词的分类参考（设计 §8.2）：内置精简列表，
/// 内容源自 shared/registry/default.json 的核心条目，只保留拼提示词所需字段。
library;

class PromptCategory {
  final String key;
  final String displayName;
  final String description;
  final String? priorityHints;

  const PromptCategory({
    required this.key,
    required this.displayName,
    required this.description,
    this.priorityHints,
  });
}

/// 分类参考列表（辅助模型判断重要性与垃圾）。
const kPromptCategories = [
  PromptCategory(
    key: 'schedule',
    displayName: '日程',
    description: '有明确开始时间的事件：会议、约会、航班、火车、演出、预约等。',
    priorityHints: '开始时间在24小时内且不可错过（航班/会议）则 P0；一般 P1；例行提醒 P2',
  ),
  PromptCategory(
    key: 'todo',
    displayName: '待办',
    description: '需要本人执行的动作：缴费、回复、提交材料、取快递、抢票等。',
    priorityHints: '有截止时间且临近则 P0/P1；无明确时间 P2；可做可不做 P3',
  ),
  PromptCategory(
    key: 'note',
    displayName: '笔记',
    description: '值得留存但无需行动的信息：地址、账号、推荐、知识点、他人发的有用内容等。',
    priorityHints: '通常 P3；用户手动添加的笔记可为 P2',
  ),
  PromptCategory(
    key: 'express',
    displayName: '快递物流',
    description: '快递收发、物流状态：到达待取、已揽收、派送中等。',
    priorityHints: '到达待取 P1；在途 P3',
  ),
  PromptCategory(
    key: 'bill',
    displayName: '账单缴费',
    description: '水电煤、话费、信用卡还款等账单通知。',
    priorityHints: '临近最后期限 P0；常规出账 P1',
  ),
  PromptCategory(
    key: 'coupon',
    displayName: '优惠营销',
    description: '优惠券、促销、活动推送、直播开播提醒等营销类通知，多为低价值信息。',
    priorityHints: '几乎总是 P3；用户常关注的品牌且有明确截止时间可 P2',
  ),
  PromptCategory(
    key: 'verification',
    displayName: '验证码',
    description: '一次性验证码、动态口令。',
    priorityHints: '收到时总是 P0（即时使用），过期后无价值',
  ),
  PromptCategory(
    key: 'generic',
    displayName: '未分类',
    description: '兜底分类：无法归入其他任何分类时使用。',
    priorityHints: '默认 P2',
  ),
];
