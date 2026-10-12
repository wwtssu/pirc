import 'package:flutter/widgets.dart';

/// Provides the user's language preference independently of device connections.
class PircLanguage extends InheritedWidget {
  const PircLanguage({
    super.key,
    required this.value,
    required this.onChanged,
    required super.child,
  });

  final String value;
  final ValueChanged<String> onChanged;

  static PircLanguage? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PircLanguage>();

  @override
  bool updateShouldNotify(PircLanguage oldWidget) => value != oldWidget.value;
}
