import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter/material.dart';

// Design tokens from design.pen. Keep platform chrome and protocol state out of
// this file; these values describe only the mobile client's visual system.
abstract final class PircColors {
  static const background = Color(0xfff8f9fc);
  static const surface = Color(0xffffffff);
  static const ink = Color(0xff242735);
  static const muted = Color(0xff747c8d);
  static const border = Color(0xffe6e9f0);
  static const accent = Color(0xff5558cc);
  static const accentSoft = Color(0xffeef0ff);
  static const success = Color(0xff20856c);
  static const warning = Color(0xffac632e);
  static const warningSoft = Color(0xfffff5e9);
}

abstract final class PircFonts {
  static const body = 'Noto Sans SC';
  static const code = 'JetBrains Mono';
}

abstract final class PircSpacing {
  static const s1 = 1.0;
  static const s2 = 2.0;
  static const s3 = 3.0;
  static const s4 = 4.0;
  static const s5 = 5.0;
  static const s6 = 6.0;
  static const s7 = 7.0;
  static const s8 = 8.0;
  static const s9 = 9.0;
  static const s10 = 10.0;
  static const s12 = 12.0;
  static const s13 = 13.0;
  static const s14 = 14.0;
  static const s16 = 16.0;
  static const s18 = 18.0;
  static const s20 = 20.0;
  static const s22 = 22.0;
  static const s24 = 24.0;
  static const s28 = 28.0;
}

abstract final class PircRadii {
  static const agentBadge = BorderRadius.all(Radius.circular(5));
  static const badge = BorderRadius.all(Radius.circular(8));
  static const brand = BorderRadius.all(Radius.circular(10));
  static const composerAction = BorderRadius.all(Radius.circular(10));
  static const notice = BorderRadius.all(Radius.circular(12));
  static const device = BorderRadius.all(Radius.circular(13));
  static const button = BorderRadius.all(Radius.circular(14));
  static const activity = BorderRadius.all(Radius.circular(16));
  static const session = BorderRadius.all(Radius.circular(18));
  static const connection = BorderRadius.all(Radius.circular(20));
  static const emptyState = BorderRadius.all(Radius.circular(22));
  static const composer = BorderRadius.all(Radius.circular(24));
  static const dialog = composer;
  static const input = activity;
  static const drawer = BorderRadius.only(
    topRight: Radius.circular(24),
    bottomRight: Radius.circular(24),
  );
  static const userBubble = BorderRadius.only(
    topLeft: Radius.circular(18),
    topRight: Radius.circular(18),
    bottomLeft: Radius.circular(18),
    bottomRight: Radius.circular(6),
  );
}

abstract final class PircLayout {
  static const sheetHeightFactor = .8;
  static const maxContentWidth = 480.0;
  static const drawerMaxWidth = 320.0;
  static const drawerWidthFactor = .82;
  static const toolbarHeight = 64.0;
  static const brandSize = 32.0;
  static const deviceSize = 42.0;
  static const emptyStateSize = 64.0;
  static const actionSize = 48.0;
  static const composerActionSize = 36.0;
  static const attachmentMenuWidth = 204.0;
  static const attachmentChoiceHeight = 50.0;
  static const attachmentIconBox = 28.0;
  static const attachmentPreviewSize = 36.0;
  static const settingMinSize = 48.0;
  static const statusDotSize = 6.0;
  static const statusBadgeWidthFactor = .45;
  static const activityMaxHeight = 240.0;
  static const userBubbleWidthFactor = .86;
  static const borderWidth = 1.0;
  static const focusBorderWidth = 1.5;
  static const loadingMarkWidth = 40.0;
  static const loadingMarkSize = 32.0;
  static const loadingDotSize = 6.0;
  static const loadingStrokeWidth = 2.0;
  static const dialogWidth = 310.0;
  static const loadingDialogWidth = 260.0;
  static const directoryRowHeight = 56.0;
  static const inactiveOpacity = .5;
}

