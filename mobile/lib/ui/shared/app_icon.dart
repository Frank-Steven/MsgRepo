import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../services/app_icon_service.dart';

/// 来源应用图标（v2.4）：异步加载 PackageManager 图标（内存+磁盘缓存），
/// 加载中/无图标显示应用名首字符占位块。
class AppIcon extends StatefulWidget {
  final String packageName;
  final String? appName;
  final double size;

  const AppIcon({
    super.key,
    required this.packageName,
    this.appName,
    this.size = 18,
  });

  @override
  State<AppIcon> createState() => _AppIconState();
}

class _AppIconState extends State<AppIcon> {
  Uint8List? _bytes;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AppIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.packageName != widget.packageName) {
      _loaded = false;
      _bytes = null;
      _load();
    }
  }

  Future<void> _load() async {
    final bytes = await AppIconService.instance.iconFor(widget.packageName);
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    if (_bytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.22),
        child: Image.memory(
          _bytes!,
          width: size,
          height: size,
          gaplessPlayback: true,
        ),
      );
    }
    if (!_loaded) {
      return SizedBox(width: size, height: size);
    }
    final cs = Theme.of(context).colorScheme;
    final name = (widget.appName?.isNotEmpty == true
        ? widget.appName!
        : widget.packageName);
    final label = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(size * 0.22),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: size * 0.55, color: cs.onSurfaceVariant),
      ),
    );
  }
}
