import 'dart:convert';

import 'package:crypto/crypto.dart';

int? asIntOrNull(dynamic v) => v == null ? null : (v as num).toInt();

double asDouble(dynamic v) => (v as num).toDouble();

List<String> asStringList(dynamic v) =>
    v == null ? const [] : (v as List).map((e) => e.toString()).toList();

/// SHA-256(packageName|title|body|postedAt)，两端去重的统一算法。
String computeContentHash(
    String packageName, String title, String body, int postedAt) {
  return sha256
      .convert(utf8.encode('$packageName|$title|$body|$postedAt'))
      .toString();
}

String formatMillis(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

/// 附件访问方式，对齐 raw-message.schema.json 的 access 对象。
class AttachmentAccess {
  static const typeLocalPath = 'local_path';
  static const typeContentUri = 'content_uri';
  static const typeUrl = 'url';
  static const typeAppDeeplink = 'app_deeplink';
  static const typeMiniprogramPath = 'miniprogram_path';

  final String type;
  final String value;
  final String? mimeType;

  const AttachmentAccess({required this.type, required this.value, this.mimeType});

  factory AttachmentAccess.fromJson(Map<String, dynamic> json) =>
      AttachmentAccess(
        type: json['type'] as String,
        value: json['value'] as String,
        mimeType: json['mimeType'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'type': type,
        'value': value,
        if (mimeType != null) 'mimeType': mimeType,
      };
}

class Attachment {
  static const kindImage = 'image';
  static const kindFile = 'file';
  static const kindMiniprogram = 'miniprogram';
  static const kindLink = 'link';
  static const kindOther = 'other';

  final String id;
  final String kind;
  final String? label;
  final AttachmentAccess access;

  const Attachment({
    required this.id,
    required this.kind,
    this.label,
    required this.access,
  });

  factory Attachment.fromJson(Map<String, dynamic> json) => Attachment(
        id: json['id'] as String,
        kind: json['kind'] as String,
        label: json['label'] as String?,
        access:
            AttachmentAccess.fromJson(json['access'] as Map<String, dynamic>),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        if (label != null) 'label': label,
        'access': access.toJson(),
      };
}

class MessageSource {
  final String packageName;
  final String? appName;
  final String? channelId;
  final String? conversationTitle;
  final String? sender;

  const MessageSource({
    required this.packageName,
    this.appName,
    this.channelId,
    this.conversationTitle,
    this.sender,
  });

  factory MessageSource.fromJson(Map<String, dynamic> json) => MessageSource(
        packageName: json['packageName'] as String,
        appName: json['appName'] as String?,
        channelId: json['channelId'] as String?,
        conversationTitle: json['conversationTitle'] as String?,
        sender: json['sender'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'packageName': packageName,
        if (appName != null) 'appName': appName,
        if (channelId != null) 'channelId': channelId,
        if (conversationTitle != null) 'conversationTitle': conversationTitle,
        if (sender != null) 'sender': sender,
      };
}

/// 原始消息，对齐 raw-message.schema.json。
class RawMessage {
  static const captureNotification = 'notification';
  static const captureManual = 'manual';

  static const statusPending = 'pending';
  static const statusProcessed = 'processed';
  static const statusArchived = 'archived';

  final String id;
  final MessageSource source;
  final String title;
  final String body;
  final int postedAt;
  final String captureType;
  final List<Attachment> attachments;
  final String contentHash;
  String status;

  /// 本地标记（不属于 schema）：从已处理回退时置 1，
  /// 下次同步放入 reprocessMessageIds 让电脑端跳过去重。
  bool needsReprocess;

  RawMessage({
    required this.id,
    required this.source,
    required this.title,
    required this.body,
    required this.postedAt,
    required this.captureType,
    this.attachments = const [],
    required this.contentHash,
    this.status = statusPending,
    this.needsReprocess = false,
  });

  factory RawMessage.fromJson(Map<String, dynamic> json) => RawMessage(
        id: json['id'] as String,
        source: MessageSource.fromJson(json['source'] as Map<String, dynamic>),
        title: json['title'] as String,
        body: json['body'] as String,
        postedAt: (json['postedAt'] as num).toInt(),
        captureType: json['captureType'] as String,
        attachments: (json['attachments'] as List? ?? [])
            .map((e) => Attachment.fromJson(e as Map<String, dynamic>))
            .toList(),
        contentHash: json['contentHash'] as String,
        status: json['status'] as String? ?? statusPending,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'source': source.toJson(),
        'title': title,
        'body': body,
        'postedAt': postedAt,
        'captureType': captureType,
        'attachments': attachments.map((e) => e.toJson()).toList(),
        'contentHash': contentHash,
        'status': status,
      };
}

/// 统一时间语义，对齐 structured-item.schema.json 的 time 对象。
class ItemTime {
  static const kindNone = 'none';
  static const kindPoint = 'point';
  static const kindRange = 'range';
  static const kindDeadline = 'deadline';
  static const kindRecurring = 'recurring';

  final String kind;
  final int? startAt;
  final int? endAt;
  final int? deadline;
  final String? rrule;

  /// 提醒提前量（分钟）。
  final List<int> reminderOffsets;

  const ItemTime({
    required this.kind,
    this.startAt,
    this.endAt,
    this.deadline,
    this.rrule,
    this.reminderOffsets = const [],
  });

  factory ItemTime.fromJson(Map<String, dynamic> json) => ItemTime(
        kind: json['kind'] as String,
        startAt: asIntOrNull(json['startAt']),
        endAt: asIntOrNull(json['endAt']),
        deadline: asIntOrNull(json['deadline']),
        rrule: json['rrule'] as String?,
        reminderOffsets: (json['reminderOffsets'] as List? ?? [])
            .map((e) => (e as num).toInt())
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'kind': kind,
        if (startAt != null) 'startAt': startAt,
        if (endAt != null) 'endAt': endAt,
        if (deadline != null) 'deadline': deadline,
        if (rrule != null) 'rrule': rrule,
        'reminderOffsets': reminderOffsets,
      };

  ItemTime copyWith({
    String? kind,
    int? Function()? startAt,
    int? Function()? endAt,
    int? Function()? deadline,
    String? Function()? rrule,
    List<int>? reminderOffsets,
  }) =>
      ItemTime(
        kind: kind ?? this.kind,
        startAt: startAt != null ? startAt() : this.startAt,
        endAt: endAt != null ? endAt() : this.endAt,
        deadline: deadline != null ? deadline() : this.deadline,
        rrule: rrule != null ? rrule() : this.rrule,
        reminderOffsets: reminderOffsets ?? this.reminderOffsets,
      );

  /// 用于提醒调度的基准时刻。
  int? get baseTime {
    switch (kind) {
      case kindPoint:
      case kindRange:
        return startAt;
      case kindDeadline:
        return deadline;
      default:
        return null;
    }
  }
}

class ProcessedBy {
  final String provider;
  final String? model;
  final String pipelineVersion;

  const ProcessedBy({
    required this.provider,
    this.model,
    required this.pipelineVersion,
  });

  factory ProcessedBy.fromJson(Map<String, dynamic> json) => ProcessedBy(
        provider: json['provider'] as String,
        model: json['model'] as String?,
        pipelineVersion: json['pipelineVersion'] as String,
      );

  Map<String, dynamic> toJson() => {
        'provider': provider,
        if (model != null) 'model': model,
        'pipelineVersion': pipelineVersion,
      };
}

/// 结构化结果，对齐 structured-item.schema.json。
class StructuredItem {
  final String id;
  final List<String> rawMessageIds;
  final String category;
  final String schemaVersion;
  final String title;
  final String summary;
  final String priority; // P0 | P1 | P2 | P3
  final double confidence;
  final ItemTime time;
  final Map<String, dynamic> payload;
  final List<String> tags;
  final ProcessedBy processedBy;

  const StructuredItem({
    required this.id,
    required this.rawMessageIds,
    required this.category,
    required this.schemaVersion,
    required this.title,
    required this.summary,
    required this.priority,
    required this.confidence,
    required this.time,
    required this.payload,
    this.tags = const [],
    required this.processedBy,
  });

  factory StructuredItem.fromJson(Map<String, dynamic> json) =>
      StructuredItem(
        id: json['id'] as String,
        rawMessageIds: asStringList(json['rawMessageIds']),
        category: json['category'] as String,
        schemaVersion: json['schemaVersion'] as String,
        title: json['title'] as String,
        summary: json['summary'] as String,
        priority: json['priority'] as String,
        confidence: asDouble(json['confidence']),
        time: ItemTime.fromJson(json['time'] as Map<String, dynamic>),
        payload: (json['payload'] as Map?)?.cast<String, dynamic>() ?? {},
        tags: asStringList(json['tags']),
        processedBy:
            ProcessedBy.fromJson(json['processedBy'] as Map<String, dynamic>),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'rawMessageIds': rawMessageIds,
        'category': category,
        'schemaVersion': schemaVersion,
        'title': title,
        'summary': summary,
        'priority': priority,
        'confidence': confidence,
        'time': time.toJson(),
        'payload': payload,
        'tags': tags,
        'processedBy': processedBy.toJson(),
      };

  StructuredItem copyWith({
    String? title,
    ItemTime? time,
    Map<String, dynamic>? payload,
  }) =>
      StructuredItem(
        id: id,
        rawMessageIds: rawMessageIds,
        category: category,
        schemaVersion: schemaVersion,
        title: title ?? this.title,
        summary: summary,
        priority: priority,
        confidence: confidence,
        time: time ?? this.time,
        payload: payload ?? this.payload,
        tags: tags,
        processedBy: processedBy,
      );
}

class CategoryDefinition {
  final String key;
  final String displayName;
  final String description;
  final String baseKind; // specialized | generic
  final String defaultPriority;
  final String? priorityHints;
  final String? timeHints;
  final Map<String, dynamic> payloadSchema;

  const CategoryDefinition({
    required this.key,
    required this.displayName,
    required this.description,
    required this.baseKind,
    required this.defaultPriority,
    this.priorityHints,
    this.timeHints,
    required this.payloadSchema,
  });

  factory CategoryDefinition.fromJson(Map<String, dynamic> json) =>
      CategoryDefinition(
        key: json['key'] as String,
        displayName: json['displayName'] as String,
        description: json['description'] as String,
        baseKind: json['baseKind'] as String,
        defaultPriority: json['defaultPriority'] as String,
        priorityHints: json['priorityHints'] as String?,
        timeHints: json['timeHints'] as String?,
        payloadSchema:
            (json['payloadSchema'] as Map?)?.cast<String, dynamic>() ?? {},
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'displayName': displayName,
        'description': description,
        'baseKind': baseKind,
        'defaultPriority': defaultPriority,
        if (priorityHints != null) 'priorityHints': priorityHints,
        if (timeHints != null) 'timeHints': timeHints,
        'payloadSchema': payloadSchema,
      };
}

/// 分类注册表，对齐 category-registry.schema.json。
class CategoryRegistry {
  final String version;
  final List<CategoryDefinition> categories;

  const CategoryRegistry({required this.version, required this.categories});

  factory CategoryRegistry.fromJson(Map<String, dynamic> json) =>
      CategoryRegistry(
        version: json['version'] as String,
        categories: (json['categories'] as List? ?? [])
            .map((e) => CategoryDefinition.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'version': version,
        'categories': categories.map((e) => e.toJson()).toList(),
      };

  CategoryDefinition? byKey(String key) {
    for (final c in categories) {
      if (c.key == key) return c;
    }
    return null;
  }

  String displayNameOf(String key) => byKey(key)?.displayName ?? key;
}

/// 实际类别标签：todo 按时间语义细分（普通/时间点/时间段任务），
/// schedule 区分时间点/时间段，其余分类用注册表 displayName。
String itemKindLabel(StructuredItem item, CategoryRegistry? registry) {
  if (item.category == 'todo') {
    return switch (item.time.kind) {
      ItemTime.kindNone => '普通任务',
      ItemTime.kindPoint => '时间点任务',
      ItemTime.kindRange => '时间段任务',
      _ => '任务',
    };
  }
  if (item.category == 'schedule') {
    return switch (item.time.kind) {
      ItemTime.kindPoint => '时间点',
      ItemTime.kindRange => '时间段',
      _ => registry?.displayNameOf(item.category) ?? item.category,
    };
  }
  return registry?.displayNameOf(item.category) ?? item.category;
}

/// POST /v1/sync 请求体，对齐 sync-request.schema.json。
class SyncRequest {
  final String deviceId;
  final String registryVersion;
  final CategoryRegistry? registry;

  /// 用户自定义提示词，电脑端追加到 AI 系统提示词末尾。可选。
  final String? customPrompt;

  /// 强制重处理的消息 ID（回退的消息），电脑端跳过 contentHash 去重。可选。
  final List<String>? reprocessMessageIds;

  /// true 时请求电脑端以 NDJSON 流式逐条返回结果。
  final bool stream;

  final List<RawMessage> messages;

  const SyncRequest({
    required this.deviceId,
    required this.registryVersion,
    this.registry,
    this.customPrompt,
    this.reprocessMessageIds,
    this.stream = false,
    required this.messages,
  });

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'registryVersion': registryVersion,
        if (registry != null) 'registry': registry!.toJson(),
        if (customPrompt != null && customPrompt!.isNotEmpty)
          'customPrompt': customPrompt,
        if (reprocessMessageIds != null && reprocessMessageIds!.isNotEmpty)
          'reprocessMessageIds': reprocessMessageIds,
        if (stream) 'stream': true,
        'messages': messages.map((e) => e.toJson()).toList(),
      };
}

/// POST /v1/sync 响应体，对齐 sync-response.schema.json。
class SyncResponse {
  final String registryVersion;
  final List<StructuredItem> results;
  final List<String> processedMessageIds;
  final List<String> failedMessageIds;
  final List<String> warnings;

  const SyncResponse({
    required this.registryVersion,
    required this.results,
    required this.processedMessageIds,
    this.failedMessageIds = const [],
    this.warnings = const [],
  });

  factory SyncResponse.fromJson(Map<String, dynamic> json) => SyncResponse(
        registryVersion: json['registryVersion'] as String,
        results: (json['results'] as List? ?? [])
            .map((e) => StructuredItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        processedMessageIds: asStringList(json['processedMessageIds']),
        failedMessageIds: asStringList(json['failedMessageIds']),
        warnings: asStringList(json['warnings']),
      );
}
