// SilverCare: Контроль лекарств — демо для пожилых людей (один экран).
//
// По умолчанию ходит на прод (Railway). Для локального бэка:
//   flutter run --dart-define=API_URL=http://10.0.2.2:8000

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'exercises.dart';
import 'speech.dart';

const String kApiUrl = String.fromEnvironment(
  'API_URL',
  defaultValue: 'https://silvercare-api-production.up.railway.app',
);

/// Единственный источник id пациента — shared_preferences.
const String kPrefPatientId = 'patient_id';
const Duration kRefreshInterval = Duration(seconds: 60);
const Duration kHttpTimeout = Duration(seconds: 8);
const Duration kVoiceRepeatInterval = Duration(minutes: 5);
const Duration kNotifyRepeatStep = Duration(minutes: 5);
const int kNotifyRepeatCount = 12; // t, t+5 … t+55
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

/// true, если приложение холодно запущено тапом по уведомлению (или его
/// full-screen intent). Читается один раз в _HomeScreenState._start().
bool launchedFromNotification = false;

/// Тап по уведомлению при живом приложении: инкремент → HomeScreen
/// перезагружает today и озвучивает due-слот немедленно.
final ValueNotifier<int> notificationTap = ValueNotifier<int>(0);

/// Android 14+: разрешение на full-screen intent (будильник поверх экрана
/// блокировки). Плагин сам проверяет canUseFullScreenIntent() и, если
/// не разрешено, открывает системные настройки; ниже — только результат.
Future<void> requestFullScreenIntent() async {
  final android = notifications
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  if (android == null) return;
  try {
    final granted = await android.requestFullScreenIntentPermission();
    debugPrint('SilverCare: full-screen intent allowed = $granted');
  } catch (e) {
    debugPrint('SilverCare: full-screen intent request failed: $e');
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

  // Глобальные обработчики: любое исключение — в лог, а не в «немой» экран.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('SilverCare: FlutterError: ${details.exceptionAsString()}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('SilverCare: uncaught: $error\n$stack');
    return true;
  };

  // Ни один шаг инициализации не должен помешать runApp.
  await _guard('timezone', () async {
    tzdata.initializeTimeZones();
    almaty = tz.getLocation('Asia/Almaty');
    tz.setLocalLocation(almaty);
  });

  await _guard('notifications.initialize', () async {
    await notifications.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_silvercare'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: true,
          requestBadgePermission: false,
          requestSoundPermission: true,
        ),
      ),
      onDidReceiveNotificationResponse: (_) {
        debugPrint('SilverCare: notification tapped (app alive)');
        notificationTap.value++;
      },
    );
  });

  await _guard('getNotificationAppLaunchDetails', () async {
    final launch = await notifications.getNotificationAppLaunchDetails();
    launchedFromNotification = launch?.didNotificationLaunchApp ?? false;
    debugPrint(
      'SilverCare: launched from notification = $launchedFromNotification',
    );
  });

  // Запускаем инициализацию TTS, но не блокируем старт UI.
  unawaited(_ttsReady);

  // UI показываем сразу; системные диалоги разрешений — уже поверх него.
  runApp(const SilverCareApp());
  unawaited(_requestPermissions());
}

/// Запросы разрешений после runApp: диалоги (POST_NOTIFICATIONS, точные
/// будильники, full-screen intent) не должны держать пустой splash.
Future<void> _requestPermissions() async {
  if (defaultTargetPlatform == TargetPlatform.android) {
    await _guard('requestNotificationsPermission', () async {
      await notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    });
    await _guard('pickAndroidScheduleMode', pickAndroidScheduleMode);
    await _guard('requestFullScreenIntent', requestFullScreenIntent);
  } else if (defaultTargetPlatform == TargetPlatform.iOS) {
    await _guard('iOS requestPermissions', () async {
      await notifications
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, sound: true);
    });
  }
}

