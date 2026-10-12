import 'package:pirc/pirc_localizations.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc/new_session_page.dart';
import 'package:pirc/pirc_controller.dart';
import 'package:pirc/pirc_theme.dart';
import 'package:pirc/remote_directory_picker.dart';

class DirectoryController extends PircController {
  DirectoryController() {
    connection = 'connected';
  }
  final calls =
      <
        ({
          String? path,
          String? cursor,
          bool hidden,
          Completer<RemoteDirectoryPage> reply,
        })
      >[];
  final creations = <({String parent, String name, Completer<String> reply})>[];
  @override
  Future<String> createDirectory(String parent, String name) {
    final reply = Completer<String>();
    creations.add((parent: parent, name: name, reply: reply));
    return reply.future;
  }

  @override
  Future<SavedSessionCatalog> loadSavedSessions() async => SavedSessionCatalog(
    agents: const [AgentInfo(id: 'pi', name: 'Pi')],
    sessions: [],
    defaultCwd: '/remote/home',
  );
  @override
  Future<RemoteDirectoryPage> browseDirectories({
    String? path,
    String? cursor,
    bool showHidden = false,
  }) {
    final reply = Completer<RemoteDirectoryPage>();
    calls.add((path: path, cursor: cursor, hidden: showHidden, reply: reply));
    return reply.future;
  }

  void simulateDisconnect() {
    connection = 'reconnecting';
    notifyListeners();
  }
}

RemoteDirectoryPage listing(
  String path, {
  List<String> names = const [],
  List<String> files = const [],
  String? cursor,
}) => RemoteDirectoryPage({
  'path': path,
  'parent': path == '/'
      ? null
      : path.substring(0, path.lastIndexOf('/')).isEmpty
      ? '/'
      : path.substring(0, path.lastIndexOf('/')),
  'home': '/remote/home',
  'next_cursor': cursor,
  'entries': [
    ...names.map(
      (name) => {'name': name, 'path': '$path/$name', 'is_directory': true},
    ),
    ...files.map(
      (name) => {'name': name, 'path': '$path/$name', 'is_directory': false},
    ),
  ],
});

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

String? currentDirectory(WidgetTester tester) => tester
    .widget<Semantics>(find.byKey(const Key('directory-breadcrumbs')))
    .properties
    .value;

