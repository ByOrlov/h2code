require "../spec_helper"

describe H2code::Tools::TodoList do
  it "exposes JS-schema parameter names" do
    todo = H2code::Tools::TodoList.new
    props = todo.parameters["properties"].as_h
    props.has_key?("todos").should be_true
    item_props = props["todos"].as_h["items"].as_h["properties"].as_h
    item_props.has_key?("title").should be_true
    item_props.has_key?("status").should be_true
    item_props.has_key?("content").should be_false
    item_props.has_key?("priority").should be_false
    enum_values = item_props["status"].as_h["enum"].as_a.map(&.to_s)
    enum_values.should contain("pending")
    enum_values.should contain("in_progress")
    enum_values.should contain("done")
    enum_values.should_not contain("completed")
    enum_values.should_not contain("cancelled")
  end

  it "creates a todo list with JS status markers" do
    todo = H2code::Tools::TodoList.new
    result = todo.execute(JSON.parse(%({"todos":[{"title":"task A","status":"pending"},{"title":"task B","status":"done"}]})))
    result.is_error?.should be_false
    result.content.should contain("task A")
    result.content.should contain("task B")
    result.content.should contain("[pending]")
    result.content.should contain("[done]")
  end

  it "appends the write reminder after a mutation" do
    todo = H2code::Tools::TodoList.new
    result = todo.execute(JSON.parse(%({"todos":[{"title":"x","status":"in_progress"}]})))
    result.is_error?.should be_false
    result.content.should contain("in_progress")
    result.content.should contain("Ensure that you continue to use the todo list")
  end

  it "accepts in_progress status" do
    todo = H2code::Tools::TodoList.new
    result = todo.execute(JSON.parse(%({"todos":[{"title":"active","status":"in_progress"}]})))
    result.is_error?.should be_false
    result.content.should contain("[in_progress]")
  end

  it "handles empty todos (clear mode)" do
    todo = H2code::Tools::TodoList.new
    # First populate
    todo.execute(JSON.parse(%({"todos":[{"title":"a","status":"pending"}]})))
    # Then clear
    result = todo.execute(JSON.parse(%({"todos":[]})))
    result.is_error?.should be_false
    result.content.should contain("cleared")
  end

  it "query mode: omit todos to read the current list without mutation" do
    todo = H2code::Tools::TodoList.new
    todo.execute(JSON.parse(%({"todos":[{"title":"read me","status":"pending"}]})))
    result = todo.execute(JSON.parse(%({})))
    result.is_error?.should be_false
    result.content.should contain("read me")
    result.content.should contain("[pending]")
    # No write reminder in query mode.
    result.content.should_not contain("Ensure that you continue")
  end

  it "query mode on an empty list" do
    todo = H2code::Tools::TodoList.new
    result = todo.execute(JSON.parse(%({})))
    result.is_error?.should be_false
    result.content.should contain("empty")
  end

  it "accepts the legacy `completed` status as an alias for `done`" do
    todo = H2code::Tools::TodoList.new
    result = todo.execute(JSON.parse(%({"todos":[{"title":"old","status":"completed"}]})))
    result.is_error?.should be_false
    result.content.should contain("[done]")
  end

  it "defaults status to pending when missing" do
    todo = H2code::Tools::TodoList.new
    result = todo.execute(JSON.parse(%({"todos":[{"title":"no status"}]})))
    result.is_error?.should be_false
    result.content.should contain("[pending]")
  end

  describe "persistence" do
    it "saves todos to <session_dir>/todo.json and reloads them" do
      Dir.tempdir.tap do |tmp|
        session_dir = File.join(tmp, "todo-persist-#{Random::Secure.hex(4)}")
        Dir.mkdir_p(session_dir)

        todo = H2code::Tools::TodoList.new(session_dir)
        todo.execute(JSON.parse(%({"todos":[{"title":"first","status":"done"},{"title":"second","status":"in_progress"}]})))

        path = File.join(session_dir, "todo.json")
        File.exists?(path).should be_true
        File.read(path).should contain("second")

        # A fresh instance (simulated restart) restores the list.
        restored = H2code::Tools::TodoList.new(session_dir)
        restored.todos.size.should eq(2)
        restored.todos[0].title.should eq("first")
        restored.todos[0].status.should eq(H2code::Tools::TodoStatus::Done)
        restored.todos[1].status.should eq(H2code::Tools::TodoStatus::InProgress)

        result = restored.execute(JSON.parse(%({})))
        result.content.should contain("[done] first")
        result.content.should contain("[in_progress] second")
      end
    end

    it "persists a clear as an empty list" do
      Dir.tempdir.tap do |tmp|
        session_dir = File.join(tmp, "todo-clear-#{Random::Secure.hex(4)}")
        Dir.mkdir_p(session_dir)

        todo = H2code::Tools::TodoList.new(session_dir)
        todo.execute(JSON.parse(%({"todos":[{"title":"x","status":"pending"}]})))
        todo.execute(JSON.parse(%({"todos":[]})))

        restored = H2code::Tools::TodoList.new(session_dir)
        restored.todos.empty?.should be_true
      end
    end

    it "clear! persists the empty state so a restart doesn't resurrect the list" do
      Dir.tempdir.tap do |tmp|
        session_dir = File.join(tmp, "todo-clear-bang-#{Random::Secure.hex(4)}")
        Dir.mkdir_p(session_dir)

        todo = H2code::Tools::TodoList.new(session_dir)
        todo.execute(JSON.parse(%({"todos":[{"title":"old","status":"done"}]})))

        todo.clear!
        todo.todos.empty?.should be_true
        File.read(File.join(session_dir, "todo.json")).should eq("[]")

        # A fresh instance (simulated restart / --resume) restores an empty list.
        restored = H2code::Tools::TodoList.new(session_dir)
        restored.todos.empty?.should be_true
      end
    end

    it "ignores a corrupt todo.json" do
      Dir.tempdir.tap do |tmp|
        session_dir = File.join(tmp, "todo-corrupt-#{Random::Secure.hex(4)}")
        Dir.mkdir_p(session_dir)
        File.write(File.join(session_dir, "todo.json"), "{not json")

        todo = H2code::Tools::TodoList.new(session_dir)
        todo.todos.empty?.should be_true
      end
    end

    it "stays in-memory without a session_dir" do
      todo = H2code::Tools::TodoList.new
      todo.execute(JSON.parse(%({"todos":[{"title":"a","status":"pending"}]})))
      todo.session_dir.should be_nil
    end
  end
end
