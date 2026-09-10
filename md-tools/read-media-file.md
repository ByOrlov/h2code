# ReadMediaFile tool — план портирования из JS в Crystal

> Источник: `packages/agent-core-v2/src/agent/media/`:
> `tools/read-media.ts` + `read-media.md`,
> `file-type.ts` (detectFileType + sniffImageDimensions + MEDIA_SNIFF_BYTES),
> `image-compress.ts` (compressImageForModel + cropImageForModel +
> IMAGE_BYTE_BUDGET + MAX_IMAGE_DECODE_BYTES + resolveMaxImageEdgePx +
> resolveReadImageByteBudget + formatByteSize),
> `image-format-policy.ts` (buildImageConversionGuidance +
> isModelAcceptedImageMime),
> `image-originals.ts`, `imageConfigBridge.ts`, `mediaToolsRegistrar.ts`,
> `registerMediaTools.ts`, `configSection.ts`.

Цель — 1 тул `Tools::ReadMediaFile` в `h2code.cr/src/tools/read_media.cr`,
регистрируемый **только** если активная модель поддерживает image/video
input.

---

## 1. Контракт

### 1.1. `name`

`"ReadMediaFile"`.

### 1.2. `description`

Template + capability-tail (см. `buildDescription` в JS):

Head (`read-media.md` с подставленным `MAX_MEDIA_MEGABYTES`):
```
Read media content from a file.

**Tips:**
- Make sure you follow the description of each tool parameter.
- A `<system>` tag accompanies the media content; it summarizes the mime type, byte size and, for images, the original pixel dimensions, and states how the image was delivered (untouched, downsampled, cropped, or native resolution). When outputting coordinates, give relative coordinates first and compute absolute coordinates from the original image size. After generating or editing media via commands or scripts, read the result back before continuing.
- Large images are downsampled by default when automatic compression can safely fit them within model limits, which can blur fine detail (small text, dense UI). Compute absolute coordinates from the original dimensions reported in the `<system>` block, never by measuring the displayed copy. When the `<system>` tag reports downsampling and you need that detail, call this tool again with the `region` parameter (original-image pixel coordinates) to view a crop at full fidelity, or set `full_resolution` to true when the whole file fits the per-image byte limit. Re-reading the same file without these parameters just reproduces the same downsampled image.
- If automatic compression cannot safely produce an image within model limits, the tool returns an error and does not send the original image. Follow the error: use Bash or an available image-processing tool to create a smaller copy, then read that copy. Do not retry the unchanged file.
- The system will notify you when there is anything wrong when reading the file.
- This tool is a tool that you typically want to use in parallel. Always read multiple files in one response when possible.
- This tool can only read image or video files. To read text files, use the Read tool. To list directories, use `ls` via Bash for a known directory, or Glob for pattern search.
- If the file doesn't exist or path is invalid, an error will be returned.
- The maximum size that can be read is 100MB. An error will be returned if the file is larger than this limit.
- The media content will be returned in a form that you can directly view and understand.

**Capabilities**
```

Затем **capability-tail** (зависит от `ModelCapability`):
- `image_in && video_in` → `- This tool supports image and video files for the current model.`
- `image_in && !video_in` →
  ```
  - This tool supports image files for the current model.
  - Video files are not supported by the current model.
  ```
- `!image_in && video_in` →
  ```
  - This tool supports video files for the current model.
  - Image files are not supported by the current model.
  ```
- `!image_in && !video_in` → тул вообще не регистрируется (см. §3).

### 1.3. `parameters`

```json
{
  "type": "object",
  "properties": {
    "path": {
      "type": "string",
      "description": "Path to an image or video file. Relative paths resolve against the working directory; a path outside the working directory must be absolute. Directories and text files are not supported."
    },
    "region": {
      "type": "object",
      "properties": {
        "x": { "type": "integer", "minimum": 0, "description": "Left edge of the crop, in original-image pixels." },
        "y": { "type": "integer", "minimum": 0, "description": "Top edge of the crop, in original-image pixels." },
        "width": { "type": "integer", "minimum": 1, "description": "Crop width, in original-image pixels." },
        "height": { "type": "integer", "minimum": 1, "description": "Crop height, in original-image pixels." }
      },
      "required": ["x", "y", "width", "height"],
      "additionalProperties": false,
      "description": "Images only: view just this rectangle of the image (original-image pixel coordinates). Use after a downsampled full view to inspect fine detail — a region within the size limits is delivered at full fidelity."
    },
    "full_resolution": {
      "type": "boolean",
      "description": "Images only: skip the default downscaling and view at native resolution. Fails with an explicit error when the payload would exceed the per-image byte limit; use region for files that large."
    }
  },
  "required": ["path"],
  "additionalProperties": false
}
```

