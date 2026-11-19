defmodule SuperPi.WorkspaceApproval do
  @moduledoc "Requests a human decision before adding a local folder to a conversation."

  alias SuperPi.Durable.{Doc, Storage}
  alias SuperPi.Plugins.Permissions
  alias SuperPi.UI.PermissionPrompt

  def spec do
    %{
      "name" => "request_workspace_access",
      "description" =>
        "Ask the user to add a folder to this conversation's trusted workspace roots. Use when the user asks to trust/add a folder or needs access outside the current workspace. Available in Ask, Plan and Build in local CLI/ACP sessions. Only the permission-dialog response grants access. Does not change Zed's own trust settings, run commands, or override workflow restrictions.",
      "effects" => ["state_write"],
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Absolute path to an existing folder"},
          "reason" => %{
            "type" => "string",
            "description" => "Why access to this folder is needed"
          }
        },
        "required" => ["path", "reason"]
      }
    }
  end

  def available?(agent),
    do:
      agent["workspaceApprovalScope"] == "conversation" and
        (agent["workspace"] || %{"kind" => "local"})["kind"] == "local"

  def request(args, %{conversation_id: id} = ctx) when is_integer(id) do
    agent = Doc.snapshot("conversation", id, "pi.agent") || %{}
    settings = Permissions.load_effective_settings(agent)

    with :ok <- enabled(agent, settings),
         {:ok, path} <- directory(args["path"]),
         :ok <- reason(args["reason"]),
         true <- PermissionPrompt.available?(id, settings) do
      fields = %{
        "tool_name" => "request_workspace_access",
        "arguments" => %{"path" => path},
        "reason" =>
          "Add trusted folder: #{path}\n#{args["reason"]}\nApplies to this conversation, its reloads and forks. Plan may read it; Build may also edit it. Ask still cannot inspect files. The primary working directory stays the same. Command approvals and protected-path rules still apply. This does not change Zed's project trust settings.",
        "risk" => "high",
        "options" => [
          %{
            "option_id" => "allow_once",
            "name" => "Trust folder for this conversation",
            "kind" => "allow_once"
          },
          %{"option_id" => "reject_once", "name" => "Reject", "kind" => "reject_once"}
        ]
      }

      case PermissionPrompt.ask(ctx, fields) do
        :allow_once -> approve(id, path)
        _ -> error("Workspace access was rejected, cancelled or timed out. No folders changed.")
      end
    else
      false -> error("A connected permission dialog is required to add a trusted folder.")
      {:error, message} -> error(message)
    end
  end

  def request(_, _), do: error("A conversation is required to request workspace access.")

  defp approve(id, path) do
    agent = Doc.snapshot("conversation", id, "pi.agent") || %{}

    with :ok <- enabled(agent, Permissions.load_effective_settings(agent)),
         {:ok, ^path} <- directory(path) do
      Storage.configure_agent!(id, %{
        "approvedWorkspacePaths" => Enum.uniq((agent["approvedWorkspacePaths"] || []) ++ [path]),
        "workspacePaths" => Enum.uniq((agent["workspacePaths"] || []) ++ [path])
      })

      %{
        "output" =>
          "Trusted folder added for this conversation: #{path}. Use its absolute path to target it. Workflow and command restrictions remain in effect.",
        "details" => %{"path" => path, "scope" => "conversation"}
      }
    else
      {:error, message} -> error(message)
      _ -> error("The folder changed while approval was pending. Request access again.")
    end
  end

  defp enabled(agent, settings) do
    cond do
      not available?(agent) ->
        {:error, "Workspace approval is available only in local CLI/ACP filesystem sessions."}

      "request_workspace_access" in (get_in(settings, ["permissions", "denyTools"]) || []) ->
        {:error, "Workspace access requests are disabled by policy."}

      true ->
        :ok
    end
  end

  defp directory(path) when is_binary(path) do
    if Path.type(path) == :absolute and not String.contains?(path, <<0>>) and File.dir?(path),
      do: {:ok, Permissions.canonical_path(path)},
      else: {:error, "Supply an absolute path to an existing folder."}
  end

  defp directory(_), do: {:error, "Supply an absolute path to an existing folder."}

  defp reason(value) when is_binary(value) and byte_size(value) in 1..2000, do: :ok
  defp reason(_), do: {:error, "Supply a short reason for requesting workspace access."}

  defp error(message), do: %{"is_error" => true, "output" => message, "details" => %{}}
end