abstract final class PircIconSizes {
  static const notice = 15.0;
  static const activity = 16.0;
  static const small = 18.0;
  static const brand = 19.0;
  static const chevron = 20.0;
  static const session = 21.0;
  static const toolbar = 22.0;
  static const emptyState = 28.0;
}

abstract final class PircMotion {
  static const loadingCycle = Duration(milliseconds: 1100);
}

abstract final class PircEffects {
  static const popupElevation = 2.0;
  // Pencil colors use RGBA; Flutter's integer color uses ARGB.
  static const dialogShadow = [
    BoxShadow(color: Color(0x330f172a), blurRadius: 48, offset: Offset(0, 18)),
  ];
  static const composerShadow = [
    BoxShadow(color: Color(0x100f172a), blurRadius: 16, offset: Offset(0, 3)),
  ];
}

abstract final class PircInputDecorations {
  static const directoryPath = InputDecoration(
    isDense: true,
    filled: false,
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    disabledBorder: InputBorder.none,
    contentPadding: EdgeInsets.symmetric(
      horizontal: PircSpacing.s4,
      vertical: PircSpacing.s12,
    ),
    constraints: BoxConstraints(minHeight: PircLayout.actionSize),
    suffixIconConstraints: BoxConstraints(
      minWidth: PircLayout.actionSize,
      minHeight: PircLayout.actionSize,
    ),
  );

  static const composer = InputDecoration(
    filled: false,
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    contentPadding: EdgeInsets.symmetric(
      horizontal: PircSpacing.s12,
      vertical: PircSpacing.s13,
    ),
  );
}

@immutable
class PircExtraTheme extends ThemeExtension<PircExtraTheme> {
  const PircExtraTheme({
    this.success = PircColors.success,
    this.warning = PircColors.warning,
    this.warningSurface = PircColors.warningSoft,
    this.code = const TextStyle(
      fontFamily: PircFonts.code,
      fontFamilyFallback: [PircFonts.body],
      fontSize: 12,
      height: 1.6,
      color: PircColors.ink,
    ),
    this.thinking = const TextStyle(
      fontFamily: PircFonts.body,
      fontSize: 13,
      height: 1.6,
      color: PircColors.ink,
    ),
  });
  final Color success;
  final Color warning;
  final Color warningSurface;
  final TextStyle code;
  final TextStyle thinking;

  @override
  PircExtraTheme copyWith({
    Color? success,
    Color? warning,
    Color? warningSurface,
    TextStyle? code,
    TextStyle? thinking,
  }) => PircExtraTheme(
    success: success ?? this.success,
    warning: warning ?? this.warning,
    warningSurface: warningSurface ?? this.warningSurface,
    code: code ?? this.code,
    thinking: thinking ?? this.thinking,
  );

  @override
  PircExtraTheme lerp(covariant PircExtraTheme? other, double t) {
    if (other == null) return this;
    return PircExtraTheme(
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningSurface: Color.lerp(warningSurface, other.warningSurface, t)!,
      code: TextStyle.lerp(code, other.code, t)!,
      thinking: TextStyle.lerp(thinking, other.thinking, t)!,
    );
  }
}

extension PircThemeAccess on BuildContext {
  ColorScheme get pircColors => Theme.of(this).colorScheme;
  TextTheme get pircText => Theme.of(this).textTheme;
  PircExtraTheme get pirc =>
      Theme.of(this).extension<PircExtraTheme>() ?? const PircExtraTheme();
  ButtonStyle pircComposerButtonStyle({required bool waiting}) =>
      IconButton.styleFrom(
        fixedSize: const Size.square(PircLayout.composerActionSize),
        minimumSize: const Size.square(PircLayout.composerActionSize),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.padded,
        iconSize: PircIconSizes.small,
        backgroundColor: pircColors.primary,
        foregroundColor: pircColors.onPrimary,
        disabledBackgroundColor: waiting
            ? pircColors.primaryContainer
            : pircColors.surfaceContainerLowest,
        disabledForegroundColor: pircColors.onSurfaceVariant.withValues(
          alpha: PircLayout.inactiveOpacity,
        ),
        shape: const RoundedRectangleBorder(
          borderRadius: PircRadii.composerAction,
        ),
      );
}

