defmodule SuperPi.Artifacts.Tools do
  @moduledoc "Runs `artifact_put`, `artifact_get` and `artifact_list` for a conversation and its workspace."

  alias SuperPi.Artifacts
  alias SuperPi.Env.Workspace

  @max_inline 100 * 1024

  def run(_tool, _args, _ws, %{conversation_id: nil}), do: error("artifact tools need a conversation", "invalid_context")

  def run("artifact_put", args, ws, %{conversation_id: conv}) do
    name = args["name"]
    content_type = if is_binary(args["content_type"]), do: args["content_type"], else: "text/plain"

    with {:ok, data} <- source(args, ws),
         {:ok, %{size: size}} <- Artifacts.put(conv, name, data, content_type) do
      ok("Saved artifact #{name} (#{size} bytes).", %{"name" => name, "size" => size})
    else
      {:error, reason} -> error(describe(reason, name), status(reason))
    end
  end

  def run("artifact_get", args, ws, %{conversation_id: conv}) do
    name = args["name"]

    case Artifacts.get(conv, name) do
      {:ok, %{data: data, content_type: type, size: size}} ->
        case args["to_path"] do
          path when is_binary(path) and path != "" -> write_out(ws, path, name, data)
          _ -> inline(name, data, type, size)
        end

      {:error, reason} ->
        error(describe(reason, name), status(reason))
    end
  end

  def run("artifact_list", _args, _ws, %{conversation_id: conv}) do
    items = Artifacts.list(conv)

    text =
      case items do
        [] -> "No artifacts."
        _ -> Enum.map_join(items, "\n", &"#{&1.name}  #{&1.size} bytes  #{&1.content_type}")
      end

    ok(text, %{"artifacts" => Enum.map(items, &%{"name" => &1.name, "size" => &1.size, "content_type" => &1.content_type})})
  end

  def run(other, _args, _ws, _ctx), do: error("unknown artifact tool #{other}", "unknown_tool")

  # The content comes from `content`, or from a workspace file named by `path`.
  defp source(%{"content" => content}, _ws) when is_binary(content), do: {:ok, content}

  defp source(%{"path" => path}, ws) when is_binary(path) and path != "" do
    if Workspace.supports?(ws, "read") do
      abs = file_path(ws, path)

      case ws.env.read_file(abs, []) do
        {:ok, text} -> {:ok, text}
        {:error, reason} -> {:error, {:read_failed, path, reason}}
      end
    else
      {:error, {:no_filesystem, ws.kind}}
    end
  end

  defp source(_args, _ws), do: {:error, :missing_content}

  defp write_out(ws, path, name, data) do
    if Workspace.supports?(ws, "write") do
      case ws.env.write_file(file_path(ws, path), data, []) do
        :ok -> ok("Wrote artifact #{name} to #{path} (#{byte_size(data)} bytes).", %{"name" => name, "path" => path})
        {:error, reason} -> error("Cannot write #{path}: #{inspect(reason)}", "write_failed")
      end
    else
      error("The #{ws.kind} workspace has no filesystem, so to_path is not possible.", "workspace_unsupported")
    end
  end

  defp file_path(%{confined?: true} = ws, path), do: Workspace.contain!(ws, path)
  defp file_path(_ws, path), do: Path.expand(path)

  defp inline(name, data, type, size) do
    cond do
      not String.valid?(data) ->
        error("Artifact #{name} is binary (#{size} bytes). Use to_path to write it to a workspace file.", "binary")

      byte_size(data) > @max_inline ->
        error("Artifact #{name} is #{size} bytes, too large to return. Use to_path to write it to a workspace file.", "too_large_to_return")

      true ->
        ok(data, %{"name" => name, "size" => size, "content_type" => type})
    end
  end

  defp describe(:invalid_name, _), do: "Invalid artifact name. Use letters, digits, . _ - and / (no .. and no leading /)."
  defp describe(:not_found, name), do: "No artifact named #{name}."
  defp describe({:too_large, max}, _), do: "The artifact is larger than the limit of #{max} bytes."
  defp describe({:too_many, max}, _), do: "This conversation already has #{max} artifacts. Replace one, or delete what you do not need."
  defp describe(:missing_content, _), do: "Give `content` (text) or `path` (a workspace file)."
  defp describe({:read_failed, path, reason}, _), do: "Cannot read #{path}: #{inspect(reason)}"
  defp describe({:no_filesystem, kind}, _), do: "The #{kind} workspace has no filesystem, so `path` is not possible. Give `content`."
  defp describe(other, _), do: "Artifact error: #{inspect(other)}"

  defp status(:invalid_name), do: "invalid_name"
  defp status(:not_found), do: "not_found"
  defp status({:too_large, _}), do: "too_large"
  defp status({:too_many, _}), do: "too_many"
  defp status(:missing_content), do: "invalid_arguments"
  defp status(_), do: "failed"

  defp ok(text, structured), do: %{"output" => text, "structured_output" => structured, "details" => %{}}

  defp error(message, status) do
    %{"output" => message, "structured_output" => %{"error" => message, "status" => status}, "details" => %{"status" => status}, "is_error" => true}
  end
end
