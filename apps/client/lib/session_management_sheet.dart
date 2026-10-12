import 'pirc_localizations.dart';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'pirc_controller.dart';
import 'pirc_theme.dart';

Future<void> showSessionManagementSheet(
  BuildContext context,
  PircController model,
  SessionView session,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: context.pircColors.surface,
  shape: const RoundedRectangleBorder(borderRadius: PircRadii.dialog),
  clipBehavior: Clip.antiAlias,
  builder: (_) => SessionManagementSheet(model: model, session: session),
);

class SessionManagementSheet extends StatefulWidget {
  const SessionManagementSheet({
    super.key,
    required this.model,
    required this.session,
  });
  final PircController model;
  final SessionView session;
  @override
  State<SessionManagementSheet> createState() => _SessionManagementSheetState();
}

class _SessionManagementSheetState extends State<SessionManagementSheet> {
  bool saving = false;
  String? error;
  SessionView get current =>
      widget.model.sessions
          .where((s) => s.instance == widget.session.instance)
          .firstOrNull ??
      widget.session;

  Future<void> exit() async {
    if (saving || widget.model.exitDisabledReason(current) != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AnimatedBuilder(
        animation: widget.model,
        builder: (_, _) {
          final reason = widget.model.exitDisabledReason(current);
          return AlertDialog(
            key: const Key('exit-session-confirmation'),
            title: Text(context.l10n.exitSessionQuestion),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.exitSessionDescription(
                      current.sessionName ?? context.l10n.unnamedSession,
                    ),
                  ),
                  if (reason != null) ...[
                    const SizedBox(height: PircSpacing.s12),
                    Text(
                      context.localize(reason),
                      style: context.pircText.hint.copyWith(
                        color: context.pirc.warning,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(context.l10n.cancel),
              ),
              FilledButton(
                key: const Key('confirm-exit-session'),
                onPressed: reason == null
                    ? () => Navigator.pop(dialogContext, true)
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: context.pircColors.error,
                  foregroundColor: context.pircColors.onError,
                ),
                child: Text(context.l10n.exitSession),
              ),
            ],
          );
        },
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.model.exitSession(current);
      if (mounted) Navigator.pop(context);
    } catch (failure) {
      if (mounted) {
        setState(() => error = '$failure'.replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.model,
    builder: (_, _) {
      final session = current;
      final reason = widget.model.exitDisabledReason(session);
      final enabled = !saving && reason == null;
      final color = enabled
          ? context.pircColors.error
          : context.pircColors.onSurfaceVariant.withValues(
              alpha: PircLayout.inactiveOpacity,
            );
      return Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: PircLayout.maxContentWidth,
            maxHeight:
                MediaQuery.sizeOf(context).height *
                PircLayout.sheetHeightFactor,
          ),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(PircSpacing.s20),
              child: Column(
                key: const Key('session-management'),
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          context.l10n.sessionManagement,
                          style: context.pircText.section,
                        ),
                      ),
                      IconButton(
                        tooltip: context.l10n.closeMenu,
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(
                          LucideIcons.x,
                          size: PircIconSizes.chevron,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: PircSpacing.s12),
                  Text(
                    session.sessionName ?? context.l10n.unnamedSession,
                    style: context.pircText.cardTitle,
                  ),
                  const SizedBox(height: PircSpacing.s6),
                  Text(session.cwd, style: context.pircText.path),
                  const SizedBox(height: PircSpacing.s16),
                  const Divider(),
                  const SizedBox(height: PircSpacing.s8),
                  ListTile(
                    key: const Key('exit-session'),
                    enabled: enabled,
                    shape: const RoundedRectangleBorder(
                      borderRadius: PircRadii.button,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: PircSpacing.s12,
                    ),
                    leading: saving
                        ? const SizedBox(
                            width: PircIconSizes.toolbar,
                            height: PircIconSizes.toolbar,
                            child: CircularProgressIndicator(
                              strokeWidth: PircLayout.loadingStrokeWidth,
                            ),
                          )
                        : Icon(
                            LucideIcons.logOut,
                            color: color,
                            size: PircIconSizes.toolbar,
                          ),
                    title: Text(
                      saving ? context.l10n.exiting : context.l10n.exitSession,
                      style: context.pircText.action.copyWith(color: color),
                    ),
                    subtitle: Text(
                      saving
                          ? context.l10n.exitPendingDescription
                          : reason == null
                          ? context.l10n.exitActionDescription
                          : context.localize(reason),
                      style: context.pircText.hint,
                    ),
                    onTap: enabled ? exit : null,
                  ),
                  if (error != null) ...[
                    const SizedBox(height: PircSpacing.s12),
                    Text(
                      context.localize(error!),
                      key: const Key('exit-session-error'),
                      style: context.pircText.hint.copyWith(
                        color: context.pirc.warning,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
