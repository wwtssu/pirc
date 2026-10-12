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
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: PircSpacing.s12,
                ),
                leading: const Icon(LucideIcons.languages),
                title: Text(context.l10n.language),
                subtitle: DropdownButton<String>(
                  key: const Key('app-language'),
                  value: language.value,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    DropdownMenuItem(
                      value: 'system',
                      child: Text(context.l10n.systemLanguage),
                    ),
                    DropdownMenuItem(
                      value: 'en',
                      child: Text(context.l10n.englishLanguage),
                    ),
                    DropdownMenuItem(
                      value: 'zh',
                      child: Text(context.l10n.chineseLanguage),
                    ),
                    DropdownMenuItem(
                      value: 'ja',
                      child: Text(context.l10n.japaneseLanguage),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) language.onChanged(value);
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

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
