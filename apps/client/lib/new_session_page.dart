import 'pirc_localizations.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'pirc_controller.dart';
import 'pirc_theme.dart';
import 'pirc_loading.dart';
import 'remote_directory_picker.dart';

class NewSessionPage extends StatefulWidget {
  const NewSessionPage({super.key, required this.model, this.computerName});
  final PircController model;
  final String? computerName;
  @override
  State<NewSessionPage> createState() => _NewSessionPageState();
}

class _NewSessionPageState extends State<NewSessionPage> {
  final cwd = TextEditingController();
  final search = TextEditingController();
  List<SavedSession> sessions = [];
  bool loading = true;
  bool launching = false;
  String? error;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(refresh);
    load();
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.model.removeListener(refresh);
    cwd.dispose();
    search.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final catalog = await widget.model.loadSavedSessions();
      if (!mounted) return;
      setState(() {
        sessions = catalog.sessions;
        if (cwd.text.isEmpty) cwd.text = catalog.defaultCwd;
      });
    } catch (failure) {
      if (mounted) {
        setState(() => error = '$failure'.replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> launch([SavedSession? session]) async {
    if (launching ||
        widget.model.connection != 'connected' ||
        (session == null && cwd.text.trim().isEmpty)) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      launching = true;
      error = null;
    });
    String? name;
    if (session == null) {
      final entered = await showDialog<String>(
        context: context,
        builder: (_) => const _CreationNameDialog(),
      );
      if (!mounted) return;
      if (entered == null) {
        setState(() => launching = false);
        return;
      }
      name = entered.isEmpty ? null : entered;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final failureText = ValueNotifier<String?>(null);
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ValueListenableBuilder<String?>(
        valueListenable: failureText,
        builder: (context, failure, _) => PopScope(
          canPop: failure != null,
          child: Dialog(
            key: const Key('session-launch-dialog'),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: PircLayout.dialogWidth,
              ),
              child: Padding(
                padding: const EdgeInsets.all(PircSpacing.s24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (failure == null)
                      PircLoading(
                        title: session == null
                            ? context.l10n.creatingConversation
                            : context.l10n.restoringConversation,
                        detail: session == null
                            ? context.l10n.waitingForNewSession
                            : context.l10n.waitingForRestoredSession,
                      )
                    else ...[
                      Text(
                        context.l10n.sessionNotConfirmed,
                        style: context.pircText.cardTitle,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: PircSpacing.s12),
                      Text(
                        context.localize(failure),
                        style: context.pircText.hint,
                        textAlign: TextAlign.center,
                      ),
                    ],
                    if (failure != null) ...[
                      const SizedBox(height: PircSpacing.s20),
                      FilledButton(
                        key: const Key('dismiss-session-launch-error'),
                        onPressed: () => Navigator.pop(context),
                        child: Text(context.l10n.gotIt),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final closed = navigator.push(route);
    try {
      final instance = await widget.model
          .launchSession(
            session?.cwd ?? cwd.text.trim(),
            sessionId: session?.id,
            name: name,
          )
          .timeout(
            const Duration(seconds: 60),
            onTimeout: () => throw StateError(
              'Timed out waiting for the session. The terminal may already be open. Check the device and refresh the session list before creating another session.',
            ),
          );
      if (route.isActive) navigator.removeRoute(route);
      if (mounted) Navigator.pop(context, instance);
    } catch (failure) {
      failureText.value = '$failure'.replaceFirst('Bad state: ', '');
      await closed;
    } finally {
      if (route.isActive) navigator.removeRoute(route);
      await route.completed;
      failureText.dispose();
      if (mounted) setState(() => launching = false);
    }
  }

  Future<void> browse() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final selected = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => RemoteDirectoryPicker(
          model: widget.model,
          initialPath: cwd.text.trim(),
          computerName: widget.computerName,
        ),
      ),
    );
    if (mounted && selected != null) setState(() => cwd.text = selected);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = !launching && widget.model.connection == 'connected';
    final online = widget.model.onlineSessions.map((s) => s.session).toSet();
    final query = search.text.trim().toLowerCase();
    final saved = sessions
        .where(
          (s) =>
              !online.contains(s.id) &&
              '${s.name?.isNotEmpty == true ? s.name : context.l10n.unnamedSession} ${s.cwd}'
                  .toLowerCase()
                  .contains(query),
        )
        .toList();
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: PircLayout.maxContentWidth),
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              key: const Key('new-session-back'),
              tooltip: context.l10n.back,
              onPressed: () => Navigator.pop(context),
              icon: const Icon(LucideIcons.arrowLeft),
            ),
            title: Text(
              context.l10n.newConversation,
              style: context.pircText.cardTitle,
            ),
          ),
          body: SafeArea(
            top: false,
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.all(PircSpacing.s20),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          context.l10n.startConversation,
                          style: context.pircText.section,
                        ),
                        const SizedBox(height: PircSpacing.s8),
                        Text(
                          context.l10n.chooseDirectoryDescription,
                          style: context.pircText.hint,
                        ),
                        const SizedBox(height: PircSpacing.s16),
                        TextField(
                          key: const Key('new-session-cwd'),
                          controller: cwd,
                          enabled: !launching,
                          decoration: InputDecoration(
                            labelText: context.l10n.workingDirectory,
                            hintText: '/Users/…/project',
                            prefixIcon: const Icon(LucideIcons.folder),
                            suffixIcon: IconButton(
                              key: const Key('browse-remote-directory'),
                              tooltip: context.l10n.browseDeviceDirectories,
                              color: context.pircColors.primary,
                              onPressed: enabled ? browse : null,
                              icon: const Icon(
                                LucideIcons.folderOpen,
                                size: PircIconSizes.toolbar,
                              ),
                            ),
                          ),
                          textInputAction: TextInputAction.done,
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) => launch(),
                        ),
                        const SizedBox(height: PircSpacing.s12),
                        FilledButton.icon(
                          key: const Key('launch-new-session'),
                          onPressed: enabled && cwd.text.trim().isNotEmpty
                              ? () => launch()
                              : null,
                          icon: const Icon(
                            LucideIcons.plus,
                            size: PircIconSizes.small,
                          ),
                          label: Text(context.l10n.createConversation),
                        ),
                        if (error != null) ...[
                          const SizedBox(height: PircSpacing.s12),
                          Text(
                            context.localize(error!),
                            key: const Key('new-session-error'),
                            style: context.pircText.hint.copyWith(
                              color: context.pirc.warning,
                            ),
                          ),
                        ],
                        const SizedBox(height: PircSpacing.s28),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                context.l10n.restoreHistory,
                                style: context.pircText.section,
                              ),
                            ),
                            IconButton(
                              key: const Key('refresh-saved-sessions'),
                              tooltip: context.l10n.refreshHistory,
                              onPressed: loading || !enabled ? null : load,
                              icon: const Icon(
                                LucideIcons.refreshCw,
                                size: PircIconSizes.chevron,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          context.l10n.restoreDescription,
                          style: context.pircText.hint,
                        ),
                        const SizedBox(height: PircSpacing.s12),
                        TextField(
                          key: const Key('saved-session-search'),
                          controller: search,
                          decoration: InputDecoration(
                            hintText: context.l10n.searchHistory,
                            prefixIcon: Icon(LucideIcons.search),
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ],
                    ),
                  ),
                ),
                if (loading)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(PircSpacing.s24),
                      child: PircLoading(
                        title: context.l10n.loadingHistory,
                        detail: context.l10n.readingSavedConversations,
                      ),
                    ),
                  )
                else if (saved.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(PircSpacing.s24),
                      child: Center(
                        child: Text(
                          error != null
                              ? context.l10n.historyLoadFailed
                              : query.isNotEmpty
                              ? context.l10n.noMatchingHistory
                              : context.l10n.noSavedHistory,
                          style: context.pircText.hint,
                        ),
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(
                      PircSpacing.s20,
                      0,
                      PircSpacing.s20,
                      PircSpacing.s24,
                    ),
                    sliver: SliverList.separated(
                      itemCount: saved.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: PircSpacing.s10),
                      itemBuilder: (_, index) => _SavedSessionTile(
                        session: saved[index],
                        onTap: enabled ? () => launch(saved[index]) : null,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SavedSessionTile extends StatelessWidget {
  const _SavedSessionTile({required this.session, required this.onTap});
  final SavedSession session;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final date = session.modified;
    String two(int value) => value.toString().padLeft(2, '0');
    return Material(
      color: context.pircColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: PircRadii.session,
        side: BorderSide(
          color: context.pircColors.outlineVariant,
          width: PircLayout.borderWidth,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('restore-${session.id}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(PircSpacing.s16),
          child: Row(
            children: [
              Icon(
                LucideIcons.history,
                size: PircIconSizes.session,
                color: context.pircColors.onSurfaceVariant,
              ),
              const SizedBox(width: PircSpacing.s13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.name?.isNotEmpty == true
                          ? session.name!
                          : context.l10n.unnamedSession,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.pircText.cardTitle,
                    ),
                    const SizedBox(height: PircSpacing.s6),
                    Text(
                      session.cwd,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.pircText.path,
                    ),
                    const SizedBox(height: PircSpacing.s6),
                    Text(
                      '${date.year}/${two(date.month)}/${two(date.day)} ${two(date.hour)}:${two(date.minute)}',
                      style: context.pircText.path,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: PircSpacing.s8),
              Icon(
                LucideIcons.rotateCcw,
                size: PircIconSizes.chevron,
                color: context.pircColors.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreationNameDialog extends StatefulWidget {
  const _CreationNameDialog();

  @override
  State<_CreationNameDialog> createState() => _CreationNameDialogState();
}

class _CreationNameDialogState extends State<_CreationNameDialog> {
  final name = TextEditingController();

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  void submit() => Navigator.pop(context, name.text.trim());

  @override
  Widget build(BuildContext context) => Dialog(
    key: const Key('create-session-name-dialog'),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: PircLayout.dialogWidth),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(PircSpacing.s24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.l10n.newConversationName,
              style: context.pircText.cardTitle,
            ),
            const SizedBox(height: PircSpacing.s16),
            TextField(
              key: const Key('create-session-name'),
              controller: name,
              autofocus: true,
              maxLength: 256,
              buildCounter:
                  (
                    _, {
                    required currentLength,
                    required isFocused,
                    maxLength,
                  }) => currentLength < 224
                  ? null
                  : Text(
                      '$currentLength/$maxLength',
                      style: context.pircText.hint,
                    ),
              decoration: InputDecoration(
                hintText: context.l10n.unnamedSession,
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => submit(),
            ),
            const SizedBox(height: PircSpacing.s20),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: PircSpacing.s8,
              runSpacing: PircSpacing.s8,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(context.l10n.cancel),
                ),
                FilledButton(
                  key: const Key('confirm-create-session'),
                  onPressed: submit,
                  child: Text(context.l10n.create),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
