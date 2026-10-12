import 'transcript_images.dart';
import 'attachment_button.dart';

import 'package:image_picker/image_picker.dart';
import 'package:file_selector/file_selector.dart';

import 'draft_attachments.dart';

import 'dart:async';

import 'pirc_localizations.dart';
import 'pirc_loading.dart';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'pirc_controller.dart';
import 'pirc_theme.dart';
import 'builtin_command_sheet.dart';
import 'transcript_list.dart';
import 'session_settings_bar.dart';
import 'new_session_page.dart';
import 'session_management_sheet.dart';
import 'pirc_drawer.dart';
import 'computer_connections.dart';
import 'connection_store.dart';

String stateLabel(String state) => switch (state) {
  'idle' => 'Idle',
  'running' => 'Running',
  'stopping' => 'Stopping',
  'offline' => 'Offline',
  _ => 'State unconfirmed',
};
String resultLabel(Map<String, dynamic> c) => switch (c['status']) {
  'pending' =>
    c['kind'] == 'close'
        ? 'Awaiting exit confirmation'
        : c['kind'] == 'stop'
        ? 'Awaiting stop confirmation'
        : 'Awaiting command receipt',
  'accepted' =>
    c['kind'] == 'close'
        ? 'Exiting; waiting for the device'
        : c['kind'] == 'stop'
        ? 'Stopping; send when idle is confirmed'
        : 'Command received',
  'completed' => c['kind'] == 'close' ? 'Session exited' : 'Stop confirmed',
  'rejected' => switch (c['code']) {
    'BUSY' =>
      c['kind'] == 'close'
          ? 'A task is running. Stop it before exiting.'
          : 'The terminal started a task. Message not sent.',
    'UNMANAGED_TERMINAL' =>
      'This session was started on the device. Exit it on the device.',
    'CLOSING' => 'Exiting. Wait for confirmation.',
    'STALE_STATE' => 'Session state changed. Send again.',
    'STALE_INSTANCE' => 'The original session is offline',
    'LOCAL_COMMAND_REQUIRED' => 'Run this command in the device terminal',
    'MODEL_NOT_FOUND' => 'Model not found. Select one from the list.',
    'MODEL_AUTH_REQUIRED' =>
      'Set up authentication for this model on the device first.',
    'MODEL_NO_IMAGES' => 'The selected model does not support images',
    'INVALID_THINKING_LEVEL' ||
    'INVALID_ARGUMENT' ||
    'COMPACT_FAILED' ||
    'PI_ERROR' =>
      c['detail'] as String? ??
          'Operation incomplete. Check the device terminal.',
    'NO_MODEL' => 'Select a model first',
    _ => 'Unable to send. Check the terminal.',
  },
  'unknown' => 'Result unconfirmed. Check the terminal first.',
  'acknowledged' => 'Terminal result confirmed',
  _ => '',
};

class PircScreen extends StatefulWidget {
  const PircScreen({super.key, required this.computers});
  final ComputerConnections computers;
  @override
  State<PircScreen> createState() => _PircScreenState();
}

class _PircScreenState extends State<PircScreen> {
  bool detail = false;
  bool pairingOpen = false;
  bool pairingConnecting = false;
  ComputerConnections get computers => widget.computers;
  PircController get model => computers.active.controller;
  @override
  void initState() {
    super.initState();
    computers.addListener(refresh);
  }

