# Images: нативная доставка медиа в модель (parity с JS-оригиналом)

Статус: **готово** (кроме out-of-scope пунктов ниже). Ссылки: контракт —
`md-tools/read-media-file.md`.

## Проблема

`ReadMediaFile` встраивает `data:image/...;base64,...` прямо в текст
`ToolResult.content` (`src/tools/read_media.cr:777`). Loop кладёт его в
`Message.tool(content, id)` как plain text. Провайдеры сериализуют text —
`ImageContent`/`VideoContent` есть в протоколе (`src/llm/types.cr:229,281`),
но никто их не создаёт. Итог: base64 раздувает контекст как текст, и модель
не получает картинку как multimodal part.

При этом инфраструктура уже готова: `ContentPart.to_wire_json` сериализует
parts-массив, компакшн заменяет media на `[image]`-маркеры
(`src/context/compaction.cr:275`), JSON round-trip работает через
discriminator. Разрыв только на участке ToolResult → Message.

## План

1. **`Tools::ToolResult`** (`src/tools/tool.cr`): добавить
   `property media : Array(String)` — data-URL'ы (без зависимости на LLM).
   `success`/`error` не меняются; тул заполняет `media` отдельно.

2. **`Tools::ReadMediaFile`** (`src/tools/read_media.cr`): data-URL уходит в
   `result.media`, текстовый output = теги `<image path=...>`/`</image>` +
   `<system>` note, без base64. TUI/transcript/текстовый бюджет перестают
   тащить base64.

3. **`LLM` helpers** (`src/llm/types.cr`):
   - `ContentPart.from_data_url(url) : ContentPart?` — `data:image/…` →
     `ImageContent`, `data:video/…` → `VideoContent`.
   - `Message.tool_parts(parts : Array(ContentPart), tool_call_id)` —
     конструктор tool-сообщения с parts.

4. **`Loop::ToolBatch`** (`src/loop/tool_batch.cr`):
   - `ToolBatchResult` получает `media : Array(String)`.
   - `execute_approved`: `result.media` пробрасывается в batch result;
     `sanitize_output` / `Budget.budget` применяются только к тексту.
   - `assemble_results`: при наличии media —
     `Message.tool_parts([TextContent(content)] + media_parts, id)`.

5. **`Context::Memory#add_tool_result`** (`src/context/memory.cr`): overload
   c `Array(ContentPart)` — кладёт ту же parts-структуру в историю.

6. **Провайдеры**: ничего менять не надо — все OpenAI-совместимы и ходят
   через `Message#to_wire_json`, который уже умеет parts-массив (проверить
   спеком на wire-JSON).

7. **Mock-скрипт + rake** (`src/llm/mock_provider.cr`, `Rakefile`):
   `IMAGE_DEMO_SCRIPT` — шаг 1: `ToolCallPart` на `ReadMediaFile` c
   `logo.png`; шаг 2: финальный текст. Задача `rake mock:image` прогоняет
   TUI-сессию с `H2CODE_MOCK_SCRIPT=image`.

8. **Спеки**:
   - `spec/tools/read_media_spec.cr`: обновить успех-кейсы — base64 теперь
     в `result.media`, не в `content`.
   - Новый спек: ToolBatch собирает parts-сообщение (TextContent +
     ImageContent с data-URL), wire-JSON содержит `image_url` в `content`
     role=tool.

9. **Доки**: отметить пункт «Конвертация data-URL → ImageContent» в
   `md-tools/read-media-file.md`.

## Результат

- `ToolResult.media` (`src/tools/tool.cr`) — data-URL канал, без зависимости
  на LLM.
- `ReadMediaFile`: base64 уходит в `result.media`, текст = теги + `[media: …]`
  + `<system>` note.
- `LLM::ContentPart.from_data_url` + `Message.tool_parts` / `tool_with_media`
  (`src/llm/types.cr`).
- `Loop::ToolBatch` (`src/loop/tool_batch.cr`): media пробрасывается мимо
  text-budget/sanitize; `assemble_results` собирает parts-сообщение.
- `Context::Memory#add_tool_result_parts` (`src/context/memory.cr`).
- Провайдеры: без изменений — `Message#to_wire_json` уже сериализует
  parts-массив (`image_url` в content role=tool).
