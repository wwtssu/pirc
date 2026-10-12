import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pirc_controller.dart';
import 'pirc_screen.dart';
import 'pirc_theme.dart';
import 'computer_connections.dart';
import 'pirc_localizations.dart';
import 'pirc_language.dart';

import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    for (final font in ['NotoSansSC', 'JetBrainsMono']) {
      yield LicenseEntryWithLineBreaks([
        font,
      ], await rootBundle.loadString('assets/fonts/LICENSE-$font.txt'));
    }
  });
  await RustLib.init();
  final preferences = await SharedPreferences.getInstance();
  final computers = ComputerConnections(preferences: preferences);
  computers.startupLoading = true;
  runApp(PircApp(computers: computers));
  unawaited(computers.restoreConnections());
}

class PircApp extends StatefulWidget {
  const PircApp({super.key, this.controller, this.computers, this.locale})
    : assert(controller == null || computers == null);
  final PircController? controller;
  final ComputerConnections? computers;
  final Locale? locale;
  @override
  State<PircApp> createState() => _PircAppState();
}

class _PircAppState extends State<PircApp> {
  late final computers =
      widget.computers ??
      ComputerConnections(initialController: widget.controller);
  late String language =
      computers.preferences?.getString('app-language') ?? 'system';

  void changeLanguage(String value) {
    setState(() => language = value);
    unawaited(computers.preferences?.setString('app-language', value));
  }

  @override
  void dispose() {
    if (widget.computers == null) computers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PircLanguage(
      value: language,
      onChanged: changeLanguage,
      child: MaterialApp(
        title: 'PiRC',
        debugShowCheckedModeBanner: false,
        theme: pircTheme(),
        locale:
            widget.locale ?? (language == 'system' ? null : Locale(language)),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PircScreen(computers: computers),
      ),
    );
  }
}
