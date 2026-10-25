require "./callbacks"
require "./state"

module TgBot
  # Inline keyboards and card texts — a 1:1 port of claude-tg-bot's
  # `ccbot/keyboards.py` onto our resident sessions (English strings, the
  # base language there).
  #
  # Conventions carried over verbatim:
  #   * the message text does not restate what the buttons already say —
  #     headers carry counters only, all information lives on the buttons;
  #   * the active session gets the only green mark (🟢); the idle state —
  #     the most common one — stays grey (☑️) and does not compete with it;
  #   * button captions are trimmed deliberately to 46 chars, so Telegram
  #     never truncates them at random;
  #   * a settled card keeps one button saying how it settled — stripping
  #     the buttons alone would leave a question with no answer on it.
  module Keyboards
    ACTIVE_ICON = "🟢"

    STATUS_ICON = {
      "busy"     => "⚡",
      "idle"     => "☑️",
      "waiting"  => "⏸",
      "starting" => "🔄",
      "dead"     => "💀",
      "gone"     => "❓",
      "closed"   => "🕘",
    } of String => String

    # Permission modes of our agent (claude-tg-bot cycles four Claude Code
    # modes; ours has three — there is no accept-edits middle ground).
    MODES = [
      {"⏵⏵ auto", "auto"},
      {"⏸ manual", "manual"},
      {"⏵⏵ yolo", "yolo"},
    ] of {String, String}

    # Telegram truncates long button captions, and a phone shows fewer
    # characters than a desktop — so trim deliberately instead of letting it
    # happen at random.
    BUTTON_CHARS = 46

    # One row of buttons: `[{label, data}]` — the Api expects rows of pairs.
    def self.btn(label : String, data : String) : Array({String, String})
      [{label, data}]
    end

    def self.row(*buttons : {String, String}) : Array({String, String})
      buttons.to_a
    end

    def self.fit(text : String, suffix : String = "") : String
      tail = suffix.empty? ? "" : " · #{suffix}"
      room = BUTTON_CHARS - tail.size
      if text.size > room
        text = text[0, room - 1].rstrip + "…"
      end
      text + tail
    end

    # Drop the folder prefix the bot itself put in the session name —
    # "finman · finman-a3f2" wastes the little space a button has; the
    # folder is already the first field.
    def self.distinct_name(name : String, folder : String) : String
      {"-", "_", " "}.each do |sep|
        prefix = folder + sep
        if name.starts_with?(prefix) && name.size > prefix.size
          return name[prefix.size..]
        end
      end
      name
    end

    # What identifies a list row at a glance: the name the user set, else
    # the first message of the session (flattened — a button is one line),
    # else the automatic hash name.
    def self.row_label(name : String, custom : Bool, first_prompt : String,
                       folder : String = "") : String
      return named(name, custom) if custom
      fp = first_prompt.strip.split.join(" ")
      return fp unless fp.empty?
      folder.empty? ? name : distinct_name(name, folder)
    end

    # A row's name, marked when it is the one the user gave it themselves.
    def self.named(name : String, saved : Bool) : String
      saved ? "✏️ #{name}" : name
    end

    # --- Session list (/sessions) ---

    def self.sessions_kb(views : Array(SessionView), active : String?,
                         closed_count : Int32) : Array(Array({String, String}))
      rows = [] of Array({String, String})
      # The divider reads as a separator (Telegram centres a caption) and
      # explains the group on a tap.
      rows << btn("──── 🖥 sessions ────", "grp:tmux") unless views.empty?
      views.each do |v|
        icon = STATUS_ICON[v.status]? || "•"
        mark = v.sid == active ? ACTIVE_ICON : icon
        hint = v.status == "waiting" ? "waiting" : ""
        rows << btn(fit("#{mark} #{v.dir_name} · #{row_label(v.name, v.saved_name?, v.first_prompt, v.dir_name)}", hint),
          Callback.build(Callback::Kind::Card, v.sid, ""))
      end
      rows << row(
        {"➕ New session", Callback.build(Callback::Kind::NewSession, "", "")},
        {"🕘 Recent", Callback.build(Callback::Kind::History, "", "")},
      )
      rows << row(
        {"⚙️ Service", Callback.build(Callback::Kind::ServiceShow, "", "")},
        {"🔄 Refresh", Callback.build(Callback::Kind::List, "", "")},
      )
      rows
    end

    # Counters only — by the time you have scrolled a long list, a summary
    # in the text is forgotten; all the information lives on the buttons.
    def self.sessions_header(views : Array(SessionView), closed_count : Int32) : String
      String.build do |io|
        io << "#{views.size} #{views.size == 1 ? "session" : "sessions"}"
        busy = views.count { |v| v.status == "busy" }
        io << " · #{busy} busy" if busy > 0
        io << " · #{closed_count} closed" if closed_count > 0
        io << "\ntap one for details; whether to open it is decided there."
      end
    end

    # --- Session card ---

    def self.session_kb(sid : String, active : Bool) : Array(Array({String, String}))
      rows = [] of Array({String, String})
      # "Open" makes the session active; the row is shown only when it is
      # not already the one plain text goes to.
      unless active
        rows << btn("▶️ Open", Callback.build(Callback::Kind::Action, sid, Callback::Action::OPEN))
      end
      rows << row(
        {"⏸ Esc", Callback.build(Callback::Kind::Action, sid, Callback::Action::ESC)},
        {"📊 Limits", Callback.build(Callback::Kind::Action, sid, Callback::Action::USE)},
      )
      # The three context controls travel together, and "End" leaves the row
      # they are in: it used to sit where the thumb lands for /clear.
      rows << row(
        {"🧹 /clear", Callback.build(Callback::Kind::Action, sid, Callback::Action::CLR)},
        {"🗜 /compact", Callback.build(Callback::Kind::Action, sid, Callback::Action::CMP)},
        {"📉 Context breakdown", Callback.build(Callback::Kind::Action, sid, Callback::Action::USE)},
      )
      rows << row(
        {"🧠 Model", Callback.build(Callback::Kind::Action, sid, Callback::Action::MDL)},
        {"🔐 Mode", Callback.build(Callback::Kind::Action, sid, Callback::Action::MOD)},
      )
      rows << row(
        {"✏️ Rename", Callback.build(Callback::Kind::Action, sid, Callback::Action::REN)},
        {"🚪 End", Callback.build(Callback::Kind::Action, sid, Callback::Action::END)},
      )
      rows << btn("⬅️ Sessions", Callback.build(Callback::Kind::List, "", ""))
      rows
    end

    def self.session_card_text(card : CardData) : String
      lines = [] of String
      lines << (card.active? ? "▶️ #{card.name}" : card.name)
      lines << "📁 #{card.dir}"
      lines << "📊 Status: #{card.status}"
      lines << "🧠 #{card.model}"
      lines << "🔐 #{card.mode}" unless card.mode.empty?
      if card.context_tokens > 0
        lines << "📈 Context: #{card.context_pct}% (#{card.context_tokens} tokens)"
      else
        # A fresh session has no metrics yet; the card says exactly that
        # instead of showing zeros.
        lines << "📈 Context: no data yet (first request has not gone through)"
      end
      lines << "🕘 Created: #{card.created_short}"
      lines << "🔑 #{card.sid}"
      lines.join('\n')
    end

    # --- Model / mode pickers ---

    def self.settings_kb(sid : String, models : Array(String),
                         current : String) : Array(Array({String, String}))
      rows = [] of Array({String, String})
      models.each do |m|
        mark = m == current ? "✅ " : ""
        rows << btn(fit("#{mark}#{m}"),
          Callback.build(Callback::Kind::ModelSet, sid, m))
      end
      rows << row(
        {"✖️ Cancel", Callback.build(Callback::Kind::Action, sid, Callback::Action::ESC)},
        {"⬅️ Back", Callback.build(Callback::Kind::Card, sid, "")},
      )
      rows
    end

    def self.settings_text(current : String) : String
      "🧠 Model\n\nCurrent: #{current}"
    end

    def self.mode_kb(sid : String, current : String) : Array(Array({String, String}))
      rows = [] of Array({String, String})
      MODES.each do |label, value|
        mark = value == current ? "✅ " : ""
        rows << btn("#{mark}#{label}",
          Callback.build(Callback::Kind::ModeSet, sid, value))
      end
      rows << btn("⬅️ Back", Callback.build(Callback::Kind::Card, sid, ""))
      rows
    end

    def self.mode_text(current : String) : String
      "🔐 Permission mode\n\nCurrent: #{current}"
    end

    # --- Question cards (AskUserQuestion) ---

    def self.dialog_text(question : String, header : String, labels : Array(String),
                         multi : Bool, selected : Set(Int32)) : String
      title = multi ? "❓ choose one or more:" : "❓ choose one:"
      lines = [title]
      lines << header unless header.empty?
      lines << question
      lines << ""
      labels.each_with_index do |label, oi|
        mark = multi ? (selected.includes?(oi) ? "☑" : "☐") : "•"
        lines << "#{mark} #{label}"
      end
      lines.join('\n')
    end

    def self.dialog_kb(sid : String, qid : String, qi : Int32, labels : Array(String),
                       multi : Bool, selected : Set(Int32)) : Array(Array({String, String}))
      rows = [] of Array({String, String})
      labels.each_with_index do |label, oi|
        rows << if multi
                  mark = selected.includes?(oi) ? "☑" : "☐"
                  btn("#{mark} #{oi + 1}. #{label}",
                    Callback.build(Callback::Kind::Toggle, sid, qid, qi, oi))
                else
                  btn("#{oi + 1}. #{label}",
                    Callback.build(Callback::Kind::Answer, sid, qid, qi, oi))
                end
      end
      if multi
        n = selected.size
        text = n > 0 ? "✅ Send #{n} #{n == 1 ? "choice" : "choices"}" : "✅ Send answer"
        rows << btn(text, Callback.build(Callback::Kind::Submit, sid, qid, qi))
      end
      rows << btn("⏸ Esc", Callback.build(Callback::Kind::Dismiss, sid, qid))
      rows
    end

    # --- Approvals ---

    def self.approval_kb(sid : String, qid : String) : Array(Array({String, String}))
      [
        row(
          {"✅ Allow", Callback.build(Callback::Kind::Approve, sid, qid, decision: 1)},
          {"⛔ Deny", Callback.build(Callback::Kind::Approve, sid, qid, decision: 0)},
        ),
        btn("✅ Allow this session",
          Callback.build(Callback::Kind::Approve, sid, qid, decision: 2)),
      ]
    end

    # --- Settled cards, rename, dirs, history ---

    def self.done_kb(label : String) : Array(Array({String, String}))
      label = label.split.join(" ")
      label = label[0, 59].rstrip + "…" if label.size > 60
      [btn(label, "done")]
    end

    def self.cancel_rename_kb(sid : String) : Array(Array({String, String}))
      [btn("⬅️ Cancel", Callback.build(Callback::Kind::Card, sid, ""))]
    end

    def self.service_kb : Array(Array({String, String}))
      # No "restart the bot" button (claude-tg-bot has one under systemd):
      # nothing would bring this process back — the button would end the
      # conversation instead.
      [
        row(
          {"♻️ Refresh", Callback.build(Callback::Kind::ServiceShow, "", "")},
          {"⬅️ Sessions", Callback.build(Callback::Kind::List, "", "")},
        ),
      ]
    end

    def self.dirs_kb(dirs : Array(String)) : Array(Array({String, String}))
      rows = [] of Array({String, String})
      dirs.each_with_index do |d, i|
        rows << btn("📁 #{tilde(d)}", Callback.build(Callback::Kind::NewDir, "", "", qi: i))
      end
      rows << btn("✏️ Other path", Callback.build(Callback::Kind::ManualDir, "", ""))
      rows << btn("⬅️ Cancel", Callback.build(Callback::Kind::List, "", ""))
      rows
    end

    def self.project_dirs_kb(dirs : Array(String)) : Array(Array({String, String}))
      rows = [] of Array({String, String})
      dirs.each_with_index do |d, i|
        rows << btn("➖ #{tilde(d)}", Callback.build(Callback::Kind::RemoveDir, "", "", qi: i))
      end
      rows << btn("➕ Add a directory", "adddir")
      rows << btn("⬅️ Sessions", Callback.build(Callback::Kind::List, "", ""))
      rows
    end

    HISTORY_PAGE = 8

    def self.history_kb(entries : Array(State::Entry), page : Int32 = 0,
                        pages : Int32 = 1) : Array(Array({String, String}))
      rows = [] of Array({String, String})
      entries.each do |e|
        rows << btn(fit("#{e.when_short} · #{row_label(e.name, e.custom?, e.first_prompt)}"),
          Callback.build(Callback::Kind::ClosedCard, e.sid, ""))
      end
      if pages > 1
        nav = [] of {String, String}
        nav << {"◀️", Callback.build(Callback::Kind::HistPage, "", "", qi: page - 1)} if page > 0
        nav << {"page #{page + 1} of #{pages}", Callback.build(Callback::Kind::HistPage, "", "", qi: page)}
        nav << {"▶️", Callback.build(Callback::Kind::HistPage, "", "", qi: page + 1)} if page + 1 < pages
        rows << nav
      end
      rows << btn("🔍 Find", Callback.build(Callback::Kind::Find, "", ""))
      rows << btn("⬅️ Sessions", Callback.build(Callback::Kind::List, "", ""))
      rows
    end

    def self.history_header(total : Int32) : String
      "🕘 Closed sessions — resuming starts a new session in the same directory.\n\n#{total} in all.\ntap one for details."
    end

    # A closed session gets a card of its own — full name, path, time of last
    # activity, the first prompt — and only then "▶️ Resume" (claude-tg-bot:
    # a tap shows the details; whether to resume is decided there).
    def self.closed_card_text(e : State::Entry) : String
      lines = ["🕘 #{named(e.name, e.custom?)}", "📁 #{e.dir}",
               "🕘 Last activity: #{e.when_short}"]
      unless e.first_prompt.empty?
        lines << "💬 It started with: #{e.first_prompt[0, 200]}"
      end
      lines << "\nresuming starts a NEW session in this directory — the context does not carry over."
      lines.join('\n')
    end

    def self.closed_card_kb(sid : String, page : Int32,
                            back : Bool = true) : Array(Array({String, String}))
      rows = [row(
        {"▶️ Resume", Callback.build(Callback::Kind::Resume, sid, "")},
        {"⬅️ Back", Callback.build(Callback::Kind::HistPage, "", "", qi: page)},
      )]
      rows << btn("⬅️ Sessions", Callback.build(Callback::Kind::List, "", ""))
      rows
    end

    def self.search_kb(entries : Array(State::Entry), page : Int32, pages : Int32,
                       query : String) : Array(Array({String, String}))
      rows = history_kb(entries, page, pages)
      # Replace the trailing rows: "Search again" instead of "Find".
      rows.pop
      rows.pop
      rows << btn("🔍 Search again", Callback.build(Callback::Kind::Find, "", ""))
      rows << btn("⬅️ Sessions", Callback.build(Callback::Kind::List, "", ""))
      rows
    end

    def self.search_header(query : String, total : Int32) : String
      "🔍 #{query}\n\n#{total} #{total == 1 ? "match" : "matches"} — names and first prompts."
    end

    # --- View structs ---

    struct SessionView
      getter sid : String
      getter dir_name : String
      getter name : String
      getter status : String
      getter first_prompt : String
      getter? saved_name : Bool

      def initialize(@sid, @dir_name, @name, @status, @saved_name = false,
                     @first_prompt = "")
      end
    end

    struct CardData
      getter name : String
      getter dir : String
      getter status : String
      getter model : String
      getter mode : String
      getter context_pct : Float64
      getter context_tokens : Int64
      getter created_short : String
      getter sid : String
      getter? active : Bool

      def initialize(@name, @dir, @status, @model, @mode, @context_pct,
                     @context_tokens, @created_short, @sid, @active)
      end
    end

    # `~` for paths under home, as claude-tg-bot shortens them on buttons.
    def self.tilde(path : String) : String
      home = ENV["HOME"]?
      if home && path.starts_with?(home)
        "~" + path[home.size..]
      else
        path
      end
    end
  end
end
