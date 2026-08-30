defmodule Exline.Board.LivenessTest do
  use ExUnit.Case, async: true

  alias Exline.Board.Liveness

  # A status-file entry as SelfReport.scan/2 hands it over.
  defp report(overrides \\ %{}) do
    Map.merge(
      %{
        status: :idle,
        age_s: 0,
        waiting_for: nil,
        pid: 4242,
        proc_start: "Sat Aug 29 18:17:48 2026",
        pid_domain: "darwin",
        name: "sess",
        cwd: "/tmp"
      },
      overrides
    )
  end

  describe "parse/1" do
    test "reads the pid and start time out of the ps columns" do
      # Right-aligned pids and the trailing pad `ps` emits for lstart.
      output = " 3331 Sat Aug 29 20:17:48 2026    \n44551 Sun Aug 30 10:58:46 2026    \n"

      assert Liveness.parse(output) ==
               {:ok,
                %{
                  3331 => "Sat Aug 29 20:17:48 2026",
                  44551 => "Sun Aug 30 10:58:46 2026"
                }}
    end

    test "no output is no running pids, not a failure" do
      assert Liveness.parse("") == {:ok, %{}}
    end

    test "a ps usage error is a failure, never an empty roster" do
      # `ps` refuses the whole argument list over one bad pid, printing no rows.
      # Reading that as "nothing is running" would wipe the board.
      assert Liveness.parse("ps: process id too large\n") == :error
    end
  end

  describe "decide/2" do
    test "a running pid whose start time matches is alive" do
      starts = {:ok, %{4242 => "Sat Aug 29 18:17:48 2026"}}
      assert Liveness.decide(report(), starts) == :alive
    end

    test "the same instant in another zone still matches" do
      # The status file records procStart in UTC; ps prints it in local time,
      # so a live session's two renderings differ by the zone offset. Demanding
      # equal strings would call every session dead.
      starts = {:ok, %{4242 => "Sat Aug 29 20:17:48 2026"}}
      assert Liveness.decide(report(), starts) == :alive
    end

    test "a pid missing from ps is a session that quit" do
      assert Liveness.decide(report(), {:ok, %{}}) == :dead
      assert Liveness.decide(report(), {:ok, %{9999 => "Sat Aug 29 18:17:48 2026"}}) == :dead
    end

    test "a running pid with an unrelated start time is a recycled pid, not the session" do
      # Off by 37 seconds: no zone offset explains that, so the pid belongs to
      # some other process now.
      starts = {:ok, %{4242 => "Sat Aug 29 20:18:25 2026"}}
      assert Liveness.decide(report(), starts) == :dead
    end

    test "a start time far enough out to be a different day is dead, not a zone shift" do
      starts = {:ok, %{4242 => "Mon Aug 31 18:17:48 2026"}}
      assert Liveness.decide(report(), starts) == :dead
    end

    test "a file with no pid or no start time cannot be checked" do
      starts = {:ok, %{4242 => "Sat Aug 29 18:17:48 2026"}}
      assert Liveness.decide(report(%{pid: nil}), starts) == :unverifiable
      assert Liveness.decide(report(%{proc_start: nil}), starts) == :unverifiable
    end

    test "a pid from another host's namespace means nothing here" do
      starts = {:ok, %{4242 => "Sat Aug 29 18:17:48 2026"}}
      assert Liveness.decide(report(%{pid_domain: "linux"}), starts) == :unverifiable
      assert Liveness.decide(report(%{pid_domain: nil}), starts) == :unverifiable
    end

    test "an unparseable start time is a format change, not a dead session" do
      starts = {:ok, %{4242 => "2026-08-29T20:17:48Z"}}
      assert Liveness.decide(report(), starts) == :unverifiable
    end

    test "ps failing leaves every session unjudged" do
      assert Liveness.decide(report(), :error) == :unverifiable
    end
  end

  describe "check/1" do
    test "an empty roster answers empty without running ps" do
      assert Liveness.check(%{}) == %{}
    end

    test "a roster with nothing checkable answers without running ps" do
      reports = %{"a" => report(%{pid: nil}), "b" => report(%{pid_domain: "linux"})}
      assert Liveness.check(reports) == %{"a" => :unverifiable, "b" => :unverifiable}
    end

    test "this very OS process reads as alive, and a free pid as dead" do
      # The one test that runs the real `ps`: it pins the whole path — argument
      # shape, output format and the timestamp comparison — against the OS this
      # runs on, which is the only place the format can drift.
      pid = System.pid() |> String.to_integer()

      {output, 0} =
        System.cmd("ps", ["-o", "lstart=", "-p", System.pid()], env: [{"LC_ALL", "C"}])

      reports = %{
        "self" => report(%{pid: pid, proc_start: String.trim(output)}),
        "recycled" => report(%{pid: pid, proc_start: "Sat Aug 29 18:17:48 2026"}),
        "quit" => report(%{pid: free_pid(), proc_start: "Sat Aug 29 18:17:48 2026"})
      }

      assert Liveness.check(reports) ==
               %{"self" => :alive, "recycled" => :dead, "quit" => :dead}
    end

    # A pid inside macOS's range that nothing is using.
    defp free_pid do
      Enum.find(99_990..99_900//-1, fn pid ->
        match?({"", _status}, System.cmd("ps", ["-o", "pid=", "-p", to_string(pid)]))
      end) || flunk("no free pid in the probe range")
    end
  end
end
