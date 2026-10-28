import 'dart:convert';

import '../services/assistant/models.dart';

/// v3 助理对话的 DB 行模型（design-v3 §1.4 conversations / chat_messages 表）。
/// 契约层（请求/流式事件）模型在 services/assistant/models.dart；
/// ChangeProposal 直接复用那边的定义，row 映射在 database.dart。

class ChatMessageStatus {
  static const streaming = 'streaming';
  static const done = 'done';
  static const error = 'error';
}

/// 对话：独立上下文、独立模型配置（可后改）。
class Conversation {
  final String id;
  final String title;

  /// 该对话绑定的模型配置（可切换）。
  final String? modelConfigId;
  final int createdAt;
  final int updatedAt;

  const Conversation({
    required this.id,
    required this.title,
    this.modelConfigId,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Conversation.fromRow(Map<String, Object?> row) => Conversation(
        id: row['id'] as String,
        title: row['title'] as String,
        modelConfigId: row['model_config_id'] as String?,
        createdAt: (row['created_at'] as num).toInt(),
        updatedAt: (row['updated_at'] as num).toInt(),
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'title': title,
        'model_config_id': modelConfigId,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  Conversation copyWith({
    String? id,
    String? title,
    String? Function()? modelConfigId,
    int? createdAt,
    int? updatedAt,
  }) =>
      Conversation(
        id: id ?? this.id,
        title: title ?? this.title,
        modelConfigId:
            modelConfigId != null ? modelConfigId() : this.modelConfigId,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// 对话内的一条消息（chat_messages 表行）。
class ChatMessage {
  final String id;
  final String conversationId;

  /// ChatRole.user / assistant / tool。
  final String role;
  final String content;

  /// 引用的库实体附件（仅引用，content 为 null；请求时再展开正文）。
  final List<ChatAttachment> attachments;

  /// ChatMessageStatus.streaming / done / error。
  final String status;
  final int createdAt;

  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    this.attachments = const [],
    this.status = ChatMessageStatus.done,
    required this.createdAt,
  });

  factory ChatMessage.fromRow(Map<String, Object?> row) => ChatMessage(
        id: row['id'] as String,
        conversationId: row['conversation_id'] as String,
        role: row['role'] as String,
        content: row['content'] as String,
        attachments: row['attachments'] == null
            ? const []
            : (jsonDecode(row['attachments'] as String) as List)
                .map((e) => ChatAttachment.fromJson(e as Map<String, dynamic>))
                .toList(),
        status: row['status'] as String,
        createdAt: (row['created_at'] as num).toInt(),
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'conversation_id': conversationId,
        'role': role,
        'content': content,
        'attachments':
            jsonEncode(attachments.map((e) => e.toJson()).toList()),
        'status': status,
        'created_at': createdAt,
      };

  ChatMessage copyWith({
    String? id,
    String? conversationId,
    String? role,
    String? content,
    List<ChatAttachment>? attachments,
    String? status,
    int? createdAt,
  }) =>
      ChatMessage(
        id: id ?? this.id,
        conversationId: conversationId ?? this.conversationId,
        role: role ?? this.role,
        content: content ?? this.content,
        attachments: attachments ?? this.attachments,
        status: status ?? this.status,
        createdAt: createdAt ?? this.createdAt,
      );
}
