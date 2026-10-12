import 'pirc_localizations.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'pirc_controller.dart';
import 'pirc_theme.dart';

// This page queries the selected computer; no native local/desktop file dialog.
class RemoteDirectoryPicker extends StatefulWidget {
  const RemoteDirectoryPicker({
    super.key,
    required this.model,
    this.initialPath,
    this.computerName,
  });
  final PircController model;
  final String? initialPath;
  final String? computerName;

  @override
  State<RemoteDirectoryPicker> createState() => _RemoteDirectoryPickerState();
}

class _RemoteDirectoryPickerState extends State<RemoteDirectoryPicker> {
  final path = TextEditingController();
  final pathFocus = FocusNode();
  final scroll = ScrollController();
  bool editingPath = false;
  String location = '';
  RemoteDirectoryPage? page;
  List<RemoteDirectory> directories = [];
  bool loading = true;
  bool more = false;
  bool showHidden = false;
  bool creating = false;
  bool failedAppend = false;
  String? error;
  String? requested;
  int revision = 0;
  late bool connected;

  @override
  void initState() {
    super.initState();
    connected = widget.model.connection == 'connected';
    widget.model.addListener(refresh);
    read(widget.initialPath);
  }

  void refresh() {
    final next = widget.model.connection == 'connected';
    if (!mounted || next == connected) return;
    setState(() {
      connected = next;
      if (!next) {
        revision++;
        loading = more = false;
        error = 'Device disconnected. Reconnect and try again.';
      }
    });
  }

