import 'pirc_localizations.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'pirc_controller.dart';
import 'pirc_theme.dart';

class SessionSettingsBar extends StatelessWidget {
  const SessionSettingsBar({
    super.key,
    required this.session,
    required this.enabled,
    required this.onSelect,
    this.loadingCommand,
  });
  final SessionView session;
  final bool enabled;
  final String? loadingCommand;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final model = session.currentModel;
    final modelName = model?['name'] as String? ?? model?['id'] as String?;
    final modelValue = session.controls == null
        ? context.l10n.notSynced
        : modelName ?? context.l10n.notSelected;
    final level = session.thinkingLevel;
    final thinkingValue = level ?? context.l10n.notSynced;
    return LayoutBuilder(
      builder: (context, constraints) {
        final thinkingWidth = math.max(
          PircLayout.settingMinSize,
          _labelWidth(context, thinkingValue) + _SettingButton.chromeWidth,
        );
        // Leave a recognizable model name visible before switching to two rows.
        final modelMinWidth = math.max(
          PircLayout.settingMinSize,
          math.min(
                _labelWidth(context, modelValue),
                _labelWidth(context, 'MMMMMM'),
              ) +
              _SettingButton.chromeWidth,
        );
        final modelButton = _SettingButton(
          key: const Key('session-model'),
          icon: LucideIcons.cpu,
          loading: loadingCommand == 'model',
          label: modelValue,
          tooltip: model == null
              ? context.l10n.currentModel(modelValue)
              : context.l10n.currentModelDetails(
                  modelName!,
                  model['provider'].toString(),
                  model['id'].toString(),
                ),
          onTap: enabled && session.supportsBuiltin('model')
              ? () => onSelect('model')
              : null,
        );
        final thinkingButton = _SettingButton(
          key: const Key('session-thinking'),
          icon: LucideIcons.sparkles,
          loading: loadingCommand == 'thinking',
          label: thinkingValue,
          tooltip: level == null
              ? context.l10n.thinkingNotSynced
              : context.l10n.currentThinking(level),
          onTap: enabled && model != null && session.supportsBuiltin('thinking')
              ? () => onSelect('thinking')
              : null,
        );
        if (modelMinWidth + PircSpacing.s8 + thinkingWidth >
            constraints.maxWidth) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [modelButton, thinkingButton],
          );
        }
        return Row(
          children: [
            Expanded(child: modelButton),
            const SizedBox(width: PircSpacing.s8),
            SizedBox(width: thinkingWidth, child: thinkingButton),
          ],
        );
      },
    );
  }

  double _labelWidth(BuildContext context, String value) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: context.pircText.description),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
}

class _SettingButton extends StatelessWidget {
  const _SettingButton({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    this.onTap,
    this.loading = false,
  });
  static const chromeWidth =
      PircSpacing.s6 * 4 + PircIconSizes.activity + PircIconSizes.notice;
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onTap;
  final bool loading;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: Colors.transparent,
      borderRadius: PircRadii.input,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: PircRadii.input,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: PircLayout.settingMinSize,
            minHeight: PircLayout.settingMinSize,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: PircSpacing.s6,
              vertical: PircSpacing.s8,
            ),
            child: Row(
              children: [
                if (loading)
                  SizedBox(
                    key: Key(
                      'builtin-loading-${icon == LucideIcons.cpu ? 'model' : 'thinking'}',
                    ),
                    width: PircIconSizes.activity,
                    height: PircIconSizes.activity,
                    child: CircularProgressIndicator(
                      strokeWidth: PircLayout.loadingStrokeWidth,
                    ),
                  )
                else
                  Icon(
                    icon,
                    size: PircIconSizes.activity,
                    color: context.pircColors.onSurfaceVariant,
                  ),
                const SizedBox(width: PircSpacing.s6),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.pircText.description.copyWith(
                      color: onTap == null
                          ? context.pircColors.onSurfaceVariant
                          : context.pircColors.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: PircSpacing.s6),
                Icon(
                  LucideIcons.chevronDown,
                  size: PircIconSizes.notice,
                  color: context.pircColors.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
