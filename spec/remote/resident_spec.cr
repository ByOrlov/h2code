require "../spec_helper"
require "../../src/remote/resident"

describe H2code::Remote::ResidentSession do
  describe ".map_answers" do
    it "maps plain string answers" do
      result = H2code::Remote::ResidentSession.map_answers(
        JSON.parse(%({"Pick?": "A"})))
      result["Pick?"].should eq("A")
    end

    it "joins array answers with a comma" do
      result = H2code::Remote::ResidentSession.map_answers(
        JSON.parse(%({"Pick?": ["A", "B"]})))
      result["Pick?"].should eq("A, B")
    end

    it "treats a non-object answers payload as dismissed" do
      result = H2code::Remote::ResidentSession.map_answers(JSON.parse("42"))
      result.empty?.should be_true
    end
  end

  describe ".parse_decision" do
    it "maps socket decisions to approval choices" do
      H2code::Remote::ResidentSession.parse_decision("allow").should eq(H2code::Permission::ApprovalChoice::ApproveOnce)
      H2code::Remote::ResidentSession.parse_decision("allow_session").should eq(H2code::Permission::ApprovalChoice::ApproveSession)
      H2code::Remote::ResidentSession.parse_decision("deny").should eq(H2code::Permission::ApprovalChoice::Deny)
      H2code::Remote::ResidentSession.parse_decision("garbage").should eq(H2code::Permission::ApprovalChoice::Deny)
    end
  end

  it "bridges a question over the socket: ev:question out, op:answer in" do
    with_tmpdir do |dir|
      session = resident_session(dir, question_timeout: 5.seconds)
      session.socket.rebind(dir)
      client = UNIXSocket.new(File.join(dir, "control.sock"))
      client.read_timeout = 5
      sleep 50.milliseconds

      done = Channel(H2code::Tools::QuestionResult?).new(1)
      spawn do
        req = H2code::Tools::QuestionRequest.new([
          H2code::Tools::QuestionItem.new(
            "Pick one?",
            [H2code::Tools::QuestionOption.new("A"), H2code::Tools::QuestionOption.new("B", "second")],
            header: "Choice"),
          H2code::Tools::QuestionItem.new(
            "Pick many?", [H2code::Tools::QuestionOption.new("X")],
            multi_select: true),
        ] of H2code::Tools::QuestionItem)
        done.send(session.question_service.request(req, nil))
      end

      frame = JSON.parse(client.gets.to_s)
      frame["ev"].to_s.should eq("question")
      qid = frame["qid"].to_s
      questions = frame["questions"].as_a
      questions.size.should eq(2)
      questions[0]["question"].to_s.should eq("Pick one?")
      questions[0]["header"].to_s.should eq("Choice")
      questions[0]["options"].as_a.size.should eq(2)
      questions[1]["multiSelect"].as_bool.should be_true

      client << {"op" => "answer", "qid" => qid,
                 "answers" => {"Pick one?" => "A", "Pick many?" => ["X"]}}.to_json << '\n'
      reply = JSON.parse(client.gets.to_s)
      reply["ok"].as_bool.should be_true

      result = done.receive
      result.should_not be_nil
      result.not_nil!["Pick one?"].should eq("A")
      result.not_nil!["Pick many?"].should eq("X")

      client.close
      session.socket.close
    end
  end

  it "resolves a question as dismissed when op:answer carries no answers" do
    with_tmpdir do |dir|
      session = resident_session(dir, question_timeout: 5.seconds)
      session.socket.rebind(dir)
      client = UNIXSocket.new(File.join(dir, "control.sock"))
      client.read_timeout = 5
      sleep 50.milliseconds

      done = Channel(H2code::Tools::QuestionResult?).new(1)
      spawn do
        req = H2code::Tools::QuestionRequest.new([
          H2code::Tools::QuestionItem.new("Q?", [H2code::Tools::QuestionOption.new("A")]),
        ] of H2code::Tools::QuestionItem)
        done.send(session.question_service.request(req, nil))
      end

      frame = JSON.parse(client.gets.to_s)
      client << {"op" => "answer", "qid" => frame["qid"].to_s,
                 "answers" => {} of String => String}.to_json << '\n'
      JSON.parse(client.gets.to_s)["ok"].as_bool.should be_true

      done.receive.not_nil!.empty?.should be_true

      client.close
      session.socket.close
    end
  end

  it "lapses a question into the dismissed branch on timeout" do
    with_tmpdir do |dir|
      session = resident_session(dir, question_timeout: 100.milliseconds)
      session.socket.rebind(dir)
      client = UNIXSocket.new(File.join(dir, "control.sock"))
      client.read_timeout = 5
      sleep 50.milliseconds

      done = Channel(H2code::Tools::QuestionResult?).new(1)
      spawn do
        req = H2code::Tools::QuestionRequest.new([
          H2code::Tools::QuestionItem.new("Q?", [H2code::Tools::QuestionOption.new("A")]),
        ] of H2code::Tools::QuestionItem)
        done.send(session.question_service.request(req, nil))
      end

      client.gets.to_s.should contain("question")
      done.receive.not_nil!.empty?.should be_true

      client.close
      session.socket.close
    end
  end

  it "bridges approvals: ev:approval out, op:approve in" do
    with_tmpdir do |dir|
      session = resident_session(dir, approval_timeout: 5.seconds)
      session.socket.rebind(dir)
      client = UNIXSocket.new(File.join(dir, "control.sock"))
      client.read_timeout = 5
      sleep 50.milliseconds

      done = Channel(H2code::Permission::ApprovalChoice).new(1)
      spawn do
        done.send(session.approval_callback("Bash", %({"command":"ls"}), nil))
      end

      frame = JSON.parse(client.gets.to_s)
      frame["ev"].to_s.should eq("approval")
      frame["tool"].to_s.should eq("Bash")
      frame["args"].to_s.should contain("ls")
      qid = frame["qid"].to_s

      client << {"op" => "approve", "qid" => qid, "decision" => "allow_session"}.to_json << '\n'
      JSON.parse(client.gets.to_s)["ok"].as_bool.should be_true
      done.receive.should eq(H2code::Permission::ApprovalChoice::ApproveSession)

      client.close
      session.socket.close
    end
  end

  it "denies an approval when the remote user never answers" do
    with_tmpdir do |dir|
      session = resident_session(dir, approval_timeout: 100.milliseconds)
      session.socket.rebind(dir)
      client = UNIXSocket.new(File.join(dir, "control.sock"))
      client.read_timeout = 5
      sleep 50.milliseconds

      done = Channel(H2code::Permission::ApprovalChoice).new(1)
      spawn do
        done.send(session.approval_callback("Bash", "args", "high"))
      end

      frame = JSON.parse(client.gets.to_s)
      frame["danger"].to_s.should eq("high")
      done.receive.should eq(H2code::Permission::ApprovalChoice::Deny)

      client.close
      session.socket.close
    end
  end

  it "interrupts a running turn: ok reply, turn ended ok=false, next prompt works" do
    with_tmpdir do |dir|
      script = [
        H2code::LLM::MockStep.new(
          parts: [H2code::LLM::ToolCallPart.new("m1", "Bash", %({"command":"sleep 5"}))] of H2code::LLM::MessagePart,
          stop_reason: "tool_use",
          part_delay_ms: 300),
        H2code::LLM::MockStep.new(
          parts: [H2code::LLM::TextPart.new("after")] of H2code::LLM::MessagePart,
          stop_reason: "end_turn",
          part_delay_ms: 300),
      ]
      provider = H2code::LLM::MockProvider.new(script)
      memory = H2code::Context::Memory.new
      agent = H2code::Loop::Agent.new(provider, memory,
        H2code::Tools::Registry.new,
        H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo))
      store = H2code::Session::Store.new(dir)
      session = H2code::Remote::ResidentSession.new(agent, store, "sys", "test-model")
      session.wire
      session.socket.rebind(dir)
      client = UNIXSocket.new(File.join(dir, "control.sock"))
      client.read_timeout = 10
      sleep 50.milliseconds

      session.deliver("go")
      loop do
        line = client.gets.to_s
        break if line.includes?(%("phase":"started"))
      end

      client << {"op" => "interrupt"}.to_json << '\n'
      reply = JSON.parse(client.gets.to_s)
      reply["ok"].as_bool.should be_true

      ended = false
      20.times do
        line = client.gets.to_s
        if (f = JSON.parse(line)["ev"]?.try(&.to_s)) == "turn"
          ended = f == "turn" && JSON.parse(line)["phase"]?.try(&.to_s) == "ended" &&
                  JSON.parse(line)["ok"]?.try(&.as_bool?) == false
          break if ended
        end
      end
      ended.should be_true

      # The cancelled turn leaves a marker so the next turn's model sees why.
      memory.messages.any? { |m| m.role == "user" }.should be_true

      # The session keeps serving: a fresh prompt runs a fresh turn.
      session.deliver("again")
      saw_end = saw_text = false
      20.times do
        line = client.gets.to_s
        break if line.empty?
        f = JSON.parse(line)
        saw_text = true if f["ev"]?.try(&.to_s) == "assistant"
        if f["ev"]?.try(&.to_s) == "turn" && f["phase"]?.try(&.to_s) == "ended"
          saw_end = f["ok"]?.try(&.as_bool?) == true
        end
        break if saw_end
      end
      saw_end.should be_true

      client.close
      session.socket.close
    end
  end

end

private def resident_session(dir : String,
                             question_timeout : Time::Span = 5.seconds,
                             approval_timeout : Time::Span = 5.seconds)
  provider = H2code::LLM::MockProvider.new([] of H2code::LLM::MockStep)
  memory = H2code::Context::Memory.new
  tools = H2code::Tools::Registry.new
  permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
  agent = H2code::Loop::Agent.new(provider, memory, tools, permission)
  store = H2code::Session::Store.new(dir)
  session = H2code::Remote::ResidentSession.new(agent, store, "sys", "test-model",
    question_timeout: question_timeout,
    approval_timeout: approval_timeout)
  session.wire
  session
end