- Фикс `LocalMediaFileSystem#read` (бинарное чтение вместо UTF-8 String).
- Mock: `IMAGE_DEMO_SCRIPT` (`H2CODE_MOCK_SCRIPT=image`), rake-задача
  `mock:image`; headless-проверка прошла (logo.png → image part).
- Спеки: `spec/tools/read_media_spec.cr` (media-канал), новый кейс в
  `spec/loop/tool_batch_spec.cr` (parts + wire JSON + контекст).
  152 примера по затронутым областям — зелёные, ameba чист.

## Этап 2: вставка картинки из буфера обмена (порт kimi-code `ImagePastePort`)

Источник JS: `apps/kimi-code/src/utils/clipboard/clipboard-image.ts` +
`clipboard-common.ts`, `src/tui/utils/image-attachment-store.ts`,
`src/tui/utils/image-placeholder.ts`, `clipboard-image-hint.ts`.

Статус: **готово** (кроме out-of-scope ниже).

### Результат

- `src/tui/image_paste_port.cr` — `ImagePastePort` (+`ClipboardMedia`):
  env-override `H2CODE_CLIPBOARD_FILE`, Wayland `wl-paste`, X11 `xclip`,
  `text/uri-list` → файлы (image-bytes / video-by-ext), WSL и Win32
  PowerShell temp-PNG, macOS osascript file URLs. Runner инъектируемый,
  бинарно-безопасные shell-out'ы с channel+select таймаутами.
- `src/tui/media_attachment_store.cr` — `MediaAttachmentStore` (id,
  плейсхолдеры `[image #N (W×H)]` / `[video #N label]`) +
  `extract_parts` — порт `extractMediaAttachments` (interleaved parts,
  видео → `<video path>` тег, неразрешённые плейсхолдеры остаются текстом).
- Ctrl+V (байт 0x16 → `Key::CtrlV`) и Alt+V (ESC v): paste-хендлер в
  `input_controller.cr` — в fiber'е, sniff dims + компрессия > budget,
  плейсхолдер в редакторе.
- Turn-плинг: `submit_message` → parts → `QueuedMessage`/`start_turn` →
  `run_turn_cb(String, Bool, parts)` → `Agent#run_goal_turn(parts:)` →
  `Memory#add_user_parts`. Транскрипт хранит текст с плейсхолдерами.
- `/new`, `/clear` сбрасывают стор.
- Демо: `rake mock:paste` (генерирует текстовую картинку через
  ImageMagick + `H2CODE_CLIPBOARD_FILE` + mock-скрипт `imagepaste`).
- Спеки: `spec/tui/image_paste_spec.cr` (11: port fake-runner, uri-list,
  override, store/extract, CtrlV-парсинг) + end-to-end кейс в
  `spec/tui/app_spec.cr` (submit → parts в run_turn_cb). PTY-драйвер
  `tmp/pty_paste_check.py` прогоняет реальный TUI: Ctrl+V → плейсхолдер →
  submit → ответ mock — PASS.
- Полный `rake spec`: 1598 примеров, 0 падений; ameba чист.

### Этап 2.1: интеграционные тесты + фикс реального буфера

Юнит-спеки с fake-runner'ом не ловили поведение живого xclip —
пользовательский репорт «не вставляется напрямую из буфера» вскрыл
два бага, найденных интеграционным тестом:

- **xclip serve-anything bug**: xclip отдаёт ЛЮБОЙ контент под запрос
  `-t image/png` (текстовый буфер возвращал текстовые байты как
  «image/png»). Фикс: `clipboard_image` — sniff-валидация прочитанных
  байтов через `Tools.detect_media_file_type`, приём только при точном
  совпадении mime (src/tui/image_paste_port.cr).
- **xclip -i fork-deadlock**: сидирование буфера через `Process.run` с
  pipe-выводом зависало навсегда (демон xclip наследует pipe, EOF не
  приходит). В спеке вывод уходит в /dev/null; порт сам защищён
  channel+select-таймаутами.
- Дополнительно: `image_paste_port.cr` теперь сам требует `"uri"`
  (раньше тянулось транзитивно из полного приложения).

Новые проверки:

- `spec/integration/clipboard_paste_spec.cr` — живой clipboard:
  seed PNG через xclip → порт с дефолтным runner'ом → roundtrip байтов;
  текстовый буфер → nil быстро (< 10 s). Soft-skip без бэкендов.
