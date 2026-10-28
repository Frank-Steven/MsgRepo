import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../models/conversation.dart';
import '../database.dart';
import 'assistant_client.dart';
import 'models.dart';
import 'proposal_executor.dart';
import 'proposal_service.dart';
import 'tool_parser.dart';
import 'tool_spec.dart';

/// 助理回合的流式事件（chat_page 渲染用；proposal_flow_test 也直接驱动它）。
sealed class AssistantEvent {
  const AssistantEvent();
}

/// 可见文本增量（工具块内容不含在内）。
class AssistantTextDelta extends AssistantEvent {
  final String delta;

  /// 截至目前的完整可见文本。
  final String fullText;
  const AssistantTextDelta(this.delta, this.fullText);
}

/// 一条提案已落待确认区（对话页内联提案卡片即时出现）。
class AssistantProposalCreated extends AssistantEvent {
  final ChangeProposal proposal;
  const AssistantProposalCreated(this.proposal);
}

/// 工具块校验失败 / 只读工具结果：已回注对话为 tool 消息。
class AssistantToolMessage extends AssistantEvent {
  final String content;
  const AssistantToolMessage(this.content);
}

/// 回合正常结束。
class AssistantTurnDone extends AssistantEvent {
  const AssistantTurnDone();
}

/// 回合失败（通道错误等）。
class AssistantTurnError extends AssistantEvent {
  final String message;
  const AssistantTurnError(this.message);
}

/// 助理编排服务（design-v3 §5.4）：
/// 组装请求（对话历史 + 附件正文内联展开 + tool_spec 说明书）→
/// AssistantClient 通道 → tool_parser 流式解析 → proposal_service 落提案。
class AssistantService {
  AssistantService._();

  static final AssistantService instance = AssistantService._();

  static const _uuid = Uuid();

  /// 通道（测试可替换为指向 mock server 的实例配置）。
  AssistantClient client = AssistantClient.instance;

  // ---- 对话管理 ----

  Future<Conversation> createConversation({String? modelConfigId}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final conv = Conversation(
      id: _uuid.v4(),
      title: '新对话',
      modelConfigId: modelConfigId,
      createdAt: now,
      updatedAt: now,
    );
    await AppDatabase.instance.insertConversation(conv);
    return conv;
  }

  // ---- 附件展开（design-v3 §3.6：请求前展开为上下文块） ----

  static const _attachmentMaxChars = 8000;

  /// 把消息级附件引用展开为带引用头的正文块（[#note:标题] 等）。
  /// 文件仅对文本类做正文抽取（截断），二进制只给名称与 mime。
  Future<List<ChatAttachment>> expandAttachments(
      List<ChatAttachment> refs) async {
    final db = AppDatabase.instance;
    final out = <ChatAttachment>[];
    for (final ref in refs) {
      switch (ref.type) {
        case ChatAttachmentType.note:
          final note = await db.getNoteById(ref.id);
          if (note == null) break;
          out.add(ChatAttachment(
            type: ref.type,
            id: ref.id,
            content: _cap('[#note:${note.title}]\n${note.content}'),
          ));
        case ChatAttachmentType.message:
          final msg = await db.getMessageById(ref.id);
          if (msg == null) break;
          out.add(ChatAttachment(
            type: ref.type,
            id: ref.id,
            content: _cap('[#message:${msg.title}]\n${msg.body}'),
          ));
        case ChatAttachmentType.file:
          final file = await db.getFileById(ref.id);
          if (file == null) break;
          var header = '[#file:${file.name}]（${file.mimeType ?? '未知类型'}）';
          final mime = file.mimeType ?? '';
          if ((mime.startsWith('text/') || mime.endsWith('json')) &&
              (file.size ?? 0) < 256 * 1024) {
            try {
              final text = await File(file.localPath).readAsString();
              header = '$header\n$text';
            } catch (_) {
              // 读不出来就只给头部元信息
            }
          }
          out.add(ChatAttachment(
              type: ref.type, id: ref.id, content: _cap(header)));
      }
    }
    return out;
  }

  static String _cap(String text) => text.length > _attachmentMaxChars
      ? '${text.substring(0, _attachmentMaxChars)}…（已截断）'
      : text;

  // ---- 一轮对话 ----

