defmodule Exline.Board.SelfReportTest do
  use ExUnit.Case, async: true

  alias Exline.Board.SelfReport

  setup do
    dir = Path.join(System.tmp_dir!(), "exline-sr-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp write(dir, name, contents) when is_binary(contents),
    do: File.write!(Path.join(dir, name), contents)

  defp write(dir, name, contents), do: write(dir, name, JSON.encode!(contents))

  defp session(overrides) do
    Map.merge(
      %{
        "pid" => 123,
        "sessionId" => "sess-1",
        "status" => "idle",
        "statusUpdatedAt" => 1_000_000
      },
      overrides
    )
  end

  describe "parsing" do
    test "maps each status word to the report the board classifies from", ctx do
      write(ctx.dir, "1.json", session(%{"sessionId" => "a", "status" => "busy"}))
      write(ctx.dir, "2.json", session(%{"sessionId" => "b", "status" => "idle"}))
      write(ctx.dir, "3.json", session(%{"sessionId" => "c", "status" => "waiting"}))

      reports = SelfReport.scan(ctx.dir, 1_000_000)

      assert %{
               "a" => %{status: :busy},
               "b" => %{status: :idle},
               "c" => %{status: :waiting}
             } = reports
    end

    test "age_s counts the seconds since the status was written", ctx do
      write(ctx.dir, "1.json", session(%{"statusUpdatedAt" => 1_000_000}))
      assert %{"sess-1" => %{age_s: 42}} = SelfReport.scan(ctx.dir, 1_042_400)
    end

    test "a status timestamp in the future reads as age zero, never negative", ctx do
      write(ctx.dir, "1.json", session(%{"statusUpdatedAt" => 2_000_000}))
      assert %{"sess-1" => %{age_s: 0}} = SelfReport.scan(ctx.dir, 1_000_000)
    end

    test "captures waitingFor so the board can say what is being waited on", ctx do
      write(
        ctx.dir,
        "1.json",
        session(%{"status" => "waiting", "waitingFor" => "permission: Bash"})
      )

      assert %{"sess-1" => %{waiting_for: "permission: Bash"}} = SelfReport.scan(ctx.dir, 1)
    end

    test "waiting_for is nil when the field is absent", ctx do
      write(ctx.dir, "1.json", session(%{"status" => "waiting"}))
      assert %{"sess-1" => %{waiting_for: nil}} = SelfReport.scan(ctx.dir, 1)
    end
  end

  describe "degrading on unexpected files" do
    test "malformed JSON is skipped instead of crashing the whole scan", ctx do
      write(ctx.dir, "bad.json", "{not json")
      write(ctx.dir, "good.json", session(%{}))

      assert Map.keys(SelfReport.scan(ctx.dir, 1)) == ["sess-1"]
    end

    test "an unknown status word is skipped so the heuristic keeps the session", ctx do
      write(ctx.dir, "1.json", session(%{"status" => "compacting"}))
      assert SelfReport.scan(ctx.dir, 1) == %{}
    end

    test "a sessionId that is missing or not a string is skipped", ctx do
      write(ctx.dir, "1.json", %{"pid" => 5, "status" => "busy"})
      write(ctx.dir, "2.json", session(%{"sessionId" => 999}))
      assert SelfReport.scan(ctx.dir, 1) == %{}
    end

    test "a missing statusUpdatedAt leaves age_s nil rather than inventing one", ctx do
      write(ctx.dir, "1.json", %{"sessionId" => "sess-1", "status" => "busy"})
      assert %{"sess-1" => %{status: :busy, age_s: nil}} = SelfReport.scan(ctx.dir, 1)
    end

    test "a directory that does not exist scans as empty", ctx do
      assert SelfReport.scan(Path.join(ctx.dir, "nope"), 1) == %{}
    end

    test "the .key sidecars and other non-json files are never read", ctx do
      write(ctx.dir, "123.abc.key", "secret-material")
      write(ctx.dir, "notes.txt", "whatever")
      assert SelfReport.scan(ctx.dir, 1) == %{}
    end
  end

  describe "two files for one session" do
    test "the newest statusUpdatedAt wins, whichever order the dir lists them", ctx do
      write(ctx.dir, "1.json", session(%{"status" => "idle", "statusUpdatedAt" => 1_000}))
      write(ctx.dir, "2.json", session(%{"status" => "busy", "statusUpdatedAt" => 9_000}))
      write(ctx.dir, "3.json", session(%{"status" => "waiting", "statusUpdatedAt" => 5_000}))

      assert %{"sess-1" => %{status: :busy}} = SelfReport.scan(ctx.dir, 9_000)
    end

    test "a file with no timestamp loses to one that has a timestamp", ctx do
      write(ctx.dir, "1.json", %{"sessionId" => "sess-1", "status" => "idle"})
      write(ctx.dir, "2.json", session(%{"status" => "busy", "statusUpdatedAt" => 1}))

      assert %{"sess-1" => %{status: :busy}} = SelfReport.scan(ctx.dir, 1)
    end
  end

  describe "default_dir/0" do
    test "follows CLAUDE_CONFIG_DIR so a relocated config still resolves" do
      previous = System.get_env("CLAUDE_CONFIG_DIR")
      System.put_env("CLAUDE_CONFIG_DIR", "/somewhere/else")

      on_exit(fn ->
        if previous,
          do: System.put_env("CLAUDE_CONFIG_DIR", previous),
          else: System.delete_env("CLAUDE_CONFIG_DIR")
      end)

      assert SelfReport.default_dir() == "/somewhere/else/sessions"
    end
  end
end