- `tmp/pty_paste_real.py` — PTY-драйвер реального TUI с живым буфером
  (без `H2CODE_CLIPBOARD_FILE`): Ctrl+V → плейсхолдер → submit →
  ответ mock. PASS.
- Полный `rake spec`: 1601 пример, 0 падений; `rake spec:integration` —
  16 примеров; ameba чист.

### Этап 2.2: Ctrl+V в современных терминалах

Репорт «в kimi-code Ctrl+V работает, в h2code — нет» вскрыл главную
причину: парсер ввода понимал только легаси-байт 0x16, а терминалы с
расширенными keyboard-протоколами шлюут Ctrl+V иначе (kimi-code/pi-tui
понимает все форматы — см. `packages/pi-tui/src/keys.ts`).

Фикс (`src/tui/input.cr`, `parse_csi` + `key_event_for_codepoint`):

- kitty CSI-u: `ESC [ 118 ; 5 u` → `Key::CtrlV` (и прочие ctrl-буквы
  по битовому полю модификаторов: 1=shift, 2=alt, 4=ctrl);
- xterm modifyOtherKeys: `ESC [ 27 ; 5 ; 118 ~` → `Key::CtrlV`;
- alt/shift-комбинации без ctrl → char-event с флагами (как
  ESC-легаси-путь); unmapped ctrl-комбо → Unknown (как сырые байты).

Проверки: спеки на все три формата (`spec/tui/image_paste_spec.cr`,
14 примеров); PTY-драйвер `tmp/pty_paste_real.py` c `CTRLV_SEQ=
legacy|kitty|xterm` — все три кодировки на живом clipboard-буфере дают
плейсхолдер + submit + ответ mock (PASS×3). Полный `rake spec`:
1604 примера, 0 падений; ameba чист.

### Этап 2.3: Alacritty и kitty keyboard protocol

Диагностика через `H2CODE_DEBUG_INPUT` показала: Ctrl+V **вообще не
доходил** до приложения — ни 0x16, ни CSI-u. Причина: у пользователя
Alacritty (`ALACRITTY_WINDOW_ID`), где Ctrl+V по умолчанию занят
терминальным paste; при картинке в буфере вставлять нечего → в
приложение уходит ноль байт. kimi-code работает, потому что pi-tui
**включает kitty keyboard protocol** (`terminal.ts`: push flags 7 +
negotiation) — при активном протоколе терминал отдаёт клавиши
приложению вместо своих дефолтных биндингов.

Фикс:

- `src/tui/terminal.cr`: `raw!` шлёт `ESC [ > 7 u` (push flags 7:
  disambiguate + event types + alternate keys), `restore!` — `ESC [ < u`
  (pop). Неподдерживающие терминалы последовательность игнорируют.
- `src/tui/input.cr`: CSI-u понимает sub-параметры `<mods>:<event-type>`
  (release `:3` дропается), control-codepoints из disambiguate-режима
  (Esc `ESC[27u`, Enter `ESC[13u`, Tab `ESC[9u`, Backspace `ESC[127u`,
  Shift+Enter `ESC[13;2u`).

Проверки: спеки — 16 примеров (включая release-drop и disambiguated
control keys); PTY `tmp/pty_paste_real.py` × {legacy 0x16, kitty
`ESC[118;5u`, xterm `ESC[27;5;118~`} — PASS ×3 на живом буфере. Полный
`rake spec`: 1606 примеров, 0 падений; ameba чист.

### Внеscope этапа 2 (как в JS, но позже)

- Footer-подсказка «Image in clipboard · Ctrl+V to paste»
  (`clipboard-image-hint.ts`).
- Сохранение original-байтов paste-time компрессии + caption на submit
  (`ImageAttachment.original`).
- Переписывание плейсхолдеров в аргументах slash-команд
  (`rewriteMediaPlaceholders`) — сейчас в `/cmd` аргументах плейсхолдеры
  остаются литеральным текстом.

## Внеscope (остаётся как раньше)

- Per-model capability gating (`MediaToolsRegistrar`) — хардкод
  image_in/video_in.
- `video_uploader` — inline data-URL fallback.
- Image format policy (`isModelAcceptedImageMime`, conversion guidance).
- Env-override лимитов сжатия, телеметрия.
