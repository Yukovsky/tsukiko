import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:tsukiko/core/text_commands.dart';
import 'package:tsukiko/core/transcript.dart';
import 'package:tsukiko/design/design.dart';
import 'package:tsukiko/features/queue/widgets/segment_row.dart';
import 'package:tsukiko/l10n/gen/app_localizations.dart';

MacosApp app(Widget child) => MacosApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

void main() {
  testWidgets('значок копирования фрагмента имеет размер панели', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        SegmentRow(
          segment: const Segment(0, 0, 'Текст'),
          showTimestamp: false,
          onCopied: () {},
          onReplacementUndo: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final icon = tester.widget<MacosIcon>(
      find.byWidgetPredicate(
        (widget) =>
            widget is MacosIcon && widget.icon == CupertinoIcons.doc_on_doc,
      ),
    );
    expect(icon.size, IconSize.toolbar);
  });

  testWidgets('заменённую команду можно вернуть из строки', (tester) async {
    var undone = -1;
    await tester.pumpWidget(
      app(
        SegmentRow(
          segment: const Segment(
            0,
            0,
            'Минск, Немига, 1',
            replacements: [
              TextReplacement(
                start: 0,
                end: 16,
                original: 'адрес офиса',
                replacement: 'Минск, Немига, 1',
              ),
            ],
          ),
          showTimestamp: false,
          onCopied: () {},
          onReplacementUndo: (index) => undone = index,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.byType(SegmentRow);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(row));
    await mouse.moveTo(tester.getCenter(row));
    await tester.pumpAndSettle();

    final undoIcon = find.byWidgetPredicate(
      (widget) =>
          widget is MacosIcon && widget.icon == CupertinoIcons.arrow_uturn_left,
    );
    await tester.tap(
      find.ancestor(of: undoIcon, matching: find.byType(MacosIconButton)),
    );

    expect(undone, 0);
  });

  testWidgets('метка голоса — имя рядом с цветом и знак перебивки', (
    tester,
  ) async {
    const voices = [
      SpeakerInfo(id: 'S1', name: 'Иван'),
      SpeakerInfo(id: 'S2', name: 'Мария', colorIndex: 1),
    ];
    String? chosen;
    await tester.pumpWidget(
      app(
        SegmentRow(
          segment: const Segment(0, 0, 'Текст', speaker: 'S2', overlap: true),
          showTimestamp: false,
          onCopied: () {},
          onReplacementUndo: (_) {},
          speakers: voices,
          onSpeakerChosen: (id) => chosen = id,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Мария'), findsOneWidget);
    expect(find.text(overlapMark), findsOneWidget);
    expect(chosen, isNull);
  });

  testWidgets('один голос — метки нет', (tester) async {
    await tester.pumpWidget(
      app(
        SegmentRow(
          segment: const Segment(0, 0, 'Текст', speaker: 'S1'),
          showTimestamp: false,
          onCopied: () {},
          onReplacementUndo: (_) {},
          speakers: const [SpeakerInfo(id: 'S1', name: 'Иван')],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Иван'), findsNothing);
  });
}
