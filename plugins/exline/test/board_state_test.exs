defmodule Exline.Board.StateTest do
  use ExUnit.Case, async: true

  alias Exline.Board.State

  # A session as the daemon first sees it: one render, no turn state.
  defp fresh(now), do: State.new(now) |> State.render(1000, now)

  defp status(s, now), do: State.classify(s, now) |> elem(0)

  describe "render diffing" do
    test "the first render seeds the api baseline without counting as an advance" do
      s = fresh(0)
      assert s.api_ms == 1000
      assert s.api_advanced_at == nil
    end

    test "an advancing api counter marks activity and clears a pending permission" do
      s = fresh(0) |> State.notification(:permission, 1) |> State.render(2000, 2)
      assert s.api_advanced_at == 2
      assert s.pending_permission == nil
    end

    test "a frozen api counter changes nothing but the render time" do
      s = fresh(0) |> State.render(1000, 5)
      assert s.last_render_at == 5
      assert s.api_advanced_at == nil
    end
  end

  describe "turn lifecycle" do
    test "submit opens the turn and working survives a frozen api (long tool run)" do
      s = fresh(0) |> State.user_prompt_submit(1)
      assert {:working, _} = State.classify(s, 1)

      s = s |> State.render(1000, 10)
      assert {:working, reason} = State.classify(s, 10)
      assert reason =~ "api"
    end

    test "stop closes the turn" do
      s = fresh(0) |> State.user_prompt_submit(1) |> State.stop(3) |> State.render(1000, 4)
      assert {:idle, "turn closed by Stop"} = State.classify(s, 4)
    end

    test "the idle-60s notification closes a turn no Stop ever closed (Esc interrupt)" do
      s = fresh(0) |> State.user_prompt_submit(1) |> State.notification(:idle, 61)
      s = State.render(s, 1000, 62)
      assert {:idle, "turn closed by idle-60s notification"} = State.classify(s, 62)
    end

    test "without turn state the api diff decides, within the recency window" do
      s = fresh(0) |> State.render(2000, 1)
      assert status(s, 1) == :working
      assert status(s |> State.render(2000, 8), 8) == :idle
    end
  end

  describe "attention" do
    test "an unanswered permission prompt wins over an open turn" do
      s = fresh(0) |> State.user_prompt_submit(1) |> State.notification(:permission, 2)
      assert {:attention, _} = State.classify(s, 2)
    end

    test "the tool batch after approval flips back to working" do
      s =
        fresh(0)
        |> State.render(1000, 8)
        |> State.user_prompt_submit(1)
        |> State.notification(:permission, 2)
        |> State.post_tool_batch(9)

      assert {:working, _} = State.classify(s, 9)
    end
  end

  describe "render age tiers" do
    test "stale after 3s without renders, gone after 10s" do
      s = fresh(0)
      assert status(s, 2) == :idle
      assert status(s, 3) == :stale
      assert status(s, 10) == :gone
    end
  end

  describe "conflicting signals" do
    test "api advancing after the turn closed is flagged, not called working" do
      s = fresh(0) |> State.stop(1) |> State.render(2000, 2)
      assert {:idle, reason} = State.classify(s, 2)
      assert reason =~ "after close"
    end

    test "the api advance that ended with the Stop itself is not flagged" do
      s = fresh(0) |> State.render(2000, 1) |> State.stop(1) |> State.render(2000, 2)
      assert {:idle, "turn closed by Stop"} = State.classify(s, 2)
    end
  end

  describe "since/3" do
    test "anchors each status to the event that caused it" do
      s = fresh(0) |> State.user_prompt_submit(3)
      assert State.since(s, :working, 10) == 7

      s = State.notification(s, :permission, 5)
      assert State.since(s, :attention, 10) == 5

      s = State.stop(s, 8)
      assert State.since(s, :idle, 10) == 2

      assert State.since(s, :stale, 10) == 10 - s.last_render_at
    end

    test "falls back to first-seen when no anchoring event exists" do
      s = fresh(0)
      assert State.since(s, :idle, 4) == 4
    end
  end
end
