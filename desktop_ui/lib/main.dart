import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

const ink = Color(0xFF1B241D);
const paper = Color(0xFFF2EFE7);
const card = Color(0xFFFBFAF6);
const muted = Color(0xFF74786F);
const forest = Color(0xFF345E43);
const lime = Color(0xFFC8E26B);
const orange = Color(0xFFD66A3D);
const hairline = Color(0xFFD9D6CC);

bool isDark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;
Color inkOf(BuildContext context) =>
    isDark(context) ? const Color(0xFFE8EDE8) : ink;
Color paperOf(BuildContext context) =>
    isDark(context) ? const Color(0xFF121713) : paper;
Color cardOf(BuildContext context) =>
    isDark(context) ? const Color(0xFF1B211C) : card;
Color mutedOf(BuildContext context) =>
    isDark(context) ? const Color(0xFFAAB3AB) : muted;
Color forestOf(BuildContext context) =>
    isDark(context) ? const Color(0xFF8FBE99) : forest;
Color orangeOf(BuildContext context) =>
    isDark(context) ? const Color(0xFFF08A5E) : orange;
Color hairlineOf(BuildContext context) =>
    isDark(context) ? const Color(0xFF343C35) : hairline;

ThemeData voiceShelfTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final background = dark ? const Color(0xFF121713) : paper;
  final surface = dark ? const Color(0xFF1B211C) : card;
  final outline = dark ? const Color(0xFF343C35) : hairline;
  final primary = dark ? const Color(0xFF8FBE99) : forest;
  final foreground = dark ? const Color(0xFFE8EDE8) : ink;
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: background,
    colorScheme: ColorScheme.fromSeed(
        seedColor: primary,
        brightness: brightness,
        surface: surface,
        onSurface: foreground),
    fontFamily: Platform.isMacOS ? '.AppleSystemUIFont' : 'Segoe UI',
    dividerColor: outline,
    dialogTheme: DialogThemeData(backgroundColor: background),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      isDense: true,
      border: OutlineInputBorder(
          borderSide: BorderSide(color: outline),
          borderRadius: BorderRadius.zero),
      enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: outline),
          borderRadius: BorderRadius.zero),
      focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: primary, width: 1.5),
          borderRadius: BorderRadius.zero),
    ),
  );
}

void main() => runApp(const VoiceShelfApp());

class VoiceShelfApp extends StatelessWidget {
  final bool enableModelCheck;
  const VoiceShelfApp({super.key, this.enableModelCheck = true});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'VoiceShelf',
      themeMode: ThemeMode.system,
      theme: voiceShelfTheme(Brightness.light),
      darkTheme: voiceShelfTheme(Brightness.dark),
      home: VoiceShelfHome(enableModelCheck: enableModelCheck),
    );
  }
}

class LocalWorker {
  Process? _process;
  StreamIterator<String>? _lines;
  Future<void> _queue = Future.value();

