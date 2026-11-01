require "../spec_helper"
require "../../src/tg_bot/api"

# The Api talks to a local HTTP::Server (via the injectable http_base), so
# the envelope-unwrapping contract with the Bot API is tested without
# Telegram: `call` must unwrap "result" exactly once.
describe TgBot::Api do
  it "unwraps the result envelope once for every call" do
    server = HTTP::Server.new do |context|
      path = context.request.path.not_nil!
      case
      when path.includes?("getMe")
        reply(context, {"ok" => true, "result" => {"id" => 7, "username" => "t"}})
      when path.includes?("getUpdates")
        reply(context, {"ok" => true, "result" => [{"update_id" => 11}]})
      when path.includes?("sendMessage")
        reply(context, {"ok" => true, "result" => {"message_id" => 42, "text" => "hi"}})
      when path.includes?("getFile")
        reply(context, {"ok" => true, "result" => {"file_path" => "documents/a.txt"}})
      when path.includes?("deleteMessage")
        reply(context, {"ok" => false, "error_code" => 400, "description" => "Bad Request: nope"})
      else
        context.response.status_code = 404
      end
    end
    address = server.bind_unused_port
    spawn { server.listen }

    api = TgBot::Api.new("token", http_base: "http://#{address}")

    me = api.get_me
    me["username"].to_s.should eq("t")

    updates = api.get_updates(0_i64, timeout: 0)
    updates.size.should eq(1)
    updates[0]["update_id"].to_s.should eq("11")

    message = api.send_message(1_i64, "hi").should_not be_nil
    message["message_id"].to_s.should eq("42")

    api.get_file_path("f1").should eq("documents/a.txt")

    expect_raises(TgBot::ApiError, /400.*nope/) do
      api.delete_message(1_i64, 2_i64)
    end

    server.close
  end

end

private def reply(context : HTTP::Server::Context, payload : Hash)
  context.response.content_type = "application/json"
  context.response.print(payload.to_json)
end
