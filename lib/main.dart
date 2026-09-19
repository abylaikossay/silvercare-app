// SilverCare: Контроль лекарств — демо для пожилых людей (один экран).
//
// Запуск с другим адресом бэкенда:
//   flutter run --dart-define=API_URL=https://your-backend.up.railway.app

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

const String kApiUrl = String.fromEnvironment(
  'API_URL',
  defaultValue: 'http://10.0.2.2:8000',
);
// int.fromEnvironment сам возвращает defaultValue, если PATIENT_ID не задан
// или не парсится в int.
const int kPatientId = int.fromEnvironment('PATIENT_ID', defaultValue: 1);
const String kPrefPatientId = 'patient_id';
const Duration kSecretHold = Duration(seconds: 3);
const Duration kRefreshInterval = Duration(seconds: 60);
const Duration kHttpTimeout = Duration(seconds: 8);
const Duration kVoiceRepeatInterval = Duration(minutes: 10);
const Duration kNotifyRepeatStep = Duration(minutes: 10);
const int kNotifyRepeatCount = 6; // t, t+10 … t+50
const Duration kNotifyLookback = Duration(minutes: 60);

/// Единственный часовой пояс приложения. Часы устройства не используются.
late final tz.Location almaty;
tz.TZDateTime nowAlmaty() => tz.TZDateTime.now(almaty);

// ---------------------------------------------------------------------------
// Цвета и размеры
// ---------------------------------------------------------------------------
const Color kBg = Colors.black;
const Color kText = Colors.white;
const Color kGreen = Color(0xFF2ECC40);
const Color kYellow = Color(0xFFFFDC00);
const Color kBlue = Color(0xFF0074D9);
const Color kRed = Color(0xFFE53935);

const double kTitleSize = 46;
const double kSubSize = 34;
const double kButtonSize = 38;
const double kButtonMinHeight = 200;
const double kPad = 16;

final FlutterLocalNotificationsPlugin notifications =
    FlutterLocalNotificationsPlugin();

/// Один экземпляр TTS на всё приложение.
final FlutterTts tts = FlutterTts();

/// Инициализация TTS. Любой speak() сначала ждёт этот Future, иначе на Android
/// озвучка уходит раньше, чем движок подключился и применил язык.
final Future<void> _ttsReady = _initTts();

Future<void> _initTts() async {
  try {
    final available = await tts.isLanguageAvailable('ru-RU');
    if (available == false) {
      debugPrint('SilverCare: TTS language ru-RU is NOT available');
    }
    await tts.setLanguage('ru-RU');
    await tts.setSpeechRate(0.45);
    await tts.setVolume(1.0);
    await tts.setPitch(1.0);
    await tts.awaitSpeakCompletion(true);
    debugPrint('SilverCare: TTS ready (ru-RU available: $available)');
  } catch (e) {
    debugPrint('SilverCare: TTS init failed: $e');
  }
}

/// Озвучить текст. Повторный setLanguage перед speak дёшев и гарантирует
/// русский язык даже если движок переподключился.
Future<void> speakRu(String text) async {
  try {
    await _ttsReady;
    await tts.stop();
    await tts.setLanguage('ru-RU');
    await tts.speak(text);
  } catch (e) {
    // Нет TTS-движка (например, на эмуляторе) — молча игнорируем.
    debugPrint('SilverCare: TTS speak failed: $e');
  }
}

/// Режим планирования Android-уведомлений: точный, если система разрешила,
/// иначе fallback на inexact. Выбирается один раз при старте.
AndroidScheduleMode scheduleMode = AndroidScheduleMode.inexactAllowWhileIdle;

Future<void> pickAndroidScheduleMode() async {
  final android = notifications
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  if (android == null) return;
  try {
    bool can = await android.canScheduleExactNotifications() ?? false;
    if (!can) {
      await android.requestExactAlarmsPermission();
      can = await android.canScheduleExactNotifications() ?? false;
    }
    scheduleMode = can
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;
  } catch (e) {
    scheduleMode = AndroidScheduleMode.inexactAllowWhileIdle;
    debugPrint('SilverCare: exact alarm check failed: $e');
  }
  debugPrint('SilverCare: android schedule mode = $scheduleMode');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  tzdata.initializeTimeZones();
  almaty = tz.getLocation('Asia/Almaty');
  tz.setLocalLocation(almaty);

  await notifications.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: false,
        requestSoundPermission: true,
      ),
    ),
  );
  if (defaultTargetPlatform == TargetPlatform.android) {
    await notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    await pickAndroidScheduleMode();
  } else if (defaultTargetPlatform == TargetPlatform.iOS) {
    await notifications
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, sound: true);
  }

  // Запускаем инициализацию TTS, но не блокируем старт UI.
  unawaited(_ttsReady);

  runApp(const SilverCareApp());
}

