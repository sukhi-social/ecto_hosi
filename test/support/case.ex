defmodule Ecto.Hosi.Case do
  @moduledoc false
  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto.Query
      import Ecto.Hosi.Case, only: [facts: 0]
      alias Ecto.Hosi.Test.{Follow, Post, Repo, Rules, User}
      alias Ecto.Hosi.Fake
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "ecto_hosi_#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    start_supervised!({Ecto.Hosi.Test.Repo, dir: dir})
    on_exit(fn -> File.rm_rf(dir) end)
    :ok
  end

  @doc "All facts, as `%{{id, attr} => values}`: from the stand-in, or from a real hosigraph."
  def facts do
    case Application.get_env(:ecto_hosi, Ecto.Hosi.Test.Repo)[:hosi] do
      Ecto.Hosi.Fake ->
        Ecto.Hosi.Fake.dump(Ecto.Hosi.Test.Repo.Conn).facts

      _real ->
        Ecto.Hosi.Test.Repo.datalog(%{q: "[:find ?e ?a ?v :where [?e ?a ?v]]", inputs: []})
        |> Enum.group_by(fn [e, a, _] -> {e, a} end, fn [_, _, v] -> v end)
    end
  end
end
