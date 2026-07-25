defmodule Exline.SessionConfig do
  @moduledoc """
  Source of truth for the context thresholds `Exline.Sessions` reports on.

  The defaults live here; an optional JSON file overrides them:

      {"context_thresholds": [{"percent": 40, "message": "Context at {percent}% — ..."}],
       "context_repeat_every": 5}

  Read once at `Exline.Sessions` init, so editing the file takes effect on the
  next daemon restart (`/exline:setup`). A missing file means "no override" and
  is silent; a file that is present but unusable keeps the defaults and says so
  in the log, since staying quiet there would look like the edit worked.
  """

  require Logger

  @default_thresholds [
    %{percent: 40, message: "Context at {percent}% — Consider preparing a handoff soon."},
    %{percent: 50, message: "Context at {percent}% — Handoff recommended."},
    %{percent: 60, message: "Context at {percent}% — Handoff strongly recommended."},
    %{percent: 70, message: "Context at {percent}% — Auto-compaction risk. Handoff advised."}
  ]

  @doc "The built-in thresholds, used whenever no valid override is configured."
  def default_thresholds, do: @default_thresholds

  @doc "Thresholds from the config file at `path`, or `default_thresholds/0`."
  def thresholds(path \\ config_path()) do
    case File.read(path) do
      {:ok, raw} -> parse(raw, path)
      {:error, _reason} -> @default_thresholds
    end
  end

  @doc "Where the optional config file is looked up."
  def config_path do
    System.get_env("EXLINE_CONFIG") || Path.expand("~/.claude/exline.json")
  end

  @doc """
  Optional step for re-reporting the top threshold's message past its percent
  (`context_repeat_every` in the config file), or `nil` when not configured.
  """
  def repeat_every(path \\ config_path()) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{"context_repeat_every" => value}} <- JSON.decode(raw) do
      if is_integer(value) and value > 0 do
        value
      else
        Logger.warning(
          "exline: ignoring context_repeat_every in #{path}: must be a positive integer"
        )

        nil
      end
    else
      _no_file_or_no_key -> nil
    end
  end

  defp parse(raw, path) do
    case JSON.decode(raw) do
      {:ok, %{"context_thresholds" => entries}} -> validate(entries, path)
      # A config file without the key configures nothing — that is not an error.
      {:ok, %{}} -> @default_thresholds
      {:ok, _other} -> fallback(path, "not a JSON object")
      {:error, _reason} -> fallback(path, "invalid JSON")
    end
  end

  defp validate(entries, path) when is_list(entries) and entries != [] do
    parsed = Enum.map(entries, &validate_entry/1)

    if Enum.all?(parsed, & &1) do
      parsed
    else
      fallback(path, "invalid context_thresholds entry")
    end
  end

  defp validate(_entries, path), do: fallback(path, "context_thresholds must be a non-empty list")

  defp validate_entry(%{"percent" => percent, "message" => message})
       when is_number(percent) and percent >= 0 and percent <= 100 and is_binary(message) do
    if String.trim(message) == "", do: nil, else: %{percent: percent, message: message}
  end

  defp validate_entry(_entry), do: nil

  defp fallback(path, reason) do
    Logger.warning("exline: ignoring #{path}: #{reason}; using default context thresholds")
    @default_thresholds
  end
end
