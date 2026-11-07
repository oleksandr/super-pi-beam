defmodule SuperPi.CommandApproval do
  @moduledoc "Requests command-prefix approval from the client; never executes a command."

  alias SuperPi.CommandRules
  alias SuperPi.Durable.{Doc, Storage}
  alias SuperPi.Plugins.Permissions
  alias SuperPi.UI.PermissionPrompt

  def spec do
    %{
      "name" => "request_command_approval",
      "description" =>
        "Ask the user to approve command prefixes for this conversation or future sessions. Use when the user asks to allow/pre-approve commands. Available in Ask, Plan and Build. Only the user's permission-dialog response grants approval. This tool does not execute commands or override workflow restrictions.",
      "effects" => ["state_write"],
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "prefixes" => %{
            "type" => "array",
            "items" => %{"type" => "array", "items" => %{"type" => "string"}},
            "description" =>
              "Literal argument prefixes, e.g. [[\"git\", \"log\"], [\"git\", \"status\"], [\"git\", \"diff\"]]. Propose the narrowest useful prefix."
          },
          "reason" => %{"type" => "string", "description" => "Why these commands are needed"}
        },
        "required" => ["prefixes", "reason"]
      }
    }
  end

  def request(args, %{conversation_id: id} = ctx) when is_integer(id) do
    agent = Doc.snapshot("conversation", id, "pi.agent") || %{}
    settings = Permissions.load_effective_settings(agent)

    with {:ok, prefixes} <- CommandRules.validate(args["prefixes"]),
         :ok <- validate_reason(args["reason"]),
         :ok <- enabled(settings),
         true <- PermissionPrompt.available?(id, settings) do
      names = Enum.map_join(prefixes, ", ", &Enum.join(&1, " "))
      persistent? = agent["commandRulesScope"] == "user"

      fields = %{
        "tool_name" => "request_command_approval",
        "arguments" => %{"prefixes" => prefixes},
        "reason" =>
          "Approve prefixes: #{names}. #{args["reason"]}\nSave for future sessions writes #{CommandRules.path(agent)} and applies to all projects using this Super-Pi data directory. Workflow limits and deny rules still apply. No command will run now.",
        "risk" => "high",
        "options" =>
          Enum.filter(
            [
              %{
                "option_id" => "allow_once",
                "name" => "Allow for this conversation",
                "kind" => "allow_once"
              },
              %{
                "option_id" => "allow_always",
                "name" => "Save for future sessions",
                "kind" => "allow_always"
              },
              %{"option_id" => "reject_once", "name" => "Reject", "kind" => "reject_once"}
            ],
            &(persistent? or &1["option_id"] != "allow_always")
          )
      }

      case PermissionPrompt.ask(ctx, fields) do
        :allow_once ->
          current = Doc.snapshot("conversation", id, "pi.agent") || %{}
          override = current["settingsOverride"] || %{}
          perms = override["permissions"] || %{}

          perms =
            Map.update(perms, "commandPrefixes", prefixes, &Enum.uniq(List.wrap(&1) ++ prefixes))

          Storage.configure_agent!(id, %{
            "settingsOverride" => Map.put(override, "permissions", perms)
          })

          success("Approved for this conversation: #{names}.")

        :allow_always when persistent? ->
          case CommandRules.save(agent, prefixes) do
            :ok ->
              success(
                "Saved command prefixes for future sessions: #{names}. Rules: #{CommandRules.path(agent)}"
              )

            {:error, reason} ->
              error(reason)
          end

        _ ->
          error("Command approval was rejected, cancelled or timed out. No rules changed.")
      end
    else
      false ->
        error(
          "A connected permission dialog is required. Chat text alone cannot approve commands."
        )

      {:error, reason} ->
        error(reason)
    end
  end

  def request(_, _), do: error("A conversation is required to request command approval.")

  defp validate_reason(reason) when is_binary(reason) and byte_size(reason) in 1..2000, do: :ok
  defp validate_reason(_), do: {:error, "Supply a short reason for requesting command approval."}

  defp enabled(settings) do
    denied = get_in(settings, ["permissions", "denyTools"]) || []

    if "request_command_approval" in denied,
      do: {:error, "Command approval requests are disabled by policy."},
      else: :ok
  end

  defp success(message), do: %{"output" => message, "details" => %{}}
  defp error(message), do: %{"is_error" => true, "output" => message, "details" => %{}}
end
