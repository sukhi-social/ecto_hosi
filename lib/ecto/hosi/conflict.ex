defmodule Ecto.Hosi.Conflict do
  @moduledoc false
  # `on_conflict:` for `insert` and `insert_all`. What Ecto hands the adapter:
  #
  #     {:raise, [], []}                      the default
  #     {:nothing, [], targets}               on_conflict: :nothing
  #     {[field, ..], [], targets}            {:replace, ..}, :replace_all, :replace_all_except
  #     {%Ecto.Query{}, params, targets}      [set: .., inc: ..] or an update query
  #
  # `targets` is the `conflict_target:` as field names: `[:email]`, `[:a, :b]`. A row conflicts
  # with an existing row when all the target fields are equal (a nil never conflicts, as in SQL).
  #
  # Looking the existing row up and writing are two steps: with the target on a `hosi_unique`
  # field hosigraph's own `unique` is the guard against a race; without it two concurrent inserts
  # of the same target can both succeed.

  alias Ecto.Hosi.{Attr, Backend, Update}

  def check!({:raise, _, _}), do: :ok
  def check!({:nothing, _, targets}), do: targets!(targets)
  def check!({fields, _, targets}) when is_list(fields), do: targets!(targets)
  def check!({%Ecto.Query{} = q, _, targets}) do
    targets!(targets)

    if q.wheres != [] do
      raise ArgumentError, "Ecto.Adapters.Hosi does not support a where in an on_conflict query"
    end
  end

  def check!(other) do
    raise ArgumentError, "Ecto.Adapters.Hosi cannot handle on_conflict: #{inspect(other)}"
  end

  defp targets!(targets) when is_list(targets), do: :ok

  defp targets!(other) do
    raise ArgumentError,
          "Ecto.Adapters.Hosi supports conflict_target: [fields] only, got: #{inspect(other)}"
  end

  def raise?({:raise, _, _}), do: true
  def raise?(_), do: false

  def nothing?({:nothing, _, _}), do: true
  def nothing?(_), do: false

  @doc "Without a target, `:nothing` means any unique violation (the caller checks those)."
  def targetless?({_, _, []}), do: true
  def targetless?(_), do: false

  @doc "The key of a row: `[{attr, value}]` of its target fields, or nil when it has none to match."
  def key(source, attrs, {_, _, targets}) when targets != [] do
    pairs = for f <- targets, do: {Attr.attr(source, f), Keyword.get(attrs, Attr.attr(source, f))}
    if Enum.any?(pairs, fn {_, v} -> is_nil(v) end), do: nil, else: pairs
  end

  def key(_source, _attrs, _on_conflict), do: nil

  @doc "`{:conflict, id}` of the existing row this one collides with, or `:none`."
  def find(meta, source, attrs, on_conflict) do
    case key(source, attrs, on_conflict) do
      nil -> :none
      pairs -> lookup(meta, source, pairs)
    end
  end

  defp lookup(meta, source, pairs) do
    vars = for {_, i} <- Enum.with_index(pairs, 1), do: "?v#{i}"

    clauses =
      for {{attr, _}, var} <- Enum.zip(pairs, vars), do: "[?e #{Attr.kw(attr)} #{var}]"

    req = %{
      q:
        "[:find ?e :in $ #{Enum.join(vars, " ")} :where [?e #{Attr.kw(Attr.marker(source))} _] " <>
          "#{Enum.join(clauses, " ")}]",
      inputs: for({_, v} <- pairs, do: [:scalar, v])
    }

    case meta |> Backend.query(req) |> Backend.ok!() |> Enum.map(fn [id] -> id end) do
      [] -> :none
      ids -> {:conflict, Enum.min(ids)}
    end
  end

  @doc "`{ops, conds}` that apply the conflict action to the existing row `id`."
  def ops(_meta, _source, _id, _entity, _attrs, {:nothing, _, _}), do: {[], []}

  def ops(meta, source, id, entity, attrs, {fields, _, _}) when is_list(fields) do
    values = for f <- fields, do: {Attr.attr(source, f), Keyword.get(attrs, Attr.attr(source, f))}
    {ops, conds} = Update.set_ops(meta, id, entity, values)
    {ops, [[:holds, id, Attr.marker(source), true] | conds]}
  end

  # The query's `^` indexes continue after the insert's own parameters, but `params` holds only
  # the query's: pad the front so an index finds its value.
  def ops(meta, source, id, entity, _attrs, {%Ecto.Query{} = q, params, _}) do
    padded = List.duplicate(nil, offset(q.updates)) ++ params
    Update.ops(meta, source, id, entity, q.updates, padded)
  end

  defp offset(updates) do
    case pins(updates, []) do
      [] -> 0
      ixs -> Enum.min(ixs)
    end
  end

  defp pins({:^, _, [ix]}, acc) when is_integer(ix), do: [ix | acc]
  defp pins(%{expr: e}, acc), do: pins(e, acc)
  defp pins(list, acc) when is_list(list), do: Enum.reduce(list, acc, &pins/2)
  defp pins({a, b}, acc), do: pins(b, pins(a, acc))
  defp pins(_, acc), do: acc
end
