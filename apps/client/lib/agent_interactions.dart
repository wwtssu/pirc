import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'pirc_controller.dart';
import 'pirc_localizations.dart';
import 'pirc_loading.dart';
import 'pirc_theme.dart';

class AskPanel extends StatefulWidget {
  const AskPanel({
    super.key,
    required this.request,
    required this.session,
    required this.model,
  });
  final Map<String, dynamic> request;
  final SessionView session;
  final PircController model;
  @override
  State<AskPanel> createState() => _AskPanelState();
}

class _AskPanelState extends State<AskPanel> {
  final selections = <String, Set<int>>{};
  final answers = <String, TextEditingController>{};
  final notes = <String, TextEditingController>{};
  bool submitting = false;
  bool submitted = false;
  String? error;
  late final ValueNotifier<Map<String, dynamic>> draft;
  List<Map> get questions => (widget.request['questions'] as List).cast<Map>();
  @override
  void initState() {
    super.initState();
    draft = widget.model.askDraft(
      widget.session,
      widget.request['id'] as String,
    );
    submitting = draft.value['submitting'] == true;
    submitted = draft.value['submitted'] == true;
    error = draft.value['error'] as String?;
    draft.addListener(updateSubmission);
    for (final q in questions) {
      final id = q['id'] as String;
      final recommended = q['recommended'] as int?;
      final saved = (draft.value['questions'] as Map?)?[id] as Map?;
      selections[id] = saved != null
          ? (saved['selected'] as List).cast<int>().toSet()
          : {
              if (recommended != null &&
                  recommended >= 0 &&
                  recommended < (q['options'] as List).length)
                recommended,
            };
      answers[id] = TextEditingController(text: saved?['text'] as String?);
      notes[id] = TextEditingController(text: saved?['note'] as String?);
      answers[id]!.addListener(saveDraft);
      notes[id]!.addListener(saveDraft);
    }
  }

  @override
  void dispose() {
    draft.removeListener(updateSubmission);
    for (final c in [...answers.values, ...notes.values]) {
      c.dispose();
    }
    super.dispose();
  }

  void updateSubmission() {
    if (mounted) {
      setState(() {
        submitting = draft.value['submitting'] == true;
        submitted = draft.value['submitted'] == true;
        error = draft.value['error'] as String?;
      });
    }
  }

  void saveDraft() {
    draft.value = {
      ...draft.value,
      'questions': {
        for (final q in questions)
          q['id']: {
            'selected': selections[q['id']]!.toList(),
            'text': answers[q['id']]!.text,
            'note': notes[q['id']]!.text,
          },
      },
    };
  }

