defmodule SuperPi.Artifacts.Store do
  @moduledoc """
  Backend contract for `SuperPi.Artifacts`. Validation (name, size) happens before a call, so a
  backend only stores and fetches. Implement it for another store, such as an S3-compatible bucket.
  """

  @callback put(
              conversation_id :: integer(),
              name :: String.t(),
              data :: binary(),
              content_type :: String.t()
            ) ::
              {:ok, %{name: String.t(), size: non_neg_integer()}} | {:error, term()}

  @callback get(conversation_id :: integer(), name :: String.t()) ::
              {:ok, %{data: binary(), content_type: String.t(), size: non_neg_integer()}}
              | {:error, :not_found | term()}

  @callback list(conversation_id :: integer()) :: [
              %{name: String.t(), size: non_neg_integer(), content_type: String.t()}
            ]

  @callback delete(conversation_id :: integer(), name :: String.t()) :: :ok | {:error, term()}
end
