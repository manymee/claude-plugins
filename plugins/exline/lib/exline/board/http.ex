defmodule Exline.Board.HTTP do
  @moduledoc """
  Minimal HTTP server for the session board: `GET /board.json` answers the
  roster from `Exline.Sessions`, `GET /` serves the static board page from
  `priv/board/index.html`. Anything else is a 404.

  Off by default; enabled by `board_http_port` in the exline config file. Binds
  all interfaces so a phone on the LAN can reach it directly — the roster
  carries session names and paths, which is acceptable on a home network.
  """

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "The port actually bound (for tests starting on port 0)."
  def port(server \\ __MODULE__), do: GenServer.call(server, :port)

  @impl true
  def init(opts) do
    port = Keyword.fetch!(opts, :port)

    # Dual-stack on one socket: the host advertises both an A and an AAAA
    # record over mDNS, and a v4-only listener costs every client a refused
    # v6 connection (Happy Eyeballs) before it falls back.
    options = [
      :binary,
      :inet6,
      {:ipv6_v6only, false},
      {:active, false},
      {:reuseaddr, true},
      {:packet, :raw}
    ]

    case :gen_tcp.listen(port, options) do
      {:ok, listen_socket} ->
        send(self(), :accept)

        {:ok,
         %{
           listen: listen_socket,
           sessions: Keyword.get(opts, :sessions, Exline.Sessions)
         }}

      {:error, reason} ->
        {:stop, {:listen_failed, port, reason}}
    end
  end

  # Same accept idiom as Exline.Listener: a timeout keeps the loop
  # shutdown-responsive instead of parking in a blocking accept.
  @accept_timeout 500

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.listen, @accept_timeout) do
      {:ok, conn_socket} ->
        sessions = state.sessions

        {:ok, pid} =
          Task.Supervisor.start_child(Exline.ConnSupervisor, fn ->
            serve(conn_socket, sessions)
          end)

        _ = :gen_tcp.controlling_process(conn_socket, pid)
        send(self(), :accept)
        {:noreply, state}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, :closed} ->
        {:stop, :closed, state}

      {:error, reason} ->
        Logger.warning("exline: board http accept failed: #{inspect(reason)}, retrying")
        Process.send_after(self(), :accept, 100)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:port, _from, state) do
    {:ok, port} = :inet.port(state.listen)
    {:reply, port, state}
  end

  @recv_timeout 2_000
  @max_request_bytes 8_192

  defp serve(conn_socket, sessions) do
    response =
      case read_request(conn_socket, "") do
        {:ok, request} -> respond(request_path(request), sessions)
        {:error, _reason} -> nil
      end

    if response, do: :gen_tcp.send(conn_socket, response)
    :gen_tcp.close(conn_socket)
  end

  # Read to the end of the headers before answering. A request split across
  # two TCP segments would otherwise leave unread bytes in the receive queue,
  # which turns close into an RST and lets the client drop our response.
  defp read_request(_socket, acc) when byte_size(acc) >= @max_request_bytes, do: {:ok, acc}

  defp read_request(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, @recv_timeout) do
        {:ok, data} -> read_request(socket, acc <> data)
        {:error, reason} -> if acc == "", do: {:error, reason}, else: {:ok, acc}
      end
    end
  end

  # First line of "GET /path HTTP/1.1\r\n…" — enough of HTTP for a poller.
  defp request_path(request) do
    case String.split(request, ["\r\n", "\n"], parts: 2) do
      [line | _rest] ->
        case String.split(line, " ") do
          ["GET", path | _version] -> path |> String.split("?") |> hd()
          _other -> nil
        end
    end
  end

  defp respond("/board.json", sessions) do
    body = JSON.encode!(%{sessions: Exline.Sessions.board(sessions)})
    http(200, "application/json", body)
  end

  defp respond(path, _sessions) when path in ["/", "/index.html"] do
    case File.read(Path.join(:code.priv_dir(:exline), "board/index.html")) do
      {:ok, body} -> http(200, "text/html; charset=utf-8", body)
      {:error, reason} -> http(500, "text/plain", "board page missing: #{inspect(reason)}")
    end
  end

  defp respond(_path, _sessions), do: http(404, "text/plain", "not found")

  @status %{200 => "200 OK", 404 => "404 Not Found", 500 => "500 Internal Server Error"}

  defp http(code, content_type, body) do
    [
      "HTTP/1.1 #{@status[code]}\r\n",
      "Content-Type: #{content_type}\r\n",
      "Content-Length: #{byte_size(body)}\r\n",
      "Cache-Control: no-store\r\n",
      "Connection: close\r\n\r\n",
      body
    ]
  end
end
