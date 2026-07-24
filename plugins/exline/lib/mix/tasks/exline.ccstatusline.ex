defmodule Mix.Tasks.Exline.Ccstatusline do
  @moduledoc """
  Run ccstatusline against a captured JSON payload and print its output
  to stdout. Ad-hoc inspection of "what would ccstatusline render for
  this payload."

  For batch regeneration of the committed `<name>.ccstatusline.txt`
  reference files alongside fixtures, see `mix exline.ccstatusline.references`.

  ## Examples

      mix exline.ccstatusline                       # newest capture, colored
      mix exline.ccstatusline --plain               # ANSI stripped
      mix exline.ccstatusline --nth 3 --plain       # 3rd newest from history
      mix exline.ccstatusline --file path/to.json   # explicit input file
      mix exline.ccstatusline --list                # list available captures

  Reads `Exline.Captures.last_path/0` by default. Falls back to
  `Exline.Ccstatusline.fallback_path/0` if no live capture exists yet.
  """

  @shortdoc "Run ccstatusline on a captured payload (ad-hoc inspection)"

  use Mix.Task

  @switches [plain: :boolean, nth: :integer, file: :string, list: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    cond do
      opts[:list] -> list_captures()
      true -> render(opts)
    end
  end

  defp list_captures do
    Exline.Captures.list()
    |> Enum.with_index(1)
    |> Enum.each(fn {path, i} ->
      IO.puts("#{i}\t#{Path.basename(path)}")
    end)
  end

  defp render(opts) do
    path = resolve_input(opts)
    IO.write(Exline.Ccstatusline.render(path, plain: Keyword.get(opts, :plain, false)))
  end

  defp resolve_input(opts) do
    cond do
      file = opts[:file] ->
        file

      n = opts[:nth] ->
        Exline.Captures.nth(n) ||
          Mix.raise("no capture at index #{n} in #{Exline.Captures.history_dir()}")

      live?() ->
        Exline.Captures.last_path()

      true ->
        Mix.shell().info(
          "warn: #{Exline.Captures.last_path()} missing, falling back to #{Exline.Ccstatusline.fallback_path()}"
        )

        Exline.Ccstatusline.fallback_path()
    end
  end

  defp live? do
    case File.stat(Exline.Captures.last_path()) do
      {:ok, %{size: size}} when size > 0 -> true
      _ -> false
    end
  end
end
