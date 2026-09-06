defmodule Exline.Board.LivenessCacheTest do
  use ExUnit.Case, async: true

  alias Exline.Board.LivenessCache

  @lstart "Sat Aug 29 18:17:48 2026"
  # The same pid started at another moment: a recycled pid, not the session.
  @other_lstart "Sat Aug 29 20:18:25 2026"

  # A status-file entry, cut down to the fields liveness reads.
  defp report(overrides \\ %{}) do
    Map.merge(%{pid: 4242, proc_start: @lstart, pid_domain: "darwin"}, overrides)
  end

  defp roster, do: %{"s" => report()}

  # Stands in for `ps`, handing out scripted snapshots (the last one repeats)
  # and announcing every run, so a test can wait for a background refresh. A
  # `{:wait, snapshot}` step parks the run until the test releases it.
  defp scripted_ps(steps) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> steps end)

    fn ->
      step =
        Agent.get_and_update(agent, fn
          [last] -> {last, [last]}
          [next | rest] -> {next, rest}
        end)

      send(test, {:ps, self()})

      case step do
        {:wait, snapshot} -> receive(do: (:go -> snapshot))
        :raise -> raise "ps blew up"
        snapshot -> snapshot
      end
    end
  end

  # Stands in for `kill -0`: pids exist unless `alive` says otherwise.
  defp fake_kill(alive \\ %{}) do
    fn pids -> {:ok, Map.new(pids, &{&1, Map.get(alive, &1, true)})} end
  end

  defp clock do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    {fn -> Agent.get(agent, & &1) end, fn ms -> Agent.update(agent, &(&1 + ms)) end}
  end

  defp start_cache(opts) do
    opts = Keyword.merge([name: nil, exists: fake_kill()], opts)
    start_supervised!(Supervisor.child_spec({LivenessCache, opts}, id: make_ref()))
  end

  # A refresher that is gone has already reported, so the next call to the cache
  # is answered from the snapshot it brought back.
  defp await_refresh(refresher) do
    ref = Process.monitor(refresher)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
  end

  test "the first check takes a snapshot and judges the whole roster against it" do
    # Break: a cold cache answering out of nothing, or the snapshot read the
    # wrong way round now that it lists every process rather than the roster's.
    fetch = scripted_ps([{:ok, %{4242 => @lstart, 7 => @other_lstart}}])
    cache = start_cache(fetch: fetch, exists: fake_kill(%{9999 => false}))

    reports = %{
      "same" => report(),
      "recycled" => report(%{pid: 7}),
      "quit" => report(%{pid: 9999}),
      "unseen" => report(%{pid: 5})
    }

    assert LivenessCache.check(cache, reports) ==
             %{"same" => :alive, "recycled" => :dead, "quit" => :dead, "unseen" => :unverifiable}

    assert_received {:ps, _cold}
  end

  test "a second check inside the TTL does not run ps again" do
    # Break: the cache forking per board read, which is the whole point of it.
    {now, advance} = clock()
    cache = start_cache(fetch: scripted_ps([{:ok, %{4242 => @lstart}}]), now: now, ttl: 2_000)

    assert LivenessCache.check(cache, roster()) == %{"s" => :alive}
    assert_received {:ps, _cold}

    advance.(2_000)
    assert LivenessCache.check(cache, roster()) == %{"s" => :alive}
    refute_receive {:ps, _again}, 50
  end

  test "past the TTL the snapshot in hand answers at once and the refresh lands behind it" do
    # Break: a board read blocking on the refresh, or never seeing its result.
    {now, advance} = clock()
    fetch = scripted_ps([{:ok, %{4242 => @lstart}}, {:ok, %{4242 => @other_lstart}}])
    cache = start_cache(fetch: fetch, now: now, ttl: 2_000)

    assert LivenessCache.check(cache, roster()) == %{"s" => :alive}
    assert_received {:ps, _cold}

    advance.(2_001)
    assert LivenessCache.check(cache, roster()) == %{"s" => :alive}

    assert_receive {:ps, refresher}
    await_refresh(refresher)
    assert LivenessCache.check(cache, roster()) == %{"s" => :dead}
  end

  test "checks piling up past the TTL start one refresh, not one each" do
    # Break: a refresh storm, every read past the TTL forking its own ps.
    {now, advance} = clock()
    fetch = scripted_ps([{:ok, %{4242 => @lstart}}, {:wait, {:ok, %{4242 => @other_lstart}}}])
    cache = start_cache(fetch: fetch, now: now, ttl: 2_000)

    assert LivenessCache.check(cache, roster()) == %{"s" => :alive}
    assert_received {:ps, _cold}

    advance.(2_001)
    for _read <- 1..5, do: assert(LivenessCache.check(cache, roster()) == %{"s" => :alive})

    assert_receive {:ps, refresher}
    refute_receive {:ps, _storm}, 50

    send(refresher, :go)
    await_refresh(refresher)
    assert LivenessCache.check(cache, roster()) == %{"s" => :dead}
  end

  test "a ps that blows up leaves the roster unjudged, and a later one recovers it" do
    # Break: one hiccup crashing the cache, or blinding it until a restart.
    cache = start_cache(fetch: scripted_ps([:raise, {:ok, %{4242 => @lstart}}]))

    assert LivenessCache.check(cache, roster()) == %{"s" => :unverifiable}
    assert_received {:ps, _cold}
    assert Process.alive?(cache)

    # A failed snapshot is due another try on the next read...
    assert LivenessCache.check(cache, roster()) == %{"s" => :unverifiable}
    assert_receive {:ps, refresher}
    await_refresh(refresher)
    # ...and the read after that has its answer.
    assert LivenessCache.check(cache, roster()) == %{"s" => :alive}
  end

  test "a pid that has gone is dead on the next read, however fresh the snapshot" do
    # Break: a session the user quit sitting on the board until the snapshot's
    # TTL runs out — the reason existence is asked per read.
    {:ok, running} = Agent.start_link(fn -> true end)
    exists = fn pids -> {:ok, Map.new(pids, &{&1, Agent.get(running, fn r -> r end)})} end
    cache = start_cache(fetch: scripted_ps([{:ok, %{4242 => @lstart}}]), exists: exists)

    assert LivenessCache.check(cache, roster()) == %{"s" => :alive}
    assert_received {:ps, _cold}

    Agent.update(running, fn _was -> false end)
    assert LivenessCache.check(cache, roster()) == %{"s" => :dead}
    refute_receive {:ps, _again}, 50
  end

  test "an existence check that cannot be trusted leaves the snapshot to decide" do
    # Break: one unreadable line from kill wiping liveness for the whole board.
    reports = %{"s" => report(), "quit" => report(%{pid: 9999})}
    snapshot = fn -> {:ok, %{4242 => @lstart}} end

    for exists <- [fn _pids -> :error end, fn _pids -> raise "kill blew up" end] do
      cache = start_cache(fetch: snapshot, exists: exists)
      assert LivenessCache.check(cache, reports) == %{"s" => :alive, "quit" => :dead}
    end
  end

  test "a cache that is not running leaves the board unjudged instead of crashing it" do
    # Break: a cache restart taking Exline.Sessions — and the board — with it.
    {:ok, cache} = LivenessCache.start_link(name: nil, fetch: fn -> {:ok, %{}} end)
    GenServer.stop(cache)

    assert LivenessCache.check(cache, roster()) == %{"s" => :unverifiable}
  end
end
