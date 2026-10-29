defmodule SuperPi.Env.FileLock do
  @moduledoc """
  Per-path advisory file lock server (`REQ-SAFE-04`, `REQ-PBT-05`).

  Registered in `SuperPi.Registry` under `{:file_lock, env_id, canonical_path}` so concurrent
  `write_file` and `edit_file` operations targeting the same path execute strictly sequentially
  without lost updates or race conditions.
  """

  use GenServer

  @doc """
  Executes `fun.()` inside the exclusive lock for `{env_id, path}`.
  Resolves `Path.expand/1` before acquiring the lock so relative and absolute paths to the same
  file share the same lock process.
  """
  def with_lock(env_id, path, fun) when is_function(fun, 0) do
    with_lock(env_id, path, 30_000, fun)
  end

  def with_lock(env_id, path, timeout, fun)
      when is_binary(env_id) and is_binary(path) and is_integer(timeout) and is_function(fun, 0) do
    canonical = canonicalize_path(path)
    lock_pid = ensure_lock_server!(env_id, canonical)

    try do
      GenServer.call(lock_pid, {:run_exclusive, fun}, timeout)
    catch
      :exit, {:timeout, _} ->
        {:error, :lock_timeout}
    end
  end

  def canonicalize_path(path) when is_binary(path) do
    expanded = Path.expand(path)
    resolve_real_path(expanded, 16)
  end

  defp resolve_real_path(path, depth)

  defp resolve_real_path(path, 0), do: path

  defp resolve_real_path(path, depth) when depth > 0 do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, target_chars} ->
        target = List.to_string(target_chars)

        resolved =
          if Path.type(target) == :relative do
            Path.expand(target, Path.dirname(path))
          else
            Path.expand(target)
          end

        resolve_real_path(resolved, depth - 1)

      _ ->
        dir = Path.dirname(path)
        base = Path.basename(path)

        if dir != path and dir != "/" and dir != "." do
          real_dir = resolve_real_path(dir, depth - 1)
          Path.join(real_dir, base)
        else
          path
        end
    end
  end

  def start_link({env_id, canonical_path}) do
    GenServer.start_link(__MODULE__, {env_id, canonical_path}, name: via_tuple(env_id, canonical_path))
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:run_exclusive, fun}, _from, state) do
    result =
      try do
        {:ok, fun.()}
      rescue
        e -> {:exception, e, __STACKTRACE__}
      catch
        kind, reason -> {:caught, kind, reason}
      end

    case result do
      {:ok, val} ->
        {:reply, val, state}

      {:exception, e, stack} ->
        {:reply, {:error, {:exception, Exception.message(e), stack}}, state}

      {:caught, kind, reason} ->
        {:reply, {:error, {kind, reason}}, state}
    end
  end

  defp via_tuple(env_id, canonical_path) do
    {:via, Registry, {SuperPi.Registry, {:file_lock, env_id, canonical_path}}}
  end

  defp ensure_lock_server!(env_id, canonical_path) do
    case Registry.lookup(SuperPi.Registry, {:file_lock, env_id, canonical_path}) do
      [{pid, _}] ->
        pid

      [] ->
        spec = {__MODULE__, {env_id, canonical_path}}

        case DynamicSupervisor.start_child(SuperPi.FileLockSupervisor, spec) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end
end
