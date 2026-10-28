import 'package:flutter/material.dart';

import '../../models/conversation.dart';
import '../../services/assistant/assistant_service.dart';
import '../../services/assistant/models.dart';
import '../../services/database.dart';
import 'approvals_page.dart';
import 'attachment_picker.dart';
import 'model_picker.dart';

/// 对话页（design-v3 §5.1）：流式渲染、附件 chip、工具调用提案卡片内联
/// （摘要 + 跳待确认区）、streaming/error 状态展示。
class ChatPage extends StatefulWidget {
  final Conversation conversation;

  const ChatPage({super.key, required this.conversation});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  List<ChatMessage> _messages = [];

  /// assistant 消息 id → 该回合落库的提案（内联卡片）。
  Map<String, List<ChangeProposal>> _proposalsByBatch = {};

  /// 当前回合的流式状态：null = 空闲。
  String? _streamingText;
  String? _streamingMessageId;
  String? _errorText;
  List<ChatAttachment> _pendingAttachments = [];
  late Conversation _conversation;

  bool get _busy => _streamingMessageId != null;

  @override
  void initState() {
    super.initState();
    _conversation = widget.conversation;
    _reload();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final db = AppDatabase.instance;
    final messages = await db.getChatMessages(_conversation.id);
    final proposals = await db.proposalsForConversation(_conversation.id);
    final byBatch = <String, List<ChangeProposal>>{};
    for (final p in proposals) {
      if (p.batchId != null) byBatch.putIfAbsent(p.batchId!, () => []).add(p);
    }
    final conv = await db.getConversationById(_conversation.id);
    if (!mounted) return;
    setState(() {
      _messages = messages;
      _proposalsByBatch = byBatch;
      if (conv != null) _conversation = conv;
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _pickAttachments() async {
    final picked = await Navigator.of(context).push<List<ChatAttachment>>(
      MaterialPageRoute(
          builder: (_) => AttachmentPickerPage(selected: _pendingAttachments)),
    );
    if (picked != null && mounted) {
      setState(() => _pendingAttachments = picked);
    }
  }

  Future<void> _switchModel() async {
    final selected = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ModelPickerPage(
          selectionMode: true,
          currentModelConfigId: _conversation.modelConfigId,
        ),
      ),
    );
    if (selected == null || !mounted) return;
    await AppDatabase.instance
        .setConversationModel(_conversation.id, selected.isEmpty ? null : selected);
    await _reload();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    _input.clear();
    final attachments = List<ChatAttachment>.of(_pendingAttachments);
    setState(() {
      _pendingAttachments = [];
      _streamingText = '';
      _errorText = null;
    });

    final stream = AssistantService.instance.sendTurn(
      conversation: _conversation,
      text: text,
      attachments: attachments,
    );
    // 用户消息落库后立即刷新列表，再消费流
    await _reload();
    setState(() => _streamingMessageId = 'pending');
    await for (final ev in stream) {
      if (!mounted) return;
      switch (ev) {
        case AssistantTextDelta():
          setState(() => _streamingText = ev.fullText);
          _scrollToBottom();
        case AssistantProposalCreated():
          await _reload();
        case AssistantToolMessage():
          await _reload();
        case AssistantTurnDone():
          break;
        case AssistantTurnError():
          setState(() => _errorText = ev.message);
      }
    }
    if (!mounted) return;
    setState(() {
      _streamingMessageId = null;
      _streamingText = null;
    });
    await _reload();
  }

  void _cancel() {
    AssistantService.instance.cancelActive();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_conversation.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '待确认区',
            icon: const Icon(Icons.fact_check_outlined),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ApprovalsPage()),
              );
              await _reload();
            },
          ),
          TextButton(
            onPressed: _busy ? null : _switchModel,
            child: Text(
              _conversation.modelConfigId == null
                  ? '默认模型'
                  : _conversation.modelConfigId!.length > 12
                      ? '${_conversation.modelConfigId!.substring(0, 12)}…'
                      : _conversation.modelConfigId!,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.all(12),
              children: [
                for (final m in _messages) ..._buildMessage(m, cs),
                if (_busy) _buildStreaming(cs),
                if (_errorText != null) _buildError(cs),
              ],
            ),
          ),
          if (_pendingAttachments.isNotEmpty) _buildAttachmentBar(cs),
          _buildInputBar(cs),
        ],
      ),
    );
  }

  List<Widget> _buildMessage(ChatMessage m, ColorScheme cs) {
    final isUser = m.role == ChatRole.user;
    final isTool = m.role == ChatRole.tool;
    final widgets = <Widget>[
      Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(10),
          constraints: const BoxConstraints(maxWidth: 560),
          decoration: BoxDecoration(
            color: isTool
                ? cs.surfaceContainerHighest
                : isUser
                    ? cs.primaryContainer
                    : cs.secondaryContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isTool)
                Text('工具结果',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              Text(m.content),
              if (m.status == ChatMessageStatus.error)
                Text('（本回合出错）',
                    style: TextStyle(fontSize: 11, color: cs.error)),
              if (m.attachments.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final a in m.attachments)
                        Chip(
                          visualDensity: VisualDensity.compact,
                          label: Text('${a.type}:${_short(a.id)}',
                              style: const TextStyle(fontSize: 11)),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    ];
    // 提案卡片内联：挂在产出它们的 assistant 消息后面
    final proposals = _proposalsByBatch[m.id];
    if (proposals != null) {
      for (final p in proposals) {
        widgets.add(_buildProposalCard(p, cs));
      }
    }
    return widgets;
  }

  Widget _buildProposalCard(ChangeProposal p, ColorScheme cs) {
    final (icon, label) = switch (p.status) {
      ProposalStatus.pending => (Icons.hourglass_top, '待审批'),
      ProposalStatus.applied => (Icons.check_circle_outline, '已生效'),
      ProposalStatus.rejected => (Icons.block, '已拒绝'),
      ProposalStatus.failed => (Icons.error_outline, '失败'),
      _ => (Icons.hourglass_top, p.status),
    };
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        dense: true,
        leading: Icon(icon, size: 20),
        title: Text(p.summary,
            maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13)),
        subtitle: Text('${p.tool} · $label',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
        trailing: p.status == ProposalStatus.pending
            ? TextButton(
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ApprovalsPage()),
                  );
                  await _reload();
                },
                child: const Text('去审批'),
              )
            : null,
      ),
    );
  }

  Widget _buildStreaming(ColorScheme cs) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(10),
        constraints: const BoxConstraints(maxWidth: 560),
        decoration: BoxDecoration(
          color: cs.secondaryContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if ((_streamingText ?? '').isNotEmpty) Text(_streamingText!),
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError(ColorScheme cs) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text('回合出错：$_errorText',
            style: TextStyle(fontSize: 12, color: cs.error)),
      );

  Widget _buildAttachmentBar(ColorScheme cs) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final a in _pendingAttachments)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: InputChip(
                label: Text('${a.type}:${_short(a.id)}',
                    style: const TextStyle(fontSize: 11)),
                onDeleted: () =>
                    setState(() => _pendingAttachments.remove(a)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildInputBar(ColorScheme cs) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          children: [
            IconButton(
              tooltip: '添加附件（笔记/消息/文件）',
              icon: const Icon(Icons.attach_file),
              onPressed: _busy ? null : _pickAttachments,
            ),
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: '和助理说点什么…',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: _busy ? '取消' : '发送',
              icon: Icon(_busy ? Icons.stop_circle_outlined : Icons.send),
              onPressed: _busy ? _cancel : _send,
            ),
          ],
        ),
      ),
    );
  }

  static String _short(String id) => id.length <= 6 ? id : id.substring(0, 6);
}
