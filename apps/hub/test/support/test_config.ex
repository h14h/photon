defmodule Photon.TestConfig do
  @moduledoc """
  Changes to the application's and the OS's environment for one test, put
  back exactly when it exits: a key that was absent is deleted again, and a
  key that was set gets its value back, even nil.

  Only the first change to a key in a test takes the value to put back, so a
  test may change a key its setup already changed, or change it twice.
  Call these from the test's process (its body or a `setup` block).
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  import ExUnit.Callbacks, only: [on_exit: 2]

  @doc "`Application.put_env/3` until the test exits."
  def put_env(app, key, value) do
    remember_env(app, key)
    Application.put_env(app, key, value)
  end

  @doc "`Application.delete_env/2` until the test exits."
  def delete_env(app, key) do
    remember_env(app, key)
    Application.delete_env(app, key)
  end

  @doc "`System.put_env/2` until the test exits."
  def put_system_env(name, value) do
    ref = {__MODULE__, :system, name}

    if Process.get(ref) == nil do
      previous = System.get_env(name)
      Process.put(ref, {:previous, previous})
      on_exit(ref, fn -> restore_system_env(name, previous) end)
    end

    System.put_env(name, value)
  end

  defp remember_env(app, key) do
    ref = {__MODULE__, app, key}

    if Process.get(ref) == nil do
      previous = Application.fetch_env(app, key)
      Process.put(ref, previous)
      on_exit(ref, fn -> restore_env(app, key, previous) end)
    end

    :ok
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)
end
