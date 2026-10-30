defmodule SuperPi.Env.ClientFS do
  @moduledoc """
  Reads a file through the ACP client, so the agent sees the unsaved editor buffer.

  This is the one real gain of ACP `fs/read_text_file`. Everything else about delegating file access
  costs something: it routes I/O around the workspace boundary check and around `Env.FileLock`, and it
  breaks outright when the machine runs on another node than the ACP connection, because the
  editor's filesystem does not exist there. So `maybe_read/4` asks the client only when all of these hold:

  1. `config :super_pi, :acp, fs_delegation:` is not `:never`. Values: `:unsaved_only` (default),
     `:never`, `:always`.
  2. An `SuperPi.ACP.Server` on this node serves the conversation and its client advertised
     `fs.readTextFile`.
  3. The workspace is `local`.
  4. The path is inside a workspace root (`Permissions.within?/2`), checked before the request leaves.

  With `:unsaved_only` a failed request (the client has no such file, a timeout) falls back to the
  local disk. With `:always` the client's error is the result. Writes are never delegated.
  """

  alias SuperPi.Durable.Doc
  alias SuperPi.Plugins.Permissions
  alias SuperPi.UI.Broker

  @doc """
  `{:ok, content}` when the client served the read, `:skip` when the caller should read the disk,
  `{:error, reason}` when `:always` is set and the client failed.
  """
  @spec maybe_read(map(), map(), String.t(), keyword()) ::
          {:ok, String.t()} | :skip | {:error, term()}
  def maybe_read(ctx, ws, path, opts) do
    conv_id = Map.get(ctx, :conversation_id)

    with mode when mode != :never <- mode(),
         "local" <- ws.kind,
         true <- is_integer(conv_id),
         server when is_pid(server) <- server_for(conv_id),
         true <- inside_workspace?(conv_id, path) do
      case SuperPi.ACP.Server.read_text_file(server, conv_id, path, opts) do
        {:ok, content} -> {:ok, content}
        {:error, _} when mode == :unsaved_only -> :skip
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> :skip
    end
  end

  @doc "The `:fs_delegation` setting."
  @spec mode() :: :unsaved_only | :never | :always
  def mode do
    case Application.get_env(:super_pi, :acp, []) |> Access.get(:fs_delegation) do
      m when m in [:never, :always] -> m
      _ -> :unsaved_only
    end
  end

  # Only a server on this node: a machine on another node has no editor to ask.
  defp server_for(conv_id) do
    Enum.find(
      :pg.get_local_members(Broker.scope(), {:acp_fs, conv_id}),
      &(node(&1) == node() and Process.alive?(&1))
    )
  end

  defp inside_workspace?(conv_id, path) do
    agent = Doc.snapshot("conversation", conv_id, "pi.agent") || %{}
    roots = Map.get(agent, "workspacePaths") || []
    Path.type(path) == :absolute and Enum.any?(roots, &Permissions.within?(path, &1))
  end
end
