defmodule Exline.SessionsTest do
  use ExUnit.Case, async: true

  alias Exline.Sessions

  @thresholds [
    %{percent: 40, message: "Context at {percent}% — first."},
    %{percent: 50, message: "Context at {percent}% — second."},
    %{percent: 60, message: "Context at {percent}% — third."}
  ]

  @session "session-a"

  defp start_sessions(opts \\ []) do
    # repeat_every: nil keeps the default from reading the user's real config.
    opts = Keyword.merge([thresholds: @thresholds, repeat_every: nil, name: nil], opts)
    start_supervised!({Sessions, opts})
  end

  describe "threshold reporting" do
    test "stays silent below the first threshold" do
      sessions = start_sessions()
      Sessions.update(sessions, @session, 39)
      assert Sessions.hook_report(sessions, @session) == nil
    end

    test "reports the crossed threshold exactly once" do
      sessions = start_sessions()
      Sessions.update(sessions, @session, 45)

      assert %{percent: 40, pct: 45, message: "Context at 45% — first."} =
               Sessions.hook_report(sessions, @session)

      assert Sessions.hook_report(sessions, @session) == nil
      assert Sessions.hook_report(sessions, @session) == nil
    end

    test "stays silent while the percentage climbs within the same threshold" do
      sessions = start_sessions()
      Sessions.update(sessions, @session, 41)
      assert %{percent: 40} = Sessions.hook_report(sessions, @session)

      Sessions.update(sessions, @session, 49)
      assert Sessions.hook_report(sessions, @session) == nil
    end

    test "reports again once the next threshold is crossed" do
      sessions = start_sessions()
      Sessions.update(sessions, @session, 45)
      assert %{percent: 40} = Sessions.hook_report(sessions, @session)

      Sessions.update(sessions, @session, 52)

      assert %{percent: 50, message: "Context at 52% — second."} =
               Sessions.hook_report(sessions, @session)
    end

    test "reports only the highest threshold when several are passed at once" do
      sessions = start_sessions()
      Sessions.update(sessions, @session, 55)

      assert %{percent: 50, message: "Context at 55% — second."} =
               Sessions.hook_report(sessions, @session)

      assert Sessions.hook_report(sessions, @session) == nil
    end

    test "interpolates the current percentage, not the threshold's" do
      sessions = start_sessions()
      Sessions.update(sessions, @session, 57)
      assert %{percent: 50, pct: 57, message: message} = Sessions.hook_report(sessions, @session)
      assert message == "Context at 57% — second."
    end

    test "returns nil for a session that has never been seen" do
      sessions = start_sessions()
      assert Sessions.hook_report(sessions, "never-seen") == nil
    end

    test "keeps sessions independent" do
      sessions = start_sessions()
      Sessions.update(sessions, "a", 45)
      Sessions.update(sessions, "b", 10)

      assert %{percent: 40} = Sessions.hook_report(sessions, "a")
      assert Sessions.hook_report(sessions, "b") == nil
    end
  end

  describe "repeating past the top threshold" do
    test "re-reports the top message every step" do
      sessions = start_sessions(repeat_every: 5)
      Sessions.update(sessions, @session, 62)

      assert %{percent: 60, message: "Context at 62% — third."} =
               Sessions.hook_report(sessions, @session)

      Sessions.update(sessions, @session, 64)
      assert Sessions.hook_report(sessions, @session) == nil

      Sessions.update(sessions, @session, 65)

      assert %{percent: 65, message: "Context at 65% — third."} =
               Sessions.hook_report(sessions, @session)

      Sessions.update(sessions, @session, 71)
      assert %{percent: 70, pct: 71} = Sessions.hook_report(sessions, @session)
      assert Sessions.hook_report(sessions, @session) == nil
    end

    test "stays silent past the top threshold when no step is configured" do
      sessions = start_sessions()
      Sessions.update(sessions, @session, 75)
      assert %{percent: 60} = Sessions.hook_report(sessions, @session)

      Sessions.update(sessions, @session, 90)
      assert Sessions.hook_report(sessions, @session) == nil
    end

    test "synthetic steps re-arm after a drop like real thresholds" do
      sessions = start_sessions(repeat_every: 5)
      Sessions.update(sessions, @session, 66)
      assert %{percent: 65} = Sessions.hook_report(sessions, @session)

      Sessions.update(sessions, @session, 45)
      Sessions.update(sessions, @session, 55)
      assert %{percent: 50} = Sessions.hook_report(sessions, @session)

      Sessions.update(sessions, @session, 66)

      assert %{percent: 65, message: "Context at 66% — third."} =
               Sessions.hook_report(sessions, @session)
    end
  end

  describe "re-arming after the context drops" do
    test "lowers the reported mark and re-fires on the way back up" do
      sessions = start_sessions()
      Sessions.update(sessions, @session, 55)
      assert %{percent: 50} = Sessions.hook_report(sessions, @session)

      # A compaction drops usage back under the reported threshold.
      Sessions.update(sessions, @session, 45)
      assert Sessions.hook_report(sessions, @session) == nil, "40 was already covered by 50"

      Sessions.update(sessions, @session, 55)
      assert %{percent: 50} = Sessions.hook_report(sessions, @session)
    end

    test "resets fully once usage falls below every threshold" do
      sessions = start_sessions()
      Sessions.update(sessions, @session, 45)
      assert %{percent: 40} = Sessions.hook_report(sessions, @session)

      Sessions.update(sessions, @session, 5)
      assert Sessions.hook_report(sessions, @session) == nil

      Sessions.update(sessions, @session, 45)
      assert %{percent: 40} = Sessions.hook_report(sessions, @session)
    end

    test "a drop alone never reports" do
      sessions = start_sessions()
      Sessions.update(sessions, @session, 65)
      assert %{percent: 60} = Sessions.hook_report(sessions, @session)

      Sessions.update(sessions, @session, 45)
      assert Sessions.hook_report(sessions, @session) == nil
    end
  end

  describe "enabling and disabling" do
    test "a disabled session never reports" do
      sessions = start_sessions()
      Sessions.update(sessions, @session, 65)
      assert Sessions.set_enabled(sessions, @session, false) == :ok
      assert Sessions.hook_report(sessions, @session) == nil

      Sessions.update(sessions, @session, 95)
      assert Sessions.hook_report(sessions, @session) == nil
    end

    test "re-enabling releases the still-pending report" do
      sessions = start_sessions()
      Sessions.update(sessions, @session, 65)
      Sessions.set_enabled(sessions, @session, false)
      assert Sessions.hook_report(sessions, @session) == nil

      Sessions.set_enabled(sessions, @session, true)
      assert %{percent: 60} = Sessions.hook_report(sessions, @session)
    end

    test "can be disabled before any statusline payload has arrived" do
      sessions = start_sessions()
      assert Sessions.set_enabled(sessions, @session, false) == :ok
      assert Sessions.status(sessions, @session) == %{enabled: false, pct: nil}

      Sessions.update(sessions, @session, 65)
      assert Sessions.hook_report(sessions, @session) == nil
      assert Sessions.status(sessions, @session) == %{enabled: false, pct: 65}
    end

    test "status defaults to enabled with no percentage for an unknown session" do
      sessions = start_sessions()
      assert Sessions.status(sessions, "never-seen") == %{enabled: true, pct: nil}
    end

    test "status tracks the last reported percentage" do
      sessions = start_sessions()
      Sessions.update(sessions, @session, 12)
      assert Sessions.status(sessions, @session) == %{enabled: true, pct: 12}

      Sessions.update(sessions, @session, 34)
      assert Sessions.status(sessions, @session) == %{enabled: true, pct: 34}
    end
  end

  describe "thresholds" do
    test "sorts injected thresholds so order in the list does not matter" do
      sessions =
        start_sessions(
          thresholds: [
            %{percent: 80, message: "high {percent}"},
            %{percent: 20, message: "low {percent}"}
          ]
        )

      Sessions.update(sessions, @session, 85)
      assert %{percent: 80, message: "high 85"} = Sessions.hook_report(sessions, @session)
    end

    test "falls back to the configured defaults when none are injected" do
      # No config file at this path, so the built-in thresholds apply.
      sessions =
        start_sessions(thresholds: Exline.SessionConfig.thresholds("/nonexistent/x.json"))

      Sessions.update(sessions, @session, 41)

      assert %{percent: 40, message: "Context at 41% — Consider preparing a handoff soon."} =
               Sessions.hook_report(sessions, @session)
    end
  end

  describe "self-reported status on the board" do
    setup do: %{dir: session_dir()}

    defp session_dir do
      dir = Path.join(System.tmp_dir!(), "exline-board-sr-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      dir
    end

    defp board_row(sessions, session_id),
      do: sessions |> Sessions.board() |> Enum.find(&(&1.session_id == session_id))

    defp write_report(dir, session_id, status, age_ms, extra \\ %{}) do
      fields =
        %{
          "sessionId" => session_id,
          "status" => status,
          "statusUpdatedAt" => System.system_time(:millisecond) - age_ms
        }
        |> Map.merge(Map.new(extra, fn {key, value} -> {to_string(key), value} end))

      File.write!(Path.join(dir, "#{extra[:pid] || 4242}.json"), JSON.encode!(fields))
    end

    test "a matching status file decides the row and dates it", ctx do
      sessions = start_sessions(self_report_dir: ctx.dir)
      Sessions.update(sessions, @session, 10, %{api_ms: 1000})
      assert %{status: :idle} = board_row(sessions, @session)

      write_report(ctx.dir, @session, "busy", 5_000)

      assert %{status: :working, reason: "self-reported busy" <> _, since_s: 5} =
               board_row(sessions, @session)
    end

    test "a file for another session leaves this row on the heuristic", ctx do
      sessions = start_sessions(self_report_dir: ctx.dir)
      Sessions.update(sessions, @session, 10, %{api_ms: 1000})
      Sessions.hook_event(sessions, @session, :user_prompt_submit)
      write_report(ctx.dir, "some-other-session", "idle", 0)

      assert %{status: :working, reason: "turn open — " <> _} = board_row(sessions, @session)
    end

    test "an empty status dir leaves every row on the heuristic", ctx do
      sessions = start_sessions(self_report_dir: ctx.dir)
      Sessions.update(sessions, @session, 10, %{api_ms: 1000})
      Sessions.hook_event(sessions, @session, :user_prompt_submit)

      assert %{status: :working, reason: "turn open — " <> _} = board_row(sessions, @session)
    end
  end

  describe "board membership from the session registry" do
    setup do
      clock = clock()
      %{dir: session_dir(), clock: clock}
    end

    # Stands in for the ps check, so no test forks a process.
    defp verdicts(by_session),
      do: fn reports ->
        Map.new(reports, fn {id, _report} -> {id, Map.get(by_session, id, :unverifiable)} end)
      end

    defp start_board(ctx, by_session),
      do:
        start_sessions(
          self_report_dir: ctx.dir,
          now: ctx.clock.now,
          liveness: verdicts(by_session)
        )

    test "a session whose process is gone leaves the board and the tracker", ctx do
      sessions = start_board(ctx, %{@session => :dead})
      Sessions.update(sessions, @session, 10, %{api_ms: 1000})
      write_report(ctx.dir, @session, "idle", 0)
      assert board_row(sessions, @session), "still rendering — too early to drop it"

      advance(ctx.clock, :timer.seconds(20))

      refute board_row(sessions, @session)
      # Dropped from state too: waiting out the 6 h prune would leave a quit
      # session on the board for hours, which is the bug this replaces.
      assert Sessions.status(sessions, @session) == %{enabled: true, pct: nil}
    end

    test "renders fresher than the gone threshold outrank a dead verdict", ctx do
      # Guards the race where ps runs between two renders of a session that is
      # very much alive.
      sessions = start_board(ctx, %{@session => :dead})
      Sessions.update(sessions, @session, 10, %{api_ms: 1000})
      settle(sessions, @session)
      write_report(ctx.dir, @session, "busy", 0)

      advance(ctx.clock, :timer.seconds(2))
      assert %{status: :working} = board_row(sessions, @session)
    end

    test "a live session parked out of sight keeps its file status", ctx do
      sessions = start_board(ctx, %{@session => :alive})
      Sessions.update(sessions, @session, 10, %{api_ms: 1000})
      settle(sessions, @session)
      write_report(ctx.dir, @session, "idle", 0)

      advance(ctx.clock, :timer.seconds(60))

      # The pane is hidden, so no renders arrive — but the process is there.
      assert %{status: :idle, last_render_age_s: 60} = board_row(sessions, @session)
    end

    test "a live session exline has never rendered still gets a row", ctx do
      sessions = start_board(ctx, %{"unseen" => :alive})

      write_report(ctx.dir, "unseen", "waiting", 7_000, %{
        name: "parked one",
        cwd: "/tmp/proj",
        pid: 4243
      })

      assert %{
               name: "parked one",
               cwd: "/tmp/proj",
               status: :attention,
               since_s: 7,
               context_pct: nil,
               model: nil,
               last_render_age_s: nil,
               reason: reason
             } = board_row(sessions, "unseen")

      assert reason =~ "no statusline feed"
    end

    test "a registry file with no live process is not a row", ctx do
      sessions = start_board(ctx, %{"quit" => :dead, "unknown" => :unverifiable})
      write_report(ctx.dir, "quit", "idle", 0, %{pid: 4243})
      write_report(ctx.dir, "unknown", "idle", 0, %{pid: 4244})

      assert Sessions.board(sessions) == []
    end

    test "an unverifiable process leaves the session on render age", ctx do
      sessions = start_board(ctx, %{})
      Sessions.update(sessions, @session, 10, %{api_ms: 1000})
      settle(sessions, @session)
      write_report(ctx.dir, @session, "busy", 0)

      advance(ctx.clock, :timer.seconds(20))
      assert %{status: :gone} = board_row(sessions, @session)
    end
  end

  describe "stale session pruning" do
    defp clock do
      {:ok, clock} = Agent.start_link(fn -> 0 end)
      %{agent: clock, now: fn -> Agent.get(clock, & &1) end}
    end

    defp advance(clock, ms), do: Agent.update(clock.agent, &(&1 + ms))

    # `update` is a cast, so read the state back before moving the clock: that
    # call is what guarantees the cast was already stamped with the old time.
    defp settle(sessions, session_id), do: Sessions.status(sessions, session_id)

    test "drops sessions untouched for six hours on the next update" do
      clock = clock()
      sessions = start_sessions(now: clock.now)
      Sessions.update(sessions, "stale", 45)
      settle(sessions, "stale")

      advance(clock, :timer.hours(7))
      Sessions.update(sessions, "fresh", 12)

      assert Sessions.status(sessions, "stale") == %{enabled: true, pct: nil}
      assert Sessions.status(sessions, "fresh") == %{enabled: true, pct: 12}
    end

    test "keeps sessions that are still within the window" do
      clock = clock()
      sessions = start_sessions(now: clock.now)
      Sessions.update(sessions, "recent", 45)
      settle(sessions, "recent")

      advance(clock, :timer.hours(5))
      Sessions.update(sessions, "fresh", 12)

      assert Sessions.status(sessions, "recent") == %{enabled: true, pct: 45}
    end

    test "a session that keeps reporting is never pruned" do
      clock = clock()
      sessions = start_sessions(now: clock.now)
      Sessions.update(sessions, @session, 45)
      settle(sessions, @session)

      advance(clock, :timer.hours(5))
      Sessions.update(sessions, @session, 46)
      settle(sessions, @session)

      advance(clock, :timer.hours(5))
      Sessions.update(sessions, @session, 47)

      assert Sessions.status(sessions, @session) == %{enabled: true, pct: 47}
    end
  end
end
