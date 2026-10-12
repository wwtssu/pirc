import 'pirc_localizations.dart';
import 'pirc_language.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'computer_connections.dart';
import 'pirc_theme.dart';

class PircDrawerButton extends StatelessWidget {
  const PircDrawerButton({super.key});

  @override
  Widget build(BuildContext context) => Builder(
    builder: (context) => IconButton(
      key: const Key('drawer-button'),
      tooltip: context.l10n.openDeviceList,
      onPressed: () {
        FocusManager.instance.primaryFocus?.unfocus();
        Scaffold.of(context).openDrawer();
      },
      icon: const Icon(LucideIcons.menu),
    ),
  );
}

class PircDrawer extends StatelessWidget {
  const PircDrawer({
    super.key,
    required this.computers,
    required this.selectComputer,
    required this.addComputer,
    required this.configureComputer,
  });
  final ComputerConnections computers;
  final ValueChanged<ComputerConnection> selectComputer;
  final VoidCallback addComputer;
  final ValueChanged<ComputerConnection> configureComputer;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Drawer(
      key: const Key('settings-drawer'),
      width: math.min(
        PircLayout.drawerMaxWidth,
        constraints.maxWidth * PircLayout.drawerWidthFactor,
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(PircSpacing.s20),
          children: [
            Text('PiRC', style: context.pircText.brand),
            const SizedBox(height: PircSpacing.s24),
            Text(context.l10n.devices, style: context.pircText.hint),
            const SizedBox(height: PircSpacing.s12),
            for (final computer in computers.computers) ...[
              _ComputerTile(
                computer: computer,
                selected: computer == computers.active,
                configure: () {
                  Scaffold.of(context).closeDrawer();
                  configureComputer(computer);
                },
                onTap: () {
                  Scaffold.of(context).closeDrawer();
                  selectComputer(computer);
                },
              ),
              const SizedBox(height: PircSpacing.s6),
            ],
            const SizedBox(height: PircSpacing.s8),
            ListTile(
              key: const Key('add-computer'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: PircSpacing.s12,
              ),
              shape: const RoundedRectangleBorder(
                borderRadius: PircRadii.button,
              ),
              leading: Icon(
                LucideIcons.plus,
                color: context.pircColors.primary,
                size: PircIconSizes.toolbar,
              ),
              title: Text(
                context.l10n.addDevice,
                style: context.pircText.action.copyWith(
                  color: context.pircColors.primary,
                ),
              ),
              onTap: () {
                Scaffold.of(context).closeDrawer();
                addComputer();
              },
            ),
            if (PircLanguage.maybeOf(context) case final language?) ...[
              const SizedBox(height: PircSpacing.s24),
              ListTile(
                key: const Key('app-language'),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: PircSpacing.s12,
                ),
                shape: const RoundedRectangleBorder(
                  borderRadius: PircRadii.button,
                ),
                leading: Icon(
                  LucideIcons.languages,
                  size: PircIconSizes.toolbar,
                  color: context.pircColors.onSurfaceVariant,
                ),
                title: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Text(
                        context.l10n.language,
                        style: context.pircText.body,
                      ),
                    ),
                    const SizedBox(width: PircSpacing.s8),
                    Flexible(
                      child: Text(
                        _languageLabels(context)[language.value] ??
                            context.l10n.systemLanguage,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.pircText.description.copyWith(
                          color: context.pircColors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                trailing: Icon(
                  LucideIcons.chevronRight,
                  size: PircIconSizes.small,
                  color: context.pircColors.onSurfaceVariant,
                ),
                onTap: () async {
                  final value = await _showLanguageSheet(
                    context,
                    language.value,
                  );
                  if (value != null) language.onChanged(value);
                },
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

Map<String, String> _languageLabels(BuildContext context) => {
  'system': context.l10n.systemLanguage,
  'zh': context.l10n.chineseLanguage,
  'en': context.l10n.englishLanguage,
  'ja': context.l10n.japaneseLanguage,
};

Future<String?> _showLanguageSheet(
  BuildContext context,
  String selected,
) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: context.pircColors.surface,
  shape: const RoundedRectangleBorder(borderRadius: PircRadii.dialog),
  clipBehavior: Clip.antiAlias,
  builder: (context) => SafeArea(
    top: false,
    child: Center(
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: PircLayout.maxContentWidth,
          maxHeight:
              MediaQuery.sizeOf(context).height * PircLayout.sheetHeightFactor,
        ),
        child: SingleChildScrollView(
          child: Padding(
            key: const Key('app-language-sheet'),
            padding: const EdgeInsets.all(PircSpacing.s20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.l10n.language,
                        style: context.pircText.section,
                      ),
                    ),
                    IconButton(
                      tooltip: context.l10n.closeMenu,
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(
                        LucideIcons.x,
                        size: PircIconSizes.chevron,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: PircSpacing.s12),
                for (final entry in _languageLabels(context).entries)
                  Semantics(
                    selected: entry.key == selected,
                    child: ListTile(
                      key: ValueKey('app-language-${entry.key}'),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: PircSpacing.s12,
                      ),
                      shape: const RoundedRectangleBorder(
                        borderRadius: PircRadii.button,
                      ),
                      title: Text(entry.value, style: context.pircText.body),
                      trailing: entry.key == selected
                          ? Icon(
                              LucideIcons.check,
                              size: PircIconSizes.small,
                              color: context.pircColors.primary,
                            )
                          : null,
                      onTap: () => Navigator.pop(context, entry.key),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
);

class _ComputerTile extends StatelessWidget {
  const _ComputerTile({
    required this.computer,
    required this.selected,
    required this.onTap,
    required this.configure,
  });
  final ComputerConnection computer;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback configure;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: ValueKey('computer-${computer.endpoint}'),
      selected: selected,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: PircSpacing.s12,
        vertical: PircSpacing.s4,
      ),
      shape: const RoundedRectangleBorder(borderRadius: PircRadii.button),
      selectedTileColor: context.pircColors.primaryContainer,
      leading: Icon(
        LucideIcons.laptop,
        size: PircIconSizes.toolbar,
        color: selected
            ? context.pircColors.primary
            : context.pircColors.onSurfaceVariant,
      ),
      title: Text(
        computer.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.pircText.cardTitle,
      ),
      trailing: IconButton(
        key: ValueKey('configure-computer-${computer.endpoint}'),
        tooltip: context.l10n.connectionSettings,
        onPressed: configure,
        icon: Icon(
          LucideIcons.settings,
          size: PircIconSizes.small,
          color: context.pircColors.onSurfaceVariant,
        ),
      ),
      onTap: onTap,
    );
  }
}