  Future<void> start() async {
    if (_process != null) return;
    final env = Platform.environment;
    if (Platform.isMacOS) {
      final contents = File(Platform.resolvedExecutable).parent.parent;
      final bundledWorker = File(
          '${contents.path}${Platform.pathSeparator}Resources${Platform.pathSeparator}worker${Platform.pathSeparator}voiceshelf-worker');
      if (await bundledWorker.exists()) {
        _process = await Process.start(bundledWorker.path, const [],
            workingDirectory: bundledWorker.parent.path);
        _lines = StreamIterator(_process!.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter()));
        return;
      }
    }
    final python =
        env['VOICESHELF_PYTHON'] ?? (Platform.isWindows ? 'python' : 'python3');
    final root = env['VOICESHELF_ROOT'] ?? Directory.current.parent.path;
    _process = await Process.start(python, ['-m', 'voiceshelf.worker'],
        workingDirectory: root);
    _lines = StreamIterator(_process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter()));
  }

  Future<Map<String, dynamic>> call(Map<String, dynamic> request) async {
    final result = Completer<Map<String, dynamic>>();
    _queue = _queue.then((_) async {
      try {
        result.complete(await _callNow(request));
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<Map<String, dynamic>> _callNow(Map<String, dynamic> request) async {
    await start();
    _process!.stdin.writeln(jsonEncode(request));
    if (!await _lines!.moveNext()) {
      throw Exception('Локальный движок неожиданно остановился');
    }
    final response = jsonDecode(_lines!.current) as Map<String, dynamic>;
    if (response['ok'] != true) {
      throw Exception(response['error'] ?? 'Неизвестная ошибка');
    }
    return Map<String, dynamic>.from(response['result'] ?? response);
  }

  void cancelCurrentOperation() {
    final process = _process;
    _process = null;
    _lines = null;
    process?.kill();
  }

  void close() => cancelCurrentOperation();
}

class VoiceShelfHome extends StatefulWidget {
  final bool enableModelCheck;
  const VoiceShelfHome({super.key, required this.enableModelCheck});
  @override
  State<VoiceShelfHome> createState() => _VoiceShelfHomeState();
}

class _VoiceShelfHomeState extends State<VoiceShelfHome>
    with WidgetsBindingObserver {
  static const defaultVocabularyTerms = [
    'Notion',
    'Figma',
    'Claude',
    'ChatGPT'
  ];
  final worker = LocalWorker();
  final recorder = AudioRecorder();
  static const macRecorder = MethodChannel('local.voiceshelf.desktop/recorder');
  StreamSubscription<Amplitude>? amplitudeSubscription;
  Timer? amplitudeTimer;
  Timer? playbackTimer;
  final vocabulary =
      TextEditingController(text: defaultVocabularyTerms.join(', '));
  List<String> vocabularyTerms = [...defaultVocabularyTerms];
  String? mediaPath;
  String? playingPath;
  List<RecordingEntry> recordings = [];
  int page = 0;
  String model = 'small';
  String organizerModel = 'qwen2.5:7b';
  String language = 'auto';
  bool recording = false;
  bool? microphoneGranted;
  bool microphoneDialogOpen = false;
  double recordingPeakDb = -160;
  DateTime? recordingStartedAt;
  List<double> amplitudeLevels = List.filled(30, .08);
  bool busy = false;
  String status = 'Выберите файл или запишите голос';
  Map<String, dynamic>? transcript;
  Map<String, dynamic>? organized;
  bool whisperReady = false;
  bool? organizerReady;
  String organizerMessage = 'Проверяю локальные модели…';
  Map<String, dynamic> organizerDiagnostics = {};
  int tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.enableModelCheck) {
      checkModels();
      loadRecordings();
      loadVocabulary();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // macOS shows its native permission prompt from AppDelegate. This
        // second check keeps the Flutter state in sync without opening a
        // duplicate dialog when access was previously denied.
        checkMicrophoneAccess(
            request: true, showDialogOnDenied: !Platform.isMacOS);
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.enableModelCheck) {
      checkMicrophoneAccess(request: false, showDialogOnDenied: false);
    }
  }

  Future<bool> checkMicrophoneAccess({
    required bool request,
    required bool showDialogOnDenied,
  }) async {
    try {
      final granted = await recorder.hasPermission(request: request);
      if (mounted) {
        setState(() {
          microphoneGranted = granted;
          if (!granted) status = 'Нет доступа к микрофону';
        });
      }
      if (!granted && showDialogOnDenied) await showMicrophoneAccessDialog();
      return granted;
    } catch (error) {
      if (mounted) setState(() => microphoneGranted = false);
      if (showDialogOnDenied) {
        _error('Не удалось проверить доступ к микрофону:\n$error');
      }
      return false;
    }
  }

  Future<void> showMicrophoneAccessDialog() async {
    if (!mounted || microphoneDialogOpen) return;
    microphoneDialogOpen = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.mic_off_rounded, color: orange, size: 34),
        title: const Text('VoiceShelf нужен доступ к микрофону'),
        content: const Text(
          'Без разрешения запись не начнётся. Откройте «Конфиденциальность и безопасность → Микрофон» и включите VoiceShelf.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Позже'),
          ),
          FilledButton.icon(
            onPressed: () async {
              await Process.run('open', [
                'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone'
              ]);
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            icon: const Icon(Icons.settings_rounded, size: 17),
            label: const Text('Открыть настройки'),
          ),
        ],
      ),
    );
    microphoneDialogOpen = false;
  }

  Future<void> checkModels() async {
    try {
      final result = await worker.call({
        'action': 'models_status',
        'ollama_model': organizerModel,
        'autostart': true
      });
      final whisper =
          (result['whisper'] as List? ?? []).cast<Map<String, dynamic>>();
      final ollama = Map<String, dynamic>.from(result['ollama'] ?? {});
      if (mounted)
        setState(() {
          organizerDiagnostics = result;
          whisperReady = whisper.any(
              (item) => item['model'] == model && item['installed'] == true);
          organizerReady =
              ollama['available'] == true && ollama['model_installed'] == true;
          organizerMessage =
              'Whisper $model: ${whisperReady ? 'готов' : 'не установлен'}  ·  Qwen $organizerModel: ${organizerReady == true ? 'готов' : 'не установлен'}';
        });
    } catch (_) {
      if (mounted)
        setState(() {
          whisperReady = false;
          organizerReady = false;
          organizerMessage = 'Не удалось проверить локальные модели';
        });
    }
  }

  Future<void> showModelManager() async {
    final selected = await showDialog<Map<String, String>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ModelManagerDialog(
          worker: worker, whisperModel: model, ollamaModel: organizerModel),
    );
    if (selected == null || !mounted) return;
    setState(() {
      model = selected['whisper'] ?? model;
      organizerModel = selected['ollama'] ?? organizerModel;
      organizerMessage = 'Проверяю выбранные модели…';
    });
    await checkModels();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    worker.close();
    amplitudeSubscription?.cancel();
    amplitudeTimer?.cancel();
    playbackTimer?.cancel();
    if (Platform.isMacOS && widget.enableModelCheck) {
      macRecorder.invokeMethod<void>('stopPlayback');
    }
    recorder.dispose();
    vocabulary.dispose();
    super.dispose();
  }

  Future<void> pickFile() async {
    final result = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: [
      'mp3',
      'wav',
      'm4a',
      'aac',
      'flac',
      'ogg',
      'opus',
      'webm',
      'mp4',
      'mov',
      'mkv',
      'avi'
    ]);
    if (result?.files.single.path != null)
      setState(() {
        mediaPath = result!.files.single.path;
        status = 'Файл готов к расшифровке';
      });
  }

  Future<Directory> recordingsDirectory() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(
        '${support.path}${Platform.pathSeparator}VoiceShelf${Platform.pathSeparator}recordings');
    await directory.create(recursive: true);
    return directory;
  }

  Future<File> vocabularyFile() async {
    final support = await getApplicationSupportDirectory();
    final directory =
        Directory('${support.path}${Platform.pathSeparator}VoiceShelf');
    await directory.create(recursive: true);
    return File('${directory.path}${Platform.pathSeparator}vocabulary.json');
  }

  Future<void> loadVocabulary() async {
    try {
      final file = await vocabularyFile();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      final raw = decoded is Map ? decoded['terms'] : decoded;
      if (raw is! List) return;
      final terms = raw
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList();
      if (!mounted) return;
      setState(() {
        vocabularyTerms = terms;
        vocabulary.text = terms.join(', ');
      });
    } catch (_) {
      // Keep the built-in starter terms if the local file cannot be read.
    }
  }

  Future<void> saveVocabulary(List<String> terms) async {
    final file = await vocabularyFile();
    await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert({'terms': terms}));
    if (!mounted) return;
    setState(() {
      vocabularyTerms = terms;
      vocabulary.text = terms.join(', ');
      status = 'Словарь сохранён · ${terms.length} терминов';
    });
  }

  Future<void> showVocabularyManager() async {
    final terms = await showDialog<List<String>>(
        context: context,
        barrierDismissible: false,
        builder: (_) => VocabularyManagerDialog(initialTerms: vocabularyTerms));
    if (terms != null) await saveVocabulary(terms);
  }

  Future<void> loadRecordings() async {
    try {
      final directory = await recordingsDirectory();
      final items = <RecordingEntry>[];
      await for (final entity in directory.list()) {
        if (entity is! File || !entity.path.toLowerCase().endsWith('.wav')) {
          continue;
        }
        final stat = await entity.stat();
        items.add(RecordingEntry(
            path: entity.path, modified: stat.modified, bytes: stat.size));
      }
      items.sort((a, b) => b.modified.compareTo(a.modified));
      if (mounted) setState(() => recordings = items);
    } catch (_) {
      // Leave the library empty if the application support folder is unavailable.
    }
  }

  String recordingFileName() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return 'voice-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}.wav';
  }

  Future<void> togglePlayback(String path) async {
    if (!Platform.isMacOS) {
      _error('Прослушивание записей пока доступно в macOS-версии.');
      return;
    }
    try {
      if (playingPath == path) {
        await macRecorder.invokeMethod<void>('stopPlayback');
        playbackTimer?.cancel();
        if (mounted) setState(() => playingPath = null);
        return;
      }
      await macRecorder.invokeMethod<bool>('play', {'path': path});
      playbackTimer?.cancel();
      setState(() => playingPath = path);
      playbackTimer =
          Timer.periodic(const Duration(milliseconds: 300), (_) async {
        final active =
            await macRecorder.invokeMethod<bool>('isPlaying') ?? false;
        if (!active) {
          playbackTimer?.cancel();
          if (mounted) setState(() => playingPath = null);
        }
      });
    } catch (error) {
      if (mounted) setState(() => playingPath = null);
      _error('Не удалось воспроизвести запись:\n$error');
    }
  }

  Future<void> stopPlayback() async {
    playbackTimer?.cancel();
    playbackTimer = null;
    try {
      if (Platform.isMacOS) {
        await macRecorder.invokeMethod<void>('stopPlayback');
      }
    } finally {
      if (mounted) {
        setState(() {
          playingPath = null;
          status = 'Прослушивание остановлено';
        });
      }
    }
  }

  void openRecording(RecordingEntry entry) {
    setState(() {
      mediaPath = entry.path;
      transcript = null;
      organized = null;
      page = 0;
      tab = 0;
      status = 'Запись из библиотеки готова к расшифровке';
    });
  }

  Future<void> deleteRecording(RecordingEntry entry) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            icon: Icon(Icons.delete_outline_rounded,
                color: orangeOf(dialogContext), size: 32),
            title: const Text('Удалить запись?'),
            content: Text(
                '«${entry.displayName}» будет безвозвратно удалена с этого компьютера.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Отмена')),
              FilledButton.icon(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  style: FilledButton.styleFrom(
                      backgroundColor: orangeOf(dialogContext),
                      foregroundColor: Colors.white),
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('Удалить')),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    try {
      if (playingPath == entry.path) await stopPlayback();
      final file = File(entry.path);
      if (await file.exists()) await file.delete();
      if (!mounted) return;
      setState(() {
        if (mediaPath == entry.path) {
          mediaPath = null;
          transcript = null;
          organized = null;
        }
        status = 'Запись удалена';
      });
      await loadRecordings();
    } catch (error) {
      _error('Не удалось удалить запись:\n$error');
    }
  }

  Future<void> toggleRecording() async {
    if (recording) {
      await amplitudeSubscription?.cancel();
      amplitudeSubscription = null;
      amplitudeTimer?.cancel();
      amplitudeTimer = null;
      final path = Platform.isMacOS
          ? await macRecorder.invokeMethod<String>('stop')
          : await recorder.stop();
      if (path != null) {
        final file = File(path);
        for (var attempt = 0; attempt < 20; attempt++) {
          if (await file.exists() && await file.length() >= 512) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        if (!await file.exists() || await file.length() < 512) {
          setState(() {
            recording = false;
            mediaPath = null;
            status = 'Запись не сохранилась';
          });
          _error(
              'Запись остановлена, но аудиофайл пуст. Проверьте доступ к микрофону в системных настройках.');
          return;
        }
      }
      setState(() {
        recording = false;
        mediaPath = path;
        status = path == null
            ? 'Запись не сохранена'
            : 'Запись готова · ${(File(path).lengthSync() / 1024).toStringAsFixed(0)} КБ';
      });
      await loadRecordings();
      return;
    }
    if (!await checkMicrophoneAccess(request: true, showDialogOnDenied: true)) {
      return;
    }
    if (playingPath != null && Platform.isMacOS) {
      await macRecorder.invokeMethod<void>('stopPlayback');
      playbackTimer?.cancel();
      if (mounted) setState(() => playingPath = null);
    }
    final devices = Platform.isMacOS
        ? const <InputDevice>[InputDevice(id: 'macos-native', label: 'macOS')]
        : await recorder.listInputDevices();
    if (devices.isEmpty) {
      _error(
          'Система не видит ни одного микрофона. Подключите или включите микрофон и попробуйте снова.');
      return;
    }
    final dir = await recordingsDirectory();
    final path = '${dir.path}${Platform.pathSeparator}${recordingFileName()}';
    try {
      if (Platform.isMacOS) {
        await macRecorder.invokeMethod<bool>('start', {'path': path});
        amplitudeTimer =
            Timer.periodic(const Duration(milliseconds: 150), (_) async {
          final current =
              await macRecorder.invokeMethod<double>('amplitude') ?? -160;
          if (!mounted || !recording) return;
          recordingPeakDb = math.max(recordingPeakDb, current);
          final raw = ((current + 60) / 50).clamp(.03, 1.0).toDouble();
          final normalized = math.pow(raw, .72).toDouble();
          final smoothed = amplitudeLevels.last * .35 + normalized * .65;
          setState(() {
            amplitudeLevels = [...amplitudeLevels.skip(1), smoothed];
          });
        });
      } else {
        await recorder.start(
            const RecordConfig(
                encoder: AudioEncoder.pcm16bits,
                sampleRate: 48000,
                numChannels: 1),
            path: path);
        amplitudeSubscription = recorder
            .onAmplitudeChanged(const Duration(milliseconds: 150))
            .listen((amp) {
          if (!mounted) return;
          recordingPeakDb = math.max(recordingPeakDb, amp.current);
          final raw = ((amp.current + 60) / 50).clamp(.03, 1.0).toDouble();
          final normalized = math.pow(raw, .72).toDouble();
          final smoothed = amplitudeLevels.last * .35 + normalized * .65;
          setState(() {
            amplitudeLevels = [...amplitudeLevels.skip(1), smoothed];
          });
        });
      }
      setState(() {
        recording = true;
        recordingPeakDb = -160;
        recordingStartedAt = DateTime.now();
        amplitudeLevels = List.filled(30, .08);
        status = 'Идёт запись с микрофона…';
      });
    } catch (error) {
      await amplitudeSubscription?.cancel();
      amplitudeSubscription = null;
      amplitudeTimer?.cancel();
      amplitudeTimer = null;
      _error('Не удалось начать запись:\n$error');
    }
  }

  Future<void> transcribe() async {
    if (mediaPath == null) {
      _error('Сначала выберите аудио или видео.');
      return;
    }
    setState(() {
      busy = true;
      status = 'Whisper слушает запись локально…';
    });
    try {
      final result = await worker.call({
        'action': 'transcribe',
        'path': mediaPath,
        'model': model,
        'language': language == 'auto' ? null : language,
        'vocabulary': vocabulary.text
      });
      setState(() {
        transcript = result;
        organized = null;
        busy = false;
        tab = 0;
        status =
            'Готово · ${(result['language'] ?? '').toString().toUpperCase()} · Whisper $model';
      });
    } catch (e) {
      setState(() => busy = false);
      _error(e.toString());
    }
  }

  Future<void> organize() async {
    if (transcript == null) {
      _error('Сначала расшифруйте заметку.');
      return;
    }
    setState(() {
      busy = true;
      status = 'Раскладываю заметку по полочкам…';
    });
    try {
      final result = await worker.call({
        'action': 'organize',
        'text': transcript!['text'],
        'engine': 'ollama',
        'ollama_model': organizerModel
      });
      setState(() {
        organized = result;
        organizerReady = true;
        organizerMessage = 'Модель $organizerModel готова';
        busy = false;
        tab = 1;
        status = 'Готово · ${result['engine']}';
      });
    } catch (e) {
      setState(() => busy = false);
      _error(e.toString());
    }
  }

  void _error(String message) {
    if (!mounted) return;
    setState(() => status = 'Ошибка — откройте подробности');
    showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
              icon: const Icon(Icons.error_outline, color: orange),
              title: const Text('Не удалось выполнить операцию'),
              content: SelectableText(message),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Закрыть'))
              ],
            ));
  }

  String get title {
    if (organized?['title'] != null) return organized!['title'];
    if (mediaPath == null) return 'Новая заметка';
    return mediaPath!
        .split(Platform.pathSeparator)
        .last
        .replaceFirst(RegExp(r'\.[^.]+$'), '');
  }

  String get markdown =>
      organized?['markdown'] ??
      (transcript == null ? '' : '# $title\n\n${transcript!['text']}\n');

  String get currentCopyText {
    if (tab == 0) return transcript?['text']?.toString() ?? '';
    if (tab == 1) return organized?['markdown']?.toString() ?? '';
    if (organized == null) return '';
    final tree = Map<String, dynamic>.from(organized!['diagram']);
    final lines = <String>[tree['label']?.toString() ?? 'Заметка'];
    final sections =
        (tree['children'] as List? ?? []).cast<Map<String, dynamic>>();
    for (var sectionIndex = 0; sectionIndex < sections.length; sectionIndex++) {
      final section = sections[sectionIndex];
      final lastSection = sectionIndex == sections.length - 1;
      lines.add('${lastSection ? '└' : '├'}─ ${section['label']}');
      final leaves =
          (section['children'] as List? ?? []).cast<Map<String, dynamic>>();
      for (var leafIndex = 0; leafIndex < leaves.length; leafIndex++) {
        final branch = lastSection ? '   ' : '│  ';
        lines.add(
            '$branch${leafIndex == leaves.length - 1 ? '└' : '├'}─ ${leaves[leafIndex]['label']}');
      }
    }
    return lines.join('\n');
  }

  String get currentCopyLabel => switch (tab) {
        0 => 'Копировать расшифровку',
        1 => 'Копировать структуру',
        _ => 'Копировать схему',
      };

  Future<void> copyCurrentTab() async {
    final text = currentCopyText;
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) setState(() => status = '$currentCopyLabel — готово');
  }

  Future<void> saveMarkdown() async {
    if (markdown.isEmpty) return;
    final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Сохранить заметку',
        fileName: '$title.md',
        type: FileType.custom,
        allowedExtensions: ['md']);
    if (path != null) await File(path).writeAsString(markdown);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          _header(),
          Expanded(child: page == 0 ? _workspacePage(context) : _libraryPage()),
        ]),
      ),
    );
  }

  Widget _workspacePage(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final compact = constraints.maxWidth < 860;
        final horizontalPadding = compact ? 16.0 : 42.0;
        final intro = <Widget>[
          Text('ЛОКАЛЬНО · БЕЗ API · БЕЗ ТОКЕНОВ',
              style: TextStyle(
                  color: forestOf(context),
                  fontWeight: FontWeight.w800,
                  fontSize: 10,
                  letterSpacing: 1.8)),
          const SizedBox(height: 10),
          Text('Голос превращается в ясную мысль.',
              style: TextStyle(
                  color: inkOf(context),
                  fontFamily: 'Georgia',
                  fontSize: compact ? 29 : 38,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -1.2)),
          const SizedBox(height: 8),
          Text(
              'Русская речь, английские термины, аудио и видео — всё обрабатывается на этом компьютере.',
              style: TextStyle(
                  color: mutedOf(context), fontSize: 14, height: 1.4)),
          SizedBox(height: compact ? 18 : 26),
        ];
        final workspaceDecoration = BoxDecoration(
            color: cardOf(context),
            border: Border.all(color: hairlineOf(context)),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x14000000),
                  blurRadius: 36,
                  offset: Offset(0, 16))
            ]);
        final workspace = Container(
            decoration: workspaceDecoration,
            child: compact
                ? Column(children: [
                    SizedBox(height: 720, child: _sourcePanel()),
                    const Divider(height: 1),
                    SizedBox(height: 650, child: _resultPanel()),
                  ])
                : SizedBox(
                    height:
                        math.max(540, MediaQuery.sizeOf(context).height - 240),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(width: 330, child: _sourcePanel()),
                          const VerticalDivider(width: 1),
                          Expanded(child: _resultPanel())
                        ])));
        if (compact) {
          return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                  horizontalPadding, 22, horizontalPadding, 34),
              child: Center(
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1500),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [...intro, workspace]))));
        }

        return Padding(
            padding: EdgeInsets.fromLTRB(
                horizontalPadding, 30, horizontalPadding, 34),
            child: Center(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1500),
                    child: SizedBox(
                        width: double.infinity,
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ...intro,
                              Expanded(
                                  child: Container(
                                      decoration: workspaceDecoration,
                                      child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            SizedBox(
                                                width: 330,
                                                child: _sourcePanel()),
                                            const VerticalDivider(width: 1),
                                            Expanded(child: _resultPanel())
                                          ])))
                            ])))));
      });

  Widget _header() => LayoutBuilder(builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        final medium = constraints.maxWidth < 1500;
        final brand = Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.graphic_eq_rounded, color: forestOf(context), size: 27),
          const SizedBox(width: 10),
          const Text('VoiceShelf',
              style: TextStyle(
                  fontFamily: 'Georgia',
                  fontSize: 21,
                  fontWeight: FontWeight.bold)),
        ]);
        final stop = playingPath == null
            ? const SizedBox.shrink()
            : FilledButton.icon(
                onPressed: stopPlayback,
                style: FilledButton.styleFrom(
                    backgroundColor: orangeOf(context),
                    foregroundColor: Colors.white,
                    shape: const RoundedRectangleBorder(),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10)),
                icon: const Icon(Icons.stop_rounded, size: 17),
                label: Text(compact ? 'Стоп' : 'Остановить звук'));
        if (compact) {
          return Container(
              height: 136,
              padding: const EdgeInsets.fromLTRB(14, 9, 14, 8),
              decoration: BoxDecoration(
                  border:
                      Border(bottom: BorderSide(color: hairlineOf(context)))),
              child: Column(children: [
                Row(children: [
                  brand,
                  const Spacer(),
                  stop,
                  IconButton(
                      onPressed: busy ? null : showModelManager,
                      tooltip: 'Модели и диагностика',
                      icon: const Icon(Icons.memory_rounded, size: 20)),
                ]),
                const SizedBox(height: 5),
                Row(children: [
                  Expanded(
                      child: _navigationButton(
                          'Новая заметка', Icons.edit_note_rounded, 0)),
                  const SizedBox(width: 6),
                  Expanded(
                      child: _navigationButton(
                          'Библиотека${recordings.isEmpty ? '' : ' · ${recordings.length}'}',
                          Icons.library_music_outlined,
                          1)),
                ]),
              ]));
        }
        return Container(
            height: 68,
            padding: EdgeInsets.symmetric(horizontal: medium ? 20 : 38),
            decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: hairlineOf(context)))),
            child: Row(children: [
              brand,
              SizedBox(width: medium ? 15 : 28),
              _navigationButton('Новая заметка', Icons.edit_note_rounded, 0),
              const SizedBox(width: 4),
              _navigationButton(
                  'Библиотека${recordings.isEmpty ? '' : ' · ${recordings.length}'}',
                  Icons.library_music_outlined,
                  1),
              const Spacer(),
              if (playingPath != null) ...[
                stop,
                const SizedBox(width: 10),
              ],
              if (medium)
                IconButton(
                    onPressed: busy ? null : showModelManager,
                    tooltip: 'Модели и диагностика',
                    icon: const Icon(Icons.memory_rounded, size: 19))
              else
                TextButton.icon(
                    onPressed: busy ? null : showModelManager,
                    icon: const Icon(Icons.memory_rounded, size: 17),
                    label: const Text('Модели и диагностика')),
              if (!medium) ...[
                const SizedBox(width: 18),
                Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                        color: Color(0xFF69A16C), shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Text('ВСЁ ОСТАЁТСЯ НА ЭТОМ КОМПЬЮТЕРЕ',
                    style: TextStyle(
                        color: mutedOf(context),
                        fontSize: 9,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w700)),
              ],
            ]));
      });

  Widget _navigationButton(String label, IconData icon, int index) =>
      TextButton.icon(
          onPressed: () async {
            if (index == 1) await loadRecordings();
            if (mounted) setState(() => page = index);
          },
          icon: Icon(icon, size: 17),
          label: Text(label),
          style: TextButton.styleFrom(
              foregroundColor:
                  page == index ? forestOf(context) : mutedOf(context),
              backgroundColor: page == index
                  ? (isDark(context)
                      ? const Color(0xFF26392B)
                      : const Color(0xFFE6EBDD))
                  : Colors.transparent,
              shape: const RoundedRectangleBorder(),
              padding:
                  const EdgeInsets.symmetric(horizontal: 13, vertical: 11)));

  Widget _sourcePanel() => SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _eyebrow('01 / ИСТОЧНИК'),
        const SizedBox(height: 18),
        InkWell(
            onTap: pickFile,
            child: Container(
                height: 156,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                    color: isDark(context)
                        ? const Color(0xFF171D18)
                        : const Color(0xFFF7F5EF),
                    border: Border.all(color: hairlineOf(context))),
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.upload_file_outlined,
                          color: forestOf(context), size: 30),
                      const SizedBox(height: 10),
                      Text(
                          mediaPath == null
                              ? 'Выбрать аудио или видео'
                              : mediaPath!.split(Platform.pathSeparator).last,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontFamily: 'Georgia', fontSize: 16)),
                      const SizedBox(height: 7),
                      Text('MP3 · WAV · M4A · MP4 · MOV · WEBM',
                          style: TextStyle(
                              color: mutedOf(context),
                              fontSize: 8,
                              letterSpacing: .6))
                    ]))),
        const SizedBox(height: 10),
        _outlineButton(
            recording
                ? 'Остановить запись'
                : microphoneGranted == null
                    ? 'Проверяю микрофон…'
                    : 'Записать с микрофона',
            recording ? Icons.stop_rounded : Icons.fiber_manual_record,
            microphoneGranted == null ? null : toggleRecording,
            danger: recording),
        const SizedBox(height: 8),
        _microphoneAccessCard(),
        AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: recording
                ? Padding(
                    key: const ValueKey('waveform'),
                    padding: const EdgeInsets.only(top: 10),
                    child: RecordingWaveform(levels: amplitudeLevels))
                : const SizedBox.shrink(key: ValueKey('no-waveform'))),
        if (!recording &&
            mediaPath != null &&
            mediaPath!.toLowerCase().endsWith('.wav')) ...[
          const SizedBox(height: 10),
          _outlineButton(
              playingPath == mediaPath
                  ? 'Остановить прослушивание'
                  : 'Прослушать запись',
              playingPath == mediaPath
                  ? Icons.stop_circle_outlined
                  : Icons.play_circle_outline_rounded,
              busy ? null : () => togglePlayback(mediaPath!)),
        ],
        const SizedBox(height: 22),
        _eyebrow('РАСПОЗНАВАНИЕ'),
        const SizedBox(height: 9),
        DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: language,
            decoration: const InputDecoration(labelText: 'Язык'),
            items: const [
              DropdownMenuItem(
                  value: 'auto',
                  child: Text('Авто: русский + English',
                      overflow: TextOverflow.ellipsis)),
              DropdownMenuItem(value: 'ru', child: Text('Русский')),
              DropdownMenuItem(value: 'en', child: Text('English'))
            ],
            onChanged: (x) => setState(() => language = x!)),
        const SizedBox(height: 9),
        InkWell(
            onTap: showVocabularyManager,
            child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: cardOf(context),
                    border: Border.all(color: hairlineOf(context))),
                child: Row(children: [
                  Icon(Icons.menu_book_outlined,
                      color: forestOf(context), size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        const Text('Словарь терминов',
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 3),
                        Text(
                            vocabularyTerms.isEmpty
                                ? 'Пока пуст · нажмите, чтобы добавить'
                                : '${vocabularyTerms.length} терминов · ${vocabularyTerms.take(3).join(', ')}${vocabularyTerms.length > 3 ? '…' : ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: mutedOf(context), fontSize: 10)),
                      ])),
                  const Icon(Icons.chevron_right_rounded, size: 20),
                ]))),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(10),
          color: whisperReady && organizerReady == true
              ? (isDark(context)
                  ? const Color(0xFF243A29)
                  : const Color(0xFFEAF1E6))
              : (isDark(context)
                  ? const Color(0xFF432A22)
                  : const Color(0xFFFFECE4)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(
                whisperReady && organizerReady == true
                    ? Icons.check_circle_outline
                    : Icons.warning_amber_rounded,
                size: 16,
                color: whisperReady && organizerReady == true
                    ? forestOf(context)
                    : orangeOf(context)),
            const SizedBox(width: 7),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(organizerMessage,
                      style: TextStyle(
                          fontSize: 10,
                          height: 1.35,
                          color: whisperReady && organizerReady == true
                              ? forestOf(context)
                              : orangeOf(context))),
                  const SizedBox(height: 5),
                  InkWell(
                      onTap: showModelManager,
                      child: const Text('Выбрать / установить / диагностика',
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              decoration: TextDecoration.underline))),
                ])),
          ]),
        ),
        const SizedBox(height: 20),
        FilledButton(
            onPressed: busy || recording || mediaPath == null || !whisperReady
                ? null
                : transcribe,
            style: FilledButton.styleFrom(
                backgroundColor:
                    isDark(context) ? const Color(0xFF416B4C) : ink,
                foregroundColor: Colors.white,
                shape: const RoundedRectangleBorder(),
                padding: const EdgeInsets.symmetric(vertical: 19)),
            child: const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  SizedBox(width: 8),
                  Text('Расшифровать',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  Icon(Icons.arrow_forward, size: 18)
                ])),
      ]));

  Widget _libraryPage() => LayoutBuilder(builder: (context, constraints) {
        final compact = constraints.maxWidth < 700;
        return Padding(
            padding: EdgeInsets.fromLTRB(
                compact ? 16 : 42, compact ? 22 : 30, compact ? 16 : 42, 24),
            child: Center(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1100),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Expanded(
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                      Text('БИБЛИОТЕКА',
                                          style: TextStyle(
                                              color: forestOf(context),
                                              fontWeight: FontWeight.w800,
                                              fontSize: 10,
                                              letterSpacing: 1.8)),
                                      const SizedBox(height: 9),
                                      Text('Все ваши записи',
                                          style: TextStyle(
                                              color: inkOf(context),
                                              fontFamily: 'Georgia',
                                              fontSize: compact ? 27 : 34,
                                              fontWeight: FontWeight.w500)),
                                      const SizedBox(height: 6),
                                      Text(
                                          'Записи хранятся только на этом компьютере.',
                                          style: TextStyle(
                                              color: mutedOf(context),
                                              fontSize: 13)),
                                    ])),
                                TextButton.icon(
                                    onPressed: loadRecordings,
                                    icon: const Icon(Icons.refresh_rounded,
                                        size: 17),
                                    label: const Text('Обновить')),
                              ]),
                          const SizedBox(height: 24),
                          Expanded(
                              child: recordings.isEmpty
                                  ? Container(
                                      decoration: BoxDecoration(
                                          color: cardOf(context),
                                          border: Border.all(
                                              color: hairlineOf(context))),
                                      child: Center(
                                          child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                            Icon(Icons.library_music_outlined,
                                                size: 58,
                                                color: hairlineOf(context)),
                                            const SizedBox(height: 12),
                                            const Text('Записей пока нет',
                                                style: TextStyle(
                                                    fontFamily: 'Georgia',
                                                    fontSize: 20)),
                                            const SizedBox(height: 5),
                                            Text(
                                                'Запишите первую заметку — она появится здесь автоматически.',
                                                style: TextStyle(
                                                    color: mutedOf(context),
                                                    fontSize: 11)),
                                          ])))
                                  : ListView.separated(
                                      itemCount: recordings.length,
                                      separatorBuilder: (_, __) =>
                                          const SizedBox(height: 10),
                                      itemBuilder: (_, index) =>
                                          _recordingCard(recordings[index]))),
                        ]))));
      });

  Widget _recordingCard(RecordingEntry entry) =>
      LayoutBuilder(builder: (context, constraints) {
        final compact = constraints.maxWidth < 620;
        final details = Row(children: [
          Container(
              width: 48,
              height: 48,
              color: isDark(context)
                  ? const Color(0xFF432A22)
                  : const Color(0xFFFFECE4),
              child: Icon(Icons.graphic_eq_rounded, color: orangeOf(context))),
          const SizedBox(width: 16),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(entry.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontFamily: 'Georgia',
                        fontSize: 17,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 5),
                Text(
                    '${_formatDate(entry.modified)}  ·  ${_formatBytes(entry.bytes)}',
                    style: TextStyle(color: mutedOf(context), fontSize: 11)),
              ])),
        ]);
        final listenButton = TextButton.icon(
            onPressed: recording ? null : () => togglePlayback(entry.path),
            icon: Icon(
                playingPath == entry.path
                    ? Icons.stop_circle_outlined
                    : Icons.play_circle_outline_rounded,
                size: 18),
            label: Text(playingPath == entry.path ? 'Стоп' : 'Слушать'));
        final openButton = FilledButton.icon(
            onPressed: () => openRecording(entry),
            style: FilledButton.styleFrom(
                backgroundColor:
                    isDark(context) ? const Color(0xFF416B4C) : ink,
                foregroundColor: Colors.white,
                shape: const RoundedRectangleBorder(),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
            icon: const Icon(Icons.arrow_forward_rounded, size: 17),
            label: const Text('Открыть'));
        final deleteButton = IconButton(
            onPressed: () => deleteRecording(entry),
            tooltip: 'Удалить запись',
            color: orangeOf(context),
            icon: const Icon(Icons.delete_outline_rounded));
        return Container(
            padding: EdgeInsets.symmetric(
                horizontal: compact ? 14 : 20, vertical: 16),
            decoration: BoxDecoration(
                color: cardOf(context),
                border: Border.all(color: hairlineOf(context))),
            child: compact
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                        details,
                        const SizedBox(height: 12),
                        Row(children: [
                          Expanded(child: listenButton),
                          const SizedBox(width: 8),
                          Expanded(child: openButton),
                          const SizedBox(width: 4),
                          deleteButton,
                        ])
                      ])
                : Row(children: [
                    Expanded(child: details),
                    listenButton,
                    const SizedBox(width: 8),
                    openButton,
                    const SizedBox(width: 4),
                    deleteButton,
                  ]));
      });

  String _formatDate(DateTime date) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(date.day)}.${two(date.month)}.${date.year}, ${two(date.hour)}:${two(date.minute)}';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} КБ';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }

  Widget _resultPanel() => LayoutBuilder(
      builder: (context, constraints) => Padding(
          padding: EdgeInsets.fromLTRB(constraints.maxWidth < 600 ? 16 : 30, 24,
              constraints.maxWidth < 600 ? 16 : 30, 22),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    _eyebrow('02 / РЕЗУЛЬТАТ'),
                    const SizedBox(height: 7),
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontFamily: 'Georgia', fontSize: 25))
                  ])),
              TextButton(
                  onPressed: markdown.isEmpty ? null : saveMarkdown,
                  child: const Text('Сохранить .md'))
            ]),
            const SizedBox(height: 12),
            if (busy)
              LinearProgressIndicator(
                  minHeight: 2,
                  color: forestOf(context),
                  backgroundColor: hairlineOf(context)),
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 9),
                child: Text(status,
                    style: TextStyle(
                        color: mutedOf(context),
                        fontSize: 10,
                        letterSpacing: .5))),
            Wrap(alignment: WrapAlignment.start, children: [
              _tabButton('Расшифровка', 0),
              _tabButton('По полочкам', 1),
              _tabButton('Схема', 2),
              TextButton.icon(
                  onPressed: currentCopyText.isEmpty ? null : copyCurrentTab,
                  icon: const Icon(Icons.copy_rounded, size: 15),
                  label: Text(currentCopyLabel))
            ]),
            const Divider(height: 1),
            Expanded(
                child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: _tabContent())),
            const Divider(height: 1),
            const SizedBox(height: 14),
            Wrap(spacing: 10, runSpacing: 8, children: [
              _outlineButton(
                  'Разложить по полочкам',
                  Icons.auto_awesome_outlined,
                  busy || transcript == null || organizerReady != true
                      ? null
                      : organize),
              _outlineButton('Нарисовать схему', Icons.account_tree_outlined,
                  organized == null ? null : () => setState(() => tab = 2))
            ]),
          ])));

  Widget _tabContent() {
    if (transcript == null)
      return Center(
          key: ValueKey('empty'),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.graphic_eq, color: hairlineOf(context), size: 72),
            const SizedBox(height: 12),
            const Text('Здесь появится расшифровка',
                style: TextStyle(fontFamily: 'Georgia', fontSize: 19)),
            const SizedBox(height: 4),
            Text('Выберите файл или запишите голос',
                style: TextStyle(color: mutedOf(context), fontSize: 11))
          ]));
    if (tab == 0) return _transcriptView();
    if (tab == 1)
      return organized == null
          ? Center(
              child: Text('Нажмите «Разложить по полочкам»',
                  style: TextStyle(color: mutedOf(context))))
          : _organizedView();
    return organized == null
        ? const SizedBox()
        : DiagramView(tree: Map<String, dynamic>.from(organized!['diagram']));
  }

  Widget _transcriptView() {
    final segments =
        (transcript!['segments'] as List).cast<Map<String, dynamic>>();
    return ListView.separated(
        key: const ValueKey('transcript'),
        padding: const EdgeInsets.symmetric(vertical: 20),
        itemCount: segments.length,
        separatorBuilder: (_, __) => const SizedBox(height: 14),
        itemBuilder: (_, i) {
          final s = segments[i];
          final seconds = (s['start'] as num).toInt();
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
                width: 52,
                child: Text(
                    '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}',
                    style: TextStyle(
                        color: orangeOf(context),
                        fontFamily: 'monospace',
                        fontSize: 10))),
            Expanded(
                child: SelectableText(s['text'],
                    style: const TextStyle(
                        fontFamily: 'Georgia', fontSize: 16, height: 1.55)))
          ]);
        });
  }

  Widget _organizedView() => ListView(
          key: const ValueKey('organized'),
          padding: const EdgeInsets.symmetric(vertical: 18),
          children: [
            if (organized!['warning'] != null)
              Container(
                  color: paperOf(context),
                  padding: const EdgeInsets.all(12),
                  child: Text(organized!['warning'],
                      style: TextStyle(color: mutedOf(context), fontSize: 11))),
            _section('Коротко', [organized!['summary']]),
            _section('Задачи', organized!['tasks']),
            _section('Решения', organized!['decisions']),
            _section('Открытые вопросы', organized!['questions']),
            _section('Тезисы', organized!['notes'])
          ]);
  Widget _section(String title, dynamic raw) {
    final items = (raw is List ? raw : [raw])
        .where((x) => x != null && x.toString().trim().isNotEmpty)
        .toList();
    if (items.isEmpty) return const SizedBox();
    return Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: const TextStyle(
                  fontFamily: 'Georgia',
                  fontSize: 18,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 7),
          ...items.map((x) => Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text(title == 'Коротко' ? x.toString() : '•  $x',
                  style: const TextStyle(fontSize: 13, height: 1.5))))
        ]));
  }

  Widget _eyebrow(String text) => Text(text,
      style: TextStyle(
          color: forestOf(context),
          fontWeight: FontWeight.w800,
          fontSize: 9,
          letterSpacing: 1.3));
  Widget _microphoneAccessCard() {
    final checking = microphoneGranted == null;
    final granted = microphoneGranted == true;
    final color = checking
        ? mutedOf(context)
        : (granted ? forestOf(context) : orangeOf(context));
    return InkWell(
      onTap: microphoneGranted == false ? showMicrophoneAccessDialog : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        color: granted
            ? (isDark(context)
                ? const Color(0xFF243A29)
                : const Color(0xFFEAF1E6))
            : checking
                ? (isDark(context)
                    ? const Color(0xFF292F2A)
                    : const Color(0xFFECEBE6))
                : (isDark(context)
                    ? const Color(0xFF432A22)
                    : const Color(0xFFFFECE4)),
        child: Row(children: [
          Icon(
              checking
                  ? Icons.hourglass_top_rounded
                  : granted
                      ? Icons.mic_rounded
                      : Icons.mic_off_rounded,
              size: 15,
              color: color),
          const SizedBox(width: 7),
          Expanded(
              child: Text(
                  checking
                      ? 'Проверяю доступ к микрофону'
                      : granted
                          ? 'Микрофон доступен'
                          : 'Нет доступа · открыть настройки',
                  style: TextStyle(
                      color: color,
                      fontSize: 10,
                      fontWeight: FontWeight.w700))),
        ]),
      ),
    );
  }

  Widget _tabButton(String text, int index) => TextButton(
      onPressed: () => setState(() => tab = index),
      style: TextButton.styleFrom(
          foregroundColor: tab == index ? inkOf(context) : mutedOf(context),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          shape: const RoundedRectangleBorder(),
          side: BorderSide(
              color: tab == index ? orangeOf(context) : Colors.transparent,
              width: 0,
              strokeAlign: BorderSide.strokeAlignOutside)),
      child: Text(text));
  Widget _outlineButton(String text, IconData icon, VoidCallback? onPressed,
          {bool danger = false}) =>
      OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 17, color: danger ? orangeOf(context) : null),
          label: Text(text),
          style: OutlinedButton.styleFrom(
              foregroundColor: danger ? orangeOf(context) : inkOf(context),
              side: BorderSide(
                  color: danger ? orangeOf(context) : inkOf(context)),
              shape: const RoundedRectangleBorder(),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 15)));
}