extension PircTextRoles on TextTheme {
  TextStyle get brand => displaySmall!;
  TextStyle get section => titleLarge!;
  TextStyle get sessionTitle => titleMedium!;
  TextStyle get cardTitle => titleSmall!;
  TextStyle get body => bodyLarge!;
  TextStyle get description => bodyMedium!;
  TextStyle get hint => bodySmall!;
  TextStyle get action => labelLarge!;
  TextStyle get path => labelMedium!;
  TextStyle get directoryPath =>
      description.copyWith(fontWeight: FontWeight.w400, height: body.height);
  TextStyle get tag => labelSmall!;
  TextStyle get activityTitle =>
      description.copyWith(fontWeight: FontWeight.w600);
  TextStyle get author => path.copyWith(fontWeight: FontWeight.w600);
  TextStyle get emptyTitle => cardTitle.copyWith(fontSize: 16);
  TextStyle get emptyDescription => description.copyWith(height: 1.7);
}

ThemeData pircTheme() {
  const text = TextTheme(
    displaySmall: TextStyle(
      fontFamily: PircFonts.body,
      fontSize: 24,
      fontWeight: FontWeight.w700,
      letterSpacing: -.6,
      color: PircColors.ink,
    ),
    titleLarge: TextStyle(
      fontFamily: PircFonts.body,
      fontSize: 20,
      fontWeight: FontWeight.w700,
      color: PircColors.ink,
    ),
    titleMedium: TextStyle(
      fontFamily: PircFonts.body,
      fontSize: 17,
      fontWeight: FontWeight.w600,
      color: PircColors.ink,
    ),
    titleSmall: TextStyle(
      fontFamily: PircFonts.body,
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: PircColors.ink,
    ),
    bodyLarge: TextStyle(
      fontFamily: PircFonts.body,
      fontSize: 14,
      height: 1.65,
      color: PircColors.ink,
    ),
    bodyMedium: TextStyle(
      fontFamily: PircFonts.body,
      fontSize: 13,
      color: PircColors.ink,
    ),
    bodySmall: TextStyle(
      fontFamily: PircFonts.body,
      fontSize: 12,
      color: PircColors.muted,
    ),
    labelLarge: TextStyle(
      fontFamily: PircFonts.body,
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: PircColors.ink,
    ),
    labelMedium: TextStyle(
      fontFamily: PircFonts.body,
      fontSize: 11,
      color: PircColors.muted,
    ),
    labelSmall: TextStyle(
      fontFamily: PircFonts.body,
      fontSize: 10,
      color: PircColors.muted,
    ),
  );
  final base = ThemeData(
    useMaterial3: true,
    fontFamily: PircFonts.body,
    colorScheme: ColorScheme.fromSeed(
      seedColor: PircColors.accent,
      primary: PircColors.accent,
      onPrimary: PircColors.surface,
      primaryContainer: PircColors.accentSoft,
      onPrimaryContainer: PircColors.accent,
      surface: PircColors.surface,
      surfaceContainerLowest: PircColors.background,
      onSurface: PircColors.ink,
      onSurfaceVariant: PircColors.muted,
      outlineVariant: PircColors.border,
    ),
  );
  const inputBorder = OutlineInputBorder(
    borderRadius: PircRadii.input,
    borderSide: BorderSide(
      color: PircColors.border,
      width: PircLayout.borderWidth,
    ),
  );
  return base.copyWith(
    extensions: const [PircExtraTheme()],
    scaffoldBackgroundColor: PircColors.background,
    textTheme: base.textTheme.merge(text),
    appBarTheme: const AppBarTheme(
      backgroundColor: PircColors.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleSpacing: PircSpacing.s20,
      toolbarHeight: PircLayout.toolbarHeight,
      iconTheme: IconThemeData(
        color: PircColors.ink,
        size: PircIconSizes.toolbar,
      ),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: PircColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrimColor: PircColors.ink.withValues(alpha: PircLayout.inactiveOpacity),
      shape: const RoundedRectangleBorder(borderRadius: PircRadii.drawer),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(
        borderSide: const BorderSide(
          color: PircColors.accent,
          width: PircLayout.focusBorderWidth,
        ),
      ),
      filled: true,
      fillColor: PircColors.background,
      hintStyle: text.bodyLarge!.copyWith(color: PircColors.muted),
      labelStyle: text.bodySmall,
      helperStyle: text.bodySmall,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: PircSpacing.s16,
        vertical: PircSpacing.s14,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(PircLayout.actionSize, PircLayout.actionSize),
        padding: const EdgeInsets.symmetric(
          horizontal: PircSpacing.s20,
          vertical: PircSpacing.s12,
        ),
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: PircRadii.button),
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(PircLayout.actionSize, PircLayout.actionSize),
        padding: const EdgeInsets.all(PircSpacing.s12),
        shape: const RoundedRectangleBorder(borderRadius: PircRadii.button),
        textStyle: text.labelLarge,
      ),
    ),
    dialogTheme: DialogThemeData(
      elevation: 0,
      backgroundColor: PircColors.surface,
      surfaceTintColor: Colors.transparent,
      constraints: const BoxConstraints(maxWidth: PircLayout.dialogWidth),
      insetPadding: const EdgeInsets.all(PircSpacing.s24),
      barrierColor: PircColors.ink.withValues(
        alpha: PircLayout.inactiveOpacity,
      ),
      shape: const RoundedRectangleBorder(borderRadius: PircRadii.dialog),
      titleTextStyle: text.titleLarge!.copyWith(fontWeight: FontWeight.w600),
      contentTextStyle: text.bodyMedium,
    ),
    dividerTheme: const DividerThemeData(
      color: PircColors.border,
      thickness: PircLayout.borderWidth,
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: PircColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: PircRadii.notice),
    ),
    cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
  );
}