---

## 2. Константы / лимиты

| Имя                          | Значение                | Источник                    |
|------------------------------|-------------------------|-----------------------------|
| `MAX_MEDIA_MEGABYTES`        | `100`                   | read-media.ts               |
| `MAX_MEDIA_BYTES`            | `100 * 1024 * 1024`     | read-media.ts               |
| `MEDIA_SNIFF_BYTES`          | ~ `4096`                | file-type.ts                |
| `IMAGE_BYTE_BUDGET`          | ~ `6 * 1024 * 1024`     | image-compress.ts           |
| `MAX_IMAGE_DECODE_BYTES`     | ~ `50 * 1024 * 1024`    | image-compress.ts           |
| max-edge                     | ~ `2048` px (model-dependent) | image-compress.ts      |

Точные значения — см. `image-compress.ts` (env-overridable через config).

---

## 3. Регистрация (capability-gated)

`registerMediaTools` (`mediaToolsRegistrar.ts`) регистрирует
`ReadMediaFile` только если:

```crystal
if capabilities.image_in || capabilities.video_in
  tools.register(Tools::ReadMediaFile.new(fs, env, workspace, capabilities, video_uploader, telemetry))
end
```

Для моделей **без** image_in и video_in тул не появляется в `tools.list`.

---

## 4. `resolveExecution` (validation)

1. Path resolution: `path = resolve_path_access_path(args.path, env, workspace, "read")`.
   - Uses shared path resolver из `Tools::Read` / `Tools::Write`.
2. `accesses: ToolAccesses.readFile(path)`.
3. `description: "Reading media: #{args.path}"`.
4. `display: { kind: "file_io", operation: "read", path }`.
5. `approvalRule: literalRulePattern("ReadMediaFile", path)`.
6. `matchesRule: matchesPathRuleSubject(ruleArgs, path, { cwd, home_dir, path_class })`.

---

## 5. `execute` — алгоритм

1. Если `args.path` пустой → `ToolResult.error("File path cannot be empty.")`.
2. Прочитать header (первые `MEDIA_SNIFF_BYTES` байт) → `detect_file_type(path, header, "media")`.

### 5.1. Branch by file kind

- `text` → `ToolResult.error("\"#{args.path}\" is a text file. Use Read to read text files.")`.
- `unknown` →
  `ToolResult.error("\"#{args.path}\" is not a supported image or video file. Use Read for text files, or Bash or an MCP tool for other binary formats.")`.
- `image` без `capabilities.image_in` →
  `ToolResult.error("The current model does not support image input. Tell the user to use a model with image input capability.")`.
- `image` + mime не accepted →
  `build_image_conversion_guidance(path, mime, os_kind)` (например
  WebP/HEIC для моделей без native поддержки — рекомендация
  сконвертировать).
- `video` без `capabilities.video_in` → аналогично image-case.
- иначе → продолжить.

### 5.2. File size checks

```
stat = fs.stat(safe_path)
stat.size == 0 → "\"#{args.path}\" is empty."
stat.size > MAX_MEDIA_BYTES →
  "\"#{args.path}\" is #{stat.size} bytes, which exceeds the maximum 100MB for media files."
```

### 5.3. Param-vs-kind checks

- `video && (region || full_resolution)` →
  `"region and full_resolution apply only to image files."`.
- `image && stat.size > MAX_IMAGE_DECODE_BYTES && (region || full_resolution)` →
  `build_image_decode_limit_error(stat.size)`.
- `image && region.nil? && full_resolution && stat.size > IMAGE_BYTE_BUDGET` →
  `build_full_resolution_limit_error(path, stat.size)`.