class VocabularyManagerDialog extends StatefulWidget {
  final List<String> initialTerms;

  const VocabularyManagerDialog({super.key, required this.initialTerms});

  @override
  State<VocabularyManagerDialog> createState() =>
      _VocabularyManagerDialogState();
}

class _VocabularyManagerDialogState extends State<VocabularyManagerDialog> {
  final pasteController = TextEditingController();
  final termController = TextEditingController();
  final searchController = TextEditingController();
  late List<String> terms;
  String search = '';

  @override
  void initState() {
    super.initState();
    terms = [...widget.initialTerms];
  }

  @override
  void dispose() {
    pasteController.dispose();
    termController.dispose();
    searchController.dispose();
    super.dispose();
  }

  List<String> parseTerms(String text) => text
      .split(RegExp(r'[\s,;|]+'))
      .map((item) => item.trim().replaceAll(
          RegExp(r'^[^\w\u0400-\u04FF+#.-]+|[^\w\u0400-\u04FF+#.-]+$'), ''))
      .where((item) => item.isNotEmpty)
      .toList();

  void addTerms(Iterable<String> additions) {
    final known = terms.map((item) => item.toLowerCase()).toSet();
    final next = <String>[];
    for (final item in additions) {
      final clean = item.trim();
      if (clean.isEmpty || !known.add(clean.toLowerCase())) continue;
      next.add(clean);
    }
    if (next.isEmpty) return;
    setState(() {
      terms.addAll(next);
      terms.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    });
  }