  Future<void> submit() async {
    if (submitting || submitted) return;
    if (questions.any(
      (q) =>
          q['multi'] != true &&
          selections[q['id']]!.isEmpty &&
          answers[q['id']]!.text.trim().isEmpty,
    )) {
      draft.value = {
        ...draft.value,
        'error': 'Choose an option or enter an answer for each question.',
      };
      return;
    }
    draft.value = {...draft.value, 'submitting': true, 'error': null};
    try {
      await widget.model.answerAsk(
        widget.session,
        widget.request['id'] as String,
        [
          for (final q in questions)
            {
              'id': q['id'],
              'selected': selections[q['id']]!.toList()..sort(),
              'text': answers[q['id']]!.text.trim().isEmpty
                  ? null
                  : answers[q['id']]!.text.trim(),
              'note': notes[q['id']]!.text.trim().isEmpty
                  ? null
                  : notes[q['id']]!.text.trim(),
            },
        ],
      );
      draft.value = {...draft.value, 'submitted': true};
    } catch (failure) {
      draft.value = {...draft.value, 'error': '$failure'};
    } finally {
      draft.value = {...draft.value, 'submitting': false};
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled =
        !submitting && !submitted && widget.model.connection == 'connected';
    return Padding(
      padding: const EdgeInsets.only(bottom: PircSpacing.s16),
      child: Material(
        color: context.pircColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: PircRadii.activity,
          side: BorderSide(color: context.pircColors.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(PircSpacing.s14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    LucideIcons.messageCircleQuestion,
                    size: PircIconSizes.activity,
                    color: context.pircColors.primary,
                  ),
                  const SizedBox(width: PircSpacing.s8),
                  Expanded(
                    child: Text(
                      context.l10n.answerQuestions,
                      style: context.pircText.activityTitle,
                    ),
                  ),
                ],
              ),
              for (final q in questions) ...[
                const SizedBox(height: PircSpacing.s16),
                if ((q['header'] as String?)?.isNotEmpty == true)
                  Text(q['header'] as String, style: context.pircText.hint),
                Text(q['question'] as String, style: context.pircText.body),
                const SizedBox(height: PircSpacing.s8),
                for (var i = 0; i < (q['options'] as List).length; i++)
                  _option(q, i, enabled),
                const SizedBox(height: PircSpacing.s8),
                TextField(
                  key: ValueKey('ask-text-${q['id']}'),
                  controller: answers[q['id']],
                  enabled: enabled,
                  minLines: 1,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: context.l10n.customAnswer,
                  ),
                ),
                const SizedBox(height: PircSpacing.s8),
                TextField(
                  key: ValueKey('ask-note-${q['id']}'),
                  controller: notes[q['id']],
                  enabled: enabled,
                  minLines: 1,
                  maxLines: 3,
                  decoration: InputDecoration(
                    hintText: context.l10n.answerNote,
                  ),
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: PircSpacing.s12),
                Text(
                  context.localize(error!),
                  style: context.pircText.hint.copyWith(
                    color: context.pirc.warning,
                  ),
                ),
              ],
              const SizedBox(height: PircSpacing.s16),
              FilledButton(
                key: const Key('submit-ask'),
                onPressed: enabled ? submit : null,
                child: submitting
                    ? const PircLoadingMark()
                    : Text(
                        submitted
                            ? context.l10n.completed
                            : context.l10n.submitAnswers,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _option(Map q, int index, bool enabled) {
    final option = (q['options'] as List)[index] as Map;
    final id = q['id'] as String;
    final selected = selections[id]!.contains(index);
    void change() => setState(() {
      if (q['multi'] != true) {
        selections[id] = {index};
      } else if (selected) {
        selections[id]!.remove(index);
      } else {
        selections[id]!.add(index);
      }
      saveDraft();
    });
    return ListTile(
      key: ValueKey('ask-option-$id-$index'),
      contentPadding: EdgeInsets.zero,
      onTap: enabled ? change : null,
      selected: selected,
      leading: Icon(
        q['multi'] == true
            ? (selected ? LucideIcons.squareCheck : LucideIcons.square)
            : (selected ? LucideIcons.circleDot : LucideIcons.circle),
        size: PircIconSizes.activity,
        color: selected
            ? context.pircColors.primary
            : context.pircColors.onSurfaceVariant,
      ),
      title: Text(
        option['label'] as String,
        style: context.pircText.description,
      ),
      subtitle: option['description'] == null && option['preview'] == null
          ? null
          : Text(
              [
                option['description'],
                option['preview'],
              ].whereType<String>().join('\n'),
              style: context.pircText.hint,
            ),
    );
  }
}

class TodoList extends StatelessWidget {
  const TodoList({super.key, required this.phases});
  final List phases;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final phase in phases.cast<Map>()) ...[
        Padding(
          padding: const EdgeInsets.only(bottom: PircSpacing.s8),
          child: Row(
            children: [
              Icon(
                LucideIcons.layers,
                size: PircIconSizes.small,
                color: context.pircColors.onSurfaceVariant,
              ),
              const SizedBox(width: PircSpacing.s8),
              Expanded(
                child: Text(
                  (phase['name'] as String).isEmpty
                      ? context.l10n.todoTitle
                      : phase['name'] as String,
                  style: context.pircText.activityTitle,
                ),
              ),
              Text(
                '${(phase['tasks'] as List).where((t) => t['status'] == 'completed').length}/${(phase['tasks'] as List).length}',
                style: context.pircText.path,
              ),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.only(
            left: PircSpacing.s8,
            bottom: PircSpacing.s12,
          ),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: context.pircColors.outlineVariant,
                width: PircLayout.borderWidth,
              ),
            ),
          ),
          child: Column(
            children: [
              for (final task in (phase['tasks'] as List).cast<Map>())
                Padding(
                  padding: const EdgeInsets.only(bottom: PircSpacing.s10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: PircSpacing.s8),
                        child: Container(
                          width: PircSpacing.s12,
                          height: PircLayout.borderWidth,
                          color: context.pircColors.outlineVariant,
                        ),
                      ),
                      const SizedBox(width: PircSpacing.s8),
                      Icon(
                        switch (task['status']) {
                          'completed' => LucideIcons.circleCheck,
                          'in_progress' => LucideIcons.circleDot,
                          'blocked' => LucideIcons.circleAlert,
                          'abandoned' => LucideIcons.circleX,
                          _ => LucideIcons.circle,
                        },
                        size: PircIconSizes.small,
                        color: switch (task['status']) {
                          'completed' => context.pirc.success,
                          'in_progress' => context.pircColors.primary,
                          'blocked' => context.pirc.warning,
                          _ => context.pircColors.onSurfaceVariant,
                        },
                      ),
                      const SizedBox(width: PircSpacing.s8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              task['content'] as String,
                              style: context.pircText.description,
                            ),
                            Text(switch (task['status']) {
                              'completed' => context.l10n.completed,
                              'in_progress' => context.l10n.todoInProgress,
                              'blocked' => context.l10n.todoBlocked,
                              'abandoned' => context.l10n.todoAbandoned,
                              _ => context.l10n.todoPending,
                            }, style: context.pircText.hint),
                            if (task['blocker'] != null)
                              Text(
                                task['blocker'] as String,
                                style: context.pircText.hint.copyWith(
                                  color: context.pirc.warning,
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
    ],
  );
}

class PersistentTodoPanel extends StatefulWidget {
  const PersistentTodoPanel({
    super.key,
    required this.phases,
    this.maxTreeHeight = PircLayout.activityMaxHeight,
  });
  final List phases;
  final double maxTreeHeight;

  @override
  State<PersistentTodoPanel> createState() => _PersistentTodoPanelState();
}

class _PersistentTodoPanelState extends State<PersistentTodoPanel> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) {
    final tasks = widget.phases
        .cast<Map>()
        .expand((phase) => (phase['tasks'] as List).cast<Map>())
        .toList();
    final completed = tasks
        .where((task) => task['status'] == 'completed')
        .length;
    Map? current;
    Map? currentPhase;
    for (final status in ['in_progress', 'blocked', 'pending']) {
      for (final phase in widget.phases.cast<Map>()) {
        final match = (phase['tasks'] as List)
            .cast<Map>()
            .where((task) => task['status'] == status)
            .firstOrNull;
        if (match != null) {
          current = match;
          currentPhase = phase;
          break;
        }
      }
      if (current != null) break;
    }
    final statusLabel = switch (current?['status']) {
      'in_progress' => context.l10n.todoInProgress,
      'blocked' => context.l10n.todoBlocked,
      'pending' => context.l10n.todoPending,
      _ => context.l10n.completed,
    };
    return Container(
      key: const Key('persistent-todo-panel'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: context.pircColors.surface,
        borderRadius: PircRadii.activity,
        border: Border.all(color: context.pircColors.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            expanded: expanded,
            child: InkWell(
              key: const Key('toggle-todo-panel'),
              onTap: () => setState(() => expanded = !expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: PircSpacing.s12,
                  vertical: PircSpacing.s10,
                ),
                child: Row(
                  children: [
                    Icon(
                      LucideIcons.listTodo,
                      size: PircIconSizes.small,
                      color: context.pircColors.primary,
                    ),
                    const SizedBox(width: PircSpacing.s10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            current?['content'] as String? ??
                                context.l10n.todoTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.pircText.activityTitle,
                          ),
                          Text(
                            [
                              if ((currentPhase?['name'] as String? ?? '')
                                  .isNotEmpty)
                                currentPhase!['name'] as String,
                              statusLabel,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.pircText.hint,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: PircSpacing.s8),
                    Text(
                      '$completed/${tasks.length}',
                      style: context.pircText.hint,
                    ),
                    const SizedBox(width: PircSpacing.s8),
                    Icon(
                      expanded
                          ? LucideIcons.chevronUp
                          : LucideIcons.chevronDown,
                      size: PircIconSizes.small,
                      color: context.pircColors.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (expanded && widget.maxTreeHeight > 0)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: widget.maxTreeHeight.clamp(
                  0.0,
                  MediaQuery.sizeOf(context).height *
                      PircLayout.taskTreeHeightFactor,
                ),
              ),
              child: SingleChildScrollView(
                key: const Key('todo-tree-scroll'),
                padding: const EdgeInsets.symmetric(
                  horizontal: PircSpacing.s12,
                ),
                child: TodoList(phases: widget.phases),
              ),
            ),
          LinearProgressIndicator(
            value: tasks.isEmpty ? 0 : completed / tasks.length,
            minHeight: 2,
            color: context.pircColors.primary,
            backgroundColor: context.pircColors.primaryContainer,
          ),
        ],
      ),
    );
  }
}
