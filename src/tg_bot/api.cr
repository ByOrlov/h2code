require "http/client"
require "json"

module TgBot
  class ApiError < Exception
    getter error_code : Int32

    def initialize(@error_code, description)
      super("Telegram API #{error_code}: #{description}")
    end
  end

  # Minimal Telegram Bot API client over HTTP::Client (stdlib only):
  # long-polling getUpdates, sendMessage/editMessageText/deleteMessage with
  # inline keyboards, answerCallbackQuery, file download. Network errors
  # propagate to the caller — the long-poll loop decides whether to retry.
  class Api
    API_BASE = "https://api.telegram.org"

    def initialize(@token : String, @http_base : String = API_BASE)
    end

    def get_me : JSON::Any
      call("getMe")
    end

    # Register the "/" menu (setMyCommands) and make the button beside the
    # input box open it — two separate things, and a chat left on "default"
    # may show the attachment clip instead (claude-tg-bot lesson).
    def set_my_commands(commands : Array({String, String})) : Nil
      cmds = commands.map do |(cmd, desc)|
        JSON::Any.new({
          "command"     => JSON::Any.new(cmd),
          "description" => JSON::Any.new(desc),
        } of String => JSON::Any)
      end
      call("setMyCommands", {"commands" => JSON::Any.new(cmds)})
      call("setChatMenuButton", {"menu_button" => JSON::Any.new({
        "type" => JSON::Any.new("commands"),
      } of String => JSON::Any)})
      nil
    end

    # Long poll. `timeout` is the server-side wait (seconds); the HTTP read
    # timeout is a bit above so a quiet poll returns, not times out.
    def get_updates(offset : Int64, timeout : Int32 = 50) : Array(JSON::Any)
      # call() already unwraps the "result" envelope.
      call("getUpdates", {"offset" => JSON::Any.new(offset), "timeout" => JSON::Any.new(timeout)}).as_a
    end

    def send_message(chat_id : Int64, text : String,
                     keyboard : Array(Array({String, String}))? = nil,
                     parse_mode : String? = nil) : JSON::Any?
      params = {
        "chat_id" => JSON::Any.new(chat_id),
        "text"    => JSON::Any.new(text),
      } of String => JSON::Any
      params["parse_mode"] = JSON::Any.new(parse_mode) if parse_mode
      params["reply_markup"] = keyboard_markup(keyboard) if keyboard
      # call() already unwraps the "result" envelope (the sent message).
      call("sendMessage", params)
    end

    # Persistent reply keyboard — the main-command buttons that live in the
    # chat input area on the phone. Buttons send their own text (e.g. "📊 /status"),
    # which flows through the normal message handling.
    def send_keyboard(chat_id : Int64, text : String,
                      buttons : Array(Array(String))) : JSON::Any?
      rows = buttons.map do |row|
        JSON::Any.new(row.map { |b|
          JSON::Any.new({"text" => JSON::Any.new(b)} of String => JSON::Any)
        })
      end
      params = {
        "chat_id"      => JSON::Any.new(chat_id),
        "text"         => JSON::Any.new(text),
        "reply_markup" => JSON::Any.new({
          "keyboard"        => JSON::Any.new(rows),
          "resize_keyboard" => JSON::Any.new(true),
        } of String => JSON::Any),
      } of String => JSON::Any
      call("sendMessage", params)
    end

    def edit_message_text(chat_id : Int64, message_id : Int64, text : String,
                          keyboard : Array(Array({String, String}))? = nil,
                          parse_mode : String? = nil) : Nil
      params = {
        "chat_id"    => JSON::Any.new(chat_id),
        "message_id" => JSON::Any.new(message_id),
        "text"       => JSON::Any.new(text),
      } of String => JSON::Any
      params["parse_mode"] = JSON::Any.new(parse_mode) if parse_mode
      params["reply_markup"] = keyboard_markup(keyboard) if keyboard
      call("editMessageText", params)
      nil
    end

    def edit_keyboard(chat_id : Int64, message_id : Int64,
                      keyboard : Array(Array({String, String}))? = nil) : Nil
      params = {
        "chat_id"    => JSON::Any.new(chat_id),
        "message_id" => JSON::Any.new(message_id),
      } of String => JSON::Any
      params["reply_markup"] = keyboard_markup(keyboard) if keyboard
      call("editMessageReplyMarkup", params)
      nil
    end

    def delete_message(chat_id : Int64, message_id : Int64) : Nil
      call("deleteMessage", {
        "chat_id"    => JSON::Any.new(chat_id),
        "message_id" => JSON::Any.new(message_id),
      })
      nil
    end

    def answer_callback_query(id : String, text : String? = nil) : Nil
      params = {"callback_query_id" => JSON::Any.new(id)} of String => JSON::Any
      params["text"] = JSON::Any.new(text) if text
      call("answerCallbackQuery", params)
      nil
    end

    # file_path for a file_id, or nil when the API refuses.
    def get_file_path(file_id : String) : String?
      # call() already unwraps the "result" envelope (the file object).
      call("getFile", {"file_id" => JSON::Any.new(file_id)})["file_path"]?.try(&.to_s)
    end

    # Download a file_path (from get_file_path) into dest.
    def download_file(file_path : String, dest : String) : Nil
      url = "#{@http_base}/file/bot#{@token}/#{file_path}"
      uri = URI.parse(url)
      HTTP::Client.new(uri) do |client|
        client.read_timeout = 120.seconds
        client.get(uri.request_target) do |response|
          raise "download failed: HTTP #{response.status_code}" unless response.success?
          File.write(dest, response.body_io)
        end
      end
    end

    private def keyboard_markup(keyboard : Array(Array({String, String})))
      rows = keyboard.map do |row|
        JSON::Any.new(row.map { |(label, data)|
          JSON::Any.new({"text" => JSON::Any.new(label), "callback_data" => JSON::Any.new(data)} of String => JSON::Any)
        })
      end
      JSON::Any.new({"inline_keyboard" => JSON::Any.new(rows)} of String => JSON::Any)
    end

    private def call(method : String, params = {} of String => JSON::Any) : JSON::Any
      uri = URI.parse("#{@http_base}/bot#{@token}/#{method}")
      body = HTTP::Client.new(uri) do |client|
        client.connect_timeout = 30.seconds
        # Above the long-poll server wait so a quiet poll returns normally.
        client.read_timeout = 90.seconds
        client.post(uri.request_target,
          headers: HTTP::Headers{"Content-Type" => "application/json"},
          body: params.to_json) do |response|
          response.body_io.gets_to_end
        end
      end
      json = JSON.parse(body)
      unless json["ok"]?.try(&.as_bool?)
        raise ApiError.new(json["error_code"]?.try(&.as_i?) || 0,
          json["description"]?.try(&.to_s) || "unknown error")
      end
      json["result"]? || JSON::Any.new(nil)
    end
  end
end
