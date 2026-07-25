defmodule Exline.PluginVersion do
  @moduledoc false

  # Detects version drift between the running daemon and the plugin copy
  # installed via a Claude Code marketplace. Claude Code records installs in
  # ~/.claude/plugins/installed_plugins.json; when that version differs from
  # the daemon's own, the statusline shows a "run /exline:setup" nag. Not
  # installed as a plugin (no exline@* key), unreadable file, or a matching
  # version all mean no drift.

  @doc """
  Returns `{running, installed}` when the installed plugin version differs
  from the running daemon's, `nil` otherwise.
  """
  def drift(path \\ default_path()) do
    running = running_version()
    installed = installed_version(path)

    if running && installed && running != installed do
      {running, installed}
    end
  end

  def running_version do
    case Application.spec(:exline, :vsn) do
      nil -> nil
      vsn -> List.to_string(vsn)
    end
  end

  def installed_version(path \\ default_path()) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{"plugins" => plugins}} <- JSON.decode(raw) do
      Enum.find_value(plugins, fn {key, entries} ->
        String.starts_with?(key, "exline@") && entry_version(entries)
      end)
    else
      _ -> nil
    end
  end

  defp entry_version([%{"version" => v} | _]) when is_binary(v) and v != "unknown", do: v
  defp entry_version(_), do: nil

  defp default_path do
    Path.join(System.user_home!(), ".claude/plugins/installed_plugins.json")
  end
end
