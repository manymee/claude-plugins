defmodule Exline.SessionConfigTest do
  # Not async: these tests set EXLINE_CONFIG, which is VM-global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Exline.SessionConfig
  alias Exline.Sessions

  @moduletag :tmp_dir

  defp write_config(dir, contents) do
    path = Path.join(dir, "exline.json")
    File.write!(path, contents)
    path
  end

  defp defaults, do: SessionConfig.default_thresholds()

  describe "thresholds/1" do
    test "reads a valid config file", %{tmp_dir: dir} do
      path =
        write_config(
          dir,
          ~s({"context_thresholds": [{"percent": 25, "message": "at {percent}%"}]})
        )

      assert capture_log(fn ->
               assert SessionConfig.thresholds(path) == [%{percent: 25, message: "at {percent}%"}]
             end) == ""
    end

    test "falls back to the defaults silently when the file is missing", %{tmp_dir: dir} do
      path = Path.join(dir, "absent.json")

      assert capture_log(fn ->
               assert SessionConfig.thresholds(path) == defaults()
             end) == ""
    end

    test "falls back silently when the file configures no thresholds", %{tmp_dir: dir} do
      path = write_config(dir, ~s({"something_else": true}))

      assert capture_log(fn ->
               assert SessionConfig.thresholds(path) == defaults()
             end) == ""
    end

    test "warns and falls back on malformed JSON", %{tmp_dir: dir} do
      path = write_config(dir, "not json at all")

      log = capture_log(fn -> assert SessionConfig.thresholds(path) == defaults() end)
      assert log =~ "invalid JSON"
      assert log =~ path
    end

    test "warns and falls back when the top level is not an object", %{tmp_dir: dir} do
      path = write_config(dir, ~s([{"percent": 25, "message": "at {percent}%"}]))

      assert capture_log(fn -> assert SessionConfig.thresholds(path) == defaults() end) =~
               "not a JSON object"
    end

    test "warns and falls back on an empty threshold list", %{tmp_dir: dir} do
      path = write_config(dir, ~s({"context_thresholds": []}))

      assert capture_log(fn -> assert SessionConfig.thresholds(path) == defaults() end) =~
               "non-empty list"
    end

    test "warns and falls back when context_thresholds is not a list", %{tmp_dir: dir} do
      path = write_config(dir, ~s({"context_thresholds": {"percent": 25}}))

      assert capture_log(fn -> assert SessionConfig.thresholds(path) == defaults() end) =~
               "non-empty list"
    end

    test "warns and falls back on an out-of-range percent", %{tmp_dir: dir} do
      path = write_config(dir, ~s({"context_thresholds": [{"percent": 140, "message": "hi"}]}))

      assert capture_log(fn -> assert SessionConfig.thresholds(path) == defaults() end) =~
               "invalid context_thresholds entry"
    end

    test "warns and falls back on a non-numeric percent", %{tmp_dir: dir} do
      path = write_config(dir, ~s({"context_thresholds": [{"percent": "40", "message": "hi"}]}))

      assert capture_log(fn -> assert SessionConfig.thresholds(path) == defaults() end) =~
               "invalid context_thresholds entry"
    end

    test "warns and falls back on a blank message", %{tmp_dir: dir} do
      path = write_config(dir, ~s({"context_thresholds": [{"percent": 40, "message": "  "}]}))

      assert capture_log(fn -> assert SessionConfig.thresholds(path) == defaults() end) =~
               "invalid context_thresholds entry"
    end

    test "rejects the whole file when a single entry is bad", %{tmp_dir: dir} do
      path =
        write_config(dir, ~s({"context_thresholds": [
          {"percent": 40, "message": "fine"},
          {"percent": 50}
        ]}))

      assert capture_log(fn -> assert SessionConfig.thresholds(path) == defaults() end) =~
               "invalid context_thresholds entry"
    end
  end

  describe "config_path/0" do
    test "honors EXLINE_CONFIG", %{tmp_dir: dir} do
      path = Path.join(dir, "custom.json")
      System.put_env("EXLINE_CONFIG", path)
      on_exit(fn -> System.delete_env("EXLINE_CONFIG") end)

      assert SessionConfig.config_path() == path
    end

    test "defaults to ~/.claude/exline.json" do
      System.delete_env("EXLINE_CONFIG")
      assert SessionConfig.config_path() == Path.expand("~/.claude/exline.json")
    end
  end

  describe "repeat_every/1" do
    test "reads a positive integer", %{tmp_dir: dir} do
      path = write_config(dir, ~s({"context_repeat_every": 5}))
      assert SessionConfig.repeat_every(path) == 5
    end

    test "nil when the file or the key is missing", %{tmp_dir: dir} do
      assert SessionConfig.repeat_every(Path.join(dir, "absent.json")) == nil
      assert SessionConfig.repeat_every(write_config(dir, ~s({}))) == nil
    end

    test "warns and ignores a non-positive or non-integer value", %{tmp_dir: dir} do
      for bad <- [~s("5"), "0", "-3", "2.5"] do
        path = write_config(dir, ~s({"context_repeat_every": #{bad}}))

        assert capture_log(fn -> assert SessionConfig.repeat_every(path) == nil end) =~
                 "context_repeat_every"
      end
    end
  end

  describe "Exline.Sessions wiring" do
    test "loads its repeat step from the config file at init", %{tmp_dir: dir} do
      path =
        write_config(
          dir,
          ~s({"context_thresholds": [{"percent": 20, "message": "at {percent}"}], "context_repeat_every": 10})
        )

      System.put_env("EXLINE_CONFIG", path)
      on_exit(fn -> System.delete_env("EXLINE_CONFIG") end)

      sessions = start_supervised!({Sessions, name: nil})
      Sessions.update(sessions, "s", 33)

      assert %{percent: 30, message: "at 33"} = Sessions.hook_report(sessions, "s")
    end

    test "loads its thresholds from the config file at init", %{tmp_dir: dir} do
      path =
        write_config(
          dir,
          ~s({"context_thresholds": [{"percent": 25, "message": "custom {percent}"}]})
        )

      System.put_env("EXLINE_CONFIG", path)
      on_exit(fn -> System.delete_env("EXLINE_CONFIG") end)

      sessions = start_supervised!({Sessions, name: nil})
      Sessions.update(sessions, "s", 30)

      assert %{percent: 25, message: "custom 30"} = Sessions.hook_report(sessions, "s")
    end
  end
end