class SilverCareApp extends StatelessWidget {
  const SilverCareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SilverCare',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const HomeScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// Модель
// ---------------------------------------------------------------------------
class Intake {
  Intake({
    required this.id,
    required this.name,
    required this.dose,
    required this.scheduledAt,
    required this.status,
  });

  final int id;
  final String name;
  final String dose;
  final tz.TZDateTime? scheduledAt; // всегда в Asia/Almaty
  final String status; // pending | taken | missed

  static Intake? fromJson(dynamic j) {
    if (j is! Map) return null;
    final rawId = j['intake_id'] ?? j['id'];
    final id = rawId is int ? rawId : int.tryParse('${rawId ?? ''}');
    if (id == null) return null;
    return Intake(
      id: id,
      name: '${j['medication_name'] ?? j['name'] ?? 'Лекарство'}',
      dose: '${j['dose'] ?? ''}',
      scheduledAt: parseAlmaty('${j['scheduled_at'] ?? ''}'),
      status: '${j['status'] ?? 'pending'}',
    );
  }

  /// ISO-строка без tz ("2026-09-19T14:30:00") → компоненты → Asia/Almaty.
  /// DateTime.tryParse нужен только чтобы разобрать компоненты; пояс
  /// устройства при этом не влияет на y/m/d/h/min.
  static tz.TZDateTime? parseAlmaty(String raw) {
    final d = DateTime.tryParse(raw);
    if (d == null) return null;
    return tz.TZDateTime(almaty, d.year, d.month, d.day, d.hour, d.minute);
  }

  String get timeText {
    final t = scheduledAt;
    if (t == null) return '';
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
  }

  String get reminderText => 'Пора принять $name, $dose';
  String get repeatText => 'Напоминаю: пора принять $name, $dose';
}

// ---------------------------------------------------------------------------
// Главный экран
// ---------------------------------------------------------------------------
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Intake> items = [];
  Intake? next;
  bool loading = true;
  bool error = false;
  bool sending = false;
  bool exerciseOpen = false;
  bool pickerOpen = false;

  /// Текущий пациент: из shared_preferences, иначе из --dart-define.
  int patientId = kPatientId;
  String patientName = '';

  Timer? refreshTimer;
  Timer? secretHoldTimer;

  /// Время последней озвучки по intake_id — повтор не чаще раза в 10 минут.
  final Map<int, tz.TZDateTime> lastSpokenAt = {};

  @override
  void initState() {
    super.initState();
    _start();
    refreshTimer = Timer.periodic(kRefreshInterval, (_) => loadToday());
  }