- `image && region.nil? && !full_resolution && stat.size > MAX_IMAGE_DECODE_BYTES && stat.size > read_byte_budget` →
  `build_image_delivery_limit_error(stat.size, read_byte_budget, max_edge)`.

### 5.4. Read full data + branch

```
data = fs.read(safe_path)
dimensions = (fileType.kind == "image") ? sniff_image_dimensions(data) : nil

if image
  if region
    outcome = crop_image_for_model(data, mime, region, skip_resize: full_resolution, telemetry: ...)
    outcome.ok == false → "Cannot read region from \"#{args.path}\": #{outcome.error}"
    base64 = Base64.strict_encode64(outcome.data)
    media_part = { type: "image_url", image_url: { url: "data:#{outcome.mime_type};base64,#{base64}" } }
    delivery = { kind: "crop", width: outcome.width, height: outcome.height,
                 byte_length: outcome.final_byte_length, mime_type: outcome.mime_type,
                 region: outcome.region, resized: outcome.resized }
    dimensions = { width: outcome.original_width, height: outcome.original_height }
  elsif full_resolution
    if data.size > IMAGE_BYTE_BUDGET
      → build_full_resolution_limit_error(path, data.size)
    end
    base64 = Base64.strict_encode64(data)
    media_part = { type: "image_url", image_url: { url: "data:#{mime};base64,#{base64}" } }
    delivery = { kind: "full", width: dimensions&.width || 0, height: dimensions&.height || 0,
                 byte_length: data.size, mime_type: mime }
  else
    compressed = compress_image_for_model(data, mime, byte_budget: read_byte_budget, max_edge: max_edge, ...)
    if compressed.final_byte_length > read_byte_budget || [compressed.width, compressed.height].max > max_edge
      → build_image_delivery_limit_error(compressed.final_byte_length, read_byte_budget, max_edge)
    end
    base64 = Base64.strict_encode64(compressed.data)
    media_part = { type: "image_url", image_url: { url: "data:#{compressed.mime_type};base64,#{base64}" } }
    delivery = { kind: compressed.changed ? "downsampled" : "untouched", ... }
    dimensions = { width: compressed.original_width, height: compressed.original_height } if compressed.changed
  end
elsif video_uploader
  media_part = video_uploader.call(data, mime, File.basename(safe_path))
else
  base64 = Base64.strict_encode64(data)
  media_part = { type: "video_url", video_url: { url: "data:#{mime};base64,#{base64}" } }
end
```

### 5.5. Output

```crystal
tag = (file_type.kind == "image") ? "image" : "video"
open_text = "<#{tag} path=\"#{safe_path}\">"
close_text = "</#{tag}>"

note = build_media_note(kind: file_type.kind, mime_type: file_type.mime_type,
                       byte_size: stat.size, dimensions: dimensions, delivery: delivery)

output = [
  { type: "text", text: open_text },
  media_part,
  { type: "text", text: close_text },
]

ToolResult.new(output: output, note: note, is_error: false)
```

`output` — массив из 3 ContentPart (text + media + text). `note` —
строка для model-context, не для TUI.

---

## 6. `build_media_note` (verbatim structure)

Формат: `<system>...</system>` (single-line, joined by space).

```
<system>Read image file. Mime type: image/png. Size: 234567 bytes. Original dimensions: 800x600 pixels. The attached image was downsampled to 768x576 pixels (image/jpeg, 102400 bytes) to fit model limits; fine detail may be lost. To inspect fine detail, call ReadMediaFile again with the region parameter (original-image pixel coordinates) to view a crop at full fidelity. If you need to output coordinates, output relative coordinates first and compute absolute coordinates using the original image size. If you generate or edit images or videos via commands or scripts, read the result back immediately before continuing.</system>
```

Parts (подробно):

- base:
  - `"Read #{kind} file."`
  - `"Mime type: #{mime_type}."`
  - `"Size: #{byte_size} bytes."`
- image + dimensions:
  - `"Original dimensions: #{w}x#{h} pixels."`
