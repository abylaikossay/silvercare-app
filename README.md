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

В Android Studio: Run → Edit Configurations → поле «Additional run args» →
`--dart-define=API_URL=https://...`.

Если сервер недоступен, на экране будет «Нет связи с сервером» и кнопка
«ПОВТОРИТЬ».

## Примечания

- Часовой пояс для уведомлений захардкожен: `Asia/Almaty`.
- Уведомления планируются в режиме `inexactAllowWhileIdle` (без exact alarm),
  поэтому могут прийти с задержкой в несколько минут — это нормально.
- TTS зависит от установленного на устройстве голосового движка с русским
  языком (Google TTS на эмуляторе с Google Play обычно есть).
