import 'pirc_localizations.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'pirc_controller.dart';
import 'pirc_theme.dart';

/// Rebasing a sliver must also translate the coordinates of its active physics
/// simulation. Drag updates read current pixels, but ballistic ticks still use
/// the origin captured when the pointer was released.
class _TranscriptScrollController extends ScrollController {
  _TranscriptScrollController({
    super.keepScrollOffset,
    super.onAttach,
    super.onDetach,
  });

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _TranscriptScrollPosition(
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );
}

class _TranscriptScrollPosition extends ScrollPositionWithSingleContext {
  _TranscriptScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });
  double _ballisticShift = 0;

  @override
  void beginActivity(ScrollActivity? newActivity) {
    if (newActivity != null && !identical(activity, newActivity)) {
      _ballisticShift = 0;
    }
    super.beginActivity(newActivity);
  }

  @override
  void correctPixels(double value) {
    if (activity is BallisticScrollActivity) _ballisticShift += value - pixels;
    super.correctPixels(value);
  }

  @override
  double setPixels(double newPixels) => super.setPixels(
    activity is BallisticScrollActivity
        ? newPixels + _ballisticShift
        : newPixels,
  );
}

/// Older pages grow upward from this boundary without measuring their heights.
class TranscriptList extends StatefulWidget {
  const TranscriptList({
    super.key,
    required this.model,
    required this.session,
    required this.items,
    required this.itemBuilder,
    required this.empty,
    this.bottomOverlap = 0,
  });
  final PircController model;
  final SessionView session;
  final List<Map<String, dynamic>> items;
  final Widget Function(Map<String, dynamic>) itemBuilder;
  final Widget empty;
  final double bottomOverlap;
  @override
  State<TranscriptList> createState() => TranscriptListState();
}

class TranscriptListState extends State<TranscriptList> {
  late final scroll = _TranscriptScrollController(
    keepScrollOffset: false,
    onAttach: (position) =>
        position.isScrollingNotifier.addListener(onActivityChanged),
    onDetach: (position) =>
        position.isScrollingNotifier.removeListener(onActivityChanged),
  );
  final viewport = GlobalKey();
  static const centerKey = ValueKey('transcript-center');
  String? boundary;
  String? forwardAnchor;
  bool hadItems = false;
  double anchor = 1;
  bool pinned = true;
  bool newContent = false;
  bool resetting = false;
  bool paginationScheduled = false;
  bool rebaseScheduled = false;
  bool selecting = false;
  String? selectionReply;
  _ReplySelectionState? _activeReply;
  bool idleScheduled = false;
  bool get scrolling =>
      scroll.hasClients && scroll.position.isScrollingNotifier.value;
  late String contentStamp;
  int windowRevision = 0;
  int observedSeq = 0;
  String? observedLast;
  String stamp() =>
      '${widget.session.lastSeq}:${widget.items.lastOrNull?['id']}:${widget.items.lastOrNull?['text']?.hashCode}:${widget.items.lastOrNull?['arguments']?.hashCode}';
  @override
  void initState() {
    super.initState();
    windowRevision = widget.session.historyRevision;
    contentStamp = stamp();
    hadItems = widget.items.isNotEmpty;
    observedSeq = widget.session.lastSeq;
    observedLast = widget.items.lastOrNull?['id'] as String?;
    resetWindow();
    scroll.addListener(trackScroll);
  }

  @override
  void didUpdateWidget(TranscriptList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final replaced = windowRevision != widget.session.historyRevision;
    windowRevision = widget.session.historyRevision;
    final next = stamp();
    if (replaced || !hadItems && widget.items.isNotEmpty) {
      resetWindow();
    } else if (next != contentStamp) {
      if (pinned && !widget.session.hasAfter && !selecting && !scrolling) {
        newContent = false;
        boundary = widget.items.lastOrNull?['id'] as String?;
        forwardAnchor = null;
        anchor = 1;
        resetOffset(automatic: true);
      } else if (widget.session.lastSeq != observedSeq ||
          observedLast == widget.items.lastOrNull?['id']) {
        newContent = true;
      }
    }
    contentStamp = next;
    hadItems = widget.items.isNotEmpty;
    observedSeq = widget.session.lastSeq;
    observedLast = widget.items.lastOrNull?['id'] as String?;
    if (!widget.items.any((item) => item['id'] == selectionReply)) {
      selectionReply = latestReply;
    }
    schedulePagination();
  }

  String? get latestReply =>
      widget.items
              .where((item) => item['role'] == 'assistant')
              .lastOrNull?['id']
          as String?;