- delivery kind:
  - `downsampled`:
    ```
    "The attached image was downsampled to #{w}x#{h} pixels (#{mime}, #{format_byte_size(bytes)}) to fit model limits; fine detail may be lost."
    "To inspect fine detail, call ReadMediaFile again with the region parameter (original-image pixel coordinates) to view a crop at full fidelity."
    ```
  - `crop` (с region):
    ```
    "Showing region (x=#{x}, y=#{y}, width=#{w}, height=#{h}) of the original image#{resized ? ", downsampled to #{dw}x#{dh} pixels" : " at native resolution"}."
    "To output coordinates in original-image pixels, locate them within this crop and add the region offset (x=#{x}, y=#{y})."
    ```
  - `full`:
    `"Shown at native resolution; no downscaling applied."`
  - `untouched`: (ничего)
- image + dimensions + delivery != crop:
  ```
  "If you need to output coordinates, output relative coordinates first and compute absolute coordinates using the original image size."
  ```
- final (всегда):
  ```
  "If you generate or edit images or videos via commands or scripts, read the result back immediately before continuing."
  ```

Join через `" "`. Обернуть в `<system>...</system>`.

---

## 7. Error message templates (verbatim)

### `build_image_delivery_limit_error`

```
"Image is too large to send safely after compression (#{final} bytes; limit #{budget} bytes and #{max_edge}px on the longest edge). The original image was not sent to the model. Do not retry the same file unchanged. Use Bash or an available image-processing tool to create a smaller copy within both limits, then call ReadMediaFile on the smaller copy."
```

### `build_image_decode_limit_error`

```
"Image is too large to process safely for region or full_resolution (#{final} bytes; safe decode limit #{MAX_IMAGE_DECODE_BYTES} bytes). The original image was not sent to the model. Do not retry the same file unchanged. Use Bash or an available image-processing tool to create a smaller copy or crop the needed region into a separate image, then call ReadMediaFile on the resulting file."
```

### `build_full_resolution_limit_error`

```
"\"#{path}\" is #{final} bytes (#{format_byte_size(final)}), over the #{IMAGE_BYTE_BUDGET}-byte (#{format_byte_size(IMAGE_BYTE_BUDGET)}) per-image limit, so full_resolution cannot be honored. Use region to view a crop at full fidelity instead."
```

### `format_byte_size(n)`

- `< 1024` → `"#{n}B"`
- `< 1024*1024` → `"#{(n/1024).round(1)}KiB"`
- иначе → `"#{(n/1024/1024).round(1)}MiB"`

---

## 8. `MediaToolsRegistrar` абстракция

```crystal
class MediaToolsRegistrar
  def self.register(tools : ToolRegistry, fs : HostFileSystem, env : HostEnvironment,
                    workspace : WorkspaceConfig, capabilities : ModelCapability,
                    video_uploader : VideoUploader? = nil, telemetry : TelemetryService? = nil) : Nil
    return unless capabilities.image_in || capabilities.video_in
    tools.register(Tools::ReadMediaFile.new(fs, env, workspace, capabilities, video_uploader, telemetry))
  end
end
```

---

## 9. Image compression / crop — зависимости

В Crystal:

- Использовать `ImageMagick` (через shell-out или `magick` shard) для
  resize/crop/convert.
- `compress_image_for_model(data, mime, byte_budget, max_edge)`:
  1. Decode bytes → image.
  2. If longest edge > max_edge → downscale.
  3. Re-encode to JPEG/WebP quality, итеративно снижая quality пока
     bytes ≤ byte_budget.
  4. If can't meet → return data anyway, `changed: true`,
     `final_byte_length > byte_budget` — caller вернёт error.
- `crop_image_for_model(data, mime, region, skip_resize)`:
  1. Decode.
  2. Crop to `region`.
  3. If `!skip_resize && longest_edge > max_edge` → downscale.
  4. Re-encode.
  5. Return `{ ok: true, data, mime_type, width, height,
            original_width, original_height, region, resized,
            final_byte_length }`.

Альтернатива — делегировать в JS-sidecar процесс (Node worker). Для
MVP Crystal — shell-out в `convert`/`magick` из ImageMagick.

`sniff_image_dimensions(data)` — парсинг PNG/JPEG/GIF/WebP header для
получения ширины/высоты без полного decode.

`detect_file_type(path, header, mode)` — magic-byte sniffing
(см. `file-type.ts`).

---

## 10. План реализации (чек-лист)

