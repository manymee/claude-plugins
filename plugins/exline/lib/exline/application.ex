defmodule Exline.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @start_listener Application.compile_env(:exline, :start_listener, true)

  @impl true
  def start(_type, _args) do
    children =
      [{Task.Supervisor, name: Exline.ConnSupervisor}, Exline.GitCache, Exline.Sessions] ++
        if(@start_listener, do: [Exline.Listener], else: []) ++
        board_http()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Exline.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The board HTTP endpoint runs only when the config file names a port —
  # and never in the test app, which starts servers per-test instead.
  defp board_http do
    if @start_listener do
      case Exline.SessionConfig.board_http_port() do
        nil -> []
        port -> [{Exline.Board.HTTP, port: port}]
      end
    else
      []
    end
  end
end