  void resetWindow() {
    selecting = false;
    selectionReply = latestReply;
    final target = widget.session.historyAnchor;
    if (target != null) {
      final index = widget.items.indexWhere((i) => i['first_seq'] == target);
      boundary = index > 0 ? widget.items[index - 1]['id'] as String : null;
      forwardAnchor = index >= 0
          ? widget.items[index]['id'] as String
          : widget.items.firstOrNull?['id'] as String?;
      anchor = .2;
      pinned = false;
    } else {
      boundary = widget.items.lastOrNull?['id'] as String?;
      forwardAnchor = null;
      anchor = 1;
      pinned = true;
    }
    newContent = false;
    resetOffset();
  }

  void resetOffset({bool automatic = false}) {
    resetting = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (scroll.hasClients && (!automatic || !scrolling)) scroll.jumpTo(0);
      resetting = false;
      schedulePagination();
    });
  }

  void onActivityChanged() {
    if (scrolling || idleScheduled) return;
    idleScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      idleScheduled = false;
      if (mounted && !scrolling) trackScroll();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> showLatest() async {
    if (widget.session.hasAfter) {
      await widget.model.loadHistory('latest');
    } else {
      setState(() {
        anchor = 1;
        boundary = widget.items.lastOrNull?['id'] as String?;
        forwardAnchor = null;
        pinned = true;
        newContent = false;
      });
      resetOffset();
    }
  }

  void trackScroll() {
    if (resetting || !scroll.hasClients) return;
    final atBottom =
        scroll.position.extentAfter < 80 && !widget.session.hasAfter;
    if (pinned != atBottom || atBottom && newContent) {
      setState(() {
        pinned = atBottom;
        if (atBottom) newContent = false;
      });
    }
    if (atBottom && anchor != 1 && !selecting && !scrolling) {
      final distanceFromBottom = scroll.position.extentAfter;
      setState(() {
        boundary = widget.items.lastOrNull?['id'] as String?;
        forwardAnchor = null;
        anchor = 1;
      });
      // Rebase coordinates without starting a new scroll activity or snapping
      // the last few visible pixels to the bottom.
      scroll.position.correctPixels(-distanceFromBottom);
    }
    if (!pinned) rebaseReadingAnchor();
    schedulePagination();
  }

  void rebaseReadingAnchor() {
    // Keep the origin on the reader during drags and inertia too. Otherwise,
    // output below shifts history while the list is still anchored at its end.
    // correctPixels preserves the active gesture while changing coordinates.
    if (rebaseScheduled || selecting) return;
    rebaseScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      rebaseScheduled = false;
      if (!mounted || pinned || resetting || !scroll.hasClients || selecting) {
        return;
      }
      final root = viewport.currentContext?.findRenderObject();
      if (root is! RenderBox) return;
      _RenderTranscriptAnchor? visible;
      _RenderTranscriptAnchor? firstBelowTop;
      double firstBelowTopOffset = double.infinity;
      double top = 0;
      void visit(RenderObject object) {
        if (object is _RenderTranscriptAnchor &&
            object.attached &&
            object.hasSize) {
          final dy = object.localToGlobal(Offset.zero, ancestor: root).dy;
          if (dy <= 0 && dy + object.size.height > 0) {
            visible = object;
            top = dy;
          } else if (dy >= 0 &&
              dy < root.size.height &&
              dy < firstBelowTopOffset) {
            firstBelowTop = object;
            firstBelowTopOffset = dy;
          }
        } else {
          object.visitChildren(visit);
        }
      }

      root.visitChildren(visit);
      if (visible == null) {
        visible = firstBelowTop;
        top = firstBelowTopOffset;
      }
      if (visible == null) return;
      final index = widget.items.indexWhere((i) => i['id'] == visible!.id);
      if (index < 0) return;
      final nextAnchor = widget.items[index]['id'] as String;
      if (nextAnchor == forwardAnchor && anchor == 0) return;
      setState(() {
        forwardAnchor = nextAnchor;
        anchor = 0;
      });
      // Apply both the new anchor and its coordinates to the same next layout.
      // jumpTo would cancel a drag that starts between two frame callbacks.
      scroll.position.correctPixels(-top);
      WidgetsBinding.instance.ensureVisualUpdate();
    });
  }

  void schedulePagination() {
    if (paginationScheduled) return;
    paginationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      paginationScheduled = false;
      if (!mounted || !scroll.hasClients || resetting) return;
      final session = widget.session;
      if (!session.paged ||
          session.historyLoading != null ||
          session.historyError != null ||
          widget.model.connection != 'connected') {
        return;
      }
      if (scroll.position.extentBefore < 160 && session.hasBefore) {
        unawaited(widget.model.loadHistory('before'));
      } else if (scroll.position.extentAfter < 160 && session.hasAfter) {
        unawaited(widget.model.loadHistory('after'));
      }
    });
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  Widget edge({required bool before}) {
    final session = widget.session;
    final direction = before ? 'before' : 'after';
    final hasMore = before ? session.hasBefore : session.hasAfter;
    final busy = session.historyLoading == direction;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: PircSpacing.s8),
      child: Center(
        child: busy
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: PircIconSizes.activity,
                    height: PircIconSizes.activity,
                    child: CircularProgressIndicator(
                      strokeWidth: PircLayout.loadingStrokeWidth,
                    ),
                  ),
                  const SizedBox(width: PircSpacing.s8),
                  Text(
                    context.l10n.loadingRecords,
                    style: context.pircText.hint,
                  ),
                ],
              )
            : session.historyError != null
            ? TextButton(
                key: Key('history-retry-$direction'),
                onPressed: widget.model.retryHistory,
                child: Text(
                  context.l10n.historyRetry(
                    context.localize(session.historyError!),
                  ),
                ),
              )
            : hasMore
            ? TextButton(
                key: Key('history-load-$direction'),
                onPressed: () => widget.model.loadHistory(direction),
                child: Text(
                  before
                      ? context.l10n.loadEarlierRecords
                      : context.l10n.loadLaterRecords,
                ),
              )
            : before && session.paged
            ? Text(
                session.history['truncated'] == true
                    ? context.l10n.earliestRetainedRecord
                    : context.l10n.earliestRecord,
                style: context.pircText.hint,
              )
            : const SizedBox.shrink(),
      ),
    );
  }

  Widget blocks(List<Map<String, dynamic>> items) => SliverPadding(
    padding: const EdgeInsets.symmetric(horizontal: PircSpacing.s20),
    sliver: SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) => KeyedSubtree(
          key: ValueKey('block:${items[index]['id']}'),
          child: _TranscriptAnchor(
            id: items[index]['id'] as String,
            child: items[index]['role'] == 'assistant'
                ? _ReplySelection(
                    active: selectionReply == items[index]['id'],
                    onActivate: (reply) {
                      if (_activeReply != reply || !reply.active) {
                        _activeReply?.setActive(false);
                        _activeReply = reply;
                        reply.setActive(true);
                        selectionReply = items[index]['id'] as String;
                      }
                    },
                    child: widget.itemBuilder(items[index]),
                  )
                : SelectionContainer.disabled(
                    child: widget.itemBuilder(items[index]),
                  ),
          ),
        ),
        childCount: items.length,
        findChildIndexCallback: (key) {
          final index = items.indexWhere(
            (i) => ValueKey('block:${i['id']}') == key,
          );
          return index < 0 ? null : index;
        },
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    if (!session.historyInitialized && widget.items.isEmpty) {
      return Center(
        child: session.historyError != null
            ? TextButton(
                key: const Key('history-initial-retry'),
                onPressed: widget.model.retryHistory,
                child: Text(
                  context.l10n.historyRetry(
                    context.localize(session.historyError!),
                  ),
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(
                    strokeWidth: PircLayout.loadingStrokeWidth,
                  ),
                  const SizedBox(height: PircSpacing.s12),
                  Text(
                    context.l10n.loadingSession,
                    style: context.pircText.hint,
                  ),
                ],
              ),
      );
    }
    if (widget.items.isEmpty) return widget.empty;
    final split = forwardAnchor != null
        ? widget.items
              .indexWhere((i) => i['id'] == forwardAnchor)
              .clamp(0, widget.items.length)
        : boundary == null
        ? 0
        : widget.items.indexWhere((i) => i['id'] == boundary) + 1;
    final older = widget.items.take(split).toList().reversed.toList();
    final newer = widget.items.skip(split).toList();
    // Extend painting beneath the rounded leading edge of the task dock. The
    // scroll anchor and controls stay within the unobstructed reading area.
    return LayoutBuilder(
      builder: (context, constraints) => OverflowBox(
        alignment: Alignment.topCenter,
        minHeight: constraints.maxHeight + widget.bottomOverlap,
        maxHeight: constraints.maxHeight + widget.bottomOverlap,
        child: Stack(
          children: [
            Positioned.fill(
              child: NotificationListener<ScrollMetricsNotification>(
                onNotification: (notification) {
                  if (notification.depth == 0) schedulePagination();
                  return false;
                },
                child: SelectionArea(
                  onSelectionChanged: (content) {
                    selecting = content != null && content.plainText.isNotEmpty;
                  },
                  child: RepaintBoundary(
                    key: viewport,
                    child: CustomScrollView(
                      key: const Key('transcript'),
                      controller: scroll,
                      center: centerKey,
                      anchor:
                          anchor *
                          constraints.maxHeight /
                          (constraints.maxHeight + widget.bottomOverlap).clamp(
                            1.0,
                            double.infinity,
                          ),
                      slivers: [
                        SliverToBoxAdapter(
                          child: SelectionContainer.disabled(
                            child: edge(before: true),
                          ),
                        ),
                        blocks(older),
                        const SliverToBoxAdapter(
                          key: centerKey,
                          child: SizedBox.shrink(),
                        ),
                        blocks(newer),
                        SliverToBoxAdapter(
                          child:
                              session.hasAfter ||
                                  session.historyLoading == 'after'
                              ? SelectionContainer.disabled(
                                  child: edge(before: false),
                                )
                              : const SizedBox.shrink(),
                        ),
                        SliverToBoxAdapter(
                          child: SizedBox(height: widget.bottomOverlap),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (!pinned || session.hasAfter || newContent)
              Positioned(
                bottom: PircSpacing.s12 + widget.bottomOverlap,
                right: PircSpacing.s20,
                child: IconButton.filledTonal(
                  key: const Key('jump-to-latest'),
                  onPressed: showLatest,
                  tooltip: context.l10n.jumpToLatest,
                  icon: const Icon(
                    LucideIcons.arrowDown,
                    size: PircIconSizes.small,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TranscriptAnchor extends SingleChildRenderObjectWidget {
  const _TranscriptAnchor({required this.id, required super.child});
  final String id;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTranscriptAnchor(id);
  @override
  void updateRenderObject(
    BuildContext context,
    _RenderTranscriptAnchor renderObject,
  ) {
    renderObject.id = id;
  }
}

class _RenderTranscriptAnchor extends RenderProxyBox {
  _RenderTranscriptAnchor(this.id);
  String id;

  @override
  void showOnScreen({
    RenderObject? descendant,
    Rect? rect,
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
  }) {
    // EditableText reveals its caret while selecting, even when it is visible.
    // Avoid feeding that redundant request into the reverse-growing sliver,
    // where implicit scrolling can move the list and rebase the selected block.
    RenderObject? viewport = parent;
    while (viewport != null && viewport is! RenderViewport) {
      viewport = viewport.parent;
    }
    if (viewport is RenderViewport) {
      final target = descendant ?? this;
      // Caret reveal includes extra space for selection handles. That padding
      // must not push an already visible last line away from the bottom edge.
      final bounds = MatrixUtils.transformRect(
        target.getTransformTo(viewport),
        (rect ?? target.paintBounds).intersect(target.paintBounds),
      );
      final visible = viewport.paintBounds;
      if (visible.contains(bounds.topLeft) &&
          visible.contains(bounds.bottomRight)) {
        return;
      }
    }
    super.showOnScreen(
      descendant: descendant,
      rect: rect,
      duration: duration,
      curve: curve,
    );
  }
}

/// Accept selection events only in the reply where the pointer started. Switching synchronously preserves fast down/drag gestures.
class _ReplySelection extends StatefulWidget {
  const _ReplySelection({
    required this.active,
    required this.onActivate,
    required this.child,
  });
  final bool active;
  final ValueChanged<_ReplySelectionState> onActivate;
  final Widget child;
  @override
  State<_ReplySelection> createState() => _ReplySelectionState();
}

class _ReplySelectionState extends State<_ReplySelection> {
  final delegate = _ReplySelectionDelegate();
  bool get active => delegate.active;
  void setActive(bool value) {
    if (delegate.active == value) return;
    if (!value) delegate.dispatchSelectionEvent(const ClearSelectionEvent());
    delegate.active = value;
  }

  @override
  void initState() {
    super.initState();
    if (widget.active) widget.onActivate(this);
  }

  @override
  void didUpdateWidget(_ReplySelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active) {
      widget.onActivate(this);
    } else {
      setActive(false);
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => widget.onActivate(this),
    child: SelectionContainer(delegate: delegate, child: widget.child),
  );

  @override
  void dispose() {
    delegate.active = false;
    delegate.dispose();
    super.dispose();
  }
}

class _ReplySelectionDelegate extends StaticSelectionContainerDelegate {
  bool active = false;
  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    if (!active && event is! ClearSelectionEvent) return SelectionResult.next;
    return super.dispatchSelectionEvent(event);
  }
}
