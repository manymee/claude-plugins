defmodule Exline.ClientTest do
  # Not async: each test binds a real unix socket and shells out.
  use ExUnit.Case, async: false

  @client Path.expand("../client", __DIR__)
  @stale_marker "\e[1;31m⚠\e[0m"

  setup do
    dir = Path.expand("tmp/c#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    %{dir: dir, session: "sess-#{System.unique_integer([:positive])}"}
  end

  # The client reads its payload from stdin, which System.cmd cannot feed, so
  # sh redirects a file into it. $0/$1 keep the paths out of the command string.
  defp run(ctx, socket_path, payload) do
    payload_path = Path.join(ctx.dir, "payload.json")
    File.write!(payload_path, payload)

    {output, _status} =
      System.cmd("/bin/sh", ["-c", ~s("$0" < "$1"), @client, payload_path],
        env: [{"TMPDIR", ctx.dir}, {"EXLINE_SOCKET", socket_path}]
      )

    output
  end

  defp cache_path(ctx), do: Path.join(ctx.dir, "exline-last-#{ctx.session}")

  defp dead_socket(ctx), do: Path.join(ctx.dir, "no-daemon.sock")

  defp payload(session), do: ~s({"session_id":"#{session}","version":"2.1.140"})

  # A daemon stand-in: reads the NUL-terminated request the way the real one
  # does, answers with a fixed render, closes so nc sees the end.
  defp fake_daemon(render) do
    # sun_path caps at ~104 bytes, so bind straight under /tmp.
    path = "/tmp/exl-c#{System.unique_integer([:positive])}.sock"
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, path}])

    served =
      Task.async(fn ->
        {:ok, conn} = :gen_tcp.accept(listen, 5_000)
        read_until_null(conn, "")
        :gen_tcp.send(conn, render)
        :gen_tcp.close(conn)
      end)

    on_exit(fn ->
      :gen_tcp.close(listen)
      File.rm(path)
    end)

    {path, served}
  end

  defp read_until_null(socket, acc) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    combined = acc <> data

    unless String.contains?(combined, <<0>>), do: read_until_null(socket, combined)
  end

  describe "a daemon that answers" do
    test "prints the render and caches it for the session", ctx do
      {socket_path, served} = fake_daemon("first line\nsecond line")

      assert run(ctx, socket_path, payload(ctx.session)) == "first line\nsecond line"
      Task.await(served)
      assert File.read!(cache_path(ctx)) == "first line\nsecond line"
    end

    test "caches nothing for a payload without a session id", ctx do
      {socket_path, served} = fake_daemon("only line")

      assert run(ctx, socket_path, ~s({"version":"2.1.140"})) == "only line"
      Task.await(served)
      refute Enum.any?(File.ls!(ctx.dir), &String.starts_with?(&1, "exline-last-"))
    end
  end

  describe "an unreachable daemon" do
    test "reprints the cached render, marked stale on the first line only", ctx do
      File.write!(cache_path(ctx), "first line\nsecond line")

      assert run(ctx, dead_socket(ctx), payload(ctx.session)) ==
               "first line #{@stale_marker}\nsecond line"
    end

    test "prints nothing when the session has no cached render", ctx do
      assert run(ctx, dead_socket(ctx), payload(ctx.session)) == ""
    end
  end
end
