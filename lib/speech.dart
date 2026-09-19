// Подготовка текста дозы для TTS. Чистый Dart, без Flutter.
//
// Android TTS читает «2 таблетки» как «два таблетки». Здесь число в начале
// строки заменяется словом в нужном роде, дроби — «половина», сокращения
// раскрываются. Название лекарства эта функция не трогает.
//
// Примеры:
//   doseForSpeech('2 таблетки')     → 'две таблетки'
//   doseForSpeech('1 капсула')      → 'одна капсула'
//   doseForSpeech('5 мг')           → 'пять миллиграмм'
//   doseForSpeech('0,5 таблетки')   → 'половина таблетки'
//   doseForSpeech('1/2 таб.')       → 'половина таблетка'
//   doseForSpeech('10 мл')          → 'десять миллилитров'
//   doseForSpeech('3 раза в день')  → 'три раза в день'

const List<String> _feminine = [
  'одна',
  'две',
  'три',
  'четыре',
  'пять',
  'шесть',
  'семь',
  'восемь',
  'девять',
  'десять',
];

const List<String> _masculine = [
  'один',
  'два',
  'три',
  'четыре',
  'пять',
  'шесть',
  'семь',
  'восемь',
  'девять',
  'десять',
];

/// Слова женского рода (в любой форме), перед которыми число читается
/// как «одна/две».
const List<String> _feminineWords = [
  'таблетка',
  'таблетки',
  'таблеток',
  'таб',
  'таб.',
  'капсула',
  'капсулы',
  'капсул',
  'капля',
  'капли',
  'капель',
  'ампула',
  'ампулы',
  'ампул',
  'ложка',
  'ложки',
  'ложек',
  'чайная',
  'чайные',
  'чайных',
  'столовая',
  'столовые',
  'столовых',
];

/// Сокращения → полные слова (поиск по границам слова).
const Map<String, String> _abbreviations = {
  'мг': 'миллиграмм',
  'мл': 'миллилитров',
  'таб.': 'таблетка',
  'таб': 'таблетка',
};

final RegExp _leadingInt = RegExp(r'^\s*(\d+)\s+(\S+)');
final RegExp _leadingHalf = RegExp(r'^\s*(0[.,]5|1/2|½)(\s+|$)');

String doseForSpeech(String dose) {
  var s = dose.trim();
  if (s.isEmpty) return s;

  // Дробь в начале → «половина».
  final half = _leadingHalf.firstMatch(s);
  if (half != null) {
    s = 'половина${half.group(2)!.isEmpty ? '' : ' '}${s.substring(half.end)}';
  } else {
    // Целое число 1–10 в начале перед словом.
    final m = _leadingInt.firstMatch(s);
    if (m != null) {
      final n = int.tryParse(m.group(1)!);
      if (n != null && n >= 1 && n <= 10) {
        final nextWord = m.group(2)!.toLowerCase();
        final fem = _feminineWords.any(
          (w) => nextWord == w || nextWord.startsWith('$w,'),
        );
        final word = (fem ? _feminine : _masculine)[n - 1];
        s = s.replaceFirst(RegExp(r'^\d+'), word);
      }
    }
  }

  // Сокращения: только целыми словами, «таб.» раньше «таб».
  for (final entry in _abbreviations.entries) {
    final key = RegExp.escape(entry.key);
    s = s.replaceAll(
      RegExp(
        '(?<![\\wа-яё])$key(?![\\wа-яё])',
        caseSensitive: false,
        unicode: true,
      ),
      entry.value,
    );
  }
  return s;
}
