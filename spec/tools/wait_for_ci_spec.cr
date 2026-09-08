require "../spec_helper"

WAIT_CI_SPEC_SHA = "c" * 40

module H2code::Tools
  # Drives the pending→terminal transition from a separate fiber after a
  # short delay, mimicking the background poll loop.
  class DelayedCiService < Ci::LiveCiService
    property settle_after : Time::Span = 50.milliseconds

    def observe_and_settle(sha : String, status : Ci::Status) : Nil
      observe(sha, "/tmp")
      obs = observer_for(sha).not_nil!
      spawn do
        sleep settle_after
        obs.status = status
        obs.detail = "1 run(s) passed"
      end
    end
  end

  describe WaitForCI do
    # Drives the pending→terminal transition from a separate fiber after a
    # short delay, mimicking the background poll loop.
    # (helper: DelayedCiService at module level above)

    it "errors when no CI service is wired" do
      old = Ci.service
      Ci.service = nil
      begin
        tool = WaitForCI.new
        result = tool.execute(JSON.parse(%({})))
        result.is_error?.should be_true
        result.content.should contain("not available")
      ensure
        Ci.service = old
      end
    end

    it "errors when no observer is running and the repo is not eligible" do
      old = Ci.service
      with_tmpdir do |dir|
        svc = Ci::LiveCiService.new
        svc.autostart = false
        Ci.service = svc
        tool = WaitForCI.new(dir)

        result = tool.execute(JSON.parse(%({})))
        result.is_error?.should be_true
        result.content.should contain("not eligible")
      ensure
        Ci.service = old
      end
    end

    it "waits for a pending observer and returns success" do
      old = Ci.service
      begin
        svc = DelayedCiService.new
        svc.autostart = false
        svc.settle_after = 50.milliseconds
        svc.observe_and_settle(WAIT_CI_SPEC_SHA, Ci::Status::Success)
        Ci.service = svc
        tool = WaitForCI.new

        result = tool.execute(JSON.parse(%({ "timeout_s": 10 })))
        result.is_error?.should be_false
        result.content.should contain("CI passed")
        result.content.should contain(WAIT_CI_SPEC_SHA[0, 7])
      ensure
        Ci.service = old
      end
    end

    it "returns a failure result with the failure detail" do
      old = Ci.service
      begin
        svc = DelayedCiService.new
        svc.autostart = false
        svc.settle_after = 50.milliseconds
        svc.observe_and_settle(WAIT_CI_SPEC_SHA, Ci::Status::Failure)
        Ci.service = svc
        tool = WaitForCI.new

        result = tool.execute(JSON.parse(%({ "timeout_s": 10 })))
        result.is_error?.should be_true
        result.content.should contain("CI FAILED")
      ensure
        Ci.service = old
      end
    end

    it "claims the observer so no duplicate notification is delivered" do
      old = Ci.service
      begin
        svc = DelayedCiService.new
        svc.autostart = false
        svc.settle_after = 50.milliseconds
        svc.observe_and_settle(WAIT_CI_SPEC_SHA, Ci::Status::Success)
        Ci.service = svc
        tool = WaitForCI.new

        tool.execute(JSON.parse(%({ "timeout_s": 10 })))
        svc.observer_for(WAIT_CI_SPEC_SHA).not_nil!.claimed?.should be_true
      ensure
        Ci.service = old
      end
    end

    it "errors on timeout while the observer keeps running" do
      old = Ci.service
      begin
        svc = DelayedCiService.new
        svc.autostart = false
        svc.settle_after = 5.seconds # never settles within the tool timeout
        svc.observe_and_settle(WAIT_CI_SPEC_SHA, Ci::Status::Success)
        Ci.service = svc
        tool = WaitForCI.new

        result = tool.execute(JSON.parse(%({ "timeout_s": 1 })))
        result.is_error?.should be_true
        result.content.should contain("Timed out")
        svc.observer_for(WAIT_CI_SPEC_SHA).not_nil!.pending?.should be_true
        # Timeout releases the claim so the background delivery still fires.
        svc.observer_for(WAIT_CI_SPEC_SHA).not_nil!.claimed?.should be_false
      ensure
        Ci.service = old
      end
    end
  end
end
