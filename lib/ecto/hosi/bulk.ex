defmodule Ecto.Hosi.Bulk do
  @moduledoc false
  # `Repo.update_all/3` and `Repo.delete_all/2` on one schema: find the matching ids with the
  # same `where` as a read, then change them in ONE hosigraph write, guarded so that a row
  # that vanished meanwhile fails the write rather than being resurrected.

  alias Ecto.Hosi.{Attr, Backend, Reader, Update}

  def update_all(meta, %Ecto.Query{} = query, params) do
    no_select!(query, "update_all")
    {source, _schema, rows} = matching(meta, query, params)

    {ops, conds} =
      Enum.reduce(rows, {[], []}, fn {id, entity}, {ops, conds} ->
        {o, c} = Update.ops(meta, source, id, entity, query.updates, params)
        {ops ++ o, conds ++ c}
      end)

    write!(meta, ops, conds)
    {length(rows), nil}
  end

  def delete_all(meta, %Ecto.Query{} = query, params) do
    no_select!(query, "delete_all")
    {source, _schema, rows} = matching(meta, query, params)
    marker = Attr.marker(source)

    ops =
      for {id, entity} <- rows,
          {attr, vals} <- entity,
          v <- vals,
          do: [:delete, id, attr, Backend.wrap(meta, attr, v)]

    write!(meta, ops, for({id, _} <- rows, do: [:holds, id, marker, true]))
    {length(rows), nil}
  end

  # [{id, entity}] of the rows that really are rows of the schema.
  defp matching(meta, query, params) do
    {source, schema, ids} = Reader.candidate_ids(meta, query, params)
    marker = Attr.marker(source)

    rows =
      if ids == [] do
        []
      else
        meta
        |> Backend.get_entities(ids)
        |> Backend.ok!()
        |> then(&Enum.zip(ids, &1))
        |> Enum.filter(fn {_, entity} -> Map.has_key?(entity, marker) end)
      end

    {source, schema, rows}
  end

  defp write!(_meta, [], _conds), do: :ok

  defp write!(meta, ops, conds) do
    case Backend.write(meta, ops, when: conds) do
      {:ok, _} ->
        :ok

      {:error, {_, :conflict, _}} ->
        raise Ecto.Hosi.Error, message: "a row changed while it was being updated; try again"

      {:error, {_, :"write-rejected", msg}} ->
        raise Ecto.Hosi.Error, message: "hosigraph refused the write: " <> msg

      {:error, reason} ->
        raise Ecto.Hosi.Error, reason: reason
    end
  end

  defp no_select!(%{select: nil}, _what), do: :ok

  defp no_select!(_query, what) do
    raise ArgumentError,
          "Ecto.Adapters.Hosi does not support :select / returning in #{what}; read the rows first"
  end
end
