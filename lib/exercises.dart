// Генерация заданий для упражнения на память. Чистый Dart, без Flutter.
//
// Каждое задание = что показать на фазе «запомни» (может быть пусто),
// вопрос, что показать рядом с вопросом, варианты ответа и правильный ответ.

import 'dart:math';

/// Элемент для показа/варианта. [color] — ARGB, только для цветных заданий.
class ExItem {
  const ExItem(this.label, {this.color});
  final String label;
  final int? color;
}

/// Как отрисовывать элементы фазы «запомни».
enum ShowKind { none, digits, colors, words }

class Exercise {
  const Exercise({
    required this.template,
    required this.kind,
    required this.shown,
    required this.question,
    required this.questionShown,
    required this.options,
    required this.correct,
  });

  /// Имя шаблона (для отсутствия повторов в сессии и для логов).
  final String template;
  final ShowKind kind;

  /// Что показать 5 секунд. Пусто → фазы запоминания нет.
  final List<ExItem> shown;
  final String question;

  /// Что показать крупно на фазе вопроса (например, 2 цифры из 3).
  final List<ExItem> questionShown;

  /// Варианты, уже перемешаны.
  final List<ExItem> options;

  /// Правильный ответ (label).
  final String correct;

  bool get hasMemorizePhase => shown.isNotEmpty;
}

// ---------------------------------------------------------------------------
// Константы
// ---------------------------------------------------------------------------

const List<String> kWords = [
  'ХЛЕБ',
  'ЧАЙ',
  'ОКНО',
  'СТОЛ',
  'КОШКА',
  'ДОМ',
  'ЛОЖКА',
  'КНИГА',
  'ЧАСЫ',
  'ЯБЛОКО',
  'ВОДА',
  'ШАПКА',
  'ДВЕРЬ',
  'ЛАМПА',
  'СОЛЬ',
  'РЕКА',
  'ЗИМА',
  'ПТИЦА',
  'СТУЛ',
  'НОЖ',
  'МОЛОКО',
  'ЦВЕТОК',
  'ДОРОГА',
  'СОЛНЦЕ',
  'ТЕЛЕФОН',
  'ОЧКИ',
  'КЛЮЧ',
  'САХАР',
];

/// Название → ARGB.
const List<ExItem> kColors = [
  ExItem('КРАСНЫЙ', color: 0xFFE53935),
  ExItem('ЗЕЛЁНЫЙ', color: 0xFF2ECC40),
  ExItem('СИНИЙ', color: 0xFF0074D9),
  ExItem('ЖЁЛТЫЙ', color: 0xFFFFDC00),
  ExItem('БЕЛЫЙ', color: 0xFFFFFFFF),
  ExItem('ОРАНЖЕВЫЙ', color: 0xFFFF851B),
];

const List<String> kWeekdays = [
  'ПОНЕДЕЛЬНИК',
  'ВТОРНИК',
  'СРЕДА',
  'ЧЕТВЕРГ',
  'ПЯТНИЦА',
  'СУББОТА',
  'ВОСКРЕСЕНЬЕ',
];

const List<String> kMonths = [
  'ЯНВАРЬ',
  'ФЕВРАЛЬ',
  'МАРТ',
  'АПРЕЛЬ',
  'МАЙ',
  'ИЮНЬ',
  'ИЮЛЬ',
  'АВГУСТ',
  'СЕНТЯБРЬ',
  'ОКТЯБРЬ',
  'НОЯБРЬ',
  'ДЕКАБРЬ',
];

const List<String> kSeasons = ['ЗИМА', 'ВЕСНА', 'ЛЕТО', 'ОСЕНЬ'];

const List<String> kOrdinal = ['первой', 'второй', 'третьей'];

/// Все шаблоны. Функция принимает Random и «сейчас» (для today).
typedef ExerciseBuilder = Exercise Function(Random rnd, DateTime now);

const Map<String, ExerciseBuilder> kTemplates = {
  'digits_first': digitsFirst,
  'digits_last': digitsLast,
  'digits_missing': digitsMissing,
  'colors': colors,
  'words_which': wordsWhich,
  'words_extra': wordsExtra,
  'today': today,
};

// ---------------------------------------------------------------------------
// Сессия
// ---------------------------------------------------------------------------

/// [count] заданий со случайными шаблонами без повтора.
List<Exercise> makeSession(Random rnd, DateTime now, {int count = 3}) {
  final names = kTemplates.keys.toList()..shuffle(rnd);
  return names.take(count).map((n) => kTemplates[n]!(rnd, now)).toList();
}

// ---------------------------------------------------------------------------
// Вспомогательные
// ---------------------------------------------------------------------------

List<int> _threeDigits(Random rnd) {
  final pool = List<int>.generate(9, (i) => i + 1)..shuffle(rnd);
  return pool.take(3).toList();
}