- [x] Прочитать JS: `tools/read-media.ts` + `.md`,
      `file-type.ts`, `image-compress.ts`, `image-format-policy.ts`,
      `image-originals.ts`, `imageConfigBridge.ts`,
      `mediaToolsRegistrar.ts`, `registerMediaTools.ts`,
      `configSection.ts`, `webp-decode.ts`.
- [x] Описать контракт в `md-tools/read-media-file.md`.
- [x] Реализовать `detect_file_type` (magic-byte sniffing для PNG/JPEG/
      GIF/WebP/MP4/WebM).
- [x] Реализовать `sniff_image_dimensions` (header-only).
- [x] Реализовать `compress_image_for_model` — `ImageMagickImageProcessor`
      (shell-out `magick`/`convert`, downscale-ladder до byte budget;
      pass-through fallback когда ImageMagick нет).
- [x] Реализовать `crop_image_for_model` (включая budget-fit ladder).
- [x] Реализовать `format_byte_size`, error message templates,
      `build_media_note`.
- [x] Реализовать `Tools::ReadMediaFile` (§1–§7).
- [ ] Реализовать `MediaToolsRegistrar` (capability-gated). Частично:
      capabilities вайрятся статически (image_in=true, video_in=false) в
      `h2code.cr` / `acp/server.cr`; динамический per-model gating не
      портирован (в Crystal нет таблицы model capabilities).
- [x] Добавить `ContentPart` тип `image_url` / `video_url` в Crystal message protocol.
- [ ] Подключить `video_uploader` для провайдеров, требующих upload-to-URL
      (например Moonshot video API) — отложено (не требуется для текущих
      провайдеров; inline data-URL fallback работает).
- [x] Тесты в `spec/tools/read_media_spec.cr`:
  - [x] text-file reject; unknown-binary reject; empty-file reject;
        oversize-file reject; image-without-capability reject;
        video-without-capability reject.
  - [x] image default read (downsampled / untouched).
  - [x] image with `region` (crop).
  - [x] image with `full_resolution` (success + over-budget reject).
  - [x] decode-limit reject (huge file + region/full_resolution).
  - [x] delivery-limit reject (huge default read).
  - [x] unsupported-mime guidance.
  - [x] `<system>` note content checks.
- [x] Обновить `FIX-TOOLS.md`: отметить строку #19 выполненной.
- [x] Рантайм-вайринг: `Media.fs` / `Media.capabilities` / `Media.image_processor`
      назначаются в `h2code.cr` и `acp/server.cr` (раньше тул всегда отвечал
      "not initialized").
- [x] Конвертация data-URL в tool result → `ImageContent` part в loop —
      реализовано: `ToolResult.media` (data-URL канал) →
      `Loop::ToolBatch` → `LLM::Message.tool_with_media`
      (TextContent + ImageContent/VideoContent parts) →
      `Context::Memory#add_tool_result_parts`. Base64 больше не ходит
      по текстовому контексту. Демо: `rake mock:image`
      (headless: `H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=image ./h2code -p x --yolo`).
- [x] Фикс `LocalMediaFileSystem#read`: файл читался как UTF-8 String и
      падал на бинарных данных («Invalid multibyte sequence»); теперь
      читается как байты (реальный FS-путь не покрывался спеками —
      гонялись только через FakeMediaFS).

---

## 11. Расхождения / допущения

- Image processing: JS использует `sharp` (native binding). В Crystal —
  ImageMagick shell-out как минимум; pure-Crystal (например `stumpy_png`)
  только для PNG MVP.
- WebP decode в JS — wasm-decoder. В Crystal — ImageMagick handles WebP.
- Video upload — провайдер-specific. В Crystal — Moonshot API upload
  endpoint (если требуется) или inline data: URL fallback.
- Telemetry (`ImageCompressionTelemetry`) — опциональная; в Crystal
  hook через `TelemetryService` если есть.
- `os_kind` (для conversion guidance) — в Crystal `{{flag?(:darwin)}}`
  compile-time или runtime detect.
- Output как массив ContentPart — текущий Crystal `ToolResult` должен
  поддерживать multi-part output. Расширить `ToolResult.output` с
  массива parts вместо plain string.
- Registration time — тул регистрируется per-session/per-model. Crystal
  `ToolRegistry` должен поддерживать late registration после определения
  capabilities.
