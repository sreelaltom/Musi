import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class MusiSearchBar extends StatelessWidget {
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onClear;
  final VoidCallback? onTap;
  final bool readOnly;
  final bool autofocus;
  final String hintText;

  const MusiSearchBar({
    super.key,
    this.controller,
    this.onChanged,
    this.onSubmitted,
    this.onClear,
    this.onTap,
    this.readOnly = false,
    this.autofocus = false,
    this.hintText = 'Search songs, artists, albums...',
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2A2E3D), width: 0.8),
      ),
      child: TextField(
        controller: controller,
        readOnly: readOnly,
        autofocus: autofocus,
        onTap: onTap,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        style: const TextStyle(color: AppTheme.textPrimary, fontSize: 15),
        cursorColor: AppTheme.accent,
        decoration: InputDecoration(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
          prefixIcon: const Icon(
            Icons.search_rounded,
            color: AppTheme.textMuted,
            size: 22,
          ),
          suffixIcon: (controller?.text.isNotEmpty ?? false)
              ? IconButton(
                  icon: const Icon(
                    Icons.close_rounded,
                    color: AppTheme.textMuted,
                    size: 18,
                  ),
                  onPressed: onClear,
                )
              : null,
          hintText: hintText,
          hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 14),
          border: InputBorder.none,
        ),
      ),
    );
  }
}
