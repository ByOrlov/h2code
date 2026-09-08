require "spec"
require "../src/duration_format"

describe DurationFormat do
  describe ".hms" do
    it "formats zero" do
      DurationFormat.hms(0).should eq("00:00")
    end

    it "formats seconds only" do
      DurationFormat.hms(45).should eq("00:45")
    end

    it "pads minutes and seconds" do
      DurationFormat.hms(125).should eq("02:05")
    end

    it "switches to hh:mm:ss from an hour up" do
      DurationFormat.hms(3600).should eq("01:00:00")
      DurationFormat.hms(3725).should eq("01:02:05")
    end

    it "clamps negative input to zero" do
      DurationFormat.hms(-3).should eq("00:00")
    end
  end
end
