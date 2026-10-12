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
  List<AgentInfo> agents = [];
  String? agentId;
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
        agents = catalog.agents;
        if (!agents.any((a) => a.id == agentId)) {
          agentId = agents.isEmpty ? null : agents.first.id;
        }
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
        (session == null && (agentId == null || cwd.text.trim().isEmpty))) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      launching = true;
      error = null;
    });
    String? name;
    var launchAgent = session?.agentId ?? agentId!;
    if (session == null) {
      final entered = await showDialog<({String name, String agentId})>(
        context: context,
        builder: (_) =>
            _CreationNameDialog(agents: agents, initialAgentId: launchAgent),
      );
      if (!mounted) return;
      if (entered == null) {
        setState(() => launching = false);
        return;
      }
      name = entered.name.isEmpty ? null : entered.name;
      launchAgent = entered.agentId;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final failureText = ValueNotifier<String?>(null);
    String? missingDirectory;
    Completer<bool>? createDecision;
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
                        missingDirectory == null
                            ? context.l10n.sessionNotConfirmed
                            : context.l10n.createWorkingDirectoryQuestion,
                        style: context.pircText.cardTitle,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: PircSpacing.s12),
                      Text(
                        missingDirectory == null
                            ? context.localize(failure)
                            : context.l10n.createWorkingDirectoryDescription,
                        style: context.pircText.hint,
                        textAlign: TextAlign.center,
                      ),
                    ],
                    if (missingDirectory != null) ...[
                      const SizedBox(height: PircSpacing.s12),
                      Text(
                        missingDirectory,
                        key: const Key('missing-working-directory'),
                        style: context.pircText.hint,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: PircSpacing.s20),
                      OverflowBar(
                        alignment: MainAxisAlignment.end,
                        spacing: PircSpacing.s8,
                        overflowSpacing: PircSpacing.s8,
                        children: [
                          TextButton(
                            onPressed: () {
                              if (createDecision?.isCompleted == false) {
                                createDecision?.complete(false);
                              }
                              Navigator.pop(context);
                            },
                            child: Text(context.l10n.cancel),
                          ),
                          FilledButton(
                            key: const Key('create-working-directory'),
                            onPressed: () {
                              if (createDecision?.isCompleted == false) {
                                createDecision?.complete(true);
                              }
                            },
                            child: Text(context.l10n.createAndContinue),
                          ),
                        ],
                      ),
                    ] else if (failure != null) ...[
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
      var createCwd = false;
      String? instance;
      while (instance == null) {
        try {
          instance = await widget.model
              .launchSession(
                session?.cwd ?? cwd.text.trim(),
                agentId: launchAgent,
                sessionId: session?.id,
                name: name,
                createCwd: createCwd,
              )
              .timeout(
                const Duration(seconds: 60),
                onTimeout: () => throw StateError(
                  'Timed out waiting for the session. The terminal may already be open. Check the device and refresh the session list before creating another session.',
                ),
              );
        } on MissingWorkingDirectory catch (missing) {
          missingDirectory = missing.path;
          createDecision = Completer<bool>();
          failureText.value = '';
          final accepted = await Future.any([
            createDecision.future,
            closed.then((_) => false),
          ]);
          if (!accepted || !mounted) return;
          createCwd = true;
          missingDirectory = null;
          createDecision = null;
          failureText.value = null;
        }
      }
      if (route.isActive) navigator.removeRoute(route);
      if (mounted) Navigator.pop(context, instance);
    } catch (failure) {
      missingDirectory = null;
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
    final online = widget.model.onlineSessions
        .map((s) => (s.agentId, s.session))
        .toSet();
    final query = search.text.trim().toLowerCase();
    final saved = sessions
        .where(
          (s) =>
              s.agentId == agentId &&
              !online.contains((s.agentId, s.id)) &&
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
                          context.l10n.workingDirectory,
                          style: context.pircText.hint,
                        ),
                        const SizedBox(height: PircSpacing.s10),
                        TextField(
                          key: const Key('new-session-cwd'),
                          controller: cwd,
                          enabled: !launching,
                          decoration: InputDecoration(
                            hintText: '/path/to/project',
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
                          onPressed:
                              enabled &&
                                  agentId != null &&
                                  cwd.text.trim().isNotEmpty
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
                        if (agents.length > 1) ...[
                          Wrap(
                            spacing: PircSpacing.s8,
                            runSpacing: PircSpacing.s8,
                            children: [
                              for (final agent in agents)
                                ChoiceChip(
                                  key: ValueKey('agent-${agent.id}'),
                                  label: Text(
                                    agent.name,
                                    style: context.pircText.description
                                        .copyWith(
                                          color: agent.id == agentId
                                              ? context.pircColors.primary
                                              : context.pircColors.onSurface,
                                        ),
                                  ),
                                  selected: agent.id == agentId,
                                  showCheckmark: false,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: PircSpacing.s4,
                                  ),
                                  labelPadding: const EdgeInsets.symmetric(
                                    horizontal: PircSpacing.s12,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  selectedColor:
                                      context.pircColors.primaryContainer,
                                  backgroundColor: context.pircColors.surface,
                                  side: BorderSide(
                                    color: agent.id == agentId
                                        ? context.pircColors.primary
                                        : context.pircColors.outlineVariant,
                                  ),
                                  shape: const StadiumBorder(),
                                  onSelected: enabled
                                      ? (_) =>
                                            setState(() => agentId = agent.id)
                                      : null,
                                ),
                            ],
                          ),
                          const SizedBox(height: PircSpacing.s12),
                        ],
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
        key: ValueKey(('restore', session.agentId, session.id)),
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
  const _CreationNameDialog({
    required this.agents,
    required this.initialAgentId,
  });
  final List<AgentInfo> agents;
  final String initialAgentId;

  @override
  State<_CreationNameDialog> createState() => _CreationNameDialogState();
}

class _CreationNameDialogState extends State<_CreationNameDialog> {
  final name = TextEditingController();
  late String agentId = widget.initialAgentId;

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  void submit() =>
      Navigator.pop(context, (name: name.text.trim(), agentId: agentId));

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
              context.l10n.createConversation,
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
                labelText: context.l10n.sessionName,
                hintText: context.l10n.unnamedSession,
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => submit(),
            ),
            if (widget.agents.length > 1) ...[
              const SizedBox(height: PircSpacing.s16),
              DropdownButtonFormField<String>(
                key: const Key('create-session-agent'),
                initialValue: agentId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Agent'),
                icon: const Icon(
                  LucideIcons.chevronDown,
                  size: PircIconSizes.chevron,
                ),
                items: [
                  for (final agent in widget.agents)
                    DropdownMenuItem(
                      value: agent.id,
                      child: Text(
                        agent.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => agentId = value);
                },
              ),
            ],
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
