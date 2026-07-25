defmodule Exline.CapturesTest do
  use ExUnit.Case

  alias Exline.Captures

  # Captures writes to the config-fixed dirs from config/test.exs, so these
  # tests share global state: not async, dirs wiped per test.
  setup do
    File.rm_rf!(Captures.crash_dir())
    :ok
  end

  defp crash_info do
    try do
      Exline.format(%{"context_window" => %{"used_percentage" => "boom"}})
    catch
      kind, reason -> {kind, reason, __STACKTRACE__}
    end
  end

  test "save_crash persists payload and formatted stacktrace, returns absolute payload path" do
    {kind, reason, stack} = crash_info()
    path = Captures.save_crash(~s({"a":1}), kind, reason, stack)

    assert Path.type(path) == :absolute
    assert File.read!(path) == ~s({"a":1})

    txt = String.replace_suffix(path, ".json", ".txt")
    assert File.read!(txt) =~ "FunctionClauseError"
    assert File.read!(txt) =~ "format_pct"
  end

  test "crashes/0 lists payloads newest first and pruning keeps the last 20" do
    {kind, reason, stack} = crash_info()

    for i <- 1..25 do
      Captures.save_crash("payload-#{i}", kind, reason, stack)
    end

    crashes = Captures.crashes()
    assert length(crashes) == 20
    assert File.read!(hd(crashes)) == "payload-25"
    assert crashes |> List.last() |> File.read!() == "payload-6"
  end
end