  void refresh() {
    if (mounted) {
      setState(() {});
      if (model.pairing != null && !pairingOpen && !pairingConnecting) {
        pairingOpen = true;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => waitForServerApproval(),
        );
      }
    }
  }

  Future<void> waitForServerApproval() async {
    final computer = computers.active;
    final controller = computer.controller;
    final pairing = controller.pairing;
    if (!mounted || pairing == null) {
      pairingOpen = false;
      return;
    }
    final navigator = Navigator.of(context);
    var completed = false;
    late final DialogRoute<bool> route;
    void checkApproval() {
      if (completed || controller.pairing != null) return;
      completed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) navigator.removeRoute(route, true);
      });
    }

    route = DialogRoute<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        key: const Key('server-approval-dialog'),
        title: Text(context.l10n.approveClientTitle),
        content: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final code =
                controller.pairing?['code'] as String? ??
                pairing['code'] as String;
            final command = 'pirc allow $code';
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(computer.displayName, style: context.pircText.cardTitle),
                  const SizedBox(height: PircSpacing.s12),
                  Text(context.l10n.approveClientDescription),
                  const SizedBox(height: PircSpacing.s16),
                  SelectableText(
                    command,
                    key: const Key('server-approval-command'),
                    style: context.pircText.path,
                  ),
                  const SizedBox(height: PircSpacing.s8),
                  Text(
                    context.l10n.pairingCodeExpiry,
                    style: context.pircText.hint,
                  ),
                ],
              ),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          TextButton.icon(
            onPressed: () => Clipboard.setData(
              ClipboardData(
                text:
                    'pirc allow ${controller.pairing?['code'] ?? pairing['code']}',
              ),
            ),
            icon: const Icon(LucideIcons.copy, size: PircIconSizes.small),
            label: Text(context.l10n.copyCommand),
          ),
        ],
      ),
    );
    controller.addListener(checkApproval);
    try {
      final approved = await navigator.push(route);
      if (approved != true && controller.pairing != null) {
        await controller.disconnect();
      }
    } finally {
      completed = true;
      controller.removeListener(checkApproval);
      pairingOpen = false;
      if (mounted) refresh();
    }
  }

  @override
  void dispose() {
    computers.removeListener(refresh);
    super.dispose();
  }

  Future<void> connect({bool adding = false}) async {
    final result = await showDialog<ConnectionOptions>(
      context: context,
      builder: (_) => ConnectionDialog(
        endpoint: adding ? '' : model.endpoint,
        initialName: adding ? '' : computers.active.name,
        initialBackupAddresses: adding
            ? const []
            : computers.active.addresses.skip(1).toList(),
        occupiedAddresses: computers.computers
            .where((c) => adding || c != computers.active)
            .expand((c) => c.addresses)
            .toSet(),
        adding: adding,
      ),
    );
    if (mounted && result != null) {
      setState(() => detail = false);
      if (result.repair) {
        await repairDevice();
        return;
      }
      if (adding) {
        await computers.addComputer(
          result.url,
          name: result.name,
          backupAddresses: result.backupAddresses,
        );
      } else {
        await computers.configureCurrent(
          result.url,
          name: result.name,
          backupAddresses: result.backupAddresses,
        );
      }
    }
  }

  Future<void> repairDevice() async {
    final controller = model;
    final navigator = Navigator.of(context);
    pairingConnecting = true;
    String? failure;
    var completed = false;
    late final DialogRoute<bool> route;
    void finish(bool ready, [String? error]) {
      if (completed) return;
      completed = true;
      failure = error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) navigator.removeRoute(route, ready);
      });
    }

    void check() {
      if (controller.pairing != null || controller.connection == 'connected') {
        finish(true);
      } else if (controller.connection == 'blocked' ||
          (controller.connection == 'disconnected' &&
              controller.error != null)) {
        finish(false, controller.error);
      }
    }

    route = DialogRoute<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        key: const Key('pairing-connection-dialog'),
        shape: const RoundedRectangleBorder(borderRadius: PircRadii.session),
        constraints: const BoxConstraints(
          maxWidth: PircLayout.loadingDialogWidth,
        ),
        child: SizedBox(
          width: PircLayout.loadingDialogWidth,
          child: Padding(
            padding: const EdgeInsets.all(PircSpacing.s20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PircLoading(
                  title: context.l10n.connectingDevice,
                  compact: true,
                ),
                const SizedBox(height: PircSpacing.s16),
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  style: TextButton.styleFrom(
                    backgroundColor: context.pircColors.surfaceContainerLowest,
                    minimumSize: const Size.fromHeight(PircLayout.actionSize),
                    shape: const RoundedRectangleBorder(
                      borderRadius: PircRadii.brand,
                    ),
                  ),
                  child: Text(context.l10n.cancel),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final waiting = navigator.push(route);
    controller.addListener(check);
    final timeout = Timer(
      const Duration(seconds: 20),
      () => finish(
        false,
        'Pairing connection timed out. Check that the server is running and try again.',
      ),
    );
    unawaited(
      computers.repairCurrent().catchError((Object error) {
        finish(false, '$error');
      }),
    );
    bool? ready;
    try {
      ready = await waiting;
    } finally {
      completed = true;
      timeout.cancel();
      controller.removeListener(check);
      pairingConnecting = false;
    }
    if (ready != true) {
      await controller.disconnect();
      if (failure != null && mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            key: const Key('pairing-connection-failure'),
            title: Text(context.l10n.pairingConnectionFailed),
            content: Text(context.localize(failure!)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(context.l10n.gotIt),
              ),
            ],
          ),
        );
      }
    }
    if (mounted) refresh();
  }

  void addComputer() => connect(adding: true);

  void selectComputer(ComputerConnection computer) {
    if (computer == computers.active) return;
    setState(() => detail = false);
    computers.selectComputer(computer);
  }

  Future<void> createSession() async {
    final instance = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => NewSessionPage(
          model: model,
          computerName: computers.active.displayName,
        ),
      ),
    );
    if (mounted && instance != null) {
      model.select(instance);
      setState(() => detail = true);
    }
  }

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: PircLayout.maxContentWidth),
      child: detail && model.selected != null
          ? SessionPage(
              key: ValueKey('${model.endpoint}/${model.selectedInstance}'),
              model: model,
              computers: computers,
              back: () {
                FocusManager.instance.primaryFocus?.unfocus();
                setState(() => detail = false);
              },
            )
          : Scaffold(
              drawer: PircDrawer(
                computers: computers,
                selectComputer: selectComputer,
                addComputer: addComputer,
                configureComputer: (computer) {
                  selectComputer(computer);
                  connect();
                },
              ),
              appBar: AppBar(
                leading: const PircDrawerButton(),
                titleSpacing: 0,
                title: Text('PiRC', style: context.pircText.brand),
              ),
              body: SafeArea(
                top: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        PircSpacing.s20,
                        PircSpacing.s8,
                        PircSpacing.s20,
                        PircSpacing.s28,
                      ),
                      child: _ConnectionCard(
                        model: model,
                        computerName: computers.active.displayName,
                        startupLoading: computers.startupLoading,
                        connect: addComputer,
                        configured: computers.active.saved,
                        retry: computers.reconnectCurrent,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: PircSpacing.s22,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              context.l10n.sessions,
                              style: context.pircText.section,
                            ),
                          ),
                          IconButton(
                            key: const Key('create-session'),
                            tooltip: context.l10n.newConversation,
                            onPressed: model.connection == 'connected'
                                ? createSession
                                : null,
                            icon: const Icon(
                              LucideIcons.plus,
                              size: PircIconSizes.chevron,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: PircSpacing.s14),
                    Expanded(
                      child:
                          computers.startupLoading ||
                              model.startupLoading ||
                              (model.onlineSessions.isEmpty &&
                                  [
                                    'connecting',
                                    'syncing',
                                    'reconnecting',
                                  ].contains(model.connection))
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const LoadingIndicator(),
                                  const SizedBox(height: PircSpacing.s12),
                                  Text(
                                    context.l10n.syncingSessions,
                                    style: context.pircText.hint,
                                  ),
                                ],
                              ),
                            )
                          : model.onlineSessions.isEmpty
                          ? _EmptyState(
                              icon: LucideIcons.terminal,
                              title: model.connection == 'disconnected'
                                  ? context.l10n.viewDeviceSessions
                                  : context.l10n.noOnlineSessions,
                              description: model.connection == 'disconnected'
                                  ? context.l10n.connectToViewSessions
                                  : context.l10n.noSessionsDescription,
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.fromLTRB(
                                PircSpacing.s20,
                                0,
                                PircSpacing.s20,
                                PircSpacing.s24,
                              ),
                              itemCount: model.onlineSessions.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: PircSpacing.s10),
                              itemBuilder: (_, index) {
                                final session = model.onlineSessions[index];
                                return _SessionTile(
                                  session: session,
                                  onManage: () => showSessionManagementSheet(
                                    context,
                                    model,
                                    session,
                                  ),
                                  onTap: () {
                                    model.select(session.instance);
                                    setState(() => detail = true);
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
    ),
  );
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.model,
    required this.connect,
    required this.computerName,
    required this.startupLoading,
    required this.configured,
    required this.retry,
  });
  final bool configured;
  final VoidCallback retry;
  final PircController model;
  final VoidCallback connect;
  final String computerName;
  final bool startupLoading;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(PircSpacing.s16),
    decoration: BoxDecoration(
      color: context.pircColors.surface,
      borderRadius: PircRadii.connection,
      border: Border.all(
        color: context.pircColors.outlineVariant,
        width: PircLayout.borderWidth,
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: PircLayout.deviceSize,
              height: PircLayout.deviceSize,
              decoration: BoxDecoration(
                color: context.pircColors.surfaceContainerLowest,
                borderRadius: PircRadii.device,
              ),
              child: Icon(
                LucideIcons.laptop,
                size: PircIconSizes.toolbar,
                color: context.pircColors.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: PircSpacing.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    startupLoading || model.startupLoading
                        ? context.l10n.restoringConnection
                        : configured || model.connection == 'connected'
                        ? computerName
                        : context.localize(model.connectionDescription),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.pircText.action,
                  ),
                  if (configured &&
                      !startupLoading &&
                      !model.startupLoading &&
                      model.connection != 'connected') ...[
                    const SizedBox(height: PircSpacing.s4),
                    Text(
                      context.localize(model.connectionDescription),
                      style: context.pircText.hint,
                    ),
                  ],
                ],
              ),
            ),
            if (configured || model.connection != 'disconnected') ...[
              IconButton(
                key: const Key('reconnect-button'),
                tooltip: model.connection == 'connected'
                    ? context.l10n.refresh
                    : context.l10n.retry,
                onPressed: retry,
                icon: Icon(
                  LucideIcons.refreshCw,
                  size: PircIconSizes.chevron,
                  color: context.pircColors.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
        if (!configured && model.connection == 'disconnected') ...[
          const SizedBox(height: PircSpacing.s16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('connect-button'),
              onPressed: connect,
              icon: const Icon(LucideIcons.link, size: PircIconSizes.small),
              label: Text(context.l10n.addDevice),
            ),
          ),
        ],
        if (model.error != null) ...[
          const SizedBox(height: PircSpacing.s12),
          Text(
            context.localize(model.error!),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: context.pircText.hint.copyWith(color: context.pirc.warning),
          ),
        ],
      ],
    ),
  );
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.onTap,
    required this.onManage,
  });
  final SessionView session;
  final VoidCallback onTap;
  final VoidCallback onManage;
  @override
  Widget build(BuildContext context) {
    final online = session.state != 'offline';
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
        key: Key('session-${session.instance}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(PircSpacing.s16),
          child: Row(
            children: [
              Container(
                width: PircLayout.deviceSize,
                height: PircLayout.deviceSize,
                decoration: BoxDecoration(
                  color: online
                      ? context.pircColors.primaryContainer
                      : context.pircColors.surfaceContainerLowest,
                  borderRadius: PircRadii.device,
                ),
                child: Icon(
                  LucideIcons.terminal,
                  size: PircIconSizes.session,
                  color: online
                      ? context.pircColors.primary
                      : context.pircColors.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: PircSpacing.s13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.sessionName ?? context.l10n.unnamedSession,
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
                    Row(
                      children: [
                        _StatusDot(connected: online),
                        const SizedBox(width: PircSpacing.s6),
                        Expanded(
                          child: Text(
                            context.localize(stateLabel(session.state)),
                            style: context.pircText.path,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: PircSpacing.s8),
              IconButton(
                key: Key('session-menu-${session.instance}'),
                tooltip: context.l10n.sessionManagement,
                onPressed: onManage,
                icon: Icon(
                  LucideIcons.ellipsisVertical,
                  size: PircIconSizes.chevron,
                  color: context.pircColors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.connected});
  final bool connected;
  @override
  Widget build(BuildContext context) => Container(
    width: PircLayout.statusDotSize,
    height: PircLayout.statusDotSize,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: connected
          ? context.pirc.success
          : context.pircColors.onSurfaceVariant,
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.description,
  });
  final IconData icon;
  final String title;
  final String description;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(PircSpacing.s24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: PircLayout.emptyStateSize,
              height: PircLayout.emptyStateSize,
              decoration: BoxDecoration(
                color: context.pircColors.primaryContainer,
                borderRadius: PircRadii.emptyState,
              ),
              child: Icon(
                icon,
                color: context.pircColors.primary,
                size: PircIconSizes.emptyState,
              ),
            ),
            const SizedBox(height: PircSpacing.s18),
            Text(title, style: context.pircText.emptyTitle),
            const SizedBox(height: PircSpacing.s8),
            Text(
              description,
              textAlign: TextAlign.center,
              style: context.pircText.emptyDescription.copyWith(
                color: context.pircColors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class SessionPage extends StatefulWidget {
  const SessionPage({
    super.key,
    required this.model,
    required this.back,
    required this.computers,
  });
  final PircController model;
  final VoidCallback back;
  final ComputerConnections computers;
  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage> {
  late final editor = TextEditingController(
    text: widget.model.draft(widget.model.selected!),
  );
  final transcript = GlobalKey<TranscriptListState>();
  late String lastDraft = editor.text;
  PircController get model => widget.model;
  @override
  void initState() {
    super.initState();
    model.addListener(update);
  }

  void update() {
    final s = model.selected;
    if (s == null) return;
    final draft = model.draft(s);
    // Incoming events must not reset cursor/IME state while the user is typing.
    if (draft != lastDraft) {
      lastDraft = draft;
      editor.value = TextEditingValue(
        text: draft,
        selection: TextSelection.collapsed(offset: draft.length),
      );
    }
  }

  @override
  void dispose() {
    model.removeListener(update);
    editor.dispose();
    super.dispose();
  }

  bool pickingImage = false;
  Future<void> chooseAttachment(String kind) async {
    if (model.selected == null || pickingImage || actionInFlight) return;
    if (kind == 'image') await pickImage();
    if (kind == 'file') await pickFile();
  }

  Future<void> pickFile() async {
    final session = model.selected;
    if (session == null || pickingImage || actionInFlight) return;
    setState(() => pickingImage = true);
    try {
      final file = await openFile();
      if (file == null) return;
      final total = await file.length();
      if (total > 20 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(context.l10n.fileTooLarge)));
        }
        return;
      }
      if (!mounted || model.selected?.instance != session.instance) return;
      model.stageFile(session, file.name, total, file.openRead);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.fileSelectionFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => pickingImage = false);
    }
  }

  Future<void> pickImage() async {
    final session = model.selected;
    if (session == null || pickingImage || actionInFlight) return;
    setState(() => pickingImage = true);
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
        requestFullMetadata: false,
      );
      if (file == null) return;
      if (await file.length() > 20 * 1024 * 1024) {
        throw StateError('Image is too large');
      }
      await model.attachImage(
        session,
        await file.readAsBytes(),
        name: file.name,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.imageSelectionFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => pickingImage = false);
    }
  }

  bool actionInFlight = false;
  bool promptInFlight = false;
  bool commandSheetOpen = false;
  String? loadingBuiltin;
  void jumpToLatest() {
    transcript.currentState?.showLatest();
  }

  Future<void> openBuiltin(String command) async {
    final session = model.selected;
    if (actionInFlight ||
        session == null ||
        !model.canConfigure(session) ||
        !session.supportsBuiltin(command)) {
      return;
    }
    setState(() {
      actionInFlight = true;
      commandSheetOpen = true;
      loadingBuiltin = command;
    });
    try {
      await showBuiltinCommandSheet(
        context,
        model,
        session,
        command,
        onReady: () {
          if (mounted) setState(() => loadingBuiltin = null);
        },
      );
    } finally {
      if (mounted) {
        setState(() {
          actionInFlight = false;
          commandSheetOpen = false;
          loadingBuiltin = null;
        });
      }
    }
  }

  Future<void> submit({required bool stop}) async {
    if (actionInFlight) return;
    final session = model.selected!;
    final text = editor.text.trim();
    final command = text.startsWith('/')
        ? text.substring(1).split(RegExp(r'\s')).first
        : '';
    final builtin =
        builtinNames.contains(command) && session.supportsBuiltin(command);
    final openSheet = builtin && command != 'compact' && text == '/$command';
    if (!stop && openSheet) {
      jumpToLatest();
      await openBuiltin(command);
      return;
    }
    setState(() {
      actionInFlight = true;
      promptInFlight = !stop && !builtin;
    });
    if (!stop) jumpToLatest();
    try {
      if (stop) {
        await model.stop();
      } else {
        await model.send();
        jumpToLatest();
      }
    } finally {
      if (mounted) {
        setState(() {
          actionInFlight = false;
          promptInFlight = false;
          commandSheetOpen = false;
          loadingBuiltin = null;
        });
      }
    }
  }

  bool get composing =>
      editor.value.composing.isValid && !editor.value.composing.isCollapsed;

  void sendFromKeyboard() {
    final session = model.selected;
    if (!composing &&
        !actionInFlight &&
        session != null &&
        model.canSend(session)) {
      submit(stop: false);
    }
  }

  KeyEventResult handleEditorKey(FocusNode node, KeyEvent event) {
    final enter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!enter || composing || HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) sendFromKeyboard();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final s = model.selected!;
    final recent = model.commands
        .where((c) => c['instance_id'] == s.instance)
        .lastOrNull;
    final unresolved = model.commands
        .where(
          (c) =>
              c['instance_id'] == s.instance &&
              (c['status'] == 'pending' ||
                  c['status'] == 'unknown' ||
                  (c['kind'] != 'prompt' && c['status'] == 'accepted')),
        )
        .lastOrNull;
    final stopping =
        s.state == 'stopping' ||
        (unresolved?['kind'] == 'stop' && unresolved?['status'] != 'unknown');
    final running = s.state == 'running';
    final waiting =
        (actionInFlight && !commandSheetOpen) || stopping || model.pending(s);
    final connected = model.connection == 'connected' && s.ready;
    final notice = unresolved?['status'] == 'unknown' ? unresolved : recent;
    final showNotice =
        notice != null &&
        (notice['status'] == 'rejected' || notice['status'] == 'unknown');
    final tooltip = !connected
        ? context.l10n.waitingForConnection
        : stopping
        ? context.l10n.stopping
        : unresolved?['status'] == 'unknown'
        ? context.l10n.waitingForTerminal
        : waiting
        ? context.l10n.waitingForConfirmation
        : running
        ? context.l10n.stop
        : context.l10n.send;
    final slashQuery =
        editor.text.startsWith('/') && !editor.text.contains(RegExp(r'\s'))
        ? editor.text.substring(1).toLowerCase()
        : null;
    final slashCommands = ((s.snapshot['slash_commands'] as List?) ?? [])
        .cast<Map<String, dynamic>>()
        .where(
          (command) =>
              slashQuery != null &&
              (command['name'] as String).toLowerCase().startsWith(slashQuery),
        )
        .take(8)
        .toList();
    final lastUser = s.items.lastIndexWhere((item) => item['role'] == 'user');
    final responseStarted = s.items
        .skip(lastUser + 1)
        .any(
          (item) =>
              item['role'] == 'thinking' ||
              item['role'] == 'tool' ||
              item['role'] == 'error' ||
              (item['role'] == 'assistant' &&
                  (item['text'] as String? ?? '').isNotEmpty),
        );
    final awaitingReply =
        connected &&
        !stopping &&
        (s.snapshot['controls'] as Map?)?['compacting'] != true &&
        unresolved?['kind'] != 'compact' &&
        !responseStarted &&
        (running ||
            promptInFlight ||
            (unresolved?['kind'] == 'prompt' &&
                unresolved?['status'] == 'pending'));
    final transcriptItems =
        (awaitingReply
                ? s.items
                      .where(
                        (item) =>
                            !(item['role'] == 'assistant' &&
                                (item['text'] as String? ?? '').isEmpty &&
                                (item['images'] as List? ?? []).isEmpty),
                      )
                      .toList()
                : s.items)
            .toList();
    final compactOperations = model.commands.where(
      (c) => c['instance_id'] == s.instance && c['kind'] == 'compact',
    );
    for (final operation in compactOperations) {
      final after = (operation['after_seq'] as num?)?.toInt() ?? 0;
      final first = (s.items.firstOrNull?['first_seq'] as num?)?.toInt() ?? 0;
      final last =
          (s.items.lastOrNull?['last_seq'] as num?)?.toInt() ?? s.lastSeq;
      if (after < first || (s.hasAfter && after > last)) continue;
      final data = operation['data'] as Map?;
      final busy =
          operation['status'] == 'pending' || operation['status'] == 'accepted';
      final item = <String, dynamic>{
        'id': 'compact-${operation['request_id']}',
        'role': 'compact',
        'title': context.l10n.compactContext,
        'text':
            data?['summary'] as String? ??
            operation['detail'] as String? ??
            (operation['status'] == 'unknown'
                ? context.l10n.checkDeviceResult
                : ''),
        'complete': !busy,
        'is_error': operation['status'] == 'rejected',
        'phase': operation['status'] == 'unknown'
            ? 'unknown'
            : operation['status'] == 'rejected'
            ? 'failed'
            : busy
            ? 'running'
            : 'completed',
        'first_seq': after,
        'last_seq': after,
      };
      final next = transcriptItems.indexWhere(
        (i) => ((i['first_seq'] as num?)?.toInt() ?? 0) > after,
      );
      transcriptItems.insert(next < 0 ? transcriptItems.length : next, item);
    }
    final canAct =
        connected &&
        !commandSheetOpen &&
        !pickingImage &&
        !actionInFlight &&
        !waiting &&
        (running ? model.canStop(s) : model.canSend(s));
    final canConfigure = !actionInFlight && model.canConfigure(s);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const Key('back-button'),
          tooltip: context.l10n.backToSessions,
          onPressed: widget.back,
          icon: const Icon(LucideIcons.arrowLeft),
        ),
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Tooltip(
              message: context.l10n.sessionNameTooltip(
                s.sessionName ?? context.l10n.unnamed,
              ),
              child: InkWell(
                key: const Key('session-name'),
                borderRadius: PircRadii.badge,
                onTap: canConfigure && s.supportsBuiltin('name')
                    ? () => openBuiltin('name')
                    : null,
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        s.sessionName ?? context.l10n.unnamedSession,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.pircText.sessionTitle,
                      ),
                    ),
                    if (s.supportsBuiltin('name')) ...[
                      const SizedBox(width: PircSpacing.s6),
                      if (loadingBuiltin == 'name')
                        SizedBox(
                          key: const Key('builtin-loading-name'),
                          width: PircIconSizes.notice,
                          height: PircIconSizes.notice,
                          child: CircularProgressIndicator(
                            strokeWidth: PircLayout.loadingStrokeWidth,
                          ),
                        )
                      else
                        Icon(
                          LucideIcons.pencil,
                          size: PircIconSizes.notice,
                          color: context.pircColors.onSurfaceVariant,
                        ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: PircSpacing.s3),
            Text(
              s.cwd,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.pircText.path,
            ),
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                PircSpacing.s22,
                PircSpacing.s2,
                PircSpacing.s22,
                PircSpacing.s12,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) => Row(
                  key: const Key('session-status-row'),
                  children: [
                    _StatusDot(connected: model.connection == 'connected'),
                    const SizedBox(width: PircSpacing.s7),
                    Expanded(
                      child: Text(
                        context.localize(model.connectionDescription),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.pircText.path,
                      ),
                    ),
                    const SizedBox(width: PircSpacing.s10),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth:
                            constraints.maxWidth *
                            PircLayout.statusBadgeWidthFactor,
                      ),
                      child: Container(
                        key: const Key('session-state-badge'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: PircSpacing.s9,
                          vertical: PircSpacing.s4,
                        ),
                        decoration: BoxDecoration(
                          color: connected && running
                              ? context.pircColors.primaryContainer
                              : context.pircColors.outlineVariant.withValues(
                                  alpha: PircLayout.inactiveOpacity,
                                ),
                          borderRadius: PircRadii.badge,
                        ),
                        child: Text(
                          connected
                              ? ((s.snapshot['controls']
                                            as Map?)?['compacting'] ==
                                        true
                                    ? context.l10n.compacting
                                    : context.localize(stateLabel(s.state)))
                              : context.l10n.stateUnconfirmed,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.pircText.tag.copyWith(
                            color: connected && running
                                ? context.pircColors.primary
                                : context.pircColors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (s.attention || s.gaps.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  PircSpacing.s20,
                  0,
                  PircSpacing.s20,
                  PircSpacing.s10,
                ),
                child: _InlineNotice(
                  text: s.attention
                      ? ((s.snapshot['ui_prompt'] as Map?)?['title'] as String?)
                                    ?.isNotEmpty ==
                                true
                            ? '${context.l10n.completeOnTerminal}: ${(s.snapshot['ui_prompt'] as Map)['title']}'
                            : context.l10n.completeOnTerminal
                      : context.l10n.incompleteConversation,
                ),
              ),
            Expanded(
              child: TranscriptList(
                key: transcript,
                model: model,
                session: s,
                items: [
                  ...transcriptItems,
                  if (awaitingReply)
                    {'id': 'awaiting-reply', 'role': 'waiting', 'text': ''},
                ],
                itemBuilder: (item) => item['role'] == 'waiting'
                    ? const _AwaitingReply(key: ValueKey('awaiting-reply'))
                    : MessageBubble(
                        key: ValueKey(item['id']),
                        item: item,
                        model: model,
                        instance: s.instance,
                      ),
                empty: _EmptyState(
                  icon: LucideIcons.messageCircle,
                  title: s.state == 'offline'
                      ? context.l10n.sessionOffline
                      : context.l10n.continueConversation,
                  description: s.state == 'offline'
                      ? context.l10n.reopenSessionDescription
                      : context.l10n.continueDescription,
                ),
              ),
            ),
            if (showNotice)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  PircSpacing.s20,
                  0,
                  PircSpacing.s20,
                  PircSpacing.s8,
                ),
                child: _InlineNotice(
                  text: context.localize(resultLabel(notice)),
                  textKey: const Key('command-result'),
                  action: notice['status'] == 'unknown'
                      ? TextButton(
                          onPressed: () => model.confirmUnknown(
                            notice['request_id'] as String,
                          ),
                          child: Text(context.l10n.confirmedOnTerminal),
                        )
                      : null,
                ),
              ),
            if (model.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  PircSpacing.s20,
                  0,
                  PircSpacing.s20,
                  PircSpacing.s8,
                ),
                child: _InlineNotice(text: context.localize(model.error!)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                PircSpacing.s16,
                PircSpacing.s8,
                PircSpacing.s16,
                PircSpacing.s12,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (slashCommands.isNotEmpty)
                    SizedBox(
                      height: PircLayout.activityMaxHeight,
                      child: ListView.builder(
                        itemCount: slashCommands.length,
                        itemBuilder: (_, index) {
                          final command = slashCommands[index];
                          return ListTile(
                            title: Text(
                              command['source'] == 'extension'
                                  ? context.l10n.deviceCommand(
                                      command['name'].toString(),
                                    )
                                  : '/${command['name']}',
                              style: context.pircText.activityTitle,
                            ),
                            subtitle: Text(
                              context.localize(
                                command['description'] as String? ??
                                    command['source'] as String,
                              ),
                              style: context.pircText.hint,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: command['source'] == 'extension'
                                ? null
                                : () {
                                    final builtin =
                                        command['source'] == 'builtin';
                                    final name = command['name'] as String;
                                    model.setDraft(
                                      s,
                                      '/$name${builtin ? '' : ' '}',
                                    );
                                    if (builtin &&
                                        name != 'compact' &&
                                        model.canSend(s)) {
                                      submit(stop: false);
                                    }
                                  },
                          );
                        },
                      ),
                    ),
                  Container(
                    key: const Key('composer'),
                    padding: const EdgeInsets.all(PircSpacing.s6),
                    decoration: BoxDecoration(
                      color: context.pircColors.surface,
                      borderRadius: PircRadii.composer,
                      border: Border.all(
                        color: context.pircColors.outlineVariant,
                        width: PircLayout.borderWidth,
                      ),
                      boxShadow: PircEffects.composerShadow,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        DraftAttachments(
                          fileName: model.draftFile(s)?.name,
                          image: model.draftImage(s),
                          imageName: model.draftImageName(s),
                          onRemoveFile:
                              actionInFlight || model.pending(s) || pickingImage
                              ? null
                              : () => model.removeFile(s),
                          onRemoveImage:
                              actionInFlight || model.pending(s) || pickingImage
                              ? null
                              : () => model.removeImage(s),
                        ),
                        Focus(
                          onKeyEvent: handleEditorKey,
                          child: TextField(
                            key: const Key('prompt-editor'),
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => sendFromKeyboard(),
                            controller: editor,
                            minLines: 1,
                            maxLines: 4,
                            textAlignVertical: TextAlignVertical.center,
                            style: context.pircText.body,
                            onChanged: (text) {
                              lastDraft = text;
                              model.setDraft(s, text);
                            },
                            decoration: PircInputDecorations.composer.copyWith(
                              prefixIcon: AttachmentButton(
                                key: const Key('attach-attachment'),
                                loading: pickingImage,
                                images:
                                    (s.snapshot['capabilities'] as List? ?? [])
                                        .contains('image_prompt'),
                                onSelected:
                                    connected &&
                                        !actionInFlight &&
                                        !pickingImage &&
                                        !model.pending(s)
                                    ? chooseAttachment
                                    : null,
                              ),
                              hintText: context.l10n.messageHint,
                            ),
                          ),
                        ),
                        const SizedBox(height: PircSpacing.s4),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: PircSpacing.s4,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Expanded(
                                child: SessionSettingsBar(
                                  key: const Key('session-settings'),
                                  session: s,
                                  enabled: canConfigure,
                                  loadingCommand: loadingBuiltin,
                                  onSelect: openBuiltin,
                                ),
                              ),
                              const SizedBox(width: PircSpacing.s4),
                              IconButton.filled(
                                key: const Key('composer-action'),
                                tooltip: tooltip,
                                onPressed: canAct
                                    ? () => submit(stop: running)
                                    : null,
                                style: context.pircComposerButtonStyle(
                                  waiting: waiting && connected,
                                ),
                                icon:
                                    waiting &&
                                        connected &&
                                        unresolved?['status'] != 'unknown'
                                    ? SizedBox(
                                        width: PircIconSizes.small,
                                        height: PircIconSizes.small,
                                        child: CircularProgressIndicator(
                                          strokeWidth:
                                              PircLayout.loadingStrokeWidth,
                                          color: context.pircColors.primary,
                                          semanticsLabel: context
                                              .l10n
                                              .waitingForConfirmation,
                                        ),
                                      )
                                    : Icon(
                                        running || stopping
                                            ? LucideIcons.square
                                            : LucideIcons.arrowUp,
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.text, this.textKey, this.action});
  final String text;
  final Key? textKey;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(
      horizontal: PircSpacing.s12,
      vertical: PircSpacing.s10,
    ),
    decoration: BoxDecoration(
      color: context.pirc.warningSurface,
      borderRadius: PircRadii.notice,
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(top: PircSpacing.s1),
          child: Icon(
            LucideIcons.info,
            size: PircIconSizes.notice,
            color: context.pirc.warning,
          ),
        ),
        const SizedBox(width: PircSpacing.s8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.localize(text),
                key: textKey,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: context.pircText.hint.copyWith(
                  color: context.pirc.warning,
                ),
              ),
              ?action,
            ],
          ),
        ),
      ],
    ),
  );
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.item,
    this.model,
    this.instance,
  });
  final PircController? model;
  final String? instance;
  final Map<String, dynamic> item;
  @override
  Widget build(BuildContext context) {
    final role = item['role'] as String;
    final text = item['text'] as String;
    if ((role == 'assistant' || role == 'thinking') &&
        text.isEmpty &&
        (item['images'] as List? ?? []).isEmpty &&
        item['complete'] == true) {
      return const SizedBox.shrink();
    }
    if (role == 'tool' || role == 'thinking' || role == 'compact') {
      final complete = item['complete'] == true;
      final arguments = item['arguments'] as String? ?? '';
      final phase = switch (item['phase']) {
        'generating' => context.l10n.generatingArguments,
        'waiting' => context.l10n.waitingToRun,
        'running' => context.l10n.running,
        'completed' => context.l10n.completed,
        'failed' => context.l10n.failed,
        'cancelled' => context.l10n.stopped,
        'unknown' => context.l10n.resultPending,
        _ => complete ? context.l10n.completed : context.l10n.running,
      };
      return Padding(
        padding: const EdgeInsets.only(bottom: PircSpacing.s16),
        child: _ActivityCard(
          child: ListTileTheme.merge(
            shape: RoundedRectangleBorder(borderRadius: PircRadii.activity),
            child: ExpansionTile(
              key: PageStorageKey('details-${item['id']}'),
              initiallyExpanded: !complete,
              minTileHeight: PircLayout.actionSize,
              tilePadding: const EdgeInsets.symmetric(
                horizontal: PircSpacing.s14,
              ),
              childrenPadding: const EdgeInsets.fromLTRB(
                PircSpacing.s14,
                0,
                PircSpacing.s14,
                PircSpacing.s14,
              ),
              shape: RoundedRectangleBorder(borderRadius: PircRadii.activity),
              collapsedShape: RoundedRectangleBorder(
                borderRadius: PircRadii.activity,
              ),
              textColor: context.pircColors.onSurface,
              collapsedTextColor: context.pircColors.onSurface,
              iconColor: context.pircColors.onSurfaceVariant,
              collapsedIconColor: context.pircColors.onSurfaceVariant,
              leading: complete
                  ? Icon(
                      role == 'thinking'
                          ? LucideIcons.sparkles
                          : role == 'compact'
                          ? LucideIcons.layers
                          : LucideIcons.terminal,
                      size: PircIconSizes.activity,
                    )
                  : const LoadingIndicator(),
              title: Text(
                role == 'thinking'
                    ? context.l10n.thinking
                    : context.l10n.toolPhase(
                        item['title']?.toString() ?? context.l10n.tools,
                        phase,
                      ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.pircText.activityTitle,
              ),
              children: [
                const Divider(height: PircSpacing.s1),
                const SizedBox(height: PircSpacing.s12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxHeight: PircLayout.activityMaxHeight,
                    ),
                    child: _StreamingActivityContent(
                      id: item['id'] as String,
                      text: text,
                      arguments: arguments,
                      complete: complete,
                      tool: role == 'tool',
                      truncated: item['truncated'] == true,
                    ),
                  ),
                ),
                if (model != null && instance != null)
                  TranscriptImages(
                    model: model!,
                    instance: instance!,
                    images: item['images'] as List? ?? [],
                  ),
              ],
            ),
          ),
        ),
      );
    }
    if (role == 'error' || item['is_error'] == true) {
      return Padding(
        padding: const EdgeInsets.only(bottom: PircSpacing.s14),
        child: _InlineNotice(
          text: text.isEmpty
              ? context.l10n.executionIncomplete
              : context.localize(text),
        ),
      );
    }
    final user = role == 'user';
    return LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: user ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
            maxWidth:
                constraints.maxWidth *
                (user ? PircLayout.userBubbleWidthFactor : 1),
          ),
          margin: const EdgeInsets.only(bottom: PircSpacing.s16),
          padding: user
              ? const EdgeInsets.symmetric(
                  horizontal: PircSpacing.s16,
                  vertical: PircSpacing.s13,
                )
              : const EdgeInsets.symmetric(vertical: PircSpacing.s4),
          decoration: user
              ? BoxDecoration(
                  color: context.pircColors.primaryContainer,
                  borderRadius: PircRadii.userBubble,
                )
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (text.isEmpty && (item['images'] as List? ?? []).isEmpty)
                const LoadingIndicator()
              else if (user)
                SelectableText(text, style: context.pircText.body)
              else
                _SelectableMarkdown(text: text),
              if (model != null && instance != null)
                TranscriptImages(
                  model: model!,
                  instance: instance!,
                  images: item['images'] as List? ?? [],
                ),
              if (item['truncated'] == true)
                Text(
                  context.l10n.contentTruncated,
                  style: context.pircText.tag.copyWith(
                    color: context.pirc.warning,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Uses the transcript's shared region to select across markdown blocks and
/// let the enclosing scrollable handle dragging at the viewport edges.
class _SelectableMarkdown extends StatelessWidget {
  const _SelectableMarkdown({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final body = MarkdownBody(
      data: text,
      selectable: false,
      styleSheet: context.pircMarkdown,
      fitContent: true,
    );
    return SelectionContainer.maybeOf(context) == null
        ? SelectionArea(child: body)
        : body;
  }
}

class _StreamingActivityContent extends StatefulWidget {
  const _StreamingActivityContent({
    required this.id,
    required this.text,
    required this.arguments,
    required this.complete,
    required this.tool,
    required this.truncated,
  });
  final String id;
  final String text;
  final String arguments;
  final bool complete;
  final bool tool;
  final bool truncated;

  @override
  State<_StreamingActivityContent> createState() =>
      _StreamingActivityContentState();
}

class _StreamingActivityContentState extends State<_StreamingActivityContent> {
  final scroll = ScrollController();
  bool following = true;
  bool queued = false;
  bool adjusting = false;

  @override
  void initState() {
    super.initState();
    if (!widget.complete) followLatest();
  }

  @override
  void didUpdateWidget(_StreamingActivityContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text ||
        widget.arguments != oldWidget.arguments) {
      followLatest();
    }
  }

  void followLatest() {
    if (!following || queued) return;
    queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      queued = false;
      if (mounted &&
          following &&
          scroll.hasClients &&
          !scroll.position.isScrollingNotifier.value) {
        adjusting = true;
        try {
          scroll.jumpTo(scroll.position.maxScrollExtent);
        } finally {
          adjusting = false;
        }
      }
    });
  }

  bool onScroll(ScrollNotification notification) {
    // SelectableText also contains a scrollable; only observe this panel.
    if (notification.depth == 0 && !adjusting) {
      if (notification is ScrollStartNotification) {
        following = false;
      } else if (notification is ScrollEndNotification) {
        following = scroll.hasClients && scroll.position.extentAfter < 24;
      }
    }
    return false;
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) => NotificationListener<ScrollNotification>(
    onNotification: onScroll,
    child: SingleChildScrollView(
      // Expansion, panel scroll, and selectable text each have their own key.
      key: PageStorageKey('content-scroll-${widget.id}'),
      controller: scroll,
      primary: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.arguments.isNotEmpty) ...[
            Text(context.l10n.arguments, style: context.pircText.tag),
            const SizedBox(height: PircSpacing.s6),
            SelectableText(
              widget.arguments,
              key: PageStorageKey('arguments-text-${widget.id}'),
              style: context.pirc.code,
            ),
          ],
          if (widget.text.isNotEmpty) ...[
            if (widget.arguments.isNotEmpty)
              const SizedBox(height: PircSpacing.s6),
            if (widget.tool) ...[
              Text(context.l10n.output, style: context.pircText.tag),
              const SizedBox(height: PircSpacing.s6),
            ],
            SelectableText(
              widget.text,
              key: PageStorageKey('output-text-${widget.id}'),
              style: widget.tool ? context.pirc.code : context.pirc.thinking,
            ),
          ],
          if (widget.truncated)
            Text(
              context.l10n.contentTruncated,
              style: context.pircText.tag.copyWith(color: context.pirc.warning),
            ),
        ],
      ),
    ),
  );
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    color: context.pircColors.surface,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: PircRadii.activity,
      side: BorderSide(
        color: context.pircColors.outlineVariant,
        width: PircLayout.borderWidth,
      ),
    ),
    child: child,
  );
}