  Future<void> _start() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getInt(kPrefPatientId);
      if (saved != null) patientId = saved;
    } catch (e) {
      debugPrint('SilverCare: prefs read failed: $e');
    }
    debugPrint('SilverCare: patientId = $patientId');
    await loadToday();
  }

  Future<void> selectPatient(int id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(kPrefPatientId, id);
    } catch (e) {
      debugPrint('SilverCare: prefs write failed: $e');
    }
    if (!mounted) return;
    setState(() {
      patientId = id;
      pickerOpen = false;
      loading = true;
      error = false;
      lastSpokenAt.clear();
    });
    await loadToday(); // внутри cancelAll + новое расписание
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    secretHoldTimer?.cancel();
    super.dispose();
  }

  // ---------------- Сеть ----------------

  Future<void> loadToday() async {
    try {
      final res = await http
          .get(Uri.parse('$kApiUrl/patients/$patientId/today'))
          .timeout(kHttpTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('HTTP ${res.statusCode}');
      }
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      final rawItems = data is Map ? data['items'] : null;
      final parsed = <Intake>[];
      if (rawItems is List) {
        for (final e in rawItems) {
          final it = Intake.fromJson(e);
          if (it != null) parsed.add(it);
        }
      }
      Intake? parsedNext = data is Map ? Intake.fromJson(data['next']) : null;
      // Если бэк не дал next — берём первый pending по времени.
      if (parsedNext == null) {
        final far = tz.TZDateTime(almaty, 2100);
        final pending = parsed.where((i) => i.status == 'pending').toList()
          ..sort(
            (a, b) => (a.scheduledAt ?? far).compareTo(b.scheduledAt ?? far),
          );
        if (pending.isNotEmpty) parsedNext = pending.first;
      }

      if (!mounted) return;
      setState(() {
        items = parsed;
        next = parsedNext;
        patientName = data is Map
            ? '${data['patient_name'] ?? data['patient']?['name'] ?? ''}'
            : '';
        loading = false;
        error = false;
      });

      await scheduleNotifications(parsed);
      maybeSpeakDueReminder();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = true;
      });
    }
  }

  Future<void> takeNext() async {
    final current = next;
    if (current == null || sending) return;
    setState(() => sending = true);
    try {
      final res = await http
          .post(Uri.parse('$kApiUrl/intakes/${current.id}/take'))
          .timeout(kHttpTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('HTTP ${res.statusCode}');
      }
      await speak('Отлично, принято');
      await loadToday();
    } catch (_) {
      if (!mounted) return;
      setState(() => error = true);
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  // ---------------- Звук ----------------

  Future<void> speak(String text) => speakRu(text);

  void maybeSpeakDueReminder() {
    final n = next;
    if (n == null || n.scheduledAt == null) return;
    if (n.status != 'pending') return;
    final now = nowAlmaty();
    if (n.scheduledAt!.isAfter(now)) return;
    final last = lastSpokenAt[n.id];
    if (last != null && now.difference(last) < kVoiceRepeatInterval) return;
    lastSpokenAt[n.id] = now;
    speak(last == null ? n.reminderText : n.repeatText);
  }

  // ---------------- Уведомления ----------------

  Future<void> scheduleNotifications(List<Intake> list) async {
    try {
      await notifications.cancelAll();
      final now = nowAlmaty();
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'silvercare_reminders',
          'Напоминания о лекарствах',
          channelDescription: 'Напоминания о приёме лекарств',
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
        ),
        iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
      );
      var scheduled = 0;
      for (final it in list) {
        final start = it.scheduledAt;
        if (it.status != 'pending' || start == null) continue;
        // Слоты старше часа не трогаем — их подберёт missed на бэке.
        if (start.isBefore(now.subtract(kNotifyLookback))) continue;
        for (var i = 0; i < kNotifyRepeatCount; i++) {
          final when = start.add(kNotifyRepeatStep * i);
          if (!when.isAfter(now)) continue;
          await notifications.zonedSchedule(
            id: it.id * 10 + i,
            title: 'SilverCare',
            body: i == 0 ? it.reminderText : it.repeatText,
            scheduledDate: when,
            notificationDetails: details,
            androidScheduleMode: scheduleMode,
          );
          scheduled++;
        }
      }
      debugPrint(
        'SilverCare: scheduled $scheduled notifications ($scheduleMode)',
      );
    } catch (_) {
      // Ошибки планирования не должны ломать экран.
    }
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: buildMain()),
            if (exerciseOpen)
              Positioned.fill(
                child: MemoryExercise(
                  onClose: () => setState(() => exerciseOpen = false),
                  speak: speak,
                ),
              ),
            if (pickerOpen)
              Positioned.fill(
                child: PatientPicker(
                  currentId: patientId,
                  onSelect: selectPatient,
                  onClose: () => setState(() => pickerOpen = false),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget buildMain() {
    if (loading) {
      return const Center(
        child: SizedBox(
          width: 90,
          height: 90,
          child: CircularProgressIndicator(color: kText, strokeWidth: 8),
        ),
      );
    }
    if (error) {
      return Column(
        children: [
          const Expanded(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(kPad),
                child: Text(
                  'Нет связи с сервером',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: kTitleSize,
                    fontWeight: FontWeight.bold,
                    color: kText,
                  ),
                ),
              ),
            ),
          ),
          BigButton(
            label: 'ПОВТОРИТЬ',
            color: kRed,
            textColor: kText,
            onPressed: () {
              setState(() {
                loading = true;
                error = false;
              });
              loadToday();
            },
          ),
          const SizedBox(height: kPad),
        ],
      );
    }

    final n = next;
    final taken = items.where((i) => i.status == 'taken').length;
    final missed = items.where((i) => i.status == 'missed').length;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(kPad, 24, kPad, 8),
            child: n == null
                ? Text(
                    missed > 0
                        ? 'На сегодня приёмов больше нет'
                        : 'На сегодня всё принято ✓',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: kTitleSize,
                      fontWeight: FontWeight.bold,
                      color: kText,
                      height: 1.15,
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        n.name,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: kTitleSize,
                          fontWeight: FontWeight.bold,
                          color: kText,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        n.dose,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: kSubSize,
                          color: kText,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        n.timeText.isEmpty ? '' : 'Время: ${n.timeText}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: kSubSize,
                          fontWeight: FontWeight.bold,
                          color: kYellow,
                          height: 1.15,
                        ),
                      ),
                    ],
                  ),
          ),
          const SizedBox(height: 8),
          if (n != null)
            BigButton(
              label: 'ПРИНЯЛ',
              color: kGreen,
              textColor: Colors.black,
              minHeight: kButtonMinHeight + 40,
              fontSize: kButtonSize + 10,
              onPressed: sending ? null : takeNext,
            ),
          const SizedBox(height: kPad),
          BigButton(
            label: 'ПОВТОРИТЬ ВСЛУХ',
            color: kYellow,
            textColor: Colors.black,
            onPressed: () => speak(
              n == null
                  ? (missed > 0
                        ? 'На сегодня приёмов больше нет'
                        : 'На сегодня всё принято')
                  : n.reminderText,
            ),
          ),
          const SizedBox(height: kPad),
          BigButton(
            label: 'УПРАЖНЕНИЕ',
            color: kBlue,
            textColor: kText,
            onPressed: () => setState(() => exerciseOpen = true),
          ),
          const SizedBox(height: kPad),
          // Скрытый вход: удержание ~3 с на счётчике открывает выбор пациента.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPressStart: (_) {
              secretHoldTimer?.cancel();
              secretHoldTimer = Timer(kSecretHold, () {
                if (mounted) setState(() => pickerOpen = true);
              });
            },
            onLongPressEnd: (_) => secretHoldTimer?.cancel(),
            onLongPressCancel: () => secretHoldTimer?.cancel(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: kPad),
              child: Column(
                children: [
                  Text(
                    'Сегодня: принято $taken / пропущено $missed',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 18, color: Colors.white70),
                  ),
                  if (patientName.isNotEmpty)
                    Text(
                      patientName,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 18, color: Colors.grey),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: kPad),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Большая кнопка
