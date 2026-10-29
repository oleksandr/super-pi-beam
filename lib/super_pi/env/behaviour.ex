defmodule SuperPi.Env.Behaviour do
  @moduledoc """
  Unified execution environment contract (`SuperPi.Env`, `REQ-SAFE-01`..`REQ-SAFE-04`).

  Provides isolated filesystem, search, and OS process operations that never crash the BEAM VM.
  """

  @callback id() :: String.t()
  @callback read_file(path :: String.t(), opts :: keyword()) :: {:ok, String.t()} | {:error, term()}
  @callback write_file(path :: String.t(), content :: String.t(), opts :: keyword()) :: :ok | {:error, term()}
  @callback edit_file(path :: String.t(), old_text :: String.t(), new_text :: String.t(), opts :: keyword()) ::
              {:ok, %{replacements: non_neg_integer()}} | {:error, term()}
  @callback list_files(root_dir :: String.t(), opts :: keyword()) :: {:ok, list(String.t())} | {:error, term()}
  @callback scan_lines(root_dir :: String.t(), pattern :: String.t(), opts :: keyword()) ::
              {:ok, list(map())} | {:error, term()}
  @callback exec_command(cmd :: String.t(), args :: list(String.t()), opts :: keyword()) ::
              {:ok, %{exit_code: integer(), output: String.t(), spilled_path: String.t() | nil}}
              | {:error, term()}
end
