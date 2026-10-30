defmodule SuperPi.Artifacts do
  @moduledoc """
  Explicit storage for files that an agent wants to keep.

  A scratch workspace disappears when its task ends or its node fails. An artifact does not:
  it is stored by name in the database, scoped to one conversation, and survives restarts and
  failover. The agent uses three tools:

  | Tool | Purpose |
  |---|---|
  | `artifact_put` | Save text (`content`) or a workspace file (`path`) under `name`. A second put replaces it. |
  | `artifact_get` | Return an artifact, or write it to a workspace file (`to_path`). |
  | `artifact_list` | List the artifacts of the conversation. |

  The backend is `SuperPi.Artifacts.Store`. The default stores blobs in the repo
  (`SuperPi.Artifacts.Ecto`: PostgreSQL, or SQLite on a single node). Another backend (for
  example an S3-compatible bucket) implements the behaviour and is set with
  `config :super_pi, artifact_store: MyStore`.

  Limits: `artifact_max_bytes` per artifact (default 10 MiB) and `artifact_max_count` per
  conversation (default 200). Names are `A-Z a-z 0-9 . _ - /`, up to 200 characters, with no
  `..` segment and no leading slash.
  """

  @type result :: {:ok, term()} | {:error, term()}

  @name_rule ~r{\A[A-Za-z0-9._\-]+(/[A-Za-z0-9._\-]+)*\z}

  def store, do: Application.get_env(:super_pi, :artifact_store, SuperPi.Artifacts.Ecto)
  def max_bytes, do: Application.get_env(:super_pi, :artifact_max_bytes, 10 * 1024 * 1024)
  def max_count, do: Application.get_env(:super_pi, :artifact_max_count, 200)

  @doc "Validates an artifact name."
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name) do
    byte_size(name) in 1..200 and Regex.match?(@name_rule, name) and
      not Enum.member?(String.split(name, "/"), "..") and
      not Enum.member?(String.split(name, "/"), ".")
  end

  def valid_name?(_), do: false

  @spec put(integer(), String.t(), binary(), String.t()) :: result()
  def put(conversation_id, name, data, content_type \\ "application/octet-stream") do
    cond do
      not valid_name?(name) -> {:error, :invalid_name}
      byte_size(data) > max_bytes() -> {:error, {:too_large, max_bytes()}}
      true -> store().put(conversation_id, name, data, content_type)
    end
  end

  @spec get(integer(), String.t()) :: result()
  def get(conversation_id, name) do
    if valid_name?(name), do: store().get(conversation_id, name), else: {:error, :invalid_name}
  end

  @spec list(integer()) :: [map()]
  def list(conversation_id), do: store().list(conversation_id)

  @spec delete(integer(), String.t()) :: :ok | {:error, term()}
  def delete(conversation_id, name), do: store().delete(conversation_id, name)

  @doc "Tool specifications for the three artifact tools."
  def tool_specs do
    [
      %{
        "name" => "artifact_put",
        "effects" => ["state_write"],
        "description" =>
          "Save a file so that it survives this task and node failures. Give `content` (text) or `path` (a file in the workspace). Saving under an existing name replaces it.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{
              "type" => "string",
              "description" => "Artifact name, for example reports/summary.md"
            },
            "content" => %{"type" => "string", "description" => "Text to save"},
            "path" => %{
              "type" => "string",
              "description" => "Workspace file to save instead of `content`"
            },
            "content_type" => %{"type" => "string"}
          },
          "required" => ["name"]
        },
        "exposure" => "direct"
      },
      %{
        "name" => "artifact_get",
        "effects" => ["read"],
        "description" => "Read a saved artifact, or write it into the workspace with `to_path`.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string"},
            "to_path" => %{
              "type" => "string",
              "description" => "Write the artifact to this workspace file instead of returning it"
            }
          },
          "required" => ["name"]
        },
        "exposure" => "direct"
      },
      %{
        "name" => "artifact_list",
        "effects" => ["read"],
        "description" => "List the saved artifacts of this conversation.",
        "parameters" => %{"type" => "object", "properties" => %{}},
        "exposure" => "direct"
      }
    ]
  end

  def tool_names, do: ["artifact_put", "artifact_get", "artifact_list"]
end