// ---------------------------------------------------------------------------
class BigButton extends StatelessWidget {
  const BigButton({
    super.key,
    required this.label,
    required this.color,
    required this.textColor,
    required this.onPressed,
    this.minHeight = kButtonMinHeight,
    this.fontSize = kButtonSize,
  });

  final String label;
  final Color color;
  final Color textColor;
  final VoidCallback? onPressed;
  final double minHeight;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kPad),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: color,
            disabledBackgroundColor: color.withValues(alpha: 0.5),
            foregroundColor: textColor,
            minimumSize: Size(double.infinity, minHeight),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w900,
              color: textColor,
              height: 1.1,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Упражнение для памяти (полноэкранный overlay)
// ---------------------------------------------------------------------------
class MemoryExercise extends StatefulWidget {
  const MemoryExercise({super.key, required this.onClose, required this.speak});

  final VoidCallback onClose;
  final Future<void> Function(String) speak;

  @override
  State<MemoryExercise> createState() => _MemoryExerciseState();
}

class _MemoryExerciseState extends State<MemoryExercise> {
  late final List<int> digits;
  late final List<int> options;
  int secondsLeft = 5;
  bool showQuestion = false;
  bool? correct; // null — ещё не ответил
  Timer? timer;

  @override
  void initState() {
    super.initState();
    final rnd = Random();
    // Три разные цифры 1..9.
    final pool = List<int>.generate(9, (i) => i + 1)..shuffle(rnd);
    digits = pool.take(3).toList();
    options = List<int>.from(digits)..shuffle(rnd);

    widget.speak('Запомните цифры: ${digits.join(', ')}');
    timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (secondsLeft <= 1) {
        t.cancel();
        setState(() {
          secondsLeft = 0;
          showQuestion = true;
        });
        widget.speak('Какое число было первым?');
      } else {
        setState(() => secondsLeft--);
      }
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  void answer(int value) {
    if (correct != null) return;
    final ok = value == digits.first;
    setState(() => correct = ok);
    widget.speak(ok ? 'Верно!' : 'Неверно, было ${digits.first}');
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: Center(child: buildBody())),
          BigButton(
            label: 'ЗАКРЫТЬ',
            color: Colors.white,
            textColor: Colors.black,
            minHeight: 140,
            onPressed: widget.onClose,
          ),
          const SizedBox(height: kPad),
        ],
      ),
    );
  }

  Widget buildBody() {
    if (!showQuestion) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(kPad),
            child: Text(
              'Запомните цифры',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: kSubSize,
                color: kText,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Text(
            digits.join('   '),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 120,
              fontWeight: FontWeight.w900,
              color: kYellow,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            '$secondsLeft',
            style: const TextStyle(fontSize: kSubSize, color: Colors.white70),
          ),
        ],
      );
    }

    if (correct != null) {
      final ok = correct!;
      return Padding(
        padding: const EdgeInsets.all(kPad),
        child: Text(
          ok ? 'Верно!' : 'Неверно,\nбыло ${digits.first}',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 64,
            fontWeight: FontWeight.w900,
            color: ok ? kGreen : kRed,
            height: 1.15,
          ),
        ),
      );
    }

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.all(kPad),
            child: Text(
              'Какое число\nбыло первым?',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: kTitleSize,
                fontWeight: FontWeight.bold,
                color: kText,
                height: 1.15,
              ),
            ),
          ),
          for (final o in options) ...[
            BigButton(
              label: '$o',
              color: kBlue,
              textColor: kText,
              minHeight: 130,
              fontSize: 60,
              onPressed: () => answer(o),
            ),
            const SizedBox(height: kPad),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Выбор пациента (скрытый полноэкранный overlay)
// ---------------------------------------------------------------------------
class PatientPicker extends StatefulWidget {
  const PatientPicker({
    super.key,
    required this.currentId,
    required this.onSelect,
    required this.onClose,
  });

  final int currentId;
  final Future<void> Function(int id) onSelect;
  final VoidCallback onClose;

  @override
  State<PatientPicker> createState() => _PatientPickerState();
}

class _PatientPickerState extends State<PatientPicker> {
  List<(int, String)> patients = [];
  bool loading = true;
  bool error = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final res = await http
          .get(Uri.parse('$kApiUrl/patients'))
          .timeout(kHttpTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('HTTP ${res.statusCode}');
      }
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      final raw = data is List ? data : (data is Map ? data['items'] : null);
      final list = <(int, String)>[];
      if (raw is List) {
        for (final e in raw) {
          if (e is! Map) continue;
          final rawId = e['id'] ?? e['patient_id'];
          final id = rawId is int ? rawId : int.tryParse('${rawId ?? ''}');
          if (id == null) continue;
          final name = '${e['name'] ?? e['full_name'] ?? 'Пациент $id'}';
          list.add((id, name));
        }
      }
      if (!mounted) return;
      setState(() {
        patients = list;
        loading = false;
        error = false;
      });
    } catch (e) {
      debugPrint('SilverCare: /patients failed: $e');
      if (!mounted) return;
      setState(() {
        loading = false;
        error = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: buildBody()),
          BigButton(
            label: 'ЗАКРЫТЬ',
            color: Colors.white,
            textColor: Colors.black,
            minHeight: 140,
            onPressed: widget.onClose,
          ),
          const SizedBox(height: kPad),
        ],
      ),
    );
  }

  Widget buildBody() {
    if (loading) {
      return const Center(
        child: SizedBox(
          width: 90,
          height: 90,
          child: CircularProgressIndicator(color: kText, strokeWidth: 8),
        ),
      );
    }
    if (error) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(kPad),
          child: Text(
            'Нет связи',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: kTitleSize,
              fontWeight: FontWeight.bold,
              color: kText,
            ),
          ),
        ),
      );
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(kPad, 24, kPad, kPad),
            child: Text(
              'Кто пользуется телефоном?',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: kTitleSize,
                fontWeight: FontWeight.bold,
                color: kText,
                height: 1.15,
              ),
            ),
          ),
          if (patients.isEmpty)
            const Padding(
              padding: EdgeInsets.all(kPad),
              child: Text(
                'Список пациентов пуст',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: kSubSize, color: kText),
              ),
            ),
          for (final (id, name) in patients) ...[
            BigButton(
              label: name,
              color: id == widget.currentId ? kGreen : kBlue,
              textColor: id == widget.currentId ? Colors.black : kText,
              minHeight: 130,
              onPressed: () => widget.onSelect(id),
            ),
            const SizedBox(height: kPad),
          ],
        ],
      ),
    );
  }
}