/// Выполнить шаг инициализации, проглотив и залогировав любую ошибку.
Future<void> _guard(String name, Future<void> Function() step) async {
  try {
    await step();
  } catch (e, st) {
    debugPrint('SilverCare: init step "$name" failed: $e\n$st');
  }
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

  /// Текст для уведомлений (как есть).
  String get reminderText => 'Пора принять $name, $dose';
  String get repeatText => 'Напоминаю: пора принять $name, $dose';

  /// Текст для голоса: доза приведена к читаемому виду («две таблетки»).
  String get reminderSpeech => 'Пора принять $name, ${doseForSpeech(dose)}';
  String get repeatSpeech =>
      'Напоминаю: пора принять $name, ${doseForSpeech(dose)}';
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

  /// Через 3 с без данных и без ошибки показываем «Загрузка…».
  bool slowLoading = false;
  Timer? slowLoadingTimer;

  /// Текущий пациент из shared_preferences. null — ещё не выбран
  /// (первый запуск), тогда показывается обязательный выбор.
  int? patientId;
  String patientName = '';

  Timer? refreshTimer;

  /// Время последней озвучки по intake_id — повтор не чаще раза в 10 минут.
  final Map<int, tz.TZDateTime> lastSpokenAt = {};

  @override
  void initState() {
    super.initState();
    _start();
    refreshTimer = Timer.periodic(kRefreshInterval, (_) => loadToday());
    notificationTap.addListener(_onNotificationTap);
    slowLoadingTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && loading) setState(() => slowLoading = true);
    });
  }

  void _onNotificationTap() {
    loadToday(speakNow: true);
  }

  Future<void> _start() async {
    int? saved;
    try {
      final prefs = await SharedPreferences.getInstance();
      saved = prefs.getInt(kPrefPatientId);
    } catch (e) {
      debugPrint('SilverCare: prefs read failed: $e');
    }
    debugPrint('SilverCare: saved patientId = $saved');
    if (!mounted) return;
    if (saved == null) {
      // Первый запуск: today не грузим, сразу обязательный выбор пациента.
      setState(() {
        patientId = null;
        loading = false;
        pickerOpen = true;
      });
      return;
    }
    setState(() => patientId = saved);
    final speakNow = launchedFromNotification;
    launchedFromNotification = false;
    await loadToday(speakNow: speakNow);
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
    slowLoadingTimer?.cancel();
    notificationTap.removeListener(_onNotificationTap);
    super.dispose();
  }

  // ---------------- Сеть ----------------

  /// [speakNow] — озвучить due-слот сразу (запуск/тап из уведомления),
  /// игнорируя интервал 5 минут между голосовыми повторами.
  Future<void> loadToday({bool speakNow = false}) async {
    final id = patientId;
    if (id == null) return; // пациент ещё не выбран
    try {
      final res = await http
          .get(Uri.parse('$kApiUrl/patients/$id/today'))
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
      if (speakNow) {
        await _ttsReady;
        maybeSpeakDueReminder(force: true);
      } else {
        maybeSpeakDueReminder();
      }
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

  void maybeSpeakDueReminder({bool force = false}) {
    final n = next;
    if (n == null || n.scheduledAt == null) return;
    if (n.status != 'pending') return;
    final now = nowAlmaty();
    if (n.scheduledAt!.isAfter(now)) return;
    final last = lastSpokenAt[n.id];
    if (!force && last != null && now.difference(last) < kVoiceRepeatInterval) {
      return;
    }
    lastSpokenAt[n.id] = now;
    speak(last == null ? n.reminderSpeech : n.repeatSpeech);
  }

  // ---------------- Уведомления ----------------

  Future<void> scheduleNotifications(List<Intake> list) async {
    try {
      await notifications.cancelAll();
      final now = nowAlmaty();
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          // Новый id: у уже созданного канала Android не меняет звук/поток.
          'silvercare_alarms_v2',
          'Напоминания о лекарствах',
          channelDescription: 'Напоминания о приёме лекарств (будильник)',
          icon: 'ic_stat_silvercare',
          color: Color(0xFF5E9484),
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.alarm,
          fullScreenIntent: true,
          ongoing: false,
          playSound: true,
          sound: UriAndroidNotificationSound(
            'content://settings/system/alarm_alert',
          ),
          audioAttributesUsage: AudioAttributesUsage.alarm,
          enableVibration: true,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          sound: 'silvercare_alarm.wav',
          interruptionLevel: InterruptionLevel.timeSensitive,
        ),
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
            id: it.id * 100 + i,
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
                  // При первом запуске закрыть нельзя, пока не выбран пациент.
                  onClose: patientId == null
                      ? null
                      : () => setState(() => pickerOpen = false),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget buildMain() {
    if (loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 90,
              height: 90,
              child: CircularProgressIndicator(color: kText, strokeWidth: 8),
            ),
            if (slowLoading)
              const Padding(
                padding: EdgeInsets.all(kPad),
                child: Text(
                  'Загрузка…',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: kTitleSize,
                    fontWeight: FontWeight.bold,
                    color: kText,
                  ),
                ),
              ),
          ],
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
                  : n.reminderSpeech,
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
          Padding(
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
                TextButton(
                  onPressed: () => setState(() => pickerOpen = true),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF9A9A9A),
                    minimumSize: const Size(0, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  child: const Text(
                    'Сменить пациента',
                    style: TextStyle(fontSize: 22),
                  ),
                ),
              ],
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
// Упражнение для памяти: сессия из 3 заданий (полноэкранный overlay)
// ---------------------------------------------------------------------------
enum _ExPhase { memorize, question, result, summary }

class MemoryExercise extends StatefulWidget {
  const MemoryExercise({super.key, required this.onClose, required this.speak});

  final VoidCallback onClose;
  final Future<void> Function(String) speak;

  @override
  State<MemoryExercise> createState() => _MemoryExerciseState();
}

class _MemoryExerciseState extends State<MemoryExercise> {
  static const int kTasks = 3;
  static const int kMemorizeSeconds = 5;
  static const Duration kResultPause = Duration(seconds: 2);
  static const double kAnswerMinHeight = 180;

  final Random rnd = Random();
  late List<Exercise> session;
  int index = 0;
  int correctCount = 0;
  _ExPhase phase = _ExPhase.memorize;
  int secondsLeft = kMemorizeSeconds;
  bool? lastCorrect;
  Timer? timer;

  Exercise get ex => session[index];

  @override
  void initState() {
    super.initState();
    startSession();
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  void startSession() {
    timer?.cancel();
    session = makeSession(rnd, nowAlmaty(), count: kTasks);
    index = 0;
    correctCount = 0;
    lastCorrect = null;
    startTask();
  }

  void startTask() {
    timer?.cancel();
    lastCorrect = null;
    if (!ex.hasMemorizePhase) {
      phase = _ExPhase.question;
      if (mounted) setState(() {});
      widget.speak(ex.question);
      return;
    }
    phase = _ExPhase.memorize;
    secondsLeft = kMemorizeSeconds;
    if (mounted) setState(() {});
    widget.speak('Запомните: ${ex.shown.map((e) => e.label).join(', ')}');
    timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (secondsLeft <= 1) {
        t.cancel();
        setState(() {
          secondsLeft = 0;
          phase = _ExPhase.question;
        });
        widget.speak(ex.question);
      } else {
        setState(() => secondsLeft--);
      }
    });
  }

  void answer(String label) {
    if (phase != _ExPhase.question) return;
    final ok = label == ex.correct;
    if (ok) correctCount++;
    setState(() {
      lastCorrect = ok;
      phase = _ExPhase.result;
    });
    widget.speak(ok ? 'Верно!' : 'Неверно. Было: ${ex.correct}');
    timer = Timer(kResultPause, () {
      if (!mounted) return;
      if (index + 1 < session.length) {
        index++;
        startTask();
      } else {
        setState(() => phase = _ExPhase.summary);
        widget.speak('Верно: $correctCount из ${session.length}');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: buildBody()),
          if (phase == _ExPhase.summary) ...[
            BigButton(
              label: 'ЕЩЁ',
              color: kGreen,
              textColor: Colors.black,
              minHeight: kAnswerMinHeight,
              onPressed: () => setState(startSession),
            ),
            const SizedBox(height: kPad),
          ],
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
    switch (phase) {
      case _ExPhase.memorize:
        return buildMemorize();
      case _ExPhase.question:
        return buildQuestion();
      case _ExPhase.result:
        return buildResult();
      case _ExPhase.summary:
        return buildSummary();
    }
  }

  Widget progressLabel() => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(
      'Задание ${index + 1} из ${session.length}',
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 18, color: Colors.white70),
    ),
  );

  /// Отрисовка показанных элементов в зависимости от вида задания.
  Widget showItems(List<ExItem> items, {double digitSize = 120}) {
    switch (ex.kind) {
      case ShowKind.digits:
        return Text(
          items.map((e) => e.label).join('   '),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: digitSize,
            fontWeight: FontWeight.w900,
            color: kYellow,
            height: 1.0,
          ),
        );
      case ShowKind.colors:
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            for (final it in items)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      color: Color(it.color ?? 0xFFFFFFFF),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white, width: 3),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    it.label,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: kText,
                    ),
                  ),
                ],
              ),
          ],
        );
      case ShowKind.words:
      case ShowKind.none:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final it in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  it.label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 56,
                    fontWeight: FontWeight.w900,
                    color: kYellow,
                    height: 1.1,
                  ),
                ),
              ),
          ],
        );
    }
  }

  Widget buildMemorize() {
    return Column(
      children: [
        progressLabel(),
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Padding(
                    padding: EdgeInsets.all(kPad),
                    child: Text(
                      'Запомните',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: kSubSize,
                        color: kText,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  showItems(ex.shown),
                  const SizedBox(height: 24),
                  Text(
                    '$secondsLeft',
                    style: const TextStyle(
                      fontSize: kSubSize,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget buildQuestion() {
    final locked = phase != _ExPhase.question;
    return Column(
      children: [
        progressLabel(),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(kPad),
                  child: Text(
                    ex.question,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: kTitleSize,
                      fontWeight: FontWeight.bold,
                      color: kText,
                      height: 1.15,
                    ),
                  ),
                ),
                if (ex.questionShown.isNotEmpty) ...[
                  showItems(ex.questionShown, digitSize: 80),
                  const SizedBox(height: kPad),
                ],
                for (final o in ex.options) ...[
                  BigButton(
                    label: o.label,
                    color: o.color != null ? Color(o.color!) : kBlue,
                    textColor: o.color != null
                        ? contrastOn(Color(o.color!))
                        : kText,
                    minHeight: kAnswerMinHeight,
                    fontSize: ex.kind == ShowKind.digits ? 60 : kButtonSize,
                    onPressed: locked ? null : () => answer(o.label),
                  ),
                  const SizedBox(height: kPad),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget buildResult() {
    final ok = lastCorrect ?? false;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(kPad),
        child: Text(
          ok ? 'Верно!' : 'Неверно.\nБыло: ${ex.correct}',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 60,
            fontWeight: FontWeight.w900,
            color: ok ? kGreen : kRed,
            height: 1.15,
          ),
        ),
      ),
    );
  }

  Widget buildSummary() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(kPad),
        child: Text(
          'Верно:\n$correctCount из ${session.length}',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 64,
            fontWeight: FontWeight.w900,
            color: kGreen,
            height: 1.15,
          ),
        ),
      ),
    );
  }
}

/// Чёрный или белый текст в зависимости от яркости фона.
Color contrastOn(Color bg) =>
    bg.computeLuminance() > 0.4 ? Colors.black : Colors.white;

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

  /// null — первый запуск, пациент ещё не выбран.
  final int? currentId;
  final Future<void> Function(int id) onSelect;

  /// null — закрыть нельзя (обязательный выбор при первом запуске).
  final VoidCallback? onClose;

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
          if (error) ...[
            BigButton(
              label: 'ПОВТОРИТЬ',
              color: kRed,
              textColor: kText,
              minHeight: 140,
              onPressed: () {
                setState(() {
                  loading = true;
                  error = false;
                });
                load();
              },
            ),
            const SizedBox(height: kPad),
          ],
          if (widget.onClose != null) ...[
            BigButton(
              label: 'ЗАКРЫТЬ',
              color: Colors.white,
              textColor: Colors.black,
              minHeight: 140,
              onPressed: widget.onClose,
            ),
            const SizedBox(height: kPad),
          ],
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
            padding: EdgeInsets.only(top: 24),
            child: Image(
              image: AssetImage('assets/logo.png'),
              width: 120,
              height: 120,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(kPad),
            child: Text(
              widget.currentId == null
                  ? 'Кто пользуется телефоном?'
                  : 'Сменить пациента',
              textAlign: TextAlign.center,
              style: const TextStyle(
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
