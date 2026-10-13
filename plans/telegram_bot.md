# Telegram-бот (h2code-tg-bot) — план реализации для h2code

> **Статус: Фаза 1 (MVP) и Фаза 2 (диспетчер) реализованы.** Ядро:
> `--resident` (`src/h2code.cr`, `src/remote/resident.cr`), протокол v2
> (`src/remote/control_socket.cr`), SocketQuestionService + approval-мост.
> Бот: `src/tg_bot/` (второй target `h2code-tg-bot` в `shard.yml`) —
> мультисессии с карточками (model/mode, /clear, /compact), 🕘 Recent с
> resume, поиск, /rename, управление директориями, журнал
> `~/.h2code/tg/state.json`. Спеки: `spec/remote/`, `spec/tg_bot/`.
> Осталось из Фазы 2: i18n интерфейса бота, перезапуск сессий при смене
> версии h2code. Отправная точка — разбор
> [vityah1/claude-tg-bot](https://github.com/vityah1/claude-tg-bot),
> Telegram-диспетчера сессий Claude Code. Его выводы о UX переняты, его
> механика (tmux, парсинг экрана, хвосты транскриптов) — нет: у h2code все
> нужные швы уже нативные.

## Контекст и зафиксированные решения

Цель: человек запускает агента **на своём сервере** и управляет им **только
с телефона через Telegram** — без ноутбука, без TUI, без общего сервиса.

Решения из обсуждения:

1. **Один открытый бинарник `h2code-tg-bot`** — Telegram-бот и супервизор
   сессий в одной связке, в этом же репозитории (второй target в
   `shard.yml`). Никакого общего/центрального бота: каждый пользователь
   регистрирует своего у @BotFather и вписывает свой токен.
2. **Ответы — push по control socket** (протокол v2). Хвост `wire.jsonl`
   не читаем: это был бы второй парсер того же, что уже стримится в
   процессе.
3. **Process-per-session** (resident-процессы h2code), не мультисессия в
   одном процессе — class-var синглтоны Goal/Plan/Task/SwarmMode шарятся
   между сессиями (см. `plans/web_interface.md`, разбор «Сервисные
   синглтоны»), изоляция нужна структурная.
4. **Manual-only сервис** — как h2code-remote (NOTE 2026-09-03 в
   `src/remote/sync.cr`): h2code никогда не стартует и не останавливает
   `h2code-tg-bot`; пользователь ставит его сам (systemd unit).

## Почему не как claude-tg-bot

claude-tg-bot работает «снаружи»: ввод через `tmux send-keys`, ответы —
хвосты `~/.claude/projects/*/<uuid>.jsonl`, диалоги — `capture-pane` +
парсинг колонок экрана. Это вынужденность: у Claude Code нет внешнего
протокола (штатные каналы заблокированы политикой орги автора).

В h2code каждый его костыль уже имеет нативный аналог:

| claude-tg-bot | h2code |
|---|---|
| `tmux paste-buffer` (ввод) | `control.sock`: `{"op":"prompt"}` / `{"op":"interrupt"}` (`src/remote/control_socket.cr`) |
| хвосты `.jsonl` (вывод) | push-события по тому же сокету (протокол v2, ниже) |
| `capture-pane` + screen.py (диалоги) | reverse-RPC `session/request_question` — паттерн уже обкатан в ACP (`src/acp/question.cr`), вопрос структурирован (опции, multiSelect) |
| `claude agents --json` (список) | `Session::Lifecycle.index`, сессии в `~/.h2code/sessions/**` |
| statusline-tee (метрики) | метрики уже в процессе — расширить ответ `op:status` |

## Архитектура

```
Телефон (Telegram) ←→ Bot API (long-polling) ←→ h2code-tg-bot (сервер)
                                                  ├── h2code --resident -s <id>   (сессия 1)
                                                  ├── h2code --resident -s <id>   (сессия 2)
                                                  └── Session::Index (~/.h2code/sessions)
```

### 1. Resident-режим в ядре (`h2code --resident`)

Сегодня headless one-shot: `-p` → ход → выход (`run_headless`,
`src/h2code.cr:737`), control socket биндится только в TUI-обвязке
(`src/h2code.cr:1200`), а `AskUserQuestion` без `QuestionService` не
работает вовсе (`src/tools/ask_user_question.cr:53` — сервис подключают
только TUI `h2code.cr:1109` и ACP `acp/server.cr:600`).

`--resident [-s <id> | -c] [-d <dir>]` — тот же headless-агент, но:

- без обязательного `-p`: процесс живёт и ждёт промпты из сокета;
- биндит `ControlSocket` в своей session-директории (вынести биндинг из
  TUI-обвязки, класс переиспользуется как есть);
- подключает `SocketQuestionService` — зеркало ACP `QuestionHandler`:
  блокирует fiber, пушит `ev:question` в сокет, ждёт `op:answer`
  (`Channel`), таймаут 30 минут (тот же бюджет, что план-ревью);
- подключает `approval_callback` permission-менеджера
  (`permission.approval_callback`, шов как в TUI `h2code.cr:1101`) на тот
  же канал — запрос пермишена это тоже вопрос с кнопками;
- на `SIGTERM` завершает текущий ход корректно (дописать `wire.jsonl`) —
  аналог их «/exit, а не /kill».

### 2. Протокол control socket v2 (`src/remote/control_socket.cr`)

Новоеline-delimited JSON, как сейчас. Существующие ops не меняются,
добавляются push-фреймы и новые ops.

Client → session (существующие + новые):

```jsonc
{"op":"prompt","text":"…"}                    // есть
{"op":"interrupt"}                            // есть
{"op":"status"}                               // есть; ответ расширяется (ниже)
{"op":"answer","qid":"…","answers":{"вопрос":"выбор"}}   // ответ на ev:question
{"op":"approve","qid":"…","decision":"allow"|"deny"}     // ответ на ev:approval
{"op":"exit"}                                 // graceful: закончить ход и выйти
```

Session → client (push, новое):

```jsonc
{"ev":"turn","phase":"started"}
{"ev":"turn","phase":"ended","ok":true}
{"ev":"assistant","text":"…"}                 // финальный текст шага (durable AssistantText)
{"ev":"question","qid":"…","questions":[ … ]} // форма 1:1 с ACP build_params
{"ev":"approval","qid":"…","tool":"…","args":"…","danger":null}
{"ev":"usage","model":"…","context_pct":42,"cost":0.21}
```

Ответ `op:status` расширяется метриками (то, ради чего у claude-tg-bot
весь statusline-tee):

```jsonc
{"ok":true,"busy":true,"model":"…","context_pct":42,"cost":0.21}
```

Источник push-событий — event-стрим агента (`on_event`), который headless
уже потребляет в `run_headless`; в resident-режиме события маршрутизируются
в сокет. Форма `questions[]` — как в `Acp::QuestionHandler#build_params`
(`src/acp/question.cr:37`), включая `multiSelect`.

### 3. Бинарник `h2code-tg-bot`

- `src/tg_bot/` + второй target в `shard.yml`. Bot API — long-polling
  `getUpdates` через `HTTP::Client` (stdlib, новых зависимостей нет).
- Конфиг `~/.h2code/tg.json`: `token`, `allowed_user_ids`, `dirs`
  (список директорий для «новая сессия»; автодискавери из истории сессий,
  как у claude-tg-bot, — Фаза 2). **Без `allowed_user_ids` отказ
  стартовать** — пустой список это бот, исполняющий промпты любому
  нашедшему его (то же железное правило, что у claude-tg-bot).
- Супервизор: spawn `h2code --resident -s <id> -d <dir>`, реконнект к
  `control.sock`, respawn при падении, `/exit` через сокет.
- Роутинг (уроки claude-tg-bot):
  - **адресность** — session id в `callback_data` каждой кнопки: ответ на
    вопрос уходит ровно в ту сессию, откуда он пришёл;
  - **активная сессия + reply** — обычный текст идёт в активную, reply на
    любое сообщение сессии направляет в неё и делает её активной;
  - **inbox-batching** — per-chat буфер с паузой ~0.8 с после последнего
    сообщения: форвард из Telegram приходит пачкой, одна пачка = один
    промпт;
  - **per-session лок на сокет** — prompt атомарен, конкурентные записи
    не пересекаются;
  - **видимость ошибок** — исключение в демоне всегда уходит сообщением в
    чат, не только в лог; «живой, но всё тихо фейлится» — худшее состояние
    для удалённого агента.
- Вопросы → inline-клавиатура: одна кнопка на опцию; multiSelect —
  чекбоксы (☑/☐, редактирование карточки) + отдельная «Отправить N»;
  таймаут 30 минут латается dismiss-ответом (тул уже умеет ветку
  «пользователь отказался отвечать»).
- «⏳ думает» — одно сообщение, редактируемое по опросу `op:status`
  (busy), удаляется на `ev:turn ended`.
- Вложения: файл из Telegram → на диск (кэш-директория демона) → путь в
  тексте промпта; `read_media`/`Read` в процессе уже умеют картинки.
- Интерфейсные строки — через существующий `src/i18n`.

### 4. Деплой

- `h2code-tg-bot --setup` — проверка токена на месте (getMe), приглашение
  написать боту (id читается с первого сообщения — приём claude-tg-bot).
- `h2code-tg-bot --install-service` — генерация systemd user unit +
  `daemon-reload` (порт `TgBot::ServicePort`, `src/tg_bot/service_port/`;
  Linux/systemd — unit в `~/.config/systemd/user/`, на остальных
  системах адаптер отказывает с понятной ошибкой). `enable`/`start`
  остаются за пользователем — manual-only сервис.
- Unit с `KillMode=process`: рестарт демона не убивает resident-сессии
  (урок claude-tg-bot — с `control-group` умирал tmux-сервер со всеми
  сессиями; у нас то же с детьми-процессами).

## Что НЕ нужно менять

- `Loop::Agent`, `src/loop/` — уже правильная граница, event-стрим
  отвязан от UI.
- `Session::Store` / `wire.jsonl` — resident пишет как обычно; резюмится
  `-s`/`-c` как обычно.
- `LLM::Provider`, `Tools::Registry`, `Permission::Manager`,
  `Context::Memory` — per-instance.
- `Remote::ControlSocket` — расширяется, не переписывается; TUI-режим
  продолжает работать поверх того же класса (новые push-фреймы TUI
  просто игнорирует, пока не подключит подписку).

## Фазы

### Фаза 1 — MVP: ядро + бот

1. `--resident` в CLI (`src/h2code.cr`, разбор аргументов ~246) +
   `run_resident` по образцу `run_headless` (737): без `-p`, живёт,
   биндит сокет.
2. Протокол v2: push-фреймы + `op:answer`/`op:approve`/`op:exit` +
   метрики в `op:status`.
3. `SocketQuestionService` + approval-мост (паттерн `acp/question.cr`).
4. `h2code-tg-bot`: токен, allowlist, одна сессия, промпты, ответы
   пушем, interrupt, вопросы кнопками (включая multiSelect), пульс ⏳.
5. Спеки: протокол v2 (пуш/ответ/таймаут), QuestionService-мост, роутинг
   сообщений бота.

### Фаза 2 — полный диспетчер

- Мультисессии: список живых + закрытых (`Session::Index`), resume,
  «новая в директории», автодискавери директорий из истории.
- Вложения (файл → путь в промпте), `/usage`, карточка сессии с метриками.
- Перезапуск сессии при смене версии h2code (аналог их `/update`).
- i18n интерфейса бота.

### Фаза 3 — опционально, сближение с web_interface.md

- seq + durable/volatile классификация событий, единый транспорт для
  Telegram-бота и будущего веб-интерфейса (`plans/web_interface.md`,
  Фаза 1). Resident-режим уже совместим с тем планом: process-per-session
  — их же рекомендация.

## Риски / открытые вопросы

- **RAM process-per-session** — десятки MB RSS на сессию (Boehm GC).
  Для personal-use сервера (1–5 сессий) приемлемо; выход — Фаза 2a
  web-плана (per-agent сервисы).
- **Курсор и ретрансляция**: если демон упал между `ev:assistant` и
  реконнектом, недостающие ответы добираются из `wire.jsonl` по факту
  (разовый resync при реконнекте, не постоянный хвост) — компромисс,
  который стоит зафиксировать при реализации v2.
- **Пуш-фреймы в TUI-режиме**: TUI сегодня не читает из сокета ничего —
  потребуется `each_line`-читатель, не ломающий существующих клиентов
  (h2code-remote пишет и не читает; надо проверить, что чтение не
  заблокирует его одностороннюю запись).