  void addPastedText() {
    addTerms(parseTerms(pasteController.text));
    pasteController.clear();
  }

  void addSingleTerm() {
    addTerms(parseTerms(termController.text));
    termController.clear();
  }

  Future<void> editTerm(String term) async {
    final controller = TextEditingController(text: term);
    final edited = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              title: const Text('Изменить термин'),
              content: TextField(
                  controller: controller,
                  autofocus: true,
                  onSubmitted: (value) =>
                      Navigator.pop(dialogContext, value.trim())),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Отмена')),
                FilledButton(
                    onPressed: () =>
                        Navigator.pop(dialogContext, controller.text.trim()),
                    child: const Text('Готово')),
              ],
            ));
    controller.dispose();
    if (edited == null || edited.isEmpty || !mounted) return;
    final duplicate = terms.any(
        (item) => item != term && item.toLowerCase() == edited.toLowerCase());
    setState(() {
      terms.remove(term);
      if (!duplicate) terms.add(edited);
      terms.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    });
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final compact = viewport.width < 700;
    final visible = terms
        .where((item) => item.toLowerCase().contains(search.toLowerCase()))
        .toList();
    return AlertDialog(
      backgroundColor: paperOf(context),
      title: Row(children: [
        Icon(Icons.menu_book_outlined, color: forestOf(context)),
        const SizedBox(width: 10),
        const Expanded(child: Text('Словарь терминов')),
        IconButton(
            onPressed: () => Navigator.pop(context),
            tooltip: 'Закрыть без сохранения',
            icon: const Icon(Icons.close_rounded)),
      ]),
      content: SizedBox(
          width: math.max(270, math.min(760, viewport.width - 56)),
          height: math.max(360, math.min(650, viewport.height - 180)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
                'Вставьте список или обычный текст. Слова разделятся автоматически по пробелам, запятым и строкам; повторы удалятся.',
                style: TextStyle(
                    color: mutedOf(context), fontSize: 12, height: 1.4)),
            const SizedBox(height: 12),
            TextField(
                controller: pasteController,
                minLines: compact ? 2 : 3,
                maxLines: compact ? 3 : 5,
                decoration: const InputDecoration(
                    labelText: 'Вставить текст или список',
                    hintText: 'Notion Figma Kubernetes Иван Петров…')),
            const SizedBox(height: 8),
            FilledButton.icon(
                onPressed: addPastedText,
                icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
                label: const Text('Распознать и добавить слова')),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: termController,
                      onSubmitted: (_) => addSingleTerm(),
                      decoration: const InputDecoration(
                          labelText: 'Добавить один термин'))),
              const SizedBox(width: 8),
              IconButton.filled(
                  onPressed: addSingleTerm,
                  tooltip: 'Добавить',
                  icon: const Icon(Icons.add_rounded)),
            ]),
            const SizedBox(height: 12),
            TextField(
                controller: searchController,
                onChanged: (value) => setState(() => search = value),
                decoration: InputDecoration(
                    labelText: 'Поиск по базе · ${terms.length} терминов',
                    prefixIcon: const Icon(Icons.search_rounded, size: 19))),
            const SizedBox(height: 10),
            Expanded(
                child: visible.isEmpty
                    ? Center(
                        child: Text(
                            terms.isEmpty
                                ? 'Словарь пока пуст'
                                : 'Ничего не найдено',
                            style: TextStyle(color: mutedOf(context))))
                    : SingleChildScrollView(
                        child: Wrap(
                            spacing: 7,
                            runSpacing: 7,
                            children: visible
                                .map((term) => InputChip(
                                    label: Text(term),
                                    tooltip: 'Нажмите, чтобы изменить',
                                    onPressed: () => editTerm(term),
                                    onDeleted: () =>
                                        setState(() => terms.remove(term)),
                                    deleteIcon: const Icon(Icons.close_rounded,
                                        size: 16)))
                                .toList()))),
          ])),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена')),
        FilledButton.icon(
            onPressed: () => Navigator.pop(context, terms),
            icon: const Icon(Icons.save_outlined, size: 18),
            label: Text('Сохранить · ${terms.length}')),
      ],
    );
  }
}

