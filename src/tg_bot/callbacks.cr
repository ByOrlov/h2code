module TgBot
  # Inline-keyboard `callback_data` codec. Telegram caps callback_data at
  # 64 bytes; session id and qid are hex (8 chars each in practice), so every
  # shape below fits. Buttons are always addressed — the session id is baked
  # into the callback, so an answer lands exactly where the question came
  # from, whichever session happens to be active.
  #
  # Question/approval shapes (a session's live request):
  #   a:<sid>:<qid>:<qi>:<oi>   answer question qi with option oi (single)
  #   t:<sid>:<qid>:<qi>:<oi>   toggle option oi in multi-select question qi
  #   s:<sid>:<qid>:<qi>        submit the ticked set of multi-select qi
  #   x:<sid>:<qid>             dismiss the question card (empty answers)
  #   p:<sid>:<qid>:<d>         approval decision: 0 deny, 1 allow once, 2 session
  #
  # Navigation shapes (the claude-tg-bot surface — list, card, history):
  #   ls / new / hist / find / ndm   no-argument screens
  #   o:<sid>                   open the session card
  #   k:<sid>:<act>             card action: op open, esc, clr /clear, cmp
  #                             /compact, use limits, ren rename, end exit,
  #                             mdl model picker, mod mode picker
  #   cfg:<sid>:<model>         set the model (rest of the payload, verbatim)
  #   mod:<sid>:<mode>          set the permission mode (auto|manual|yolo)
  #   n:<idx> / nd:<idx>        start a session in config.dirs[idx]
  #   h:<page>                  history page
  #   res:<sid>                 resume a closed session (new session, same dir)
  #   c:<sid>:<action>          legacy session buttons: st status, in
  #                             interrupt, sp stop (kept so buttons printed by
  #                             an older bot answer politely, not silently)
  struct Callback
    enum Kind
      Answer
      Toggle
      Submit
      Dismiss
      Approve
      Command
      NewDir
      List
      NewSession
      History
      HistPage
      Find
      Card
      Action
      ModelSet
      ModeSet
      ManualDir
      Resume
      AddDir
      RemoveDir
      ClosedCard
      ServiceShow
    end

    # Card actions carried by Kind::Action in the qid field.
    module Action
      OPEN = "op"
      ESC  = "esc"
      CLR  = "clr"
      CMP  = "cmp"
      USE  = "use"
      REN  = "ren"
      END  = "end"
      MDL  = "mdl"
      MOD  = "mod"
    end

    getter kind : Kind
    getter sid : String
    getter qid : String
    getter qi : Int32 = -1
    getter oi : Int32 = -1
    getter decision : Int32 = -1

    def initialize(@kind, @sid, @qid, @qi = -1, @oi = -1, @decision = -1)
    end

    def self.build(kind : Kind, sid : String, qid : String,
                   qi : Int32 = -1, oi : Int32 = -1, decision : Int32 = -1) : String
      case kind
      when Kind::Answer     then "a:#{sid}:#{qid}:#{qi}:#{oi}"
      when Kind::Toggle     then "t:#{sid}:#{qid}:#{qi}:#{oi}"
      when Kind::Submit     then "s:#{sid}:#{qid}:#{qi}"
      when Kind::Dismiss    then "x:#{sid}:#{qid}"
      when Kind::Approve    then "p:#{sid}:#{qid}:#{decision}"
      when Kind::Command    then "c:#{sid}:#{qid}"
      when Kind::NewDir     then "n:#{qi}"
      when Kind::List       then "ls"
      when Kind::NewSession then "new"
      when Kind::History    then "hist"
      when Kind::HistPage   then "h:#{qi}"
      when Kind::Find       then "find"
      when Kind::Card       then "o:#{sid}"
      when Kind::Action     then "k:#{sid}:#{qid}"
      when Kind::ModelSet   then "cfg:#{sid}:#{qid}"
      when Kind::ModeSet    then "mod:#{sid}:#{qid}"
      when Kind::ManualDir  then "ndm"
      when Kind::Resume     then "res:#{sid}"
      when Kind::AddDir     then "adddir"
      when Kind::RemoveDir  then "rd:#{qi}"
      when Kind::ClosedCard then "cc:#{sid}"
      when Kind::ServiceShow then "svc"
      else raise "unknown callback kind"
      end
    end

    # Returns nil for data that is not one of ours (foreign keyboards,
    # truncated payloads) — the caller ignores the press.
    def self.parse(data : String?) : Callback?
      return nil if data.nil?
      # No-argument screens: a single token, no colon.
      case data
      when "ls"   then return Callback.new(Kind::List, "", "")
      when "new"  then return Callback.new(Kind::NewSession, "", "")
      when "hist" then return Callback.new(Kind::History, "", "")
      when "find" then return Callback.new(Kind::Find, "", "")
      when "ndm"  then return Callback.new(Kind::ManualDir, "", "")
      when "adddir" then return Callback.new(Kind::AddDir, "", "")
      when "svc"   then return Callback.new(Kind::ServiceShow, "", "")
      end

      parts = data.split(':')
      return nil unless parts.size >= 2
      sid = parts[1]
      return nil if sid.empty?
      # n:<idx> / nd:<idx> — dir picker; the index is resolved against
      # config.dirs at press time, so a stale button (config changed) simply
      # expires.
      if parts[0] == "n" || parts[0] == "nd"
        return nil unless parts.size == 2
        idx = sid.to_i?
        return nil if idx.nil?
        return Callback.new(Kind::NewDir, "", "", qi: idx)
      end
      if parts[0] == "rd"
        return nil unless parts.size == 2
        idx = sid.to_i?
        return nil if idx.nil?
        return Callback.new(Kind::RemoveDir, "", "", qi: idx)
      end
      case parts[0]
      when "a", "t"
        return nil unless parts.size == 5
        qid = parts[2]
        return nil if qid.empty?
        qi = parts[3].to_i?
        oi = parts[4].to_i?
        return nil if qi.nil? || oi.nil?
        Callback.new(parts[0] == "a" ? Kind::Answer : Kind::Toggle, sid, qid, qi, oi)
      when "s"
        return nil unless parts.size == 4
        qid = parts[2]
        return nil if qid.empty?
        qi = parts[3].to_i?
        return nil if qi.nil?
        Callback.new(Kind::Submit, sid, qid, qi)
      when "x"
        return nil unless parts.size == 3
        return nil if parts[2].empty?
        Callback.new(Kind::Dismiss, sid, parts[2])
      when "p"
        return nil unless parts.size == 4
        qid = parts[2]
        return nil if qid.empty?
        d = parts[3].to_i?
        return nil if d.nil?
        Callback.new(Kind::Approve, sid, qid, decision: d)
      when "c"
        # c:<sid>:<action> — legacy buttons from an older bot: for command
        # buttons the qid field carries the action string (st/in/sp).
        return nil unless parts.size == 3
        return nil if parts[2].empty?
        Callback.new(Kind::Command, sid, parts[2])
      when "o"
        return nil unless parts.size == 2
        Callback.new(Kind::Card, sid, "")
      when "k"
        return nil unless parts.size == 3
        return nil if parts[2].empty?
        Callback.new(Kind::Action, sid, parts[2])
      when "cfg"
        # cfg:<sid>:<model> — the model id is the rest of the payload
        # verbatim, so an id containing ':' survives.
        return nil unless parts.size >= 3
        model = parts[2..].join(':')
        return nil if model.empty?
        Callback.new(Kind::ModelSet, sid, model)
      when "mod"
        return nil unless parts.size == 3
        return nil if parts[2].empty?
        Callback.new(Kind::ModeSet, sid, parts[2])
      when "res"
        return nil unless parts.size == 2
        Callback.new(Kind::Resume, sid, "")
      when "cc"
        return nil unless parts.size == 2
        Callback.new(Kind::ClosedCard, sid, "")
      when "h"
        return nil unless parts.size == 2
        page = sid.to_i?
        return nil if page.nil?
        Callback.new(Kind::HistPage, "", "", qi: page)
      else
        nil
      end
    end
  end
end
