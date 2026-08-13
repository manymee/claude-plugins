defmodule Exline.GitCacheTest do
  use ExUnit.Case, async: true

  alias Exline.GitCache

  setup do
    # Unsupervised Task.Supervisor for the cache's gather tasks; pid passed in.
    sup = start_supervised!(Task.Supervisor)
    %{sup: sup}
  end

  defp start_cache(opts) do
    # Default to deterministic (zero) jitter; timing tests override `now`/`ttl`.
    opts = Keyword.merge([jitter: fn -> 0 end], opts)
    start_supervised!({GitCache, Keyword.put(opts, :name, nil)})
  end

  test "gathers on a miss and serves from cache within the TTL", %{sup: sup} do
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    gather = fn key -> Agent.update(calls, &(&1 + 1)) && {:value, key} end
    cache = start_cache(task_sup: sup, ttl: 1000, now: fn -> 0 end, gather: gather)

    assert GitCache.fetch(cache, "/r") == {:value, "/r"}
    assert GitCache.fetch(cache, "/r") == {:value, "/r"}
    assert Agent.get(calls, & &1) == 1
  end

  test "re-gathers once the TTL has elapsed", %{sup: sup} do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    gather = fn _ -> Agent.update(calls, &(&1 + 1)) && :v end

    cache =
      start_cache(task_sup: sup, ttl: 100, gather: gather, now: fn -> Agent.get(clock, & &1) end)

    GitCache.fetch(cache, "/r")
    Agent.update(clock, fn _ -> 50 end)
    GitCache.fetch(cache, "/r")
    assert Agent.get(calls, & &1) == 1, "still fresh within TTL"

    Agent.update(clock, fn _ -> 150 end)
    GitCache.fetch(cache, "/r")
    assert Agent.get(calls, & &1) == 2, "re-gathered past TTL"
  end

  test "extends freshness by the jitter amount so expirations stagger", %{sup: sup} do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    gather = fn _ -> Agent.update(calls, &(&1 + 1)) && :v end

    cache =
      start_cache(
        task_sup: sup,
        ttl: 100,
        jitter: fn -> 50 end,
        gather: gather,
        now: fn -> Agent.get(clock, & &1) end
      )

    GitCache.fetch(cache, "/r")
    Agent.update(clock, fn _ -> 120 end)
    GitCache.fetch(cache, "/r")
    assert Agent.get(calls, & &1) == 1, "past base TTL but within the jittered deadline"

    Agent.update(clock, fn _ -> 160 end)
    GitCache.fetch(cache, "/r")
    assert Agent.get(calls, & &1) == 2, "past the jittered deadline"
  end

  test "coalesces concurrent misses for the same key into one gather", %{sup: sup} do
    test = self()

    gather = fn key ->
      send(test, {:gathering, self()})
      receive do: (:proceed -> {:done, key})
    end

    cache = start_cache(task_sup: sup, ttl: 1000, now: fn -> 0 end, gather: gather)

    t1 = Task.async(fn -> GitCache.fetch(cache, "/r") end)
    t2 = Task.async(fn -> GitCache.fetch(cache, "/r") end)

    assert_receive {:gathering, gpid}, 500
    refute_receive {:gathering, _}, 100

    send(gpid, :proceed)
    assert Task.await(t1) == {:done, "/r"}
    assert Task.await(t2) == {:done, "/r"}
  end

  test "different keys gather independently", %{sup: sup} do
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    gather = fn key -> Agent.update(calls, &(&1 + 1)) && {:v, key} end
    cache = start_cache(task_sup: sup, ttl: 1000, now: fn -> 0 end, gather: gather)

    assert GitCache.fetch(cache, "/a") == {:v, "/a"}
    assert GitCache.fetch(cache, "/b") == {:v, "/b"}
    assert Agent.get(calls, & &1) == 2
  end

  test "serves a stale entry at once instead of waiting on the refresh", %{sup: sup} do
    test = self()
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    gather = fn key ->
      case Agent.get_and_update(calls, &{&1 + 1, &1 + 1}) do
        1 ->
          :first

        _ ->
          send(test, {:gathering, self()})
          receive do: (:proceed -> {:refreshed, key})
      end
    end

    cache =
      start_cache(
        task_sup: sup,
        ttl: 100,
        gather: gather,
        now: fn -> Agent.get(clock, & &1) end,
        wait_timeout: 30_000
      )

    assert GitCache.fetch(cache, "/r") == :first
    Agent.update(clock, fn _ -> 150 end)

    refresh = Task.async(fn -> GitCache.fetch(cache, "/r") end)
    assert_receive {:gathering, gpid}, 500

    stale = Task.async(fn -> GitCache.fetch(cache, "/r") end)
    assert Task.await(stale, 500) == :first, "a render must not queue behind a running refresh"

    send(gpid, :proceed)
    assert Task.await(refresh) == {:refreshed, "/r"}
  end

  test "falls back to the stale value when a refresh outlives the wait bound", %{sup: sup} do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    gather = fn _ ->
      case Agent.get_and_update(calls, &{&1 + 1, &1 + 1}) do
        1 -> :first
        _ -> Process.sleep(:infinity)
      end
    end

    cache =
      start_cache(
        task_sup: sup,
        ttl: 100,
        gather: gather,
        now: fn -> Agent.get(clock, & &1) end,
        wait_timeout: 100,
        gather_timeout: 30_000
      )

    assert GitCache.fetch(cache, "/r") == :first
    Agent.update(clock, fn _ -> 150 end)

    bounded = Task.async(fn -> GitCache.fetch(cache, "/r") end)
    assert Task.await(bounded, 1000) == :first
  end

  test "returns nil within the wait bound when nothing is cached and the gather stalls",
       %{sup: sup} do
    cache =
      start_cache(
        task_sup: sup,
        ttl: 1000,
        now: fn -> 0 end,
        gather: fn _ -> Process.sleep(:infinity) end,
        wait_timeout: 100,
        gather_timeout: 30_000
      )

    cold = Task.async(fn -> GitCache.fetch(cache, "/r") end)
    assert Task.await(cold, 1000) == nil
  end

  test "caches a gather that finishes after its caller's wait bound elapsed", %{sup: sup} do
    test = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    gather = fn key ->
      Agent.update(calls, &(&1 + 1))
      send(test, {:gathering, self()})
      receive do: (:proceed -> {:late, key})
    end

    cache =
      start_cache(
        task_sup: sup,
        ttl: 1000,
        now: fn -> 0 end,
        gather: gather,
        wait_timeout: 50,
        gather_timeout: 30_000
      )

    bounded = Task.async(fn -> GitCache.fetch(cache, "/r") end)
    assert_receive {:gathering, gpid}, 500
    assert Task.await(bounded, 1000) == nil

    # The task sends its result to the cache before exiting, so its :DOWN
    # orders our next call after the cache has handled that result.
    gref = Process.monitor(gpid)
    send(gpid, :proceed)
    assert_receive {:DOWN, ^gref, :process, ^gpid, :normal}, 500

    assert GitCache.fetch(cache, "/r") == {:late, "/r"}
    assert Agent.get(calls, & &1) == 1, "the late result was cached, not re-gathered"
  end

  test "survives a wait deadline that lands after its gather already replied", %{sup: sup} do
    cache =
      start_cache(
        task_sup: sup,
        ttl: 1000,
        now: fn -> 0 end,
        gather: fn _ -> :v end,
        wait_timeout: 20
      )

    ref = Process.monitor(cache)
    assert GitCache.fetch(cache, "/r") == :v
    refute_receive {:DOWN, ^ref, :process, ^cache, _}, 100
    assert GitCache.fetch(cache, "/r") == :v
  end

  @tag :capture_log
  test "kills a gather stuck past the deadline, replies nil, retries on the next fetch",
       %{sup: sup} do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    gather = fn _ ->
      n = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})
      if n == 1, do: Process.sleep(:infinity), else: :recovered
    end

    cache =
      start_cache(task_sup: sup, ttl: 1000, now: fn -> 0 end, gather: gather, gather_timeout: 50)

    assert GitCache.fetch(cache, "/r") == nil
    assert GitCache.fetch(cache, "/r") == :recovered
  end

  # Regression: fetch/2 waited :infinity, so a GitCache that stopped answering
  # (its own bounds cannot fire while it is wedged) parked every render — each
  # holding its accepted socket — until the daemon ran out of fds. Slow by
  # design: it spends the caller-side bound.
  test "gives up and returns nil when the cache itself stops answering", %{sup: sup} do
    cache = start_cache(task_sup: sup, gather: fn _ -> :never_reached end)
    :sys.suspend(cache)

    wedged = Task.async(fn -> GitCache.fetch(cache, "/r") end)
    assert Task.await(wedged, 10_000) == nil
  end

  # Regression: gathers ran on Exline.ConnSupervisor, so a connection storm
  # delayed the very git work whose slowness caused the storm.
  test "runs gathers on a task supervisor of its own, off the connection path" do
    test = self()

    gather = fn key ->
      send(test, {:gathering, self()})
      receive do: (:proceed -> {:done, key})
    end

    # No :task_sup — this exercises the production default.
    cache = start_cache(ttl: 1000, now: fn -> 0 end, gather: gather, wait_timeout: 30_000)

    fetch = Task.async(fn -> GitCache.fetch(cache, "/r") end)
    assert_receive {:gathering, gather_pid}, 500

    assert gather_pid in Task.Supervisor.children(Exline.GitTaskSupervisor)
    refute gather_pid in Task.Supervisor.children(Exline.ConnSupervisor)

    send(gather_pid, :proceed)
    assert Task.await(fetch) == {:done, "/r"}
  end

  @tag :capture_log
  test "returns nil on a gather crash and retries on the next fetch", %{sup: sup} do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    gather = fn _ ->
      n = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})
      if n == 1, do: raise("boom"), else: :recovered
    end

    cache = start_cache(task_sup: sup, ttl: 1000, now: fn -> 0 end, gather: gather)

    assert GitCache.fetch(cache, "/r") == nil
    assert GitCache.fetch(cache, "/r") == :recovered
  end
end