class ModelManagerDialog extends StatefulWidget {
  final LocalWorker worker;
  final String whisperModel;
  final String ollamaModel;
  const ModelManagerDialog(
      {super.key,
      required this.worker,
      required this.whisperModel,
      required this.ollamaModel});

  @override
  State<ModelManagerDialog> createState() => _ModelManagerDialogState();
}

class _ModelManagerDialogState extends State<ModelManagerDialog> {
  static const whisperModels = ['tiny', 'base', 'small', 'medium', 'large-v3'];
  static const ollamaModels = ['qwen2.5:3b', 'qwen2.5:7b', 'qwen2.5:14b'];
  late String whisperModel;
  late String ollamaModel;
  Map<String, dynamic> diagnostics = {};
  bool loading = true;
  String? installing;
  String? error;

  @override
  void initState() {
    super.initState();
    whisperModel = widget.whisperModel;
    ollamaModel = widget.ollamaModel;
    load();
  }

  Future<void> load() async {
    if (mounted)
      setState(() {
        loading = true;
        error = null;
      });
    try {
      final result = await widget.worker.call({
        'action': 'models_status',
        'ollama_model': ollamaModel,
        'autostart': true
      });
      if (mounted)
        setState(() {
          diagnostics = result;
          loading = false;
        });
    } catch (e) {
      if (mounted)
        setState(() {
          error = e.toString();
          loading = false;
        });
    }
  }

