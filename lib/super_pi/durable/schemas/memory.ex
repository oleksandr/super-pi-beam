defmodule SuperPi.Durable.Schemas.Memory do
  @moduledoc """
  A durable note of the Memory plugin (`memories` table).

  A note belongs to a scope `(scope_kind, scope_id)`: `owner` (the principal that owns the
  conversation, the default) or `global`. It does not belong to a conversation. Notes are not forked
  and not rewound, so `origin_conversation_id` is a plain integer, deliberately not a foreign key,
  and deleting a conversation never deletes knowledge. `created_seq`, `origin_conversation_id` and
  `origin_entry_seq` keep an as-of view possible later.

  `topics` is a space-separated string of normalized words (see `SuperPi.Memory.normalize_topics/1`),
  so one text column feeds the lexical index. `superseded_by_id` marks a corrected note: it stays
  readable and ranks below the note that replaced it.

  The lexical index (`memories_fts` on SQLite, the generated `search` column on PostgreSQL) is not a
  field here. The database keeps it in step with the row.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "memories" do
    field :scope_kind, :string, default: "owner"
    field :scope_id, :string, default: ""
    field :slug, :string
    field :title, :string
    field :body, :string
    field :topics, :string, default: ""
    field :provenance, :string, default: "agent"
    field :confidence, :float, default: 0.7
    field :source, :map, default: %{}
    field :pinned, :boolean, default: false
    field :superseded_by_id, :integer
    field :created_seq, :integer
    field :updated_seq, :integer
    field :origin_conversation_id, :integer
    field :origin_entry_seq, :integer

    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(scope_kind scope_id slug title body topics provenance confidence source pinned
             superseded_by_id created_seq updated_seq origin_conversation_id origin_entry_seq)a

  def changeset(memory, attrs) do
    memory
    |> cast(attrs, @fields)
    |> validate_required([:scope_kind, :slug, :title, :body, :created_seq, :updated_seq])
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> unique_constraint([:scope_kind, :scope_id, :slug], name: :memories_scope_kind_scope_id_slug_index)
  end
end

defmodule SuperPi.Durable.Schemas.MemoryLink do
  @moduledoc """
  A typed edge between two notes of one scope (`memory_links` table): `related`, `derived_from` or
  `supersedes`. A `supersedes` edge also sets `superseded_by_id` on the older note.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "memory_links" do
    field :from_id, :integer
    field :to_id, :integer
    field :rel, :string
    field :created_seq, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:from_id, :to_id, :rel, :created_seq])
    |> validate_required([:from_id, :to_id, :rel, :created_seq])
  end
end