  /// 发送用户消息并跑一轮助理回复。
  ///
  /// 流程：落用户消息（首条消息生成对话标题）→ 建 streaming 状态的
  /// assistant 占位消息 → 组装请求 → 流式消费 → 文本增量上屏、
  /// 工具块落提案/回注 → 结束时把可见文本与状态写回 assistant 消息。
  ///
  /// [conversation] 以调用时刻的快照为准（modelConfigId 取自它）。
  Stream<AssistantEvent> sendTurn({
    required Conversation conversation,
    required String text,
    List<ChatAttachment> attachments = const [],
  }) async* {
    final db = AppDatabase.instance;
    final now = DateTime.now().millisecondsSinceEpoch;

    final userMsg = ChatMessage(
      id: _uuid.v4(),
      conversationId: conversation.id,
      role: ChatRole.user,
      content: text,
      attachments: attachments,
      status: ChatMessageStatus.done,
      createdAt: now,
    );
    await db.insertChatMessage(userMsg);
    // 首条用户消息截断生成对话标题（design-v3 §1.4）
    if (conversation.title == '新对话') {
      final title = text.trim();
      await db.renameConversation(
          conversation.id,
          title.length > 20 ? '${title.substring(0, 20)}…' : title);
    }
    await db.touchConversation(conversation.id);

    final assistantMsg = ChatMessage(
      id: _uuid.v4(),
      conversationId: conversation.id,
      role: ChatRole.assistant,
      content: '',
      status: ChatMessageStatus.streaming,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await db.insertChatMessage(assistantMsg);

    // 请求消息序列：说明书前言（schema 的 role 枚举无 system，前言作为
    // 首条 user 消息注入，details §2.4 说明书由 mobile 组装）+ 历史
    // （streaming/error 占位与空消息不进上下文）。
    final history = (await db.getChatMessages(conversation.id))
        .where((m) =>
            m.id != assistantMsg.id &&
            m.status == ChatMessageStatus.done &&
            m.content.isNotEmpty)
        .map((m) => ChatMessageModel(
            role: m.role, content: m.content, attachments: m.attachments))
        .toList();
    final requestMessages = [
      ChatMessageModel(
          role: ChatRole.user,
          content: '[系统说明]\n${buildToolSpecPrompt(DateTime.now())}'),
      ...history,
    ];
    final expanded = await expandAttachments(attachments);

    final parser = ToolBlockParser();
    final visible = StringBuffer();
    var interrupted = false;
    String? errorText;

    Future<void> handleBlock(ParsedToolBlock block) async {
      final outcome = await ProposalService.instance.handleToolBlock(
        conversationId: conversation.id,
        batchId: assistantMsg.id,
        block: block,
      );
      switch (outcome) {
        case ProposalCreated():
          // 事件在下方 yield（闭包无法 yield，用队列中转）
          _pendingEvents.add(AssistantProposalCreated(outcome.proposal));
        case ProposalDuplicate():
          break; // 重放命中去重键：跳过
        case ProposalValidationFailure():
          final content = '一个动作未能理解，已跳过：${outcome.reason}';
          await ProposalExecutor.instance
              .reportToolMessage(conversation.id, content);
          _pendingEvents.add(AssistantToolMessage(content));
        case ReadToolResult():
          await ProposalExecutor.instance
              .reportToolMessage(conversation.id, outcome.text);
          _pendingEvents.add(AssistantToolMessage(outcome.text));
      }
    }

    try {
      await for (final ev in client.chat(
        conversationId: conversation.id,
        messages: requestMessages,
        attachments: expanded,
        modelConfigId: conversation.modelConfigId,
      )) {
        switch (ev) {
          case ChatTokenDelta():
            final res = parser.feed(ev.delta);
            if (res.text.isNotEmpty) {
              visible.write(res.text);
              yield AssistantTextDelta(res.text, visible.toString());
            }
            for (final block in res.blocks) {
              await handleBlock(block);
            }
          case ChatProposalEvent():
            // desktop 不透传 proposal 事件（提案由手机端落库）；忽略。
            break;
          case ChatDone():
            break;
          case ChatError():
            errorText = ev.error;
        }
        // 中转闭包产出的事件
        while (_pendingEvents.isNotEmpty) {
          yield _pendingEvents.removeAt(0);
        }
        if (errorText != null) break;
      }
    } catch (e) {
      errorText = '$e';
    }

    // 流收尾：未闭合块整体丢弃（details §2.2），尾行文本仍上屏
    final tail = parser.finish(interrupted: interrupted || errorText != null);
    if (tail.text.isNotEmpty) {
      visible.write(tail.text);
      yield AssistantTextDelta(tail.text, visible.toString());
    }
    for (final block in tail.blocks) {
      await handleBlock(block);
    }
    while (_pendingEvents.isNotEmpty) {
      yield _pendingEvents.removeAt(0);
    }

    if (errorText != null) {
      await db.updateChatMessageContent(assistantMsg.id, visible.toString());
      await db.updateChatMessageStatus(
          assistantMsg.id, ChatMessageStatus.error);
      yield AssistantTurnError(errorText);
      return;
    }
    await db.updateChatMessageContent(assistantMsg.id, visible.toString());
    await db.updateChatMessageStatus(assistantMsg.id, ChatMessageStatus.done);
    yield const AssistantTurnDone();
  }

  final List<AssistantEvent> _pendingEvents = [];

  /// 中断在途回合（未闭合工具块丢弃，已落库提案保留）。
  void cancelActive() => client.cancelActive();

  @visibleForTesting
  void debugReset() => _pendingEvents.clear();
}
