defmodule Ecto.Hosi.RepoApi do
  @moduledoc false
  # What `Ecto.Adapters.Hosi.__before_compile__/1` adds to a Repo.

  alias Ecto.Hosi.{Attr, Backend, Query}

  defp meta(repo), do: Ecto.Adapter.lookup_meta(repo.get_dynamic_repo())

  def datalog(repo, %Query{} = query, opts), do: datalog(repo, Query.to_request(query), opts)

  def datalog(repo, %{q: _} = request, _opts) do
    meta = meta(repo)
    meta |> Backend.query(request) |> Backend.ok!()
  end

  def history(repo, id) do
    meta = meta(repo)
    meta.backend.history(meta.conn, id) |> Backend.ok!()
  end

  def erase(repo, erasures) do
    meta = meta(repo)
    meta.backend.erase(meta.conn, erasures) |> Backend.ok!()
  end

  def highest(repo, schema, field, limit, opts) do
    meta = meta(repo)
    source = schema.__schema__(:source)
    attr = Attr.attr(source, field)

    places = meta.backend.highest(meta.conn, attr, limit, opts) |> Backend.ok!()
    ids = Enum.map(places, & &1.id)
    entities = if ids == [], do: [], else: Backend.get_entities(meta, ids) |> Backend.ok!()

    structs =
      for {id, entity} <- Enum.zip(ids, entities) do
        data =
          for f <- schema.__schema__(:fields), into: %{} do
            if f == :id, do: {:id, id}, else: {f, Backend.first(entity, Attr.attr(source, f))}
          end

        repo.load(schema, data)
      end

    {structs, List.last(places)}
  end
end