  @override
  void dispose() {
    revision++;
    widget.model.removeListener(refresh);
    path.dispose();
    pathFocus.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> read(String? target, {bool append = false}) async {
    if (!connected) {
      setState(() {
        loading = more = false;
        error = 'Device disconnected. Reconnect and try again.';
      });
      return;
    }
    final current = ++revision;
    final cursor = append ? page?.nextCursor : null;
    requested = target?.trim().isEmpty == true ? null : target?.trim();
    if (!append) {
      path.text = requested ?? page?.home ?? '';
      location = _displayDirectoryPath(path.text, page?.home);
      editingPath = false;
      FocusManager.instance.primaryFocus?.unfocus();
      if (scroll.hasClients) scroll.jumpTo(0);
    }
    setState(() {
      loading = !append;
      more = append;
      failedAppend = append;
      error = null;
    });
    try {
      final result = await widget.model
          .browseDirectories(
            path: requested,
            cursor: cursor,
            showHidden: showHidden,
          )
          .timeout(
            const Duration(seconds: 8),
            onTimeout: () {
              throw StateError(
                'Reading the directory timed out. Retry or choose another directory.',
              );
            },
          );
      if (!mounted || revision != current) return;
      setState(() {
        directories = append
            ? [...directories, ...result.directories]
            : result.directories;
        page = result;
        // A reply arriving while the user types must not replace the draft.
        if (!editingPath) path.text = result.path;
        location = result.path;
      });
    } catch (failure) {
      if (!mounted || revision != current) return;
      setState(() => error = '$failure'.replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted && revision == current) {
        setState(() => loading = more = false);
      }
    }
  }

  Future<void> newFolder() async {
    if (page == null || !connected || loading || more || creating) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final parent = page!.path;
    final origin = revision;
    var dismissed = false;
    final created = await showDialog<String>(
      context: context,
      builder: (_) => _NewDirectoryDialog(
        model: widget.model,
        parent: parent,
        onStarted: () {
          if (mounted) setState(() => creating = true);
        },
        onSettled: () {
          if (!mounted) return;
          setState(() => creating = false);
          // Closing the dialog doesn't undo a remote mkdir. If it completes
          // later, refresh only the original location without moving the user.
          if (dismissed &&
              connected &&
              revision == origin &&
              page?.path == parent) {
            unawaited(read(parent));
          }
        },
      ),
    );
    dismissed = true;
    if (mounted && created != null && connected && revision == origin) {
      await read(created);
    }
  }

  bool get canUseDirectory =>
      connected &&
      !loading &&
      !more &&
      !editingPath &&
      error == null &&
      page != null &&
      path.text.trim() == page!.path;

  void editPath() {
    if (!connected) return;
    if (!editingPath) {
      setState(() {
        editingPath = true;
        path.value = TextEditingValue(
          text: location,
          selection: TextSelection(
            baseOffset: 0,
            extentOffset: location.length,
          ),
        );
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && editingPath) pathFocus.requestFocus();
    });
  }

  void cancelPathEdit() {
    pathFocus.unfocus();
    setState(() {
      editingPath = false;
      path.text = location;
    });
  }

  Future<void> goToDirectory(String target) async {
    final loaded = page;
    final destination = target.trim();
    if (connected &&
        !loading &&
        !more &&
        error == null &&
        loaded != null &&
        location == loaded.path &&
        _displayDirectoryPath(
              destination.isEmpty ? loaded.home : destination,
              loaded.home,
            ) ==
            _displayDirectoryPath(loaded.path, loaded.home)) {
      cancelPathEdit();
      return;
    }
    await read(target);
  }

  Future<void> refreshDirectory() =>
      read(location.isEmpty ? requested : location);

  void toggleHidden() {
    if (!connected) return;
    setState(() => showHidden = !showHidden);
    unawaited(refreshDirectory());
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final titleHeight =
        scaler.scale(context.pircText.cardTitle.fontSize!) *
        (context.pircText.cardTitle.height ?? 1.3);
    final subtitleHeight =
        scaler.scale(context.pircText.hint.fontSize!) *
        (context.pircText.hint.height ?? 1.3);
    final pathStyle = context.pircText.directoryPath;
    final pathBarHeight = math.max(
      PircLayout.actionSize,
      scaler.scale(pathStyle.fontSize!) * pathStyle.height! +
          PircSpacing.s12 * 2,
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: PircLayout.maxContentWidth),
        child: Scaffold(
          appBar: AppBar(
            toolbarHeight: math.max(
              PircLayout.toolbarHeight,
              titleHeight + subtitleHeight + PircSpacing.s16,
            ),
            leadingWidth: PircLayout.actionSize,
            titleSpacing: 0,
            leading: IconButton(
              key: const Key('directory-cancel'),
              tooltip: context.l10n.cancelSelection,
              onPressed: () => Navigator.pop(context),
              icon: const Icon(LucideIcons.x),
            ),
            title: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.chooseWorkingDirectory,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.pircText.cardTitle,
                ),
                Text(
                  widget.computerName ?? context.l10n.currentDevice,
                  key: const Key('directory-computer'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.pircText.hint,
                ),
              ],
            ),
            actions: [
              IconButton(
                key: const Key('directory-new-folder'),
                tooltip: context.l10n.newFolder,
                onPressed: canUseDirectory && !creating ? newFolder : null,
                color: context.pircColors.primary,
                icon: creating
                    ? const SizedBox(
                        width: PircIconSizes.small,
                        height: PircIconSizes.small,
                        child: CircularProgressIndicator(
                          strokeWidth: PircLayout.loadingStrokeWidth,
                        ),
                      )
                    : const Icon(LucideIcons.folderPlus),
              ),
              IconButton(
                key: const Key('directory-refresh'),
                tooltip: context.l10n.refresh,
                color: context.pircColors.primary,
                onPressed: connected ? refreshDirectory : null,
                icon: const Icon(LucideIcons.refreshCw),
              ),
              IconButton(
                key: const Key('directory-hidden'),
                tooltip: showHidden
                    ? context.l10n.hideHiddenFolders
                    : context.l10n.showHiddenFolders,
                color: context.pircColors.primary,
                isSelected: showHidden,
                onPressed: connected ? toggleHidden : null,
                icon: const Icon(LucideIcons.eyeOff),
                selectedIcon: const Icon(LucideIcons.eye),
              ),
              const SizedBox(width: PircSpacing.s8),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                Container(
                  key: const Key('directory-navigation'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: PircSpacing.s12,
                  ),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: context.pircColors.outlineVariant,
                      ),
                    ),
                  ),
                  child: SizedBox(
                    height: pathBarHeight,
                    child: editingPath
                        ? CallbackShortcuts(
                            bindings: {
                              const SingleActivator(LogicalKeyboardKey.escape):
                                  cancelPathEdit,
                            },
                            child: TextField(
                              key: const Key('directory-path'),
                              controller: path,
                              focusNode: pathFocus,
                              enabled: connected,
                              style: context.pircText.directoryPath,
                              textAlignVertical: TextAlignVertical.center,
                              autocorrect: false,
                              enableSuggestions: false,
                              decoration: PircInputDecorations.directoryPath
                                  .copyWith(
                                    hintText: context.l10n.enterFullPath,
                                    suffixIcon: IconButton(
                                      key: const Key('directory-go'),
                                      tooltip: context.l10n.goToDirectory,
                                      onPressed: connected
                                          ? () => goToDirectory(path.text)
                                          : null,
                                      icon: const Icon(
                                        LucideIcons.arrowRight,
                                        size: PircIconSizes.small,
                                      ),
                                    ),
                                  ),
                              onTapOutside: (_) => cancelPathEdit(),
                              textInputAction: TextInputAction.go,
                              onChanged: (_) => setState(() {}),
                              onSubmitted: connected ? goToDirectory : null,
                            ),
                          )
                        : _DirectoryBreadcrumbs(
                            location: location,
                            connected: connected,
                            navigate: read,
                            edit: editPath,
                          ),
                  ),
                ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: refreshDirectory,
                    child: CustomScrollView(
                      key: const Key('directory-scroll'),
                      controller: scroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        if (error != null)
                          SliverPadding(
                            padding: const EdgeInsets.all(PircSpacing.s16),
                            sliver: SliverToBoxAdapter(
                              child: Container(
                                key: const Key('directory-error'),
                                padding: const EdgeInsets.all(PircSpacing.s16),
                                decoration: BoxDecoration(
                                  color: context.pirc.warningSurface,
                                  borderRadius: PircRadii.notice,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      context.localize(error!),
                                      style: context.pircText.hint.copyWith(
                                        color: context.pirc.warning,
                                      ),
                                    ),
                                    const SizedBox(height: PircSpacing.s8),
                                    TextButton(
                                      key: const Key('directory-retry'),
                                      onPressed: connected
                                          ? () => read(
                                              requested,
                                              append: failedAppend,
                                            )
                                          : null,
                                      child: Text(context.l10n.retry),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        if (loading)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.all(PircSpacing.s24),
                              child: Column(
                                children: [
                                  const CircularProgressIndicator(
                                    key: Key('directory-loading'),
                                  ),
                                  const SizedBox(height: PircSpacing.s12),
                                  Text(
                                    context.l10n.readingDirectory,
                                    style: context.pircText.hint,
                                  ),
                                ],
                              ),
                            ),
                          )
                        else if (error == null && directories.isEmpty)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.all(PircSpacing.s24),
                              child: Text(
                                context.l10n.noSubdirectories,
                                textAlign: TextAlign.center,
                                style: context.pircText.hint,
                              ),
                            ),
                          ),
                        if (!loading && (error == null || failedAppend))
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(
                              PircSpacing.s12,
                              PircSpacing.s4,
                              PircSpacing.s12,
                              PircSpacing.s12,
                            ),
                            sliver: SliverList.builder(
                              itemCount: directories.length,
                              itemBuilder: (_, index) {
                                final directory = directories[index];
                                return Semantics(
                                  button: true,
                                  enabled: connected,
                                  child: Material(
                                    type: MaterialType.transparency,
                                    borderRadius: PircRadii.notice,
                                    clipBehavior: Clip.antiAlias,
                                    child: InkWell(
                                      key: ValueKey(
                                        'directory:${directory.path}',
                                      ),
                                      onTap: connected
                                          ? () => read(directory.path)
                                          : null,
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          minHeight:
                                              PircLayout.directoryRowHeight,
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.all(
                                            PircSpacing.s12,
                                          ),
                                          child: Row(
                                            children: [
                                              Icon(
                                                LucideIcons.folder,
                                                color:
                                                    context.pircColors.primary,
                                                size: PircIconSizes.toolbar,
                                              ),
                                              const SizedBox(
                                                width: PircSpacing.s14,
                                              ),
                                              Expanded(
                                                child: Text(
                                                  directory.name,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: context.pircText.body,
                                                ),
                                              ),
                                              const SizedBox(
                                                width: PircSpacing.s8,
                                              ),
                                              Icon(
                                                LucideIcons.chevronRight,
                                                color: context
                                                    .pircColors
                                                    .onSurfaceVariant,
                                                size: PircIconSizes.chevron,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        if (!loading &&
                            page?.nextCursor != null &&
                            (error == null || failedAppend))
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.all(PircSpacing.s16),
                              child: Center(
                                child: more
                                    ? const CircularProgressIndicator()
                                    : TextButton(
                                        key: const Key('directory-more'),
                                        onPressed: connected
                                            ? () =>
                                                  read(page!.path, append: true)
                                            : null,
                                        child: Text(
                                          context.l10n.loadMoreFolders,
                                        ),
                                      ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(
                    PircSpacing.s16,
                    PircSpacing.s12,
                    PircSpacing.s16,
                    PircSpacing.s16,
                  ),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(color: context.pircColors.outlineVariant),
                    ),
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const Key('directory-select'),
                      onPressed: canUseDirectory
                          ? () => Navigator.pop(context, page!.path)
                          : null,
                      icon: const Icon(
                        LucideIcons.check,
                        size: PircIconSizes.small,
                      ),
                      label: Text(context.l10n.useDirectory),
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

String _displayDirectoryPath(String path, String? home) {
  if (path == '~') return home ?? path;
  if (path.startsWith('~/') && home != null) {
    path = '$home/${path.substring(2)}';
  }
  if (!path.startsWith('/')) return path;
  final segments = <String>[];
  for (final segment in path.split('/')) {
    if (segment == '' || segment == '.') continue;
    if (segment == '..') {
      if (segments.isNotEmpty) segments.removeLast();
    } else {
      segments.add(segment);
    }
  }
  return '/${segments.join('/')}';
}

class _DirectoryCrumb {
  const _DirectoryCrumb(this.name, this.path);
  final String name;
  final String path;
}

class _DirectoryBreadcrumbs extends StatefulWidget {
  const _DirectoryBreadcrumbs({
    required this.location,
    required this.connected,
    required this.navigate,
    required this.edit,
  });
  final String location;
  final bool connected;
  final Future<void> Function(String?) navigate;
  final VoidCallback edit;

  @override
  State<_DirectoryBreadcrumbs> createState() => _DirectoryBreadcrumbsState();
}

class _DirectoryBreadcrumbsState extends State<_DirectoryBreadcrumbs> {
  final scroll = ScrollController();
  double? viewportWidth;
  double? textSize;
  bool positioning = false;

  @override
  void initState() {
    super.initState();
    positionAtCurrentDirectory();
  }

  @override
  void didUpdateWidget(covariant _DirectoryBreadcrumbs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.location != oldWidget.location) positionAtCurrentDirectory();
  }

  void positionAtCurrentDirectory() {
    if (positioning) return;
    positioning = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      positioning = false;
      if (!mounted || !scroll.hasClients) return;
      scroll.jumpTo(scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  List<_DirectoryCrumb> get crumbs {
    final location = widget.location;
    if (!location.startsWith('/')) {
      return [
        _DirectoryCrumb(
          location.isEmpty ? context.l10n.homeDirectory : location,
          location,
        ),
      ];
    }
    final result = <_DirectoryCrumb>[const _DirectoryCrumb('/', '/')];
    var path = '';
    for (final segment in location.split('/')) {
      if (segment.isEmpty) continue;
      path += '/$segment';
      result.add(_DirectoryCrumb(segment, path));
    }
    return result;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final all = crumbs;
      final scaledSize = MediaQuery.textScalerOf(context)
          .scale(context.pircText.directoryPath.fontSize!);
      if (viewportWidth != constraints.maxWidth || textSize != scaledSize) {
        viewportWidth = constraints.maxWidth;
        textSize = scaledSize;
        positionAtCurrentDirectory();
      }
      return Semantics(
        key: const Key('directory-breadcrumbs'),
        label: context.l10n.currentDirectory,
        value: widget.location,
        child: GestureDetector(
          key: const Key('directory-path-area'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.connected ? widget.edit : null,
          child: SingleChildScrollView(
            key: const Key('directory-breadcrumb-scroll'),
            controller: scroll,
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var index = 0; index < all.length; index++) ...[
                    if (index > 0)
                      Icon(
                        LucideIcons.chevronRight,
                        size: PircIconSizes.notice,
                        color: context.pircColors.onSurfaceVariant,
                      ),
                    Tooltip(
                      message: index == all.length - 1
                          ? context.l10n.enterFullPath
                          : all[index].path,
                      child: TextButton(
                        key: index == all.length - 1
                            ? const Key('directory-current')
                            : ValueKey('directory-crumb:${all[index].path}'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.standard,
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.symmetric(
                            horizontal: PircSpacing.s4,
                          ),
                          foregroundColor: index == all.length - 1
                              ? context.pircColors.onSurface
                              : context.pircColors.onSurfaceVariant,
                        ),
                        onPressed: !widget.connected
                            ? null
                            : index == all.length - 1
                            ? widget.edit
                            : () => widget.navigate(all[index].path),
                        child: Text(
                          all[index].name,
                          maxLines: 1,
                          style: index == all.length - 1
                              ? context.pircText.directoryPath
                              : context.pircText.directoryPath.copyWith(
                                  color: context.pircColors.onSurfaceVariant,
                                ),
                        ),
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

String? _directoryNameError(String value) {
  final name = value.trim();
  if (name.isEmpty) return 'Enter a folder name';
  if (name == '.' ||
      name == '..' ||
      name.contains(RegExp(r'[/\\]')) ||
      name.contains('\u0000')) {
    return 'Enter a single name without / or backslash';
  }
  if (utf8.encode(name).length > 255) {
    return 'Name is too long. Shorten it and retry.';
  }
  return null;
}

class _NewDirectoryDialog extends StatefulWidget {
  const _NewDirectoryDialog({
    required this.model,
    required this.parent,
    required this.onStarted,
    required this.onSettled,
  });
  final PircController model;
  final String parent;
  final VoidCallback onStarted;
  final VoidCallback onSettled;
  @override
  State<_NewDirectoryDialog> createState() => _NewDirectoryDialogState();
}

class _NewDirectoryDialogState extends State<_NewDirectoryDialog> {
  final name = TextEditingController();
  bool creating = false;
  bool edited = false;
  String? error;

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> create() async {
    if (creating || _directoryNameError(name.text) != null) return;
    setState(() {
      creating = true;
      error = null;
    });
    widget.onStarted();
    try {
      final result = await widget.model
          .createDirectory(widget.parent, name.text.trim())
          .timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw StateError(
              'Creation is unconfirmed. Close and refresh the directory before retrying.',
            ),
          );
      if (mounted) Navigator.pop(context, result);
    } catch (failure) {
      if (mounted) {
        setState(() => error = '$failure'.replaceFirst('Bad state: ', ''));
      }
    } finally {
      widget.onSettled();
      if (mounted) setState(() => creating = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(context.l10n.newFolder),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.parent,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: context.pircText.path,
        ),
        const SizedBox(height: PircSpacing.s12),
        TextField(
          key: const Key('directory-new-name'),
          controller: name,
          autofocus: true,
          enabled: !creating,
          decoration: InputDecoration(
            labelText: context.l10n.folderName,
            errorText: edited && _directoryNameError(name.text) != null
                ? context.localize(_directoryNameError(name.text)!)
                : null,
            errorMaxLines: 3,
          ),
          textInputAction: TextInputAction.done,
          onChanged: (_) => setState(() {
            edited = true;
            error = null;
          }),
          onSubmitted: (_) => create(),
        ),
        if (error != null) ...[
          const SizedBox(height: PircSpacing.s12),
          Text(
            context.localize(error!),
            key: const Key('directory-create-error'),
            style: context.pircText.hint.copyWith(color: context.pirc.warning),
          ),
        ],
      ],
    ),
    actions: [
      TextButton(
        key: const Key('directory-create-cancel'),
        onPressed: () => Navigator.pop(context),
        child: Text(creating ? context.l10n.close : context.l10n.cancel),
      ),
      FilledButton(
        key: const Key('directory-create-confirm'),
        onPressed: !creating && _directoryNameError(name.text) == null
            ? create
            : null,
        child: creating
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    key: Key('directory-creating'),
                    width: PircIconSizes.small,
                    height: PircIconSizes.small,
                    child: CircularProgressIndicator(
                      strokeWidth: PircLayout.loadingStrokeWidth,
                    ),
                  ),
                  SizedBox(width: PircSpacing.s8),
                  Flexible(child: Text(context.l10n.creating)),
                ],
              )
            : Text(context.l10n.createAndOpen),
      ),
    ],
  );
}
