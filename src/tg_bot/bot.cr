require "json"
require "../home_port"
require "../notify/config"
require "../hooks/engine"
require "../config/config"
require "../transcription/client"
require "../duration_format"
require "./config"
require "./api"
require "./callbacks"
require "./link"
require "./manager"
require "./state"
require "./keyboards"
require "./markdown"

module TgBot
  # The Telegram front-end (see plans/telegram_bot.md): a long-polling loop
  # that routes chat messages into resident agent sessions and session events
  # back into the chat.
  #
  # Routing rules (lessons from claude-tg-bot):
  #   * plain text goes to the chat's active session, batched (~0.8 s pause
  #     after the last message — a forwarded flurry arrives as one prompt);
  #   * a reply to any of a session's messages routes into that session and
  #     makes it active;
  #   * every button carries its session id, so an answer lands exactly where
  #     the question came from;
  #   * an exception anywhere is reported in the chat, never only in the log.
  #
  # MVP strings are English — i18n of the bot surface is Phase 2.
  class Bot
    BATCH_PAUSE = 0.8.seconds
    MAX_TEXT    = 4000

    HELP = <<-TEXT
      h2code agent — commands:

      /sessions — live sessions (cards, model, mode)
      /new [dir] — start a new agent session (no arg → pick from dirs)
      /recent — closed sessions (resume in the same dir)
      /rename <name> — name the active session ('-' resets)
      /dirs — manage configured directories
      /status — active session status
      /interrupt — cancel the current turn
      /stop — gracefully stop the active session
      /id — show your Telegram id
      /help — this text

      Plain text is a prompt for the active session (a reply to any of its
      messages targets that session). Files are downloaded and attached to
      the prompt as paths. Voice messages are transcribed (h2voice) and
      sent as prompts.
      TEXT

    # Persistent reply-keyboard buttons (sent with /start and /help): each
    # button sends its own text, which is parsed as the command inside it.
    REPLY_BUTTONS = [
      ["🖥 /sessions", "🆕 /new"],
      ["🕘 /recent", "📊 /status"],
      ["⛔ /interrupt", "🔴 /stop"],
    ] of Array(String)

    # Bot-menu registration (the "/" autocomplete on the phone).
    COMMANDS = [
      {"sessions", "live sessions"},
      {"new", "start a new session"},
      {"recent", "closed sessions"},
      {"rename", "name the active session"},
      {"dirs", "configured directories"},
      {"status", "active session status"},
      {"interrupt", "cancel the current turn"},
      {"stop", "stop the active session"},
      {"id", "show your Telegram id"},
      {"help", "command help"},
    ] of {String, String}

    # The next plain text a chat sends is consumed by a pending flow
    # (rename / find / manual path) instead of reaching the agent.
    record PendingInput, kind : Symbol, sid : String = ""

    getter config : Config
    getter api : Api
    getter manager : Manager
    getter state : State

    @pair_mode : Bool
    @lock = Mutex.new
    @active = {} of Int64 => String           # chat → active session id
    @session_chat = {} of String => Int64     # session id → owning chat
    @by_message = {} of String => String      # "chat:msg_id" → session id
    @questions = {} of String => QuestionState # "sid:qid" → request state
    @cards = {} of String => Card             # "sid:qid:qi" → card state
    @typing = {} of String => Typing
    @inbox = {} of Int64 => Array(String)
    @inbox_deadline = {} of Int64 => Time::Instant
    @flushing = Set(Int64).new
    @inbox_lock = Mutex.new
    @last_update_id = Int64::MIN
    @state : State                       # persistent journal (names, recent)
    @session_dir = {} of String => String # live sid → working directory
    @input = {} of Int64 => PendingInput # chat → flow awaiting plain text
    @last_list = {} of Int64 => NamedTuple(find: String?, page: Int32)
    @started_at = Time.utc

    # One card per question of a request. `done` cards are removed from
    # @cards; a later button press finds nothing and reports "expired".
    class Card
      getter chat_id : Int64
      getter message_id : Int64
      getter sid : String
      getter qid : String
      getter qi : Int32
      getter question : String
      getter header : String
      getter labels : Array(String)
      getter? multi : Bool
      property selected = Set(Int32).new

      def initialize(@chat_id, @message_id, @sid, @qid, @qi, @question,
                     @labels, @multi, @header = "")
      end

      def key : String
        "#{@sid}:#{@qid}:#{@qi}"
      end
    end

    # Per-request state: answers accumulate card by card; the request is
    # answered over the socket once every question is answered (op:answer
    # answers the whole AskUserQuestion form at once).
    class QuestionState
      getter sid : String
      getter qid : String
      getter answers = {} of String => JSON::Any
      property remaining = Set(Int32).new

      def initialize(@sid, @qid)
      end

      def key : String
        "#{@sid}:#{@qid}"
      end
    end

    class Typing
      getter chat_id : Int64
      getter message_id : Int64
      property last_text = ""

      def initialize(@chat_id, @message_id)
      end
    end

    def initialize(@config : Config, @pair_mode : Bool = false, api : Api? = nil,
                   @voice_client : H2code::Transcription::Client? = nil)
      @api = api || Api.new(@config.token)
      @state = State.new(State.default_path)
      @manager = Manager.new(
        @config,
        ->(sid : String, frame : JSON::Any) { on_event(sid, frame) },
        ->(sid : String) { on_died(sid) })
    end

    def run : Nil
      me = @api.get_me
      who = me["username"]?.try(&.to_s) || me["id"].to_s
      STDERR.puts "[tg-bot] logged in as @#{who}"
      begin
        @api.set_my_commands(COMMANDS)
      rescue ex
        STDERR.puts "[tg-bot] setMyCommands failed: #{ex.message}"
      end
      if @pair_mode
        STDERR.puts "[tg-bot] pair mode: waiting for a message to learn your Telegram id"
      end
      offset = first_unseen_offset
      STDERR.puts "[tg-bot] resuming from update #{offset}"
      loop do
        updates = begin
          @api.get_updates(offset)
        rescue ex
          STDERR.puts "[tg-bot] getUpdates failed: #{ex.message}, retrying"
          sleep 3.seconds
          [] of JSON::Any
        end
        updates.each do |u|
          uid = u["update_id"]?.to_s.to_i64?
          next unless uid
          offset = uid + 1
          next if uid <= @last_update_id # dedupe: never handle an update twice
          @last_update_id = uid
          begin
            handle_update(u)
          rescue ex
            if chat = update_chat_id(u)
              say(chat, "⚠️ #{ex.message}")
            end
          end
        end
      end
    end

    # Startup must NOT replay the bot's whole unconfirmed history (old texts
    # would become prompts, every old /new would spawn a session). Polling
    # with offset=-1 returns only the newest pending update; +1 confirms
    # everything before it and the daemon starts from a clean queue.
    # Retries forever — without a valid offset we must not fall back to 0.
    private def first_unseen_offset : Int64
      loop do
        latest = @api.get_updates(-1_i64, timeout: 0)
        return (Bot.last_update_id(latest) || 0_i64) + 1
      rescue ex
        STDERR.puts "[tg-bot] getUpdates probe failed: #{ex.message}, retrying"
        sleep 3.seconds
      end
    end

    # Highest update_id in a batch, nil when the batch is empty.
    def self.last_update_id(updates : Array(JSON::Any)) : Int64?
      updates.last?.try(&.["update_id"]?).try(&.to_s).try(&.to_i64?)
    end

    # --- Update dispatch ---

    def handle_update(update : JSON::Any) : Nil
      if cb = update["callback_query"]?
        handle_callback(cb)
      elsif msg = update["message"]?
        handle_message(msg)
      end
    end

    def handle_message(msg : JSON::Any) : Nil
      chat_id = msg["chat"]["id"].to_s.to_i64
      from = msg["from"]?.try(&.["id"]?).try(&.to_s).try(&.to_i64?)

      # Pair mode: the only job is to learn the caller's id from the first
      # message (the BotFather-flow shortcut; see plans/telegram_bot.md).
      if @pair_mode
        if from
          STDOUT.puts "telegram user id: #{from}"
          STDOUT.puts "add it to allowed_user_ids in #{Config.path} and restart without --pair"
          @api.send_message(chat_id,
            "Your Telegram id: #{from}.\nAdd it to allowed_user_ids in #{Config.path} and restart without --pair.")
          exit 0
        end
        return
      end

      return unless from && @config.allows?(from)

      text = msg["text"]?.try(&.to_s) || ""
      parts = text.split
      # A command may be prefixed by button emoji ("📊 /status" from the
      # reply keyboard) — find the first "/"-token instead of requiring the
      # text to start with it.
      if parts.any?(&.starts_with?('/'))
        handle_command(chat_id, from, parts)
        return
      end

      # A pending flow (rename / find / path) consumes the next plain text.
      pending = @lock.synchronize { @input.delete(chat_id) }
      if pending && !text.strip.empty?
        consume_input(chat_id, pending, text.strip)
        return
      end

      # Reply targeting: a reply to any of a session's messages routes the
      # prompt into that session and makes it the active one.
      if reply = msg["reply_to_message"]?
        rid = reply["message_id"]?.try(&.to_s).try(&.to_i64?)
        if rid && (sid = @lock.synchronize { @by_message["#{chat_id}:#{rid}"]? })
          @lock.synchronize { @active[chat_id] = sid }
        end
      end

      if msg["photo"]? || msg["document"]?
        handle_attachment(chat_id, msg, text)
      elsif msg["voice"]?
        # Transcription can take seconds-to-minutes — run it off the polling
        # loop so later updates are not stuck behind one long voice message.
        spawn(name: "tg-voice-#{chat_id}") { handle_voice(chat_id, msg) }
      elsif !text.strip.empty?
        enqueue(chat_id, text)
      end
    end

    def handle_command(chat_id : Int64, from : Int64, parts : Array(String)) : Nil
      cmd = parts.find(&.starts_with?('/')).try { |c| c.split('@').first.downcase } || ""
      case cmd
      when "/start", "/help"
        @api.send_keyboard(chat_id, HELP, REPLY_BUTTONS)
      when "/id"
        say(chat_id, "Your Telegram id: #{from}")
      when "/sessions", "/ls", "/list"
        render_sessions(chat_id, nil)
      when "/recent", "/history"
        render_history(chat_id, nil, 0)
      when "/new"
        arg = parts[1]? && !parts[1].starts_with?('/') ? parts[1] : nil
        if arg.nil? && @config.dirs.size > 1
          offer_dirs(chat_id)
        else
          start_session(chat_id, arg)
        end
      when "/rename"
        if sid = active_sid(chat_id)
          if parts.size > 1
            apply_rename(chat_id, sid, parts[1..].join(" "))
          else
            @lock.synchronize { @input[chat_id] = PendingInput.new(:rename, sid) }
            say(chat_id, "send the new name (or '-' to reset)")
          end
        else
          say(chat_id, "no active session")
        end
      when "/dirs"
        render_dirs(chat_id, nil)
      when "/usage"
        if (link = active_link(chat_id)) && (sid = active_sid(chat_id))
          say(chat_id, usage_text(link, sid))
        else
          say(chat_id, "no active session — /new to start one")
        end
      when "/status"
        if link = active_link(chat_id)
          s = link.status
          say(chat_id, "session #{active_sid(chat_id)}\nbusy: #{s["busy"]?}\n" \
                       "model: #{s["model"]?}\ncontext: #{s["context_pct"]?}%")
        else
          say(chat_id, "no active session — /new to start one")
        end
      when "/interrupt"
        if sid = active_sid(chat_id)
          if @manager.busy?(sid) == false
            say(chat_id, "session is idle — nothing to interrupt")
          else
            @manager.link(sid).try(&.interrupt)
            say(chat_id, "⛔ interrupting…")
          end
        else
          say(chat_id, "no active session")
        end
      when "/stop"
        if sid = active_sid(chat_id)
          @manager.stop(sid)
          say(chat_id, "stopping session #{sid}…")
        else
          say(chat_id, "no active session")
        end
      else
        say(chat_id, "unknown command — /help")
      end
    end

    def start_session(chat_id : Int64, arg : String?) : Nil
      dir = pick_dir(arg)
      unless dir
        allowed = @config.dirs.empty? ? Dir.current : @config.dirs.join(", ")
        say(chat_id, "unknown dir — allowed: #{allowed}")
        return
      end
      spawn_session(chat_id, dir)
    end

    # Spawns a resident session in an already-decided directory (from the
    # config picker, the journal's resume entry, or a manual path) and
    # records it in the persistent journal under its automatic name.
    def spawn_session(chat_id : Int64, dir : String) : Nil
      link = @manager.start_session(dir)
      name = auto_name(dir, link.sid)
      @lock.synchronize do
        @session_chat[link.sid] = chat_id
        @session_dir[link.sid] = dir
        @active[chat_id] = link.sid
      end
      @state.record_start(link.sid, dir, name, custom: false)
      # Inline command buttons addressed to this session — /stop by button
      # lands on exactly this sid even if another session became active.
      session_buttons = [
        {"📊 Status", Callback.build(Callback::Kind::Command, link.sid, "st")},
        {"⛔ Interrupt", Callback.build(Callback::Kind::Command, link.sid, "in")},
        {"🔴 Stop", Callback.build(Callback::Kind::Command, link.sid, "sp")},
      ] of {String, String}
      say(chat_id, "🟢 #{name} in #{Keyboards.tilde(dir)}", [session_buttons])
    rescue ex
      say(chat_id, "⚠️ failed to start session: #{ex.message}")
    end

    # Automatic session name: "<dir basename>-<sid prefix>" — unique per
    # session, readable in a phone list (claude-tg-bot convention).
    def auto_name(dir : String, sid : String) : String
      base = File.basename(dir)
      base = "session" if base.empty?
      "#{base}-#{sid[0, 4]}"
    end

    # The session's display name: a custom one if the user set it, otherwise
    # the automatic name (reconstructed from the journal when the daemon
    # restarted and @session_dir is empty).
    def session_name(sid : String) : String
      @state.name_of(sid) || begin
        dir = @session_dir[sid]? || @state.entry(sid).try(&.dir) || ""
        auto_name(dir, sid)
      end
    end

    # A dir argument is only honoured when it is listed in config.dirs —
    # the daemon must not spawn agents in arbitrary paths.
    def pick_dir(arg : String?) : String?
      dirs = @config.dirs
      return arg.nil? ? Dir.current : nil if dirs.empty?
      return dirs.first if arg.nil?
      expanded = File.expand_path(arg)
      dirs.find { |d| File.expand_path(d).rstrip('/') == expanded.rstrip('/') }
    end

    def dirs_listing : String
      return "no dirs configured — /new uses #{Dir.current}" if @config.dirs.empty?
      String.build do |io|
        io << "configured dirs:\n"
        @config.dirs.each_with_index do |d, i|
          io << "#{i + 1}. #{d}\n"
        end
        io << "/new <path from this list> or /new to pick"
      end
    end

    # /new with several configured dirs → inline picker. The index in the
    # callback is resolved against config.dirs when pressed, so buttons from
    # an old config expire instead of opening the wrong directory.
    def offer_dirs(chat_id : Int64) : Nil
      say(chat_id, "start a session in:", Keyboards.dirs_kb(@config.dirs))
    end

    # --- Inbox batching ---

    def enqueue(chat_id : Int64, text : String) : Nil
      @inbox_lock.synchronize do
        (@inbox[chat_id] ||= [] of String) << text
        @inbox_deadline[chat_id] = Time.instant + BATCH_PAUSE
        unless @flushing.includes?(chat_id)
          @flushing << chat_id
          spawn(name: "tg-inbox-#{chat_id}") { flush_inbox(chat_id) }
        end
      end
    end

    private def flush_inbox(chat_id : Int64) : Nil
      loop do
        remaining = @inbox_lock.synchronize do
          (@inbox_deadline[chat_id]? || Time.instant) - Time.instant
        end
        sleep remaining if remaining > Time::Span.zero
        batch = @inbox_lock.synchronize do
          if Time.instant >= (@inbox_deadline[chat_id]? || Time.instant)
            @inbox_deadline.delete(chat_id)
            @flushing.delete(chat_id)
            @inbox.delete(chat_id) || [] of String
          end
        end
        if batch
          deliver_batch(chat_id, batch.join("\n\n")) unless batch.empty?
          return
        end
      end
    end

    def deliver_batch(chat_id : Int64, text : String) : Nil
      sid = active_sid(chat_id)
      link = sid.try { |s| @manager.link(s) }
      if link.nil? || link.closed?
        say(chat_id, "no active session — /new to start one")
        return
      end
      link.prompt(text)
      if sid
        @state.touch(sid)
        if (e = @state.entry(sid)) && e.first_prompt.empty?
          @state.record_first_prompt(sid, text[0, 200])
        end
      end
    rescue ex
      say(chat_id, "⚠️ #{ex.message}")
    end

    # --- Attachments ---

    def handle_attachment(chat_id : Int64, msg : JSON::Any, caption : String) : Nil
      file_id, name = if photo = msg["photo"]?.try(&.as_a?)
                        best = photo.max_by { |p| p["width"]?.try(&.to_s).try(&.to_i?) || 0 }
                        {best["file_id"].to_s, "photo#{Time.utc.to_unix}.jpg"}
                      elsif doc = msg["document"]?
                        {doc["file_id"].to_s,
                         doc["file_name"]?.try(&.to_s) || "file#{Time.utc.to_unix}"}
                      else
                        return
                      end
      path = download(file_id, name)
      text = caption.strip.empty? ? "" : caption.strip + "\n"
      enqueue(chat_id, "#{text}[file: #{path}]")
    rescue ex
      say(chat_id, "⚠️ attachment failed: #{ex.message}")
    end

    # `dest_dir` defaults to the attachment store; voice clips override it
    # with the h2voice input dir (~/.h2code/voice) — the server's file
    # transcription allowlist only accepts files under it or os.TempDir().
    def download(file_id : String, name : String, dest_dir : String? = nil) : String
      dir = dest_dir || File.join(home, "tg", "files")
      Dir.mkdir_p(dir)
      path = File.join(dir, "#{Time.utc.to_unix}_#{name}")
      file_path = @api.get_file_path(file_id) || raise "getFile refused the file"
      @api.download_file(file_path, path)
      path
    end

    # --- Voice messages ---

    # A voice message (OGG/Opus) is downloaded and transcribed by the local
    # h2voice server — POST /v1/transcribe/file, the same socket/engine/
    # language settings the TUI's Ctrl+R voice input uses. The clip goes to
    # ~/.h2code/voice: the server's allowlist only transcribes files under
    # that directory (or os.TempDir()). The transcription goes into the
    # batching inbox as a marked prompt.
    def handle_voice(chat_id : Int64, msg : JSON::Any) : Nil
      cfg = H2code::Config::Config.load.transcription
      unless cfg.enabled?
        say(chat_id, "⚠️ voice transcription is disabled (transcription.enabled = false)")
        return
      end
      file_id = msg["voice"]["file_id"].to_s
      path = download(file_id, "voice#{Time.utc.to_unix}.ogg", File.join(home, "voice"))
      text = voice_client(cfg).transcribe_file(path, mime: "audio/ogg",
        language: cfg.language, stt_engine: cfg.engine).strip
      # Echo the transcription back so the user sees what the agent got.
      say(chat_id, text.empty? ? "🎙 расшифровка пуста" : "🎙 #{text}")
      enqueue(chat_id, voice_prompt(text))
    rescue ex
      say(chat_id, "⚠️ voice failed: #{ex.message}")
    end

    # The prompt a voice transcription becomes. Empty transcripts still
    # notify the agent — silence is information too.
    def voice_prompt(text : String) : String
      text.empty? ? "получено голосовое сообщение (расшифровка пуста)" \
                  : "получено голосовое сообщение: #{text}"
    end

    private def voice_client(cfg : H2code::Config::TranscriptionConfig) : H2code::Transcription::Client
      @voice_client ||= H2code::Transcription::Client.from_config(cfg)
    end

    def home : String
      ENV["H2CODE_HOME"]? || File.join(ENV["HOME"]? || Dir.current, ".h2code")
    end

    # --- Session events (control-socket push frames) ---

    def on_event(sid : String, frame : JSON::Any) : Nil
      chat_id = @lock.synchronize { @session_chat[sid]? }
      return unless chat_id
      case frame["ev"]?.try(&.to_s)
      when "turn"
        if frame["phase"]?.try(&.to_s) == "started"
          start_typing(sid, chat_id)
        else
          finish_typing(sid, frame["ok"]?.try(&.as_bool?) || false)
        end
      when "assistant"
        text = frame["text"]?.try(&.to_s).to_s
        m = say_md(chat_id, text)
        remember_message(chat_id, m, sid)
      when "question"
        render_question(sid, chat_id, frame)
      when "approval"
        render_approval(sid, chat_id, frame)
      when "usage"
        touch_typing(sid, frame["context_pct"]?)
      when "error"
        say(chat_id, "⚠️ #{frame["text"]?.try(&.to_s)}")
      end
    rescue ex
      if chat = chat_id
        begin
          say(chat, "⚠️ #{ex.message}")
        rescue
        end
      end
    end

    def on_died(sid : String) : Nil
      chat_id = @lock.synchronize { @session_chat.delete(sid) }
      @state.touch(sid)
      return unless chat_id
      @lock.synchronize do
        @session_dir.delete(sid)
        @active.reject! { |_, active_sid| active_sid == sid }
        @questions.reject! { |k, _| k.starts_with?("#{sid}:") }
        @cards.reject! { |k, _| k.starts_with?("#{sid}:") }
      end
      stop_typing(sid)
      say(chat_id, "🔴 session #{session_name(sid)} ended")
    end

    # "⏳ thinking" pulse: one message per running turn, updated with the
    # context usage on ev:usage, deleted when the turn ends.
    def start_typing(sid : String, chat_id : Int64) : Nil
      return if @typing[sid]?
      m = say(chat_id, "⏳ …")
      if m && (mid = m["message_id"]?.try(&.to_s).try(&.to_i64?))
        @typing[sid] = Typing.new(chat_id, mid)
      end
    end

    def stop_typing(sid : String) : Nil
      t = @typing.delete(sid)
      return unless t
      @api.delete_message(t.chat_id, t.message_id) rescue nil
    end

    # A finished turn resolves the ⏳ pulse: a clean one is deleted (the
    # assistant text follows), a cancelled one is edited into a visible
    # "⛔ cancelled" — deleting it would read as the bot going silent, which
    # is exactly what an interrupt must not do.
    def finish_typing(sid : String, ok : Bool) : Nil
      t = @typing.delete(sid)
      return unless t
      if ok
        @api.delete_message(t.chat_id, t.message_id) rescue nil
      else
        begin
          @api.edit_message_text(t.chat_id, t.message_id, "⛔ cancelled")
        rescue
          @api.delete_message(t.chat_id, t.message_id) rescue nil
        end
      end
    end

    def touch_typing(sid : String, pct : JSON::Any?) : Nil
      t = @typing[sid]? || return
      text = pct ? "⏳ … · context #{pct}" : "⏳ …"
      return if text == t.last_text
      t.last_text = text
      @api.edit_message_text(t.chat_id, t.message_id, text) rescue nil
    end

    # --- Question cards ---

    def render_question(sid : String, chat_id : Int64, frame : JSON::Any) : Nil
      qid = frame["qid"]?.try(&.to_s).to_s
      questions = frame["questions"]?.try(&.as_a?) || [] of JSON::Any
      state = QuestionState.new(sid, qid)
      questions.each_with_index do |q, qi|
        question = q["question"]?.try(&.to_s).to_s
        header = q["header"]?.try(&.to_s).to_s
        multi = q["multiSelect"]?.try(&.as_bool?) || false
        labels = (q["options"]?.try(&.as_a?) || [] of JSON::Any)
          .map { |o| o["label"]?.try(&.to_s).to_s }
        card = Card.new(chat_id, 0_i64, sid, qid, qi, question, labels, multi, header)
        m = say(chat_id, card_text(card), card_keyboard(card))
        next unless m && (mid = m["message_id"]?.try(&.to_s).try(&.to_i64?))
        card = Card.new(chat_id, mid, sid, qid, qi, question, labels, multi, header)
        @lock.synchronize do
          @cards[card.key] = card
          state.remaining << qi
        end
        remember_message(chat_id, m, sid)
      end
      @lock.synchronize { @questions[state.key] = state } unless state.remaining.empty?
    end

    def card_text(card : Card) : String
      Keyboards.dialog_text(card.question, card.header, card.labels, card.multi?, card.selected)
    end

    # One button per row: `[{label, data}]` — the Api expects rows of pairs.
    def btn(label : String, data : String) : Array({String, String})
      [{label, data}]
    end

    def card_keyboard(card : Card) : Array(Array({String, String}))
      Keyboards.dialog_kb(card.sid, card.qid, card.qi, card.labels, card.multi?, card.selected)
    end

    def render_approval(sid : String, chat_id : Int64, frame : JSON::Any) : Nil
      qid = frame["qid"]?.try(&.to_s).to_s
      tool = frame["tool"]?.try(&.to_s).to_s
      args = frame["args"]?.try(&.to_s).to_s
      danger = frame["danger"]?.try(&.to_s).to_s
      header = danger.empty? ? "🔐 #{tool}" : "🔐 #{tool} · danger: #{danger}"
      m = say(chat_id, "#{header}\n\n#{clip(args, 1000)}", Keyboards.approval_kb(sid, qid))
      remember_message(chat_id, m, sid)
    end

    # --- Callback handling ---

    def handle_callback(cb : JSON::Any) : Nil
      from = cb["from"]?.try(&.["id"]?).try(&.to_s).try(&.to_i64?)
      return unless from && @config.allows?(from)
      cb_id = cb["id"].to_s
      msg = cb["message"]?
      chat_id = msg.try(&.["chat"]?).try(&.["id"]?).try(&.to_s).try(&.to_i64?)
      message_id = msg.try(&.["message_id"]?).try(&.to_s).try(&.to_i64?)

      callback = Callback.parse(cb["data"]?.try(&.to_s))
      if callback.nil?
        @api.answer_callback_query(cb_id)
        return
      end

      # Screens and dir management need no live session — handled first, so
      # a press on an old card still navigates after its session died.
      case callback.kind
      when .new_dir?
        on_new_dir(callback, cb_id, chat_id)
      when .list?
        @api.answer_callback_query(cb_id)
        render_sessions(chat_id, message_id)
      when .new_session?
        on_new_session(callback, cb_id, chat_id, message_id)
      when .history?
        @api.answer_callback_query(cb_id)
        render_history(chat_id, message_id, 0)
      when .hist_page?
        @api.answer_callback_query(cb_id)
        on_hist_page(callback, chat_id, message_id)
      when .find?
        start_input(chat_id, cb_id, :find,
          "send the search query — names and first prompts")
      when .card?
        @api.answer_callback_query(cb_id)
        if (l = @manager.link(callback.sid)) && !l.closed?
          render_card(chat_id, message_id, callback.sid)
        else
          render_closed(chat_id, message_id, callback.sid, page_of(chat_id))
        end
      when .closed_card?
        @api.answer_callback_query(cb_id)
        render_closed(chat_id, message_id, callback.sid, page_of(chat_id))
      when .resume?
        on_resume(callback, cb_id, chat_id)
      when .manual_dir?
        start_input(chat_id, cb_id, :manual_dir, "send the directory path")
      when .add_dir?
        start_input(chat_id, cb_id, :add_dir, "send the directory path to add")
      when .remove_dir?
        on_remove_dir(callback, cb_id, chat_id, message_id)
      when .service_show?
        @api.answer_callback_query(cb_id)
        render_service(chat_id, message_id)
      else
        link = @manager.link(callback.sid)
        if link.nil? || link.closed?
          @api.answer_callback_query(cb_id, "session is gone")
          return
        end
        case callback.kind
        when .answer?
          on_answer(link, callback, cb_id)
        when .toggle?
          on_toggle(callback, cb_id)
        when .submit?
          on_submit(link, callback, cb_id)
        when .dismiss?
          on_dismiss(link, callback, cb_id)
        when .approve?
          on_approve(link, callback, cb_id, chat_id, message_id)
        when .command?
          on_command_button(link, callback, cb_id)
        when .action?
          on_action(link, callback, cb_id, chat_id, message_id)
        when .model_set?
          on_model_set(link, callback, cb_id, chat_id, message_id)
        when .mode_set?
          on_mode_set(link, callback, cb_id, chat_id, message_id)
        end
      end
    end

    # --- Screens (sessions / card / history / find / dirs / service) ---

    # Edit the message the button was pressed on when possible (paging
    # through lists must not flood the chat), send a fresh one otherwise.
    # Telegram rejects an edit with identical content — that error is noise.
    def show(chat_id : Int64?, message_id : Int64?, text : String,
             keyboard : Array(Array({String, String}))) : Nil
      return unless chat_id
      if message_id
        begin
          @api.edit_message_text(chat_id, message_id, clip(text), keyboard)
          return
        rescue ex
          raise ex unless ex.message.to_s.includes?("not modified")
          return
        end
      end
      say(chat_id, text, keyboard)
    end

    def render_sessions(chat_id : Int64?, message_id : Int64?) : Nil
      return unless chat_id
      links = @manager.snapshot
      active = @lock.synchronize { @active[chat_id]? }
      views = links.map do |link|
        sid = link.sid
        dir = @session_dir[sid]? || @state.entry(sid).try(&.dir) || ""
        Keyboards::SessionView.new(sid, File.basename(dir), session_name(sid),
          status_word(sid), @state.entry(sid).try(&.custom?) || false)
      end
      closed_count = @state.closed(links.map(&.sid).to_set).size
      show(chat_id, message_id,
        Keyboards.sessions_header(views, closed_count),
        Keyboards.sessions_kb(views, active, closed_count))
    end

    # "busy" while a turn runs, "waiting" while a question/approval card is
    # unanswered, "idle" otherwise — the phone's one-glance state.
    def status_word(sid : String) : String
      return "busy" if @manager.busy?(sid)
      waiting = @lock.synchronize { @questions.any? { |k, _| k.starts_with?("#{sid}:") } }
      waiting ? "waiting" : "idle"
    end

    def render_card(chat_id : Int64?, message_id : Int64?, sid : String) : Nil
      return unless chat_id
      link = @manager.link(sid)
      if link.nil? || link.closed?
        render_closed(chat_id, message_id, sid, page_of(chat_id))
        return
      end
      s = link.status
      e = @state.entry(sid)
      active = @lock.synchronize { @active[chat_id]? == sid }
      card = Keyboards::CardData.new(
        name: session_name(sid),
        dir: Keyboards.tilde(@session_dir[sid]? || e.try(&.dir) || ""),
        status: status_word(sid),
        model: s["model"]?.try(&.to_s) || "—",
        mode: s["mode"]?.try(&.to_s) || "",
        context_pct: s["context_pct"]?.try(&.as_f?) || 0.0,
        context_tokens: s["context_tokens"]?.try(&.to_s).try(&.to_i64?) || 0_i64,
        created_short: e.try(&.when_short) || "",
        sid: sid, active: active)
      show(chat_id, message_id,
        Keyboards.session_card_text(card), Keyboards.session_kb(sid, active))
    end

    def usage_text(link : SessionLink, sid : String) : String
      s = link.status
      String.build do |io|
        io << "📊 #{session_name(sid)}\n\n"
        io << "🧠 model: #{s["model"]?}\n"
        io << "🔐 mode: #{s["mode"]?}\n" if s["mode"]?
        io << "📈 context: #{s["context_pct"]?}% (#{s["context_tokens"]?} tokens)"
      end
    end

    # History/find lists share the pager: HISTORY_PAGE per screen, clamped.
    def paginate(entries : Array(State::Entry), page : Int32)
      pages = {(entries.size / Keyboards::HISTORY_PAGE).ceil.to_i, 1}.max
      page = page.clamp(0, pages - 1)
      {page, pages, entries[page * Keyboards::HISTORY_PAGE, Keyboards::HISTORY_PAGE]? || [] of State::Entry}
    end

    def render_history(chat_id : Int64?, message_id : Int64?, page : Int32) : Nil
      return unless chat_id
      entries = @state.closed(live_sids)
      page, pages, slice = paginate(entries, page)
      @last_list[chat_id] = {find: nil, page: page}
      show(chat_id, message_id,
        Keyboards.history_header(entries.size), Keyboards.history_kb(slice, page, pages))
    end

    def render_find(chat_id : Int64?, message_id : Int64?, query : String,
                    page : Int32) : Nil
      return unless chat_id
      q = query.downcase
      entries = @state.closed(live_sids).select do |e|
        e.name.downcase.includes?(q) || e.first_prompt.downcase.includes?(q)
      end
      page, pages, slice = paginate(entries, page)
      @last_list[chat_id] = {find: query, page: page}
      show(chat_id, message_id,
        Keyboards.search_header(query, entries.size),
        Keyboards.search_kb(slice, page, pages, query))
    end

    def render_closed(chat_id : Int64?, message_id : Int64?, sid : String,
                      page : Int32 = 0) : Nil
      return unless chat_id
      e = @state.entry(sid)
      if e.nil?
        say(chat_id, "no record of this session")
        return
      end
      show(chat_id, message_id,
        Keyboards.closed_card_text(e), Keyboards.closed_card_kb(sid, page))
    end

    # /dirs screen: the configured dirs are removable, a new one addable —
    # the list is the config, edited in place and persisted.
    def render_dirs(chat_id : Int64?, message_id : Int64?) : Nil
      return unless chat_id
      show(chat_id, message_id, dirs_listing, Keyboards.project_dirs_kb(@config.dirs))
    end

    def render_service(chat_id : Int64?, message_id : Int64?) : Nil
      return unless chat_id
      text = String.build do |io|
        io << "⚙️ h2code-tg-bot\n\n"
        io << "uptime: #{DurationFormat.hms((Time.utc - @started_at).to_i)}\n"
        io << "config: #{Keyboards.tilde(Config.path)}\n"
        io << "binary: #{@config.h2code_bin}\n"
        io << "pid: #{Process.pid}"
      end
      show(chat_id, message_id, text, Keyboards.service_kb)
    end

    def live_sids : Set(String)
      @manager.snapshot.map(&.sid).to_set
    end

    # --- Pending-input flows (rename / find / manual path / add dir) ---

    def consume_input(chat_id : Int64, pending : PendingInput, text : String) : Nil
      case pending.kind
      when :rename     then apply_rename(chat_id, pending.sid, text)
      when :find       then render_find(chat_id, nil, text, 0)
      when :manual_dir then start_manual_dir(chat_id, text)
      when :add_dir    then add_dir(chat_id, text)
      end
    rescue ex
      say(chat_id, "⚠️ #{ex.message}")
    end

    def apply_rename(chat_id : Int64, sid : String, raw : String) : Nil
      if raw == "-"
        @state.set_name(sid, nil)
        say(chat_id, "name reset to #{session_name(sid)}")
      else
        @state.set_name(sid, raw)
        say(chat_id, "renamed to #{raw}")
      end
    end

    # A manual path is the explicit escape hatch from the configured dirs;
    # the only requirement is that it exists.
    def start_manual_dir(chat_id : Int64, raw : String) : Nil
      dir = File.expand_path(raw)
      unless Dir.exists?(dir)
        say(chat_id, "not a directory: #{dir}")
        return
      end
      spawn_session(chat_id, dir)
    end

    def add_dir(chat_id : Int64, raw : String) : Nil
      dir = File.expand_path(raw)
      unless Dir.exists?(dir)
        say(chat_id, "not a directory: #{dir}")
        return
      end
      unless @config.dirs.includes?(dir)
        @config.dirs << dir
        @config.save
      end
      say(chat_id, "added #{Keyboards.tilde(dir)}")
      render_dirs(chat_id, nil)
    end

    # --- Callback handlers for the screen kinds ---

    def on_new_session(callback : Callback, cb_id : String, chat_id : Int64?,
                       message_id : Int64?) : Nil
      @api.answer_callback_query(cb_id)
      return unless chat_id
      if @config.dirs.size > 1
        show(chat_id, message_id, "start a session in:", Keyboards.dirs_kb(@config.dirs))
      else
        start_session(chat_id, nil)
      end
    end

    def on_hist_page(callback : Callback, chat_id : Int64?, message_id : Int64?) : Nil
      return unless chat_id
      if (ref = @last_list[chat_id]?) && (query = ref[:find])
        render_find(chat_id, message_id, query, callback.qi)
      else
        render_history(chat_id, message_id, callback.qi)
      end
    end

    def on_resume(callback : Callback, cb_id : String, chat_id : Int64?) : Nil
      e = @state.entry(callback.sid)
      if e.nil? || chat_id.nil?
        @api.answer_callback_query(cb_id, "no record of this session")
        return
      end
      @api.answer_callback_query(cb_id)
      spawn_session(chat_id, e.dir)
    end

    def on_remove_dir(callback : Callback, cb_id : String, chat_id : Int64?,
                      message_id : Int64?) : Nil
      if callback.qi < 0 || callback.qi >= @config.dirs.size
        @api.answer_callback_query(cb_id, "expired")
        return
      end
      @config.dirs.delete_at(callback.qi)
      @config.save
      @api.answer_callback_query(cb_id, "removed")
      render_dirs(chat_id, message_id)
    end

    def start_input(chat_id : Int64?, cb_id : String, kind : Symbol, prompt : String) : Nil
      @api.answer_callback_query(cb_id)
      return unless chat_id
      @lock.synchronize { @input[chat_id] = PendingInput.new(kind) }
      say(chat_id, prompt)
    end

    def page_of(chat_id : Int64?) : Int32
      chat_id.try { |c| @last_list[c]?.try(&.[:page]) } || 0
    end

    # Dir-picker button (n:<idx>): resolve the index against the CURRENT
    # config.dirs — a press on a stale card must never open an unconfigured
    # path.
    def on_new_dir(callback : Callback, cb_id : String, chat_id : Int64?) : Nil
      dir = @config.dirs[callback.qi]?
      if dir.nil? || chat_id.nil?
        @api.answer_callback_query(cb_id, "expired — /dirs for the fresh list")
        return
      end
      @api.answer_callback_query(cb_id)
      start_session(chat_id, dir)
    end

    # Session command buttons from the 🟢 card (c:<sid>:<action>): always
    # addressed — the action lands on the session the card was issued for,
    # whichever session happens to be active now.
    def on_command_button(link : SessionLink, callback : Callback, cb_id : String) : Nil
      case callback.qid
      when "st"
        chat_id = @lock.synchronize { @session_chat[callback.sid]? }
        raise "no chat for session" unless chat_id
        s = link.status
        say(chat_id, "session #{callback.sid}\nbusy: #{s["busy"]?}\nmodel: #{s["model"]?}\n" \
                     "context: #{s["context_pct"]?}%")
        @api.answer_callback_query(cb_id)
      when "in"
        if @manager.busy?(callback.sid) == false
          @api.answer_callback_query(cb_id, "idle — nothing to interrupt")
        else
          link.interrupt
          @api.answer_callback_query(cb_id, "interrupting…")
        end
      when "sp"
        @manager.stop(callback.sid)
        @api.answer_callback_query(cb_id, "stopping…")
      else
        @api.answer_callback_query(cb_id, "unknown action")
      end
    rescue ex
      @api.answer_callback_query(cb_id, ex.message.to_s) rescue nil
    end

    # Session-card actions (k:<sid>:<act>): Open/Esc navigate, /clear and
    # /compact are the context controls, Model/Mode open pickers, Rename
    # consumes the next text, End is the graceful exit.
    def on_action(link : SessionLink, callback : Callback, cb_id : String,
                  chat_id : Int64?, message_id : Int64?) : Nil
      sid = callback.sid
      case callback.qid
      when Callback::Action::OPEN
        @lock.synchronize { @active[chat_id] = sid } if chat_id
        @api.answer_callback_query(cb_id, "active")
        render_card(chat_id, message_id, sid)
      when Callback::Action::ESC
        @api.answer_callback_query(cb_id)
        render_card(chat_id, message_id, sid)
      when Callback::Action::CLR
        link.clear_context
        @api.answer_callback_query(cb_id, "context cleared")
        render_card(chat_id, message_id, sid)
      when Callback::Action::CMP
        link.compact
        @api.answer_callback_query(cb_id, "compaction started")
        render_card(chat_id, message_id, sid)
      when Callback::Action::USE
        @api.answer_callback_query(cb_id)
        say(chat_id, usage_text(link, sid)) if chat_id
      when Callback::Action::REN
        if chat_id
          @lock.synchronize { @input[chat_id] = PendingInput.new(:rename, sid) }
        end
        @api.answer_callback_query(cb_id)
        say(chat_id, "send the new name (or '-' to reset)") if chat_id
      when Callback::Action::END
        @manager.stop(sid)
        @api.answer_callback_query(cb_id, "ending…")
      when Callback::Action::MDL
        current = link.status["model"]?.try(&.to_s) || ""
        show(chat_id, message_id,
          Keyboards.settings_text(current), Keyboards.settings_kb(sid, link.models, current))
        @api.answer_callback_query(cb_id)
      when Callback::Action::MOD
        current = link.mode.to_s
        show(chat_id, message_id,
          Keyboards.mode_text(current), Keyboards.mode_kb(sid, current))
        @api.answer_callback_query(cb_id)
      else
        @api.answer_callback_query(cb_id, "unknown action")
      end
    rescue ex
      @api.answer_callback_query(cb_id, ex.message.to_s) rescue nil
    end

    def on_model_set(link : SessionLink, callback : Callback, cb_id : String,
                     chat_id : Int64?, message_id : Int64?) : Nil
      link.set_model(callback.qid)
      @api.answer_callback_query(cb_id, "model set")
      current = link.status["model"]?.try(&.to_s) || callback.qid
      show(chat_id, message_id,
        Keyboards.settings_text(current),
        Keyboards.settings_kb(callback.sid, link.models, current))
    rescue ex
      @api.answer_callback_query(cb_id, ex.message.to_s) rescue nil
    end

    def on_mode_set(link : SessionLink, callback : Callback, cb_id : String,
                    chat_id : Int64?, message_id : Int64?) : Nil
      link.set_mode(callback.qid)
      @api.answer_callback_query(cb_id, "mode set")
      current = link.mode.to_s
      show(chat_id, message_id,
        Keyboards.mode_text(current), Keyboards.mode_kb(callback.sid, current))
    rescue ex
      @api.answer_callback_query(cb_id, ex.message.to_s) rescue nil
    end

    def on_answer(link : SessionLink, callback : Callback, cb_id : String) : Nil
      card = @lock.synchronize { @cards[callback_key(callback)]? }
      unless card
        @api.answer_callback_query(cb_id, "expired")
        return
      end
      label = card.labels[callback.oi]? || ""
      finish_card(card, "✅ #{label}")
      record_answer(card, card.question, JSON::Any.new(label), link)
      @api.answer_callback_query(cb_id, label)
    end

    def on_toggle(callback : Callback, cb_id : String) : Nil
      card = @lock.synchronize { @cards[callback_key(callback)]? }
      unless card && card.multi? && (labels = card.labels[callback.oi]?)
        @api.answer_callback_query(cb_id)
        return
      end
      if card.selected.includes?(callback.oi)
        card.selected.delete(callback.oi)
      else
        card.selected << callback.oi
      end
      @api.edit_message_text(card.chat_id, card.message_id,
        card_text(card), card_keyboard(card))
      @api.answer_callback_query(cb_id)
    end

    def on_submit(link : SessionLink, callback : Callback, cb_id : String) : Nil
      card = @lock.synchronize { @cards[callback_key(callback)]? }
      unless card && card.multi?
        @api.answer_callback_query(cb_id, "expired")
        return
      end
      values = card.selected.to_a.sort.map { |oi| JSON::Any.new(card.labels[oi]? || "") }
      finish_card(card, "✅ #{values.size} selected")
      record_answer(card, card.question, JSON::Any.new(values), link)
      @api.answer_callback_query(cb_id, "sent")
    end

    def on_dismiss(link : SessionLink, callback : Callback, cb_id : String) : Nil
      prefix = "#{callback.sid}:#{callback.qid}"
      cards = @lock.synchronize do
        @questions.delete(prefix)
        removed = @cards.reject! { |k, _| k.starts_with?("#{prefix}:") }
        removed ? removed.values : [] of Card
      end
      cards.each { |card| finish_card(card, "✕ dismissed") }
      link.answer(callback.qid, {} of String => JSON::Any)
      @api.answer_callback_query(cb_id, "dismissed")
    end

    def on_approve(link : SessionLink, callback : Callback, cb_id : String,
                   chat_id : Int64?, message_id : Int64?) : Nil
      decision = case callback.decision
                 when 1 then "allow"
                 when 2 then "allow_session"
                 else        "deny"
                 end
      link.approve(callback.qid, decision)
      @api.answer_callback_query(cb_id, decision)
      if chat_id && message_id
        @api.edit_message_text(chat_id, message_id, "🔐 #{decision}",
          [] of Array({String, String})) rescue nil
      end
    end

    # Answers accumulate per request; op:answer is sent once every question
    # of the form is answered (the socket op resolves the whole request).
    def record_answer(card : Card, question : String, value : JSON::Any,
                      link : SessionLink) : Nil
      state = @lock.synchronize do
        s = @questions["#{card.sid}:#{card.qid}"]?
        next nil unless s
        s.answers[question] = value
        s.remaining.delete(card.qi)
        s.remaining.empty? ? (@questions.delete(s.key); s) : nil
      end
      link.answer(card.qid, state.answers) if state
    end

    def finish_card(card : Card, suffix : String) : Nil
      @api.edit_message_text(card.chat_id, card.message_id,
        "#{card_text(card)}\n#{suffix}",
        [] of Array({String, String})) rescue nil
    end

    # --- Helpers ---

    def active_sid(chat_id : Int64) : String?
      sid = @lock.synchronize { @active[chat_id]? }
      return nil unless sid
      @manager.link(sid) ? sid : nil
    end

    def active_link(chat_id : Int64) : SessionLink?
      active_sid(chat_id).try { |sid| @manager.link(sid) }
    end

    def remember_message(chat_id : Int64, result : JSON::Any?, sid : String) : Nil
      mid = result.try(&.["message_id"]?).try(&.to_s).try(&.to_i64?)
      @lock.synchronize { @by_message["#{chat_id}:#{mid}"] = sid } if mid
    end

    def update_chat_id(update : JSON::Any) : Int64?
      msg = update["message"]? || update["callback_query"]?.try(&.["message"]?)
      msg.try(&.["chat"]?).try(&.["id"]?).try(&.to_s).try(&.to_i64?)
    end

    def callback_key(callback : Callback) : String
      "#{callback.sid}:#{callback.qid}:#{callback.qi}"
    end

    def say(chat_id : Int64, text : String,
            keyboard : Array(Array({String, String}))? = nil) : JSON::Any?
      @api.send_message(chat_id, clip(text), keyboard)
    end

    # Assistant replies arrive as Markdown and go out as MarkdownV2. Telegram
    # is strict about it (any unescaped special → 400), so a conversion the
    # API still refuses — exotic nesting, clipping artifacts — falls back to
    # the plain text rather than losing the reply.
    def say_md(chat_id : Int64, text : String) : JSON::Any?
      clipped = clip(text)
      begin
        @api.send_message(chat_id, MarkdownV2.convert(clipped), parse_mode: "MarkdownV2")
      rescue ex : ApiError
        raise ex unless ex.error_code == 400
        @api.send_message(chat_id, clipped)
      end
    end

    def clip(text : String, limit : Int32 = MAX_TEXT) : String
      text.size <= limit ? text : text[0, limit] + "…"
    end
  end
end
