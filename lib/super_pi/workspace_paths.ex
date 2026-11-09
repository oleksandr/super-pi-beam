defmodule SuperPi.WorkspacePaths do
  @moduledoc "Shared working-directory resolution for local tools and their permission checks."

  def primary(agent), do: List.first(agent["workspacePaths"] || []) || File.cwd!()

  # Keep .. components intact: the filesystem and permission checks must both follow symlinks
  # before interpreting a later parent component.
  def absolute(path, base) when is_binary(path) do
    cond do
      String.starts_with?(path, "~") -> Path.expand(path)
      Path.type(path) == :absolute -> path
      true -> Path.join(base, path)
    end
  end

  def absolute(path, _base), do: path

  def file(path, args, base) do
    directory =
      args["cd"] || args[:cd] || args["dir"] || args[:dir] || args["cwd"] || args[:cwd]

    absolute(path, absolute(directory || ".", base))
  end
end
