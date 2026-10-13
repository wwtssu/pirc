import 'pirc_localizations.dart';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'pirc_controller.dart';
import 'pirc_theme.dart';

import 'dart:convert';

const builtinNames = {'model', 'thinking', 'name', 'session', 'compact'};
const builtinTitles = {
  'model': 'Select model',
  'thinking': 'Thinking level',
  'name': 'Session name',
  'session': 'Session information',
  'compact': 'Compact context',
};
Future<void> showBuiltinCommandSheet(
  BuildContext context,
  PircController model,
  SessionView session,
  String command, {
  VoidCallback? onReady,
}) async {
  late final Map<String, dynamic> data;
  try {
    data = await model.runBuiltin(session, command);
  } catch (failure) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.localize('$failure'))));
    }
    return;
  }
  if (!context.mounted) return;
  onReady?.call();
  if (command == 'name') {
    await showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        key: const Key('session-name-dialog'),
        clipBehavior: Clip.antiAlias,
        child: BuiltinCommandSheet(
          model: model,
          session: session,
          command: command,
          initialData: data,
        ),
      ),
    );
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: context.pircColors.surface,
    shape: const RoundedRectangleBorder(borderRadius: PircRadii.dialog),
    clipBehavior: Clip.antiAlias,
    builder: (_) => BuiltinCommandSheet(
      model: model,
      session: session,
      command: command,
      initialData: data,
    ),
  );
}

class BuiltinCommandSheet extends StatefulWidget {
  const BuiltinCommandSheet({
    super.key,
    required this.model,
    required this.session,
    required this.command,
    required this.initialData,
  });
  final PircController model;
  final SessionView session;
  final String command;
  final Map<String, dynamic> initialData;
  @override
  State<BuiltinCommandSheet> createState() => _BuiltinCommandSheetState();
}

class _BuiltinCommandSheetState extends State<BuiltinCommandSheet> {
  final search = TextEditingController();
  final name = TextEditingController();
  late final Map<String, dynamic> data;
  String? error;
  bool saving = false;
  Map? selectedRole;
  bool loadingRole = false;
  @override
  void initState() {
    super.initState();
    data = Map<String, dynamic>.of(widget.initialData);
    name.text = data['name'] as String? ?? '';
  }

  @override
  void dispose() {
    search.dispose();
    name.dispose();
    super.dispose();
  }