void main() {
  testWidgets(
    'files identify the directory but cannot navigate or be selected',
    (tester) async {
      final model = DirectoryController();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: pircTheme(),
          home: RemoteDirectoryPicker(model: model, initialPath: '/project'),
        ),
      );
      model.calls.single.reply.complete(
        listing(
          '/project',
          names: ['src'],
          files: ['README.md', 'package.json'],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('README.md'), findsOneWidget);
      expect(find.byIcon(LucideIcons.file), findsNWidgets(2));
      final file = find.byKey(const ValueKey('directory:/project/README.md'));
      expect(tester.widget<InkWell>(file).onTap, isNull);
      await tester.tap(file);
      await tester.pump();
      expect(model.calls.length, 1);
      expect(currentDirectory(tester), '/project');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('directory-select')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const ValueKey('directory:/project/src')));
      await tester.pump();
      expect(model.calls.last.path, '/project/src');
      model.calls.last.reply.complete(
        listing('/project/src', files: ['main.dart']),
      );
      await tester.pumpAndSettle();
      expect(find.text('main.dart'), findsOneWidget);
      expect(find.text('This directory is empty.'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'current directory edits inline and failed navigation leaves ancestors usable',
    (tester) async {
      final model = DirectoryController();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: pircTheme().copyWith(
            platform: TargetPlatform.macOS,
            visualDensity: VisualDensity.compact,
          ),
          home: RemoteDirectoryPicker(
            model: model,
            computerName: 'Development device',
          ),
        ),
      );
      model.calls[0].reply.complete(
        listing('/remote/home', names: ['project']),
      );
      await tester.pumpAndSettle();
      expect(find.text('Development device'), findsOneWidget);
      expect(find.byKey(const Key('directory-path')), findsNothing);
      expect(find.byKey(const Key('directory-home')), findsNothing);
      expect(find.byKey(const Key('directory-refresh')), findsOneWidget);
      expect(find.byKey(const Key('directory-options')), findsNothing);
      for (final segment in ['/', 'remote', 'home']) {
        expect(find.text(segment), findsOneWidget);
      }
      final rootText = find.text('/');
      final rootParagraph = tester.renderObject<RenderParagraph>(rootText);
      final rootStart = tester.getTopLeft(rootText).dx;
      final rootBox = rootParagraph
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 1),
          )
          .single;
      final rootGlyphTop = rootParagraph
          .localToGlobal(Offset(rootBox.left, rootBox.top))
          .dy;
      final pathStyle = tester.widget<Text>(rootText).style!;
      final currentStyle = tester.widget<Text>(find.text('home')).style!;
      expect(currentStyle.fontSize, pathStyle.fontSize);
      expect(currentStyle.fontWeight, pathStyle.fontWeight);
      final navigationHeight = tester
          .getSize(find.byKey(const Key('directory-navigation')))
          .height;
      await tester.tap(find.byKey(const Key('directory-current')));
      await tester.pumpAndSettle();
      expect(model.calls.length, 1);
      final field = find.byKey(const Key('directory-path'));
      final editStyle = tester.widget<TextField>(field).style!;
      expect(editStyle.fontSize, pathStyle.fontSize);
      expect(editStyle.fontFamily, pathStyle.fontFamily);
      expect(editStyle.fontWeight, pathStyle.fontWeight);
      final editable = tester
          .state<EditableTextState>(
            find.descendant(of: field, matching: find.byType(EditableText)),
          )
          .renderEditable;
      final caretStart = editable
          .localToGlobal(
            editable
                .getLocalRectForCaret(const TextPosition(offset: 0))
                .topLeft,
          )
          .dx;
      final editBox = editable
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 1),
          )
          .single;
      final editGlyphTop = editable
          .localToGlobal(Offset(editBox.left, editBox.top))
          .dy;
      expect(caretStart, closeTo(rootStart, .1));
      expect(editGlyphTop, closeTo(rootGlyphTop, .1));
      expect(
        tester.getSize(find.byKey(const Key('directory-navigation'))).height,
        navigationHeight,
      );
      final row = find.byKey(const Key('directory:/remote/home/project'));
      expect(tester.getSize(row).height, 56);
      expect(
        tester.getTopLeft(row).dy,
        greaterThanOrEqualTo(
          tester
              .getBottomLeft(find.byKey(const Key('directory-navigation')))
              .dy,
        ),
      );
      expect(find.byKey(const Key('directory-up')), findsNothing);
      expect(find.byKey(const Key('directory-edit')), findsNothing);
      expect(
        tester.getTopLeft(find.byKey(const Key('directory-path'))).dy,
        lessThan(tester.getTopLeft(row).dy),
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('directory-path')))
            .focusNode!
            .hasFocus,
        isTrue,
      );
      await tester.enterText(
        find.byKey(const Key('directory-path')),
        '/remote/draft',
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('directory-select')))
            .onPressed,
        isNull,
      );
      expect(find.byKey(const Key('directory-edit-cancel')), findsNothing);
      await tester.tapAt(
        tester.getBottomRight(find.byKey(const Key('directory-scroll'))) +
            const Offset(-12, -12),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('directory-path')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('directory-select')))
            .onPressed,
        isNotNull,
      );
      expect(model.calls.length, 1);
      await tester.tap(find.byKey(const Key('directory-current')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('directory-path')),
        '/remote/home/nested/protected',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('directory-go')));
      await tester.pump();
      model.calls[1].reply.completeError(
        StateError('Device denied directory access'),
      );
      await tester.pumpAndSettle();
      expect(currentDirectory(tester), '/remote/home/nested/protected');
      expect(row, findsNothing);
      final parent = find.byKey(
        const Key('directory-crumb:/remote/home/nested'),
      );
      await tester.ensureVisible(parent);
      await tester.pumpAndSettle();
      await tester.tap(parent);
      await tester.pump();
      expect(model.calls[2].path, '/remote/home/nested');
      model.calls[2].reply.complete(listing('/remote/home/nested'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('directory-path')), findsNothing);
      expect(currentDirectory(tester), '/remote/home/nested');
      await tester.tap(find.byKey(const Key('directory-refresh')));
      await settle(tester);
      expect(model.calls[3].path, '/remote/home/nested');
      model.calls[3].reply.complete(listing('/remote/home/nested'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'full paths scroll to the current directory and ancestors stay reachable with large text',
    (tester) async {
      final model = DirectoryController();
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final deep = '/remote/home/very-long-parent-name/nested/current-project';
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: pircTheme(),
          home: RemoteDirectoryPicker(
            model: model,
            initialPath: deep,
            computerName: 'A development device with a very long name',
          ),
        ),
      );
      model.calls[0].reply.complete(listing(deep));
      await tester.pumpAndSettle();
      expect(currentDirectory(tester), deep);
      for (final segment in [
        '/',
        'remote',
        'home',
        'very-long-parent-name',
        'nested',
      ]) {
        expect(find.text(segment), findsOneWidget);
      }
      expect(find.text('current-project'), findsOneWidget);
      expect(find.byKey(const Key('directory-path')), findsNothing);
      final breadcrumbScroll = find.byKey(
        const Key('directory-breadcrumb-scroll'),
      );
      final position = tester
          .state<ScrollableState>(
            find.descendant(
              of: breadcrumbScroll,
              matching: find.byType(Scrollable),
            ),
          )
          .position;
      expect(position.maxScrollExtent, greaterThan(0));
      expect(position.pixels, position.maxScrollExtent);
      expect(
        tester.getCenter(find.byKey(const Key('directory-current'))).dx,
        lessThan(tester.getBottomRight(breadcrumbScroll).dx),
      );
      await tester.drag(breadcrumbScroll, const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(position.pixels, lessThan(position.maxScrollExtent));
      final ancestor = find.byKey(const Key('directory-crumb:/remote/home'));
      await tester.ensureVisible(ancestor);
      await tester.pumpAndSettle();
      await tester.tap(ancestor);
      await tester.pump();
      expect(model.calls[1].path, '/remote/home');
      model.calls[1].reply.complete(listing('/remote/home'));
      await tester.pumpAndSettle();
      expect(currentDirectory(tester), '/remote/home');
      expect(position.pixels, position.maxScrollExtent);
      final navigationHeight = tester
          .getSize(find.byKey(const Key('directory-navigation')))
          .height;
      await tester.tap(find.byKey(const Key('directory-current')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('directory-path')))
            .controller!
            .text,
        '/remote/home',
      );
      expect(
        tester.getSize(find.byKey(const Key('directory-navigation'))).height,
        closeTo(navigationHeight, .1),
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'submitting the unchanged root exits editing without a read and refresh still reloads',
    (tester) async {
      final model = DirectoryController();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: pircTheme(),
          home: RemoteDirectoryPicker(model: model, initialPath: '/'),
        ),
      );
      model.calls[0].reply.complete(listing('/'));
      await tester.pumpAndSettle();
      expect(currentDirectory(tester), '/');
      expect(find.text('/'), findsOneWidget);
      expect(find.byKey(const Key('directory-up')), findsNothing);
      await tester.tap(find.byKey(const Key('directory-current')));
      await tester.pumpAndSettle();
      expect(model.calls.length, 1);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('directory-path')))
            .controller!
            .text,
        '/',
      );
      await tester.tap(find.byKey(const Key('directory-go')));
      await tester.pumpAndSettle();
      expect(model.calls.length, 1);
      expect(currentDirectory(tester), '/');
      await tester.tap(find.byKey(const Key('directory-current')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('directory-path')), '//./');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('directory-path')), findsNothing);
      expect(model.calls.length, 1);
      expect(currentDirectory(tester), '/');
      await tester.tap(find.byKey(const Key('directory-refresh')));
      await settle(tester);
      expect(model.calls.length, 2);
      expect(model.calls[1].path, '/');
      model.calls[1].reply.complete(listing('/'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'equivalent path submissions preserve the list and scroll while a failed read remains retryable',
    (tester) async {
      final model = DirectoryController();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: pircTheme(),
          home: RemoteDirectoryPicker(
            model: model,
            initialPath: '/remote/home',
          ),
        ),
      );
      model.calls[0].reply.complete(
        listing(
          '/remote/home',
          names: List.generate(30, (index) => 'folder-$index'),
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byKey(const Key('directory-scroll'));
      await tester.drag(list, const Offset(0, -300));
      await tester.pumpAndSettle();
      final scroll = tester.widget<CustomScrollView>(list).controller!;
      final offset = scroll.offset;
      expect(offset, greaterThan(0));
      for (final target in [
        '/remote/home',
        ' /remote//home/project/../ ',
        '~/',
        ' ',
      ]) {
        await tester.tap(find.byKey(const Key('directory-current')));
        await tester.pumpAndSettle();
        final field = find.byKey(const Key('directory-path'));
        await tester.enterText(field, target);
        await tester.tap(find.byKey(const Key('directory-go')));
        await tester.pumpAndSettle();
        expect(model.calls.length, 1);
        expect(field, findsNothing);
        expect(find.byKey(const Key('directory-loading')), findsNothing);
        expect(currentDirectory(tester), '/remote/home');
        expect(scroll.offset, offset);
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('directory-select')))
              .onPressed,
          isNotNull,
        );
      }

      await tester.tap(find.byKey(const Key('directory-refresh')));
      await tester.pump();
      expect(model.calls.length, 2);
      model.calls[1].reply.completeError(
        StateError('Unable to read this directory'),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('directory-error')), findsOneWidget);
      await tester.tap(find.byKey(const Key('directory-current')));
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();
      expect(model.calls.length, 3);
      expect(model.calls[2].path, '/remote/home');
      model.calls[2].reply.complete(
        listing('/remote/home', names: ['updated']),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('directory-error')), findsNothing);
      expect(find.text('updated'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'blank path space edits inline and a pending reply cannot overwrite the draft',
    (tester) async {
      final model = DirectoryController();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: pircTheme(),
          home: RemoteDirectoryPicker(
            model: model,
            initialPath: '/remote/home',
          ),
        ),
      );
      final area = find.byKey(const Key('directory-path-area'));
      await tester.tapAt(tester.getTopRight(area) + const Offset(-8, 24));
      await settle(tester);
      final field = find.byKey(const Key('directory-path'));
      final controller = tester.widget<TextField>(field).controller!;
      expect(controller.text, '/remote/home');
      expect(controller.selection.baseOffset, 0);
      expect(controller.selection.extentOffset, controller.text.length);
      await tester.enterText(field, '/remote/draft');
      model.calls[0].reply.complete(
        listing('/remote/home', names: ['project']),
      );
      await tester.pumpAndSettle();
      expect(controller.text, '/remote/draft');
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(field, findsNothing);
      expect(currentDirectory(tester), '/remote/home');
      expect(model.calls.length, 1);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('directory-select')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const Key('directory-current')));
      await settle(tester);
      expect(field, findsOneWidget);
      await tester.enterText(field, '/remote/next');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();
      expect(field, findsNothing);
      expect(model.calls[1].path, '/remote/next');
      model.calls[1].reply.complete(listing('/remote/next'));
      await tester.pumpAndSettle();
      expect(currentDirectory(tester), '/remote/next');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'new folder validates a single name, preserves errors and enters the created directory',
    (tester) async {
      final model = DirectoryController();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: pircTheme(),
          home: RemoteDirectoryPicker(model: model),
        ),
      );
      model.calls[0].reply.complete(listing('/remote/home'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('directory-new-folder')));
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('directory-new-name'));
      for (final value in [
        '',
        '..',
        '../escape',
        'nested/folder',
        r'nested\folder',
        '€' * 86,
      ]) {
        await tester.enterText(field, value);
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('directory-create-confirm')),
              )
              .onPressed,
          isNull,
        );
      }
      await tester.enterText(field, 'Project Unicode');
      await tester.pump();
      await tester.tap(find.byKey(const Key('directory-create-confirm')));
      await tester.pump();
      expect(model.creations.single.parent, '/remote/home');
      expect(model.creations.single.name, 'Project Unicode');
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('directory-create-confirm')),
            )
            .onPressed,
        isNull,
      );
      model.creations[0].reply.completeError(
        StateError('A file or folder already exists. Choose another name.'),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('A file or folder already exists. Choose another name.'),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(field).controller!.text,
        'Project Unicode',
      );
      await tester.enterText(field, 'new-project');
      await tester.pump();
      await tester.tap(find.byKey(const Key('directory-create-confirm')));
      await tester.pump();
      model.creations[1].reply.complete('/remote/home/new-project');
      await settle(tester);
      expect(model.calls.last.path, '/remote/home/new-project');
      model.calls.last.reply.complete(listing('/remote/home/new-project'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(currentDirectory(tester), '/remote/home/new-project');
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'closing while creating keeps the picker usable and a late result never moves it',
    (tester) async {
      final model = DirectoryController();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: pircTheme(),
          home: RemoteDirectoryPicker(model: model),
        ),
      );
      model.calls[0].reply.complete(listing('/remote/home'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('directory-new-folder')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('directory-new-name')),
        'new',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('directory-create-confirm')));
      await tester.pump();
      expect(find.text('Close'), findsOneWidget);
      await tester.tap(find.byKey(const Key('directory-create-cancel')));
      await settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('directory-new-folder')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('directory-crumb:/remote')));
      await tester.pump();
      model.calls[1].reply.complete(listing('/remote'));
      await settle(tester);
      model.creations[0].reply.complete('/remote/home/new');
      await tester.pumpAndSettle();
      expect(model.calls.length, 2);
      expect(currentDirectory(tester), '/remote');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'new folder permission and timeout errors fit with a keyboard on small phones',
    (tester) async {
      final model = DirectoryController();
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: pircTheme(),
          home: RemoteDirectoryPicker(model: model),
        ),
      );
      model.calls[0].reply.complete(listing('/remote/home'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('directory-new-folder')));
      await tester.tap(find.byKey(const Key('directory-new-folder')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('directory-new-name')),
        'project',
      );
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const Key('directory-create-confirm')),
      );
      await tester.tap(find.byKey(const Key('directory-create-confirm')));
      await tester.pump();
      model.creations[0].reply.completeError(
        StateError(
          'Device denied directory access. Grant permission or choose another directory.' *
              3,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('directory-create-error')), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('directory-create-confirm')),
      );
      await tester.tap(find.byKey(const Key('directory-create-confirm')));
      await tester.pump(const Duration(seconds: 8));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Creation is unconfirmed. Close and refresh the directory before retrying.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.creations[1].reply.complete('/remote/home/project');
      model.dispose();
      await tester.pump();
    },
  );
  testWidgets('opening during a disconnect does not leave an endless spinner', (
    tester,
  ) async {
    final model = DirectoryController()..connection = 'reconnecting';
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        theme: pircTheme(),
        home: RemoteDirectoryPicker(model: model),
      ),
    );
    await tester.pumpAndSettle();
    expect(model.calls, isEmpty);
    expect(find.byKey(const Key('directory-loading')), findsNothing);
    expect(
      find.text('Device disconnected. Reconnect and try again.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('directory-select')))
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets(
    'remote selection fills the path, stale navigation never changes it',
    (tester) async {
      final model = DirectoryController();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: pircTheme(),
          home: NewSessionPage(model: model),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('browse-remote-directory')));
      await settle(tester);
      expect(model.calls.single.path, '/remote/home');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('directory-select')))
            .onPressed,
        isNull,
      );
      model.calls[0].reply.complete(
        listing('/remote/home', names: ['project']),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('directory:/remote/home/project')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('directory-crumb:/remote/home')));
      await settle(tester);
      await tester.pump();
      model.calls[2].reply.complete(
        listing('/remote/home', names: ['project']),
      );
      await tester.pumpAndSettle();
      model.calls[1].reply.complete(
        listing('/remote/home/project', names: ['late folder']),
      );
      await tester.pumpAndSettle();
      expect(find.text('late folder'), findsNothing);
      await tester.tap(find.byKey(const Key('directory-crumb:/remote')));
      await tester.pump();
      expect(model.calls[3].path, '/remote');
      model.calls[3].reply.complete(listing('/remote'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('directory-select')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('new-session-cwd')))
            .controller!
            .text,
        '/remote',
      );
      expect(find.text('New conversation'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'permission refusal can be retried or escaped while the read is pending',
    (tester) async {
      final model = DirectoryController();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: pircTheme(),
          home: NewSessionPage(model: model),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('browse-remote-directory')));
      await settle(tester);
      model.calls[0].reply.completeError(
        StateError(
          'Device denied directory access. Grant permission or choose another directory.',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('directory-error')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('directory-select')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('directory-retry')));
      await tester.pump();
      expect(model.calls.length, 2);
      await tester.tap(find.byKey(const Key('directory-cancel')));
      await tester.pumpAndSettle();
      expect(find.text('New conversation'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('new-session-cwd')))
            .controller!
            .text,
        '/remote/home',
      );
      model.calls[1].reply.complete(listing('/remote/late'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'timeout and disconnect leave navigation usable and ignore late replies',
    (tester) async {
      final model = DirectoryController();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: pircTheme(),
          home: RemoteDirectoryPicker(model: model),
        ),
      );
      await tester.pump(const Duration(seconds: 8));
      await tester.pump();
      expect(
        find.text(
          'Reading the directory timed out. Retry or choose another directory.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('directory-refresh')));
      await settle(tester);
      await tester.pump();
      model.calls[1].reply.complete(listing('/remote/home'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('directory-current')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('directory-path')),
        '/remote/protected',
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('directory-select')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('directory-go')));
      await tester.pump();
      model.simulateDisconnect();
      await tester.pump();
      expect(
        find.text('Device disconnected. Reconnect and try again.'),
        findsOneWidget,
      );
      model.calls[2].reply.complete(listing('/remote/protected'));
      model.calls[0].reply.complete(listing('/remote/stale'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('directory-select')))
            .onPressed,
        isNull,
      );
      expect(
        find.text('Device disconnected. Reconnect and try again.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'visible hidden control handles rapid toggles, stale replies and disconnects',
    (tester) async {
      final model = DirectoryController();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: pircTheme(),
          home: RemoteDirectoryPicker(model: model),
        ),
      );
      model.calls[0].reply.complete(listing('/remote/home'));
      await tester.pumpAndSettle();
      final hiddenButton = find.byKey(const Key('directory-hidden'));
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byIcon(LucideIcons.eyeOff), findsOneWidget);
      final buttons = [
        'directory-new-folder',
        'directory-refresh',
        'directory-hidden',
      ].map((key) => tester.widget<IconButton>(find.byKey(Key(key))));
      expect(buttons.map((button) => button.color).toSet().length, 1);
      final appBar = find.byType(AppBar);
      expect(
        tester.getBottomLeft(hiddenButton).dy,
        lessThanOrEqualTo(tester.getBottomLeft(appBar).dy),
      );
      await tester.tap(find.byKey(const Key('directory-hidden')));
      await settle(tester);
      expect(hiddenButton, findsOneWidget);
      expect(tester.widget<IconButton>(hiddenButton).isSelected, isTrue);
      expect(model.calls[1].hidden, isTrue);
      expect(find.byIcon(LucideIcons.eye), findsOneWidget);
      expect(find.byIcon(LucideIcons.eyeOff), findsNothing);
      await tester.tap(hiddenButton);
      await settle(tester);
      expect(hiddenButton, findsOneWidget);
      expect(tester.widget<IconButton>(hiddenButton).isSelected, isFalse);
      expect(model.calls.length, 3);
      expect(model.calls[2].hidden, isFalse);
      model.calls[2].reply.complete(
        listing('/remote/home', names: ['visible']),
      );
      await tester.pumpAndSettle();
      model.calls[1].reply.complete(listing('/remote/home', names: ['.stale']));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('directory:/remote/home/visible')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('directory:/remote/home/.stale')),
        findsNothing,
      );
      expect(hiddenButton, findsOneWidget);
      model.simulateDisconnect();
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(hiddenButton).isSelected, isFalse);
      expect(tester.widget<IconButton>(hiddenButton).onPressed, isNull);
      await tester.tapAt(const Offset(16, 300));
      await tester.pumpAndSettle();
      expect(hiddenButton, findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('directory-refresh')))
            .onPressed,
        isNull,
      );
      expect(currentDirectory(tester), '/remote/home');
      expect(
        find.text('Device disconnected. Reconnect and try again.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'pagination and hidden folder option work on a narrow phone with large text',
    (tester) async {
      final model = DirectoryController();
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: pircTheme(),
          home: RemoteDirectoryPicker(model: model),
        ),
      );
      model.calls[0].reply.complete(
        listing(
          '/remote/home',
          names: ['Very long directory name' * 12],
          cursor: 'next',
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('directory-more')));
      await tester.tap(find.byKey(const Key('directory-more')));
      await tester.pump();
      expect(model.calls[1].cursor, 'next');
      model.calls[1].reply.complete(
        listing('/remote/home', names: ['next folder']),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('directory-options')), findsNothing);
      expect(find.byKey(const Key('directory-refresh')), findsOneWidget);
      expect(find.byIcon(LucideIcons.eyeOff), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('directory-hidden')))
            .isSelected,
        isFalse,
      );
      await tester.tap(find.byKey(const Key('directory-hidden')));
      await settle(tester);
      expect(model.calls[2].hidden, isTrue);
      model.calls[2].reply.complete(
        listing('/remote/home', names: ['.hidden']),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('directory-hidden')))
            .isSelected,
        isTrue,
      );
      await tester.tap(find.byKey(const Key('directory-hidden')));
      await settle(tester);
      expect(model.calls[3].hidden, isFalse);
      model.calls[3].reply.complete(listing('/remote/home'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('directory-hidden')))
            .isSelected,
        isFalse,
      );
      await tester.tap(find.byKey(const Key('directory-refresh')));
      await settle(tester);
      expect(find.byKey(const Key('directory-hidden')), findsOneWidget);
      expect(model.calls[4].hidden, isFalse);
      model.calls[4].reply.complete(listing('/remote/home'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
}