List<String> _threeWords(Random rnd) {
  final pool = List<String>.from(kWords)..shuffle(rnd);
  return pool.take(3).toList();
}

List<ExItem> _digitItems(List<int> d) => d.map((x) => ExItem('$x')).toList();

List<ExItem> _wordItems(List<String> w) => w.map(ExItem.new).toList();

List<ExItem> _shuffled(Random rnd, List<ExItem> items) =>
    List<ExItem>.from(items)..shuffle(rnd);

// ---------------------------------------------------------------------------
// Шаблоны
// ---------------------------------------------------------------------------

Exercise digitsFirst(Random rnd, DateTime now) {
  final d = _threeDigits(rnd);
  return Exercise(
    template: 'digits_first',
    kind: ShowKind.digits,
    shown: _digitItems(d),
    question: 'Какая цифра была первой?',
    questionShown: const [],
    options: _shuffled(rnd, _digitItems(d)),
    correct: '${d.first}',
  );
}

Exercise digitsLast(Random rnd, DateTime now) {
  final d = _threeDigits(rnd);
  return Exercise(
    template: 'digits_last',
    kind: ShowKind.digits,
    shown: _digitItems(d),
    question: 'Какая цифра была последней?',
    questionShown: const [],
    options: _shuffled(rnd, _digitItems(d)),
    correct: '${d.last}',
  );
}

Exercise digitsMissing(Random rnd, DateTime now) {
  final d = _threeDigits(rnd);
  final missingIdx = rnd.nextInt(3);
  final missing = d[missingIdx];
  final remaining = [
    for (var i = 0; i < 3; i++)
      if (i != missingIdx) d[i],
  ];
  final others = List<int>.generate(9, (i) => i + 1)
    ..removeWhere(d.contains)
    ..shuffle(rnd);
  final options = [missing, ...others.take(2)];
  return Exercise(
    template: 'digits_missing',
    kind: ShowKind.digits,
    shown: _digitItems(d),
    question: 'Какой цифры не хватает?',
    questionShown: _digitItems(remaining),
    options: _shuffled(rnd, _digitItems(options)),
    correct: '$missing',
  );
}

Exercise colors(Random rnd, DateTime now) {
  final pool = List<ExItem>.from(kColors)..shuffle(rnd);
  final shown = pool.take(3).toList();
  final idx = rnd.nextInt(3);
  return Exercise(
    template: 'colors',
    kind: ShowKind.colors,
    shown: shown,
    question: 'Какого цвета был ${kOrdinal[idx]} квадрат?',
    questionShown: const [],
    options: _shuffled(rnd, shown),
    correct: shown[idx].label,
  );
}

Exercise wordsWhich(Random rnd, DateTime now) {
  final w = _threeWords(rnd);
  final first = rnd.nextBool();
  return Exercise(
    template: 'words_which',
    kind: ShowKind.words,
    shown: _wordItems(w),
    question: first
        ? 'Какое слово было первым?'
        : 'Какое слово было последним?',
    questionShown: const [],
    options: _shuffled(rnd, _wordItems(w)),
    correct: first ? w.first : w.last,
  );
}

Exercise wordsExtra(Random rnd, DateTime now) {
  final pool = List<String>.from(kWords)..shuffle(rnd);
  final shown = pool.take(3).toList();
  final extra = pool[3];
  final twoShown = List<String>.from(shown)..shuffle(rnd);
  final options = [...twoShown.take(2), extra];
  return Exercise(
    template: 'words_extra',
    kind: ShowKind.words,
    shown: _wordItems(shown),
    question: 'Какого слова НЕ было?',
    questionShown: const [],
    options: _shuffled(rnd, _wordItems(options)),
    correct: extra,
  );
}

Exercise today(Random rnd, DateTime now) {
  final variant = rnd.nextInt(3);
  late final String question;
  late final String correct;
  late final List<String> pool;
  switch (variant) {
    case 0:
      question = 'Какой сегодня день недели?';
      correct = kWeekdays[now.weekday - 1];
      pool = kWeekdays;
    case 1:
      question = 'Какой сейчас месяц?';
      correct = kMonths[now.month - 1];
      pool = kMonths;
    default:
      question = 'Какое сейчас время года?';
      correct = kSeasons[_seasonIndex(now.month)];
      pool = kSeasons;
  }
  final others = List<String>.from(pool)
    ..remove(correct)
    ..shuffle(rnd);
  final options = [correct, ...others.take(2)];
  return Exercise(
    template: 'today',
    kind: ShowKind.none,
    shown: const [],
    question: question,
    questionShown: const [],
    options: _shuffled(rnd, _wordItems(options)),
    correct: correct,
  );
}

int _seasonIndex(int month) {
  if (month == 12 || month <= 2) return 0; // зима
  if (month <= 5) return 1; // весна
  if (month <= 8) return 2; // лето
  return 3; // осень
}