extension PircMarkdownTheme on BuildContext {
  MarkdownStyleSheet get pircMarkdown =>
      MarkdownStyleSheet.fromTheme(Theme.of(this)).copyWith(
        p: pircText.body,
        a: pircText.body.copyWith(
          color: pircColors.primary,
          decoration: TextDecoration.underline,
        ),
        strong: pircText.body.copyWith(fontWeight: FontWeight.w700),
        h1: pircText.section,
        h2: pircText.sessionTitle,
        h3: pircText.cardTitle,
        // TextSpan backgrounds paint over the selection highlight. Keep inline
        // code transparent; fenced code retains its enclosing decoration.
        code: pirc.code,
        blockSpacing: PircSpacing.s12,
        listBullet: pircText.body,
        blockquote: pircText.body,
        blockquotePadding: const EdgeInsets.all(PircSpacing.s12),
        blockquoteDecoration: BoxDecoration(
          color: pircColors.primaryContainer,
          border: Border(
            left: BorderSide(color: pircColors.primary, width: PircSpacing.s3),
          ),
          borderRadius: PircRadii.badge,
        ),
        tableHead: pircText.body.copyWith(fontWeight: FontWeight.w600),
        tableBody: pircText.body,
        tableBorder: TableBorder.all(
          color: pircColors.outlineVariant,
          width: PircLayout.borderWidth,
        ),
        tableColumnWidth: const IntrinsicColumnWidth(),
        tableCellsPadding: const EdgeInsets.symmetric(
          horizontal: PircSpacing.s12,
          vertical: PircSpacing.s8,
        ),
        tableHeadAlign: TextAlign.left,
        codeblockPadding: const EdgeInsets.all(PircSpacing.s12),
        codeblockDecoration: BoxDecoration(
          color: pircColors.surfaceContainerLowest,
          borderRadius: PircRadii.notice,
        ),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: pircColors.outlineVariant,
              width: PircLayout.borderWidth,
            ),
          ),
        ),
      );
}