  bool get whisperInstalled {
    final models = (diagnostics['whisper'] as List? ?? []);
    return models.any((item) =>
        item is Map &&
        item['model'] == whisperModel &&
        item['installed'] == true);
  }

  bool get ollamaInstalled {
    final data = diagnostics['ollama'];
    if (data is! Map || data['available'] != true) return false;
    final names =
        (data['installed_models'] as List? ?? []).map((x) => x.toString());
    return names.contains(ollamaModel);
  }

  Future<void> installWhisper() async {
    setState(() {
      installing = 'whisper';
      error = null;
    });
    try {
      await widget.worker
          .call({'action': 'install_whisper', 'model': whisperModel});
      await load();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => installing = null);
    }
  }

  Future<void> installOllama() async {
    setState(() {
      installing = 'ollama';
      error = null;
    });
    try {
      await widget.worker
          .call({'action': 'install_ollama', 'model': ollamaModel});
      await load();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => installing = null);
    }
  }

  void closeDialog() {
    if (installing != null) widget.worker.cancelCurrentOperation();
    Navigator.pop(context);
  }

  Widget stateBadge(bool installed) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        color: installed
            ? (isDark(context)
                ? const Color(0xFF243A29)
                : const Color(0xFFEAF1E6))
            : (isDark(context)
                ? const Color(0xFF432A22)
                : const Color(0xFFFFECE4)),
        child: Text(installed ? 'УСТАНОВЛЕНА' : 'НЕ УСТАНОВЛЕНА',
            style: TextStyle(
                color: installed ? forestOf(context) : orangeOf(context),
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: .6)),
      );

  Widget modelBlock(
          {required String title,
          required String description,
          required String value,
          required List<String> items,
          required bool installed,
          required ValueChanged<String?> onChanged,
          required VoidCallback onInstall,
          required bool isInstalling}) =>
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
            color: cardOf(context),
            border: Border.all(color: hairlineOf(context))),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontFamily: 'Georgia',
                        fontSize: 19,
                        fontWeight: FontWeight.w600))),
            stateBadge(installed)
          ]),
          const SizedBox(height: 5),
          Text(description,
              style: TextStyle(
                  color: mutedOf(context), fontSize: 11, height: 1.4)),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: value,
              decoration: const InputDecoration(labelText: 'Выбранная модель'),
              items: items
                  .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                  .toList(),
              onChanged: installing == null ? onChanged : null),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: installed || installing != null ? null : onInstall,
            style: FilledButton.styleFrom(
                shape: const RoundedRectangleBorder(),
                padding: const EdgeInsets.symmetric(vertical: 14)),
            icon: isInstalling
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(installed ? Icons.check : Icons.download_rounded,
                    size: 18),
            label: Text(installed
                ? 'Модель готова'
                : isInstalling
                    ? 'Устанавливаю…'
                    : 'Установить модель'),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final pretty = diagnostics.isEmpty
        ? 'Диагностика пока не получена'
        : const JsonEncoder.withIndent('  ').convert(diagnostics);
    final viewport = MediaQuery.sizeOf(context);
    return AlertDialog(
      backgroundColor: paperOf(context),
      title: Row(children: [
        Icon(Icons.memory_rounded, color: forestOf(context)),
        const SizedBox(width: 10),
        const Expanded(child: Text('Модели и диагностика')),
        IconButton(
            onPressed: closeDialog,
            tooltip:
                installing == null ? 'Закрыть' : 'Отменить установку и закрыть',
            icon: const Icon(Icons.close_rounded))
      ]),
      content: SizedBox(
          width: math.max(260, math.min(690, viewport.width - 56)),
          height: math.max(320, math.min(610, viewport.height - 180)),
          child: loading && diagnostics.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                      Text(
                          'Обе модели работают локально. Кнопки обработки активируются только после установки выбранной модели.',
                          style: TextStyle(
                              color: mutedOf(context),
                              fontSize: 12,
                              height: 1.45)),
                      const SizedBox(height: 16),
                      modelBlock(
                          title: 'Whisper · расшифровка',
                          description:
                              'small — хороший баланс для русского и English. Большие модели точнее, но медленнее и тяжелее.',
                          value: whisperModel,
                          items: whisperModels,
                          installed: whisperInstalled,
                          isInstalling: installing == 'whisper',
                          onChanged: (x) {
                            if (x != null) setState(() => whisperModel = x);
                          },
                          onInstall: installWhisper),
                      const SizedBox(height: 12),
                      modelBlock(
                          title: 'Qwen · «по полочкам» и схема',
                          description:
                              '7b — рекомендуемый баланс. 3b быстрее, 14b обычно качественнее, но требует больше памяти.',
                          value: ollamaModel,
                          items: ollamaModels,
                          installed: ollamaInstalled,
                          isInstalling: installing == 'ollama',
                          onChanged: (x) {
                            if (x != null) setState(() => ollamaModel = x);
                            load();
                          },
                          onInstall: installOllama),
                      if (error != null) ...[
                        const SizedBox(height: 12),
                        Container(
                            color: isDark(context)
                                ? const Color(0xFF432A22)
                                : const Color(0xFFFFE4DA),
                            padding: const EdgeInsets.all(12),
                            child: SelectableText(error!,
                                style: TextStyle(
                                    color: orangeOf(context), fontSize: 11)))
                      ],
                      const SizedBox(height: 14),
                      ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: const Text('Отладочная информация',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text(
                              'Python: ${diagnostics['python'] ?? '—'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 10)),
                          children: [
                            Container(
                                width: double.infinity,
                                color: isDark(context)
                                    ? const Color(0xFF0C100D)
                                    : ink,
                                padding: const EdgeInsets.all(14),
                                child: SelectableText(pretty,
                                    style: const TextStyle(
                                        color: Color(0xFFD8E4D4),
                                        fontFamily: 'monospace',
                                        fontSize: 10,
                                        height: 1.45)))
                          ]),
                    ]))),
      actions: [
        TextButton.icon(
            onPressed: installing == null ? load : null,
            icon: const Icon(Icons.refresh, size: 17),
            label: const Text('Проверить снова')),
        TextButton(
            onPressed: closeDialog,
            child: Text(installing == null ? 'Закрыть' : 'Отменить установку')),
        FilledButton(
            onPressed: installing == null
                ? () => Navigator.pop(
                    context, {'whisper': whisperModel, 'ollama': ollamaModel})
                : null,
            child: const Text('Использовать выбранные')),
      ],
    );
  }
}

