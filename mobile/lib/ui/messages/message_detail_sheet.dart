import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../../services/attachment_store.dart';

/// 消息详情面板（P3-2）：正文 + 附件预览。
///
/// 附件此前只有「访问方式」字符串、无处可看；现在图片直接显示缩略图（点击放大），
/// 其它类型显示名称与大小，路径不可读时如实说明「文件已不可用」而不是静默空白。
Future<void> showMessageDetail(BuildContext context, Message m) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.35,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scroll) => _MessageDetail(message: m, scroll: scroll),
    ),
  );
}

class _MessageDetail extends StatelessWidget {
  const _MessageDetail({required this.message, required this.scroll});

  final Message message;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final time = DateTime.fromMillisecondsSinceEpoch(message.postedAt);
    final meta = [
      message.appName ?? message.packageName,
      if (message.conversationTitle?.isNotEmpty == true) message.conversationTitle!,
      if (message.sender?.isNotEmpty == true) message.sender!,
      '${time.month}-${time.day} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
    ].join(' · ');

    return ListView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Text(message.title, style: tt.titleMedium),
        const SizedBox(height: 4),
        Text(meta,
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        const SizedBox(height: 12),
        SelectableText(
          message.body.isEmpty ? '（无正文）' : message.body,
          style: tt.bodyMedium,
        ),
        if (message.attachments.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('附件 ${message.attachments.length}',
              style: tt.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 8),
          for (final a in message.attachments) _attachment(context, a),
        ],
      ],
    );
  }

  Widget _attachment(BuildContext context, Attachment a) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final store = AttachmentStore.instance;
    final file = store.resolve(a);
    final isImage = a.kind == Attachment.kindImage;

    if (isImage && file != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: InkWell(
          onTap: () => _previewImage(context, file),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              file,
              height: 180,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  _attachmentRow(cs, tt, a, '图片无法解码'),
            ),
          ),
        ),
      );
    }
    return _attachmentRow(
        cs, tt, a, isImage ? '图片文件已不可用' : _describe(a));
  }

  Widget _attachmentRow(
      ColorScheme cs, TextTheme tt, Attachment a, String detail) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(_iconFor(a), size: 20, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.label ?? a.kind,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(detail,
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _describe(Attachment a) {
    final size = a.bytes;
    final sizeText = size == null ? '' : ' · ${_formatBytes(size)}';
    switch (a.access.type) {
      case AttachmentAccess.typeUrl:
        return '链接：${a.access.value}';
      case AttachmentAccess.typeMiniprogramPath:
        return '小程序：${a.access.value}';
      case AttachmentAccess.typeAppDeeplink:
        return '应用内跳转：${a.access.value}';
      default:
        return '本地文件$sizeText';
    }
  }

  IconData _iconFor(Attachment a) {
    switch (a.kind) {
      case Attachment.kindImage:
        return Icons.image_outlined;
      case Attachment.kindLink:
        return Icons.link;
      case Attachment.kindMiniprogram:
        return Icons.widgets_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  void _previewImage(BuildContext context, File file) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: InteractiveViewer(
          minScale: 0.8,
          maxScale: 4,
          child: Image.file(file, fit: BoxFit.contain),
        ),
      ),
    );
  }

  static String _formatBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