class _AwaitingReply extends StatelessWidget {
  const _AwaitingReply({super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: PircSpacing.s16),
    child: _ActivityCard(
      child: ListTile(
        minTileHeight: PircLayout.actionSize,
        contentPadding: const EdgeInsets.symmetric(horizontal: PircSpacing.s14),
        leading: const LoadingIndicator(),
        title: Text(
          context.l10n.waitingForResponse,
          style: context.pircText.activityTitle,
        ),
      ),
    ),
  );
}

class LoadingIndicator extends StatelessWidget {
  const LoadingIndicator({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: PircIconSizes.activity,
    height: PircIconSizes.activity,
    child: CircularProgressIndicator(
      strokeWidth: PircLayout.loadingStrokeWidth,
      semanticsLabel: 'loading',
    ),
  );
}

class ConnectionOptions {
  ConnectionOptions(
    this.url, {
    this.name = '',
    this.backupAddresses = const [],
    this.repair = false,
  });
  final bool repair;
  final List<String> backupAddresses;
  final String url;
  final String name;
}

class ConnectionDialog extends StatefulWidget {
  const ConnectionDialog({
    super.key,
    required this.endpoint,
    this.adding = false,
    this.initialName = '',
    this.initialBackupAddresses = const [],
    this.occupiedAddresses = const {},
  });
  final List<String> initialBackupAddresses;
  final Set<String> occupiedAddresses;
  final bool adding;
  final String initialName;
  final String endpoint;
  @override
  State<ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<ConnectionDialog> {
  late final addresses = [
    TextEditingController(text: computerAddressForEditing(widget.endpoint)),
    ...widget.initialBackupAddresses.map(
      (a) => TextEditingController(text: computerAddressForEditing(a)),
    ),
  ];
  TextEditingController get address => addresses.first;
  String? validateAddress(String? value) {
    if (value == null || value.trim().isEmpty) return context.l10n.enterAddress;
    final normalized = computerAddress(value);
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return context.l10n.invalidAddress;
    }
    if (addresses.where((a) => computerAddress(a.text) == normalized).length >
        1) {
      return context.l10n.duplicateAddress;
    }
    if (widget.occupiedAddresses.contains(normalized)) {
      return context.l10n.addressOwnedByOtherDevice;
    }
    return null;
  }

