require "./spec_helper"

describe H2code::HomePort do
  {% if flag?(:win32) %}
    # Windows adapter: USERPROFILE-driven; exercised on Windows builds.
  {% else %}
    it "returns HOME when set" do
      old = ENV["HOME"]?
      ENV["HOME"] = "/home/port-spec"
      begin
        H2code::HomePort.home.should eq("/home/port-spec")
      ensure
        if old
          ENV["HOME"] = old
        else
          ENV.delete("HOME")
        end
      end
    end

    it "falls back to /tmp when HOME is unset" do
      old = ENV["HOME"]?
      ENV.delete("HOME")
      begin
        H2code::HomePort.home.should eq("/tmp")
      ensure
        if old
          ENV["HOME"] = old
        else
          ENV.delete("HOME")
        end
      end
    end
  {% end %}
end
