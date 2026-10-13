require "../spec_helper"
require "../../src/remote/control_socket"

describe H2code::Remote::ControlSocket do
  it "pushes event frames to connected clients" do
    with_tmpdir do |dir|
      sock = H2code::Remote::ControlSocket.new(
        ->(t : String) { },
        -> { },
        -> { false },
      )
      sock.rebind(dir)
      client = UNIXSocket.new(File.join(dir, "control.sock"))
      client.read_timeout = 5
      sleep 50.milliseconds # accept_loop fiber must register the client

      sock.emit("turn", {"phase" => JSON::Any.new("started")})
      frame = JSON.parse(client.gets.to_s)
      frame["ev"].to_s.should eq("turn")
      frame["phase"].to_s.should eq("started")

      client.close
      sock.close
    end
  end

  it "answers op:status with busy and status extras" do
    with_tmpdir do |dir|
      sock = H2code::Remote::ControlSocket.new(
        ->(t : String) { },
        -> { },
        -> { true },
        status_extras: -> { {"model" => JSON::Any.new("m1")} of String => JSON::Any },
      )
      sock.rebind(dir)
      client = UNIXSocket.new(File.join(dir, "control.sock"))
      client.read_timeout = 5
      sleep 50.milliseconds

      reply = rpc(client, {"op" => "status"})
      reply["ok"].as_bool.should be_true
      reply["busy"].as_bool.should be_true
      reply["model"].to_s.should eq("m1")

      client.close
      sock.close
    end
  end

  it "delivers op:answer to on_answer with qid and answers" do
    with_tmpdir do |dir|
      got = Channel({String, JSON::Any}).new(1)
      sock = H2code::Remote::ControlSocket.new(
        ->(t : String) { },
        -> { },
        -> { false },
        on_answer: ->(qid : String, answers : JSON::Any) { got.send({qid, answers}); nil },
      )
      sock.rebind(dir)
      client = UNIXSocket.new(File.join(dir, "control.sock"))
      client.read_timeout = 5
      sleep 50.milliseconds

      reply = rpc(client, {"op" => "answer", "qid" => "q1", "answers" => {"Pick?" => "A"}})
      reply["ok"].as_bool.should be_true
      qid, answers = got.receive
      qid.should eq("q1")
      answers["Pick?"].to_s.should eq("A")

      # answer without payload is rejected
      reply = rpc(client, {"op" => "answer", "qid" => "q1"})
      reply["ok"].as_bool.should be_false

      client.close
      sock.close
    end
  end

  it "validates op:approve decisions and forwards valid ones" do
    with_tmpdir do |dir|
      got = Channel({String, String}).new(1)
      sock = H2code::Remote::ControlSocket.new(
        ->(t : String) { },
        -> { },
        -> { false },
        on_approve: ->(qid : String, decision : String) { got.send({qid, decision}); nil },
      )
      sock.rebind(dir)
      client = UNIXSocket.new(File.join(dir, "control.sock"))
      client.read_timeout = 5
      sleep 50.milliseconds

      reply = rpc(client, {"op" => "approve", "qid" => "a1", "decision" => "yolo"})
      reply["ok"].as_bool.should be_false

      reply = rpc(client, {"op" => "approve", "qid" => "a1", "decision" => "allow_session"})
      reply["ok"].as_bool.should be_true
      qid, decision = got.receive
      qid.should eq("a1")
      decision.should eq("allow_session")

      client.close
      sock.close
    end
  end

  it "calls on_exit and rejects unsupported ops and malformed lines" do
    with_tmpdir do |dir|
      exited = Channel(Nil).new(1)
      sock = H2code::Remote::ControlSocket.new(
        ->(t : String) { },
        -> { },
        -> { false },
        on_exit: -> { exited.send(nil); nil },
      )
      sock.rebind(dir)
      client = UNIXSocket.new(File.join(dir, "control.sock"))
      client.read_timeout = 5
      sleep 50.milliseconds

      reply = rpc(client, {"op" => "nope"})
      reply["ok"].as_bool.should be_false

      client << "not json\n"
      reply = JSON.parse(client.gets.to_s)
      reply["ok"].as_bool.should be_false

      reply = rpc(client, {"op" => "exit"})
      reply["ok"].as_bool.should be_true
      exited.receive

      client.close
      sock.close
    end
  end

  it "does not push to write-only clients that never subscribed" do
    # A one-way client (h2code-remote) connects, sends ops and closes;
    # emit must not crash or block when such a client is gone.
    with_tmpdir do |dir|
      sock = H2code::Remote::ControlSocket.new(
        ->(t : String) { },
        -> { },
        -> { false },
      )
      sock.rebind(dir)
      client = UNIXSocket.new(File.join(dir, "control.sock"))
      client.read_timeout = 5
      sleep 50.milliseconds
      client.close
      sleep 50.milliseconds

      sock.emit("assistant", {"text" => JSON::Any.new("hi")})
      sock.close
    end
  end
end

private def rpc(client : UNIXSocket, payload : Hash) : JSON::Any
  client << payload.to_json << '\n'
  client.flush
  JSON.parse(client.gets.to_s)
end
