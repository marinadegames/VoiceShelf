import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voiceshelf/main.dart';

void main() {
  testWidgets('VoiceShelf renders its desktop shell', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const VoiceShelfApp(enableModelCheck: false));
    expect(find.text('VoiceShelf'), findsOneWidget);
    expect(find.text('Расшифровать'), findsOneWidget);
  });

  for (final size in [const Size(390, 844), const Size(820, 900)]) {
    testWidgets('VoiceShelf adapts to ${size.width.toInt()}px', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(const VoiceShelfApp(enableModelCheck: false));
      await tester.pump();

      expect(find.text('VoiceShelf'), findsOneWidget);
      expect(find.text('Новая заметка'), findsAtLeastNWidgets(1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('VoiceShelf follows system dark mode', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(const VoiceShelfApp(enableModelCheck: false));
    await tester.pump();

    final context = tester.element(find.byType(Scaffold));
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Vocabulary manager imports space-separated terms',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const VoiceShelfApp(enableModelCheck: false));
    final vocabulary = find.text('Словарь терминов');
    await tester.ensureVisible(vocabulary);
    await tester.tap(vocabulary);
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byType(TextField).first, 'Kubernetes Docker Kubernetes Redis');
    await tester.tap(find.text('Распознать и добавить слова'));
    await tester.pump();

    expect(find.text('Kubernetes'), findsOneWidget);
    expect(find.text('Docker'), findsOneWidget);
    expect(find.text('Redis'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