  late final name = TextEditingController(text: widget.initialName);
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    for (final controller in addresses) {
      controller.dispose();
    }
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: context.pircColors.surface,
        borderRadius: PircRadii.dialog,
        boxShadow: PircEffects.dialogShadow,
      ),
      child: SizedBox(
        width: PircLayout.dialogWidth,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(PircSpacing.s24),
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.adding
                      ? context.l10n.addDevice
                      : context.l10n.connectionSettings,
                  style: Theme.of(context).dialogTheme.titleTextStyle,
                ),
                const SizedBox(height: PircSpacing.s16),
                Text(
                  context.l10n.deviceNameOptional,
                  style: context.pircText.hint,
                ),
                const SizedBox(height: PircSpacing.s6),
                TextFormField(
                  key: const Key('connection-name'),
                  controller: name,
                  decoration: const InputDecoration(),
                ),
                const SizedBox(height: PircSpacing.s16),
                for (var i = 0; i < addresses.length; i++) ...[
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          i == 0
                              ? context.l10n.primaryAddress
                              : context.l10n.backupAddress(i.toString()),
                          style: context.pircText.hint,
                        ),
                      ),
                      if (addresses.length > 1) ...[
                        IconButton(
                          tooltip: context.l10n.moveUp,
                          onPressed: i == 0
                              ? null
                              : () => setState(() {
                                  final item = addresses.removeAt(i);
                                  addresses.insert(i - 1, item);
                                }),
                          icon: const Icon(
                            LucideIcons.arrowUp,
                            size: PircIconSizes.small,
                          ),
                        ),
                        IconButton(
                          tooltip: context.l10n.moveDown,
                          onPressed: i == addresses.length - 1
                              ? null
                              : () => setState(() {
                                  final item = addresses.removeAt(i);
                                  addresses.insert(i + 1, item);
                                }),
                          icon: const Icon(
                            LucideIcons.arrowDown,
                            size: PircIconSizes.small,
                          ),
                        ),
                      ],
                      if (i > 0)
                        IconButton(
                          tooltip: context.l10n.removeAddress,
                          onPressed: () {
                            final removed = addresses.removeAt(i);
                            setState(() {});
                            WidgetsBinding.instance.addPostFrameCallback(
                              (_) => removed.dispose(),
                            );
                          },
                          icon: const Icon(
                            LucideIcons.x,
                            size: PircIconSizes.small,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: PircSpacing.s6),
                  TextFormField(
                    key: i == 0
                        ? const Key('connection-url')
                        : ObjectKey(addresses[i]),
                    controller: addresses[i],
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(hintText: '192.168.1.10'),
                    validator: validateAddress,
                  ),
                  const SizedBox(height: PircSpacing.s8),
                ],
                TextButton.icon(
                  key: const Key('add-backup-address'),
                  onPressed: () =>
                      setState(() => addresses.add(TextEditingController())),
                  icon: const Icon(LucideIcons.plus, size: PircIconSizes.small),
                  label: Text(context.l10n.addBackupAddress),
                ),
                const SizedBox(height: PircSpacing.s16),
                if (!widget.adding && widget.endpoint.isNotEmpty)
                  TextButton(
                    key: const Key('repair-device'),
                    onPressed: () async {
                      FocusManager.instance.primaryFocus?.unfocus();
                      final accepted = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text(context.l10n.repairDeviceQuestion),
                          content: Text(context.l10n.repairDeviceDescription),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: Text(context.l10n.cancel),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              key: const Key('confirm-repair-device'),
                              child: Text(context.l10n.repair),
                            ),
                          ],
                        ),
                      );
                      if (context.mounted && accepted == true) {
                        Navigator.pop(
                          context,
                          ConnectionOptions(
                            widget.endpoint,
                            name: widget.initialName,
                            backupAddresses: widget.initialBackupAddresses,
                            repair: true,
                          ),
                        );
                      }
                    },
                    child: Text(context.l10n.repairDevice),
                  ),
                OverflowBar(
                  alignment: MainAxisAlignment.end,
                  spacing: PircSpacing.s8,
                  overflowSpacing: PircSpacing.s8,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(context.l10n.cancel),
                    ),
                    FilledButton(
                      key: const Key('connect-submit'),
                      onPressed: () {
                        if (form.currentState!.validate()) {
                          Navigator.pop(
                            context,
                            ConnectionOptions(
                              computerAddress(address.text),
                              name: name.text,
                              backupAddresses: addresses
                                  .skip(1)
                                  .map((a) => computerAddress(a.text))
                                  .toList(),
                            ),
                          );
                        }
                      },
                      child: Text(
                        widget.adding ? context.l10n.add : context.l10n.save,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
