defmodule Exline.SplitChainTest do
  use ExUnit.Case, async: true

  alias Exline.SplitChain

  @moduletag :tmp_dir

  defp record(from, to) do
    JSON.encode!(%{
      "time" => "2026-10-30T20:55:12+01:00",
      "from" => %{"session" => from, "name" => nil, "cwd" => "/x", "transcript" => "/x.jsonl"},
      "to" => %{"session" => to, "name" => "next", "cwd" => "/x"},
      "handoff" => "/x/handoff.md",
      "by" => "user",
      "reason" => "context filling up"
    })
  end

  defp write_log(dir, lines) do
    path = Path.join(dir, "split-chain.jsonl")
    File.write!(path, Enum.map_join(lines, "", &(&1 <> "\n")))
    path
  end

  test "nil when the log does not exist", %{tmp_dir: dir} do
    assert SplitChain.count("s1", Path.join(dir, "missing.jsonl")) == nil
  end

  test "nil when no record leads to the session", %{tmp_dir: dir} do
    path = write_log(dir, [record("a", "b")])
    assert SplitChain.count("other", path) == nil
    # The session that was split away from did not itself come from a split.
    assert SplitChain.count("a", path) == nil
  end

  test "nil for a session id that is not a string", %{tmp_dir: dir} do
    path = write_log(dir, [record("a", "b")])
    assert SplitChain.count(nil, path) == nil
  end

  test "a chain of one", %{tmp_dir: dir} do
    path = write_log(dir, [record("a", "b")])
    assert SplitChain.count("b", path) == 1
  end

  test "a chain of three, records in any order and among unrelated ones", %{tmp_dir: dir} do
    path =
      write_log(dir, [record("c", "d"), record("x", "y"), record("a", "b"), record("b", "c")])

    assert SplitChain.count("d", path) == 3
    assert SplitChain.count("c", path) == 2
  end

  test "skips malformed lines", %{tmp_dir: dir} do
    path =
      write_log(dir, [
        record("a", "b"),
        "not json",
        ~s({"from":{"session":"b"}}),
        ~s({"from":"b","to":{"session":"c"}}),
        record("b", "c")
      ])

    assert SplitChain.count("c", path) == 2
  end

  test "stops at a cycle", %{tmp_dir: dir} do
    path = write_log(dir, [record("a", "b"), record("b", "a")])
    assert SplitChain.count("b", path) == 2
  end

  test "picks up a record appended after the first read", %{tmp_dir: dir} do
    path = write_log(dir, [record("a", "b")])
    assert SplitChain.count("c", path) == nil
    File.write!(path, record("b", "c") <> "\n", [:append])
    assert SplitChain.count("c", path) == 2
  end
end