class RecordingEntry {
  final String path;
  final DateTime modified;
  final int bytes;

  const RecordingEntry(
      {required this.path, required this.modified, required this.bytes});

  String get displayName {
    final fileName = path.split(Platform.pathSeparator).last;
    return fileName.replaceFirst(RegExp(r'\.wav$', caseSensitive: false), '');
  }
}

class RecordingWaveform extends StatelessWidget {
  final List<double> levels;
  const RecordingWaveform({super.key, required this.levels});

  @override
  Widget build(BuildContext context) => Container(
        height: 94,
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
        decoration: BoxDecoration(
            color: isDark(context)
                ? const Color(0xFF35231D)
                : const Color(0xFFFFF4ED),
            border: Border.all(color: orangeOf(context), width: 1.4)),
        child: Column(children: [
          Row(children: [
            Icon(Icons.fiber_manual_record, color: orangeOf(context), size: 11),
            const SizedBox(width: 6),
            Text('ИДЁТ ЗАПИСЬ',
                style: TextStyle(
                    color: orangeOf(context),
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.1)),
            const Spacer(),
            const Text('ГОВОРИТЕ — УРОВЕНЬ МЕНЯЕТСЯ',
                style: TextStyle(
                    color: Color(0xFF9C6A55),
                    fontSize: 7,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .5)),
          ]),
          const SizedBox(height: 6),
          Expanded(
              child: SizedBox.expand(
                  child: CustomPaint(
                      painter:
                          WaveformPainter(levels, dark: isDark(context))))),
        ]),
      );
}

