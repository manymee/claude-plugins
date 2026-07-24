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
