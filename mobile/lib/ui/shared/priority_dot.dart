import 'package:flutter/material.dart';

import '../../models/task.dart';

/// 任务优先级圆点色（任务行/详情面板/日程视图/消息任务色点共用）。
Color taskPriorityDotColor(String priority) => switch (priority) {
      TaskPriority.important => Colors.red,
      TaskPriority.minor => Colors.green,
      _ => Colors.amber,
    };