  Future<void> save(String args) async {
    if (saving || args.trim().isEmpty) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.model.runBuiltin(
        widget.session,
        widget.command,
        args.trim(),
      );
      if (mounted) Navigator.pop(context);
    } catch (failure) {
      if (mounted) {
        setState(() => error = '$failure'.replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> openRole(Map role) async {
    if (saving || loadingRole) return;
    setState(() {
      loadingRole = true;
      error = null;
    });
    try {
      final result = await widget.model.runBuiltin(
        widget.session,
        'model',
        role['id'] == 'current_session'
            ? ''
            : jsonEncode({'op': 'role_models', 'role': role['id']}),
      );
      if (mounted) {
        setState(() {
          data.clear();
          data.addAll(result);
          selectedRole =
              (result['roles'] as List?)
                  ?.cast<Map>()
                  .where((r) => r['id'] == role['id'])
                  .firstOrNull ??
              role;
          search.clear();
        });
      }
    } catch (failure) {
      if (mounted) {
        setState(() => error = '$failure'.replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => loadingRole = false);
    }
  }

  Future<void> saveRole(String? selector) async {
    if (saving || selectedRole == null) return;
    if (selectedRole!['id'] == 'current_session') {
      if (selector != null) await save(selector);
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final result = await widget.model.runBuiltin(
        widget.session,
        'model',
        jsonEncode({
          'op': selector == null ? 'clear_role' : 'set_role',
          'role': selectedRole!['id'],
          'selector': ?selector,
        }),
      );
      if (mounted) {
        setState(() {
          data.clear();
          data.addAll(result);
          selectedRole = null;
          search.clear();
        });
      }
    } catch (failure) {
      if (mounted) {
        setState(() => error = '$failure'.replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nameEditor = widget.command == 'name';
    final selector = {'model', 'thinking'}.contains(widget.command);
    final roleCatalog = widget.command == 'model' && data['roles'] != null;
    final compact =
        nameEditor || selector && (!roleCatalog || selectedRole != null);
    final header = Row(
      children: [
        if (selectedRole != null)
          IconButton(
            key: const Key('model-role-back'),
            tooltip: context.l10n.back,
            onPressed: saving
                ? null
                : () => setState(() {
                    selectedRole = null;
                    search.clear();
                    error = null;
                  }),
            icon: const Icon(LucideIcons.arrowLeft),
          ),
        Expanded(
          child: Text(
            selectedRole != null
                ? (selectedRole!['id'] == 'current_session'
                      ? context.l10n.currentSessionModel
                      : selectedRole!['id'] as String)
                : roleCatalog
                ? context.l10n.modelRoles
                : context.localize(builtinTitles[widget.command]!),
            style: context.pircText.cardTitle,
          ),
        ),
        IconButton(
          tooltip: context.l10n.close,
          onPressed: () => Navigator.pop(context),
          icon: const Icon(LucideIcons.x),
        ),
      ],
    );
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(
        PircSpacing.s20,
        PircSpacing.s12,
        PircSpacing.s20,
        PircSpacing.s16,
      ),
      child: Column(
        mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          if (saving || loadingRole) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: PircSpacing.s12),
              child: Text(
                context.localize(error!),
                key: const Key('builtin-error'),
                style: context.pircText.body.copyWith(
                  color: context.pirc.warning,
                ),
              ),
            ),
          ...content(context),
        ],
      ),
    );
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    if (selector) {
      return Padding(
        padding: EdgeInsets.only(bottom: keyboard),
        child: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, constraints) => Center(
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: PircLayout.maxContentWidth,
                  maxHeight:
                      constraints.maxHeight * PircLayout.sheetHeightFactor,
                ),
                child: body,
              ),
            ),
          ),
        ),
      );
    }
    if (nameEditor) {
      return SizedBox(
        width: PircLayout.dialogWidth,
        child: SingleChildScrollView(child: body),
      );
    }
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * PircLayout.sheetHeightFactor,
      child: Padding(
        padding: EdgeInsets.only(bottom: keyboard),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: PircLayout.maxContentWidth,
            ),
            child: body,
          ),
        ),
      ),
    );
  }

  List<Widget> content(BuildContext context) {
    switch (widget.command) {
      case 'model':
        final roles = data['roles'] as List?;
        if (roles != null && selectedRole == null) {
          return [
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  ListTile(
                    key: const Key('model-role-current'),
                    title: Text(
                      context.l10n.currentSessionModel,
                      style: context.pircText.body,
                    ),
                    subtitle: Text(
                      (data['current'] as Map?)?['name'] as String? ??
                          context.l10n.noModelsAvailable,
                      style: context.pircText.path,
                    ),
                    trailing: const Icon(LucideIcons.chevronRight),
                    onTap: saving || loadingRole
                        ? null
                        : () => openRole({'id': 'current_session'}),
                  ),
                  const Divider(),
                  for (final category in ['chat', 'kind']) ...[
                    if (roles.any((r) => r['category'] == category))
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: PircSpacing.s16,
                          vertical: PircSpacing.s8,
                        ),
                        child: Text(
                          category == 'chat'
                              ? context.l10n.modelRoles
                              : context.l10n.otherModelTypes,
                          style: context.pircText.hint,
                        ),
                      ),
                    for (final role in roles.cast<Map>().where(
                      (r) => r['category'] == category,
                    ))
                      ListTile(
                        key: ValueKey('model-role-${role['id']}'),
                        title: Text(
                          role['id'] as String,
                          style: context.pircText.body,
                        ),
                        subtitle: Text(
                          role['selector'] as String? ??
                              (role['resolved'] as Map?)?['name'] as String? ??
                              context.l10n.roleUnassigned,
                          style: context.pircText.path,
                        ),
                        trailing: const Icon(LucideIcons.chevronRight),
                        onTap: saving || loadingRole
                            ? null
                            : () => openRole(role),
                      ),
                  ],
                ],
              ),
            ),
          ];
        }
        final current =
            selectedRole != null && selectedRole!['id'] != 'current_session'
            ? selectedRole!['resolved'] as Map?
            : data['current'] as Map?;
        final models = (data['models'] as List).cast<Map>();
        final query = search.text.trim().toLowerCase();
        final visible = models
            .where(
              (m) => '${m['provider']}/${m['id']} ${m['name']}'
                  .toLowerCase()
                  .contains(query),
            )
            .toList();
        return [
          if (selectedRole != null && selectedRole!['id'] != 'current_session')
            ListTile(
              key: const Key('reset-model-role'),
              title: Text(
                context.l10n.useRoleDefault,
                style: context.pircText.body,
              ),
              onTap: saving ? null : () => saveRole(null),
            ),
          TextField(
            key: const Key('model-search'),
            controller: search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: context.l10n.searchModels,
              prefixIcon: Icon(LucideIcons.search),
            ),
          ),
          const SizedBox(height: PircSpacing.s12),
          Flexible(
            child: visible.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: PircSpacing.s20,
                    ),
                    child: Text(
                      models.isEmpty
                          ? context.l10n.noModelsAvailable
                          : context.l10n.noMatchingModels,
                      style: context.pircText.body,
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: visible.length,
                    itemBuilder: (_, i) {
                      final m = visible[i];
                      final selected =
                          current?['provider'] == m['provider'] &&
                          current?['id'] == m['id'];
                      return ListTile(
                        key: ValueKey('model-${m['provider']}/${m['id']}'),
                        shape: const RoundedRectangleBorder(
                          borderRadius: PircRadii.input,
                        ),
                        title: Text(
                          m['name'] as String,
                          style: context.pircText.body,
                        ),
                        subtitle: Text(
                          '${m['provider']}/${m['id']}',
                          style: context.pircText.path,
                        ),
                        trailing: selected
                            ? Icon(
                                LucideIcons.check,
                                color: context.pircColors.primary,
                              )
                            : null,
                        onTap: saving
                            ? null
                            : () => selectedRole == null
                                  ? save('${m['provider']}/${m['id']}')
                                  : saveRole('${m['provider']}/${m['id']}'),
                      );
                    },
                  ),
          ),
        ];
      case 'thinking':
        final levels = (data['levels'] as List).cast<String>();
        return [
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final level in levels)
                  ListTile(
                    key: ValueKey('thinking-$level'),
                    shape: const RoundedRectangleBorder(
                      borderRadius: PircRadii.input,
                    ),
                    title: Text(level, style: context.pircText.body),
                    trailing: data['level'] == level
                        ? Icon(
                            LucideIcons.check,
                            color: context.pircColors.primary,
                          )
                        : null,
                    onTap: saving ? null : () => save(level),
                  ),
              ],
            ),
          ),
        ];
      case 'name':
        return [
          TextField(
            key: const Key('session-name-editor'),
            controller: name,
            enabled: !saving,
            maxLength: 256,
            buildCounter:
                (
                  context, {
                  required currentLength,
                  required isFocused,
                  maxLength,
                }) => maxLength == null || currentLength < maxLength - 32
                ? null
                : Text(
                    '$currentLength/$maxLength',
                    style: context.pircText.path,
                  ),
            decoration: InputDecoration(
              hintText: context.l10n.enterSessionName,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: save,
          ),
          const SizedBox(height: PircSpacing.s16),
          FilledButton(
            key: const Key('save-session-name'),
            onPressed: saving || name.text.trim().isEmpty
                ? null
                : () => save(name.text),
            child: Text(context.l10n.save),
          ),
        ];
      case 'session':
        final info = data['info'] as Map;
        final controls =
            widget.model.sessions
                    .where((s) => s.instance == widget.session.instance)
                    .firstOrNull
                    ?.snapshot['controls']
                as Map?;
        final model = controls?['model'] as Map?;
        final tokens = info['context_tokens'] as num?;
        final window = info['context_window'] as num? ?? 0;
        final rows = <String, String>{
          context.l10n.name: info['name'] as String? ?? context.l10n.unnamed,
          context.l10n.workingDirectory: info['cwd'] as String,
          context.l10n.model: model == null
              ? context.l10n.notSelected
              : '${model['provider']}/${model['id']}',
          context.l10n.thinkingLevel:
              controls?['thinking_level'] as String? ?? 'off',
          context.l10n.context: tokens == null
              ? context.l10n.waitingForNextResponse
              : '$tokens / $window${window > 0 ? ' · ${(tokens / window * 100).toStringAsFixed(1)}%' : ''}',
          context.l10n.messages: context.l10n.messageCounts(
            info['total_messages'].toString(),
            info['user_messages'].toString(),
            info['assistant_messages'].toString(),
          ),
          context.l10n.tools: context.l10n.toolCounts(
            info['tool_calls'].toString(),
            info['tool_results'].toString(),
          ),
          context.l10n.inputTokens:
              '${(info['input_tokens'] as num) + (info['cache_read_tokens'] as num) + (info['cache_write_tokens'] as num)}',
          context.l10n.outputTokens: '${info['output_tokens']}',
          context.l10n.cacheReadTokens: '${info['cache_read_tokens']}',
          context.l10n.cacheWriteTokens: '${info['cache_write_tokens']}',
          context.l10n.costUsd: info['cost_usd'] as String,
          context.l10n.sessionId: info['session_id'] as String,
          if (info['session_file'] != null)
            context.l10n.sessionFile: info['session_file'] as String,
        };
        return [
          Expanded(
            child: ListView(
              children: [
                for (final row in rows.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: PircSpacing.s8,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(row.key, style: context.pircText.path),
                        const SizedBox(height: PircSpacing.s4),
                        SelectableText(row.value, style: context.pircText.body),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ];
      default:
        return [];
    }
  }
}