class WaveformPainter extends CustomPainter {
  final List<double> levels;
  final bool dark;
  WaveformPainter(this.levels, {required this.dark});
  @override
  void paint(Canvas canvas, Size size) {
    final count = levels.length;
    final centerY = size.height / 2;
    canvas.drawLine(
        Offset(0, centerY),
        Offset(size.width, centerY),
        Paint()
          ..color = dark ? const Color(0x77F08A5E) : const Color(0x55D66A3D)
          ..strokeWidth = 1);
    final gap = 4.0;
    final width = (size.width - gap * (count + 1)) / count;
    final paint = Paint();
    for (var i = 0; i < count; i++) {
      final progress = i / math.max(1, count - 1);
      paint.color = dark
          ? Color.lerp(
              const Color(0xFFAF6D52), const Color(0xFFFF9A6D), progress)!
          : Color.lerp(
              const Color(0xFFDFA58C), const Color(0xFFB94D26), progress)!;
      final h = math.max(4.0, levels[i] * (size.height - 4));
      final x = gap + i * (width + gap);
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(x, (size.height - h) / 2, width, h),
              const Radius.circular(3)),
          paint);
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter old) => true;
}

class DiagramView extends StatelessWidget {
  final Map<String, dynamic> tree;
  const DiagramView({super.key, required this.tree});

  double get diagramHeight {
    var height = 45.0;
    for (final section in (tree['children'] as List? ?? [])) {
      final leaves = ((section as Map)['children'] as List? ?? []);
      if (leaves.isEmpty) {
        height += 64;
      } else {
        for (final leaf in leaves) {
          height +=
              diagramNodeHeight((leaf as Map)['label']?.toString() ?? '', 430) +
                  18;
        }
      }
      height += 18;
    }
    return math.max(430, height + 30).toDouble();
  }

  @override
  Widget build(BuildContext context) => InteractiveViewer(
      minScale: .5,
      maxScale: 2.5,
      boundaryMargin: const EdgeInsets.all(80),
      constrained: false,
      child: CustomPaint(
          size: Size(1110, diagramHeight),
          painter: DiagramPainter(tree, dark: isDark(context))));
}

double diagramNodeHeight(String text, double width,
    {double minimum = 42, bool bold = false}) {
  final painter = TextPainter(
      text: TextSpan(
          text: text,
          style: TextStyle(
              fontSize: 11,
              height: 1.35,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
      textDirection: TextDirection.ltr)
    ..layout(maxWidth: width - 24);
  return math.max(minimum, painter.height + 20).toDouble();
}

class DiagramPainter extends CustomPainter {
  final Map<String, dynamic> tree;
  final bool dark;
  DiagramPainter(this.tree, {required this.dark});
  @override
  void paint(Canvas c, Size size) {
    final sections =
        (tree['children'] as List? ?? []).cast<Map<String, dynamic>>();
    double cursor = 45;
    final layout = <({
      Map<String, dynamic> s,
      double y,
      double height,
      List<({Map<String, dynamic> l, double y, double height})> leaves
    })>[];
    for (final s in sections) {
      final leaves =
          (s['children'] as List? ?? []).cast<Map<String, dynamic>>();
      final rows = <({Map<String, dynamic> l, double y, double height})>[];
      for (final l in leaves) {
        final height = diagramNodeHeight(l['label']?.toString() ?? '', 430);
        rows.add((l: l, y: cursor + height / 2, height: height));
        cursor += height + 18;
      }
      final sectionY =
          rows.isEmpty ? cursor + 23 : (rows.first.y + rows.last.y) / 2;
      final sectionHeight = diagramNodeHeight(s['label']?.toString() ?? '', 180,
          minimum: 46, bold: true);
      layout.add((s: s, y: sectionY, height: sectionHeight, leaves: rows));
      if (rows.isEmpty) cursor += sectionHeight + 18;
      cursor += 18;
    }
    final rootY = layout.isEmpty
        ? size.height / 2
        : layout.map((x) => x.y).reduce((a, b) => a + b) / layout.length;
    for (final x in layout) {
      _line(c, const Offset(260, 0) + Offset(0, rootY), Offset(390, x.y));
      for (final leaf in x.leaves) {
        _line(c, Offset(570, x.y), Offset(650, leaf.y));
      }
    }
    final diagramInk = dark ? const Color(0xFF385342) : ink;
    final diagramText = dark ? const Color(0xFFE8EDE8) : ink;
    final diagramCard = dark ? const Color(0xFF222A24) : Colors.white;
    final diagramBorder = dark ? const Color(0xFF465148) : hairline;
    const rootWidth = 230.0;
    final rootHeight = diagramNodeHeight(
        tree['label']?.toString() ?? 'Заметка', rootWidth,
        minimum: 56, bold: true);
    _node(c, Rect.fromLTWH(30, rootY - rootHeight / 2, rootWidth, rootHeight),
        tree['label'] ?? 'Заметка', diagramInk, Colors.white,
        bold: true);
    for (final x in layout) {
      _node(c, Rect.fromLTWH(390, x.y - x.height / 2, 180, x.height),
          x.s['label'], dark ? const Color(0xFF789348) : lime, diagramText,
          bold: true);
      for (final leaf in x.leaves) {
        _node(c, Rect.fromLTWH(650, leaf.y - leaf.height / 2, 430, leaf.height),
            leaf.l['label'], diagramCard, diagramText,
            border: diagramBorder);
      }
    }
  }

  void _line(Canvas c, Offset a, Offset b) {
    final p = Path()
      ..moveTo(a.dx, a.dy)
      ..cubicTo((a.dx + b.dx) / 2, a.dy, (a.dx + b.dx) / 2, b.dy, b.dx, b.dy);
    c.drawPath(
        p,
        Paint()
          ..color = const Color(0xFFA8AEA2)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4);
  }

  void _node(Canvas c, Rect r, dynamic label, Color fill, Color color,
      {Color? border, bool bold = false}) {
    c.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(3)),
        Paint()..color = fill);
    if (border != null)
      c.drawRRect(
          RRect.fromRectAndRadius(r, const Radius.circular(3)),
          Paint()
            ..color = border
            ..style = PaintingStyle.stroke);
    final tp = TextPainter(
        text: TextSpan(
            text: label.toString(),
            style: TextStyle(
                color: color,
                fontSize: 11,
                height: 1.35,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
        textDirection: TextDirection.ltr)
      ..layout(maxWidth: r.width - 24);
    tp.paint(c, Offset(r.left + 12, r.top + (r.height - tp.height) / 2));
  }

  @override
  bool shouldRepaint(covariant DiagramPainter old) =>
      old.tree != tree || old.dark != dark;
}
