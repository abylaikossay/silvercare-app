# SilverCare: Контроль лекарств (Flutter-демо)

Один экран для пожилых людей с ослабленным зрением/слухом: крупный текст, три
большие кнопки (ПРИНЯЛ / ПОВТОРИТЬ ВСЛУХ / УПРАЖНЕНИЕ), голосовые напоминания
(TTS ru-RU) и локальные уведомления. Android-first.

## Запуск

```bash
git clone <repo-url>
cd silvercare_app
flutter pub get
```

Дальше открыть папку в Android Studio, выбрать Android-эмулятор (API 33+
желательно, чтобы увидеть запрос разрешения на уведомления) и нажать Run.
Или из терминала:

```bash
flutter run
```

Весь код в `lib/main.dart`.

## Бэкенд

Приложение ходит в FastAPI-бэкенд:

- `GET {API_URL}/patients/1/today`
- `POST {API_URL}/intakes/{intake_id}/take`

По умолчанию `API_URL = http://10.0.2.2:8000` — это `localhost:8000` хост-машины
с точки зрения Android-эмулятора. Значит, локально нужно поднять бэк:

```bash
uvicorn main:app --host 0.0.0.0 --port 8000
```

Чтобы указать другой адрес (например, Railway), передайте `--dart-define`:

```bash
flutter run --dart-define=API_URL=https://your-backend.up.railway.app
flutter build apk --debug --dart-define=API_URL=https://your-backend.up.railway.app
```

Пациент задаётся тоже через `--dart-define` (`PATIENT_ID`, по умолчанию `1`):

```bash
flutter run --dart-define=API_URL=https://your-backend.up.railway.app --dart-define=PATIENT_ID=2
```

Приложение собирается под конкретного пациента, сам пациент ничего не настраивает.

Один и тот же APK можно переключить на другого пациента: удерживайте ~3 секунды
строку «Сегодня: принято … / пропущено …» внизу экрана — откроется список
пациентов из `GET /patients`. Выбор сохраняется на телефоне (shared_preferences)
и имеет приоритет над `PATIENT_ID`; имя текущего пациента показывается мелко
под счётчиком.

В Android Studio: Run → Edit Configurations → поле «Additional run args» →
`--dart-define=API_URL=https://...`.

Если сервер недоступен, на экране будет «Нет связи с сервером» и кнопка
«ПОВТОРИТЬ».

## Примечания

- Часовой пояс для уведомлений захардкожен: `Asia/Almaty`.
- Уведомления планируются точными будильниками и повторяются каждые 10 минут
  (до 6 раз), пока не нажато «ПРИНЯЛ». На Android 12+ система может спросить
  разрешение «Будильники и напоминания»; если отказать — уведомления будут
  неточными (задержка до нескольких минут).
- TTS зависит от установленного на устройстве голосового движка с русским
  языком (Google TTS на эмуляторе с Google Play обычно есть).
