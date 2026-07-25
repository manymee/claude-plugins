defmodule Exline.Board.HTTPTest do
  # Not async: binds real TCP ports.
  use ExUnit.Case, async: false

  alias Exline.Board.HTTP
  alias Exline.Sessions

  setup do
    sessions = start_supervised!({Sessions, thresholds: [], repeat_every: nil, name: nil})
    http = start_supervised!({HTTP, port: 0, sessions: sessions, name: nil})
    %{sessions: sessions, port: HTTP.port(http)}
  end

  defp get(port, path) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "GET #{path} HTTP/1.1\r\nHost: board\r\n\r\n")
    response = read_all(socket, [])
    :gen_tcp.close(socket)

    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | headers] = String.split(head, "\r\n")
    %{status: status_line, headers: headers, body: body}
  end

  defp read_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} -> read_all(socket, [acc, data])
      {:error, _closed} -> IO.iodata_to_binary(acc)
    end
  end

  test "GET /board.json answers the roster", ctx do
    Sessions.update(ctx.sessions, "sess-1", 37, %{
      api_ms: 1000,
      name: "my session",
      cwd: "/Users/x/proj",
      model: "Fable 5"
    })

    response = get(ctx.port, "/board.json")

    assert response.status == "HTTP/1.1 200 OK"
    assert Enum.member?(response.headers, "Content-Type: application/json")

    assert %{"sessions" => [row]} = JSON.decode!(response.body)

    assert %{
             "session_id" => "sess-1",
             "name" => "my session",
             "cwd" => "/Users/x/proj",
             "model" => "Fable 5",
             "context_pct" => 37,
             "status" => "idle"
           } = row
  end

  test "GET /board.json with no sessions answers an empty roster", ctx do
    assert %{"sessions" => []} = JSON.decode!(get(ctx.port, "/board.json").body)
  end

  test "GET / serves the board page", ctx do
    response = get(ctx.port, "/")
    assert response.status == "HTTP/1.1 200 OK"
    assert response.body =~ "exline board"
    assert response.body =~ "/board.json"
  end

  test "a query string does not confuse routing", ctx do
    assert get(ctx.port, "/board.json?t=123").status == "HTTP/1.1 200 OK"
  end

  test "unknown paths get a 404", ctx do
    assert get(ctx.port, "/nope").status == "HTTP/1.1 404 Not Found"
  end
end
