defmodule Ecto.Adapters.Hosi do
  @moduledoc """
  An Ecto adapter for [hosigraph](https://github.com/sukhi-social/hosigraph): an append-only event
  log with a Datalog database (Datalevin) folded from it.

  ## Setup

      defmodule MyApp.Repo do
        use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Hosi
      end

      config :my_app, MyApp.Repo,
        dir: "/var/lib/my_app/hosi",
        schemas: [MyApp.User, MyApp.Post]     # the schemas kept in hosigraph

  A schema is an ordinary Ecto schema with an integer `:id`, which is the hosigraph entity id.
  Rows are facts: a user's name is the fact `[user-id :"user/name" "Ada"]`.

  ## What works as in Ecto

  `insert`, `update` (with `optimistic_lock`), `delete`, `insert_all`, `get`, `get_by`, `all`,
  `one`, `exists?`, `aggregate(:count)`, `preload`, and `unique_constraint` in changesets.
  Queries may use one schema, `where` (`== != < <= > >= in is_nil not and or`), `order_by`,
  `limit`, `offset` and `select` of fields. Everything else raises with a pointer to
  `c:datalog/2`.

  ## What is different

    * **`not` is "there is no such fact".** `where: not (u.age > 30)` also finds rows that have no
      age at all; SQL would skip them because `NULL > 30` is unknown. `!=`, `<` and the rest need
      the fact to exist, as in SQL.
    * **No transactions.** hosigraph writes one batch atomically; Ecto's step-by-step
      transactions do not fit it. Use `c:write_batch/2` for all-or-nothing writes of several rows.
    * `Repo.insert` of a changeset with associations writes parent and children one after
      the other (not atomically).
    * `update_all` / `delete_all` / `stream` are not supported.
    * No migrations: the hosigraph schema is derived from your Ecto schemas when the Repo starts.

  ## Functions added to your Repo

    * `datalog(query, opts \\\\ [])` – a Datalog query (`Ecto.Hosi.Query.datalog/1`), with rules
    * `history(id)` – every event of one entity
    * `highest(schema, field, limit, opts \\\\ [])` – newest-first pages, e.g. a timeline
    * `erase(erasures)` – really remove (right to be forgotten)
    * `write_batch(steps, opts \\\\ [])` – several inserts/updates/deletes, all or nothing

  ## Pointing hosigraph at Datalevin

  hosigraph keeps "now" in Datalevin: the native `dtlv`, or a resident JVM with the standalone jar.
  Say which in `:open`:

      config :my_app, MyApp.Repo,
        dir: "/var/lib/my_app/hosi",
        schemas: [...],
        open: %{config: %{khana: [:dtlv, "/opt/datalevin/dtlv"]}}
        # or: open: %{config: %{khana: [:jvm, "java", "/opt/datalevin/datalevin-1.2.10-standalone.jar"]}}

  The adapter also sets the VM's `SIGCHLD` back to its default when it starts (a setting of the
  whole VM): the BEAM starts with it ignored, and the Haskell runtime inside it then cannot wait for
  the `dtlv`/`java` process it started ("waitForProcess: does not exist (No child processes)").

  ## Options

    * `:dir` – the hosigraph directory (also used by `mix ecto.create` / `ecto.drop`)
    * `:schemas` – Ecto schema modules kept here
    * `:open` – more options for opening hosigraph (merged with `dir` and `schema`)
    * `:hosi` – the module that talks to hosigraph (default `Hosi`; a test double works too)
    * `:precheck_unique` – default `true`: before writing a `hosi_unique` field, ask whether the value
      is taken, so the changeset error is exact. Set `false` to rely on hosigraph's own `unique`
      alone (one query less per write; the error is then worked out from hosigraph's message)
  """

  @behaviour Ecto.Adapter
  @behaviour Ecto.Adapter.Schema
  @behaviour Ecto.Adapter.Queryable
  @behaviour Ecto.Adapter.Storage

  alias Ecto.Hosi.{Attr, Backend, Reader, Schema, Types}

  ## ------------------------------------------------------------ Ecto.Adapter

  @impl Ecto.Adapter
  defmacro __before_compile__(_env) do
    quote do
      @doc "Run a Datalog query (see `Ecto.Hosi.Query.datalog/1`). Returns the rows, a set: in no particular order."
      def datalog(query, opts \\ []), do: Ecto.Hosi.RepoApi.datalog(__MODULE__, query, opts)

      @doc "Every event of one entity, oldest first."
      def history(id), do: Ecto.Hosi.RepoApi.history(__MODULE__, id)

      @doc """
      The facts of `field` from the high end: `{structs, last_place}`.
      Pass `after: last_place` for the next page.
      """
      def highest(schema, field, limit, opts \\ []),
        do: Ecto.Hosi.RepoApi.highest(__MODULE__, schema, field, limit, opts)

      @doc "Really remove entities, as hosigraph's `erase` does."
      def erase(erasures), do: Ecto.Hosi.RepoApi.erase(__MODULE__, erasures)

      @doc """
      Several writes in one atomic batch:

          Repo.write_batch(
            insert: {:post, post_changeset},
            insert: {:comment, comment_changeset, refs: [post_id: :post]},
            update: {:author, author_changeset}
          )
          #=> {:ok, %{post: %Post{}, comment: %Comment{}, author: %Author{}}}
      """
      def write_batch(steps, opts \\ []), do: Ecto.Hosi.Batch.run(__MODULE__, steps, opts)
    end
  end

  @impl Ecto.Adapter
  def ensure_all_started(_config, _type), do: {:ok, []}

  @impl Ecto.Adapter
  def init(config) do
    repo = Keyword.fetch!(config, :repo)
    backend = Keyword.get(config, :hosi, Hosi)
    if backend == Hosi, do: wait_for_children!()
    attrs = Schema.build(Keyword.get(config, :schemas, []))
    name = Keyword.get(config, :conn_name, Module.concat(repo, Conn))

    open =
      config
      |> Keyword.get(:open, %{})
      |> Map.new()
      |> then(fn open ->
        if config[:dir], do: Map.put_new(open, :dir, config[:dir]), else: open
      end)
      |> Map.update(:schema, attrs, &Map.merge(attrs, &1))

    child_spec = %{
      id: name,
      start: {backend, :start_link, [[open: open, name: name]]},
      type: :worker
    }

    meta = %{
      backend: backend,
      conn: name,
      attrs: attrs,
      precheck_unique: Keyword.get(config, :precheck_unique, true)
    }

    {:ok, child_spec, meta}
  end

  @impl Ecto.Adapter
  def checkout(_meta, _config, fun), do: fun.()

  @impl Ecto.Adapter
  def checked_out?(_meta), do: false

  @impl Ecto.Adapter
  def loaders(primitive, type), do: Types.loaders(primitive, type)

  @impl Ecto.Adapter
  def dumpers(primitive, type), do: Types.dumpers(primitive, type)

  ## ------------------------------------------------------------ Ecto.Adapter.Queryable

  @impl Ecto.Adapter.Queryable
  def prepare(:all, query), do: {:nocache, query}

  def prepare(op, _query) do
    raise ArgumentError,
          "Ecto.Adapters.Hosi does not support #{op}; hosigraph keeps history, " <>
            "so change rows with update/delete (or Repo.write_batch/2)"
  end

  @impl Ecto.Adapter.Queryable
  def execute(meta, _query_meta, {:nocache, query}, params, _opts),
    do: Reader.all(meta, query, params)

  @impl Ecto.Adapter.Queryable
  def stream(_meta, _query_meta, _query, _params, _opts) do
    raise ArgumentError, "Ecto.Adapters.Hosi does not support stream/2"
  end

  ## ------------------------------------------------------------ Ecto.Adapter.Schema

  @impl Ecto.Adapter.Schema
  def autogenerate(:id), do: nil
  def autogenerate(:embed_id), do: Ecto.UUID.generate()
  def autogenerate(:binary_id), do: Ecto.UUID.bingenerate()

  @impl Ecto.Adapter.Schema
  def insert(meta, %{source: source}, fields, on_conflict, returning, _opts) do
    check_on_conflict!(on_conflict)
    attrs = field_attrs(source, fields)

    case check_unique(meta, attrs, nil) do
      [] ->
        ops =
          [[:create, [:tmp, 1], Attr.marker(source), true]] ++
            for({attr, v} <- attrs, do: [:create, [:tmp, 1], attr, Backend.wrap(meta, attr, v)])

        case Backend.write(meta, ops) do
          {:ok, report} ->
            {:ok, returning_values(meta, source, Backend.temp_id(report, 1), returning)}

          {:error, {_, :"write-rejected", msg}} ->
            {:invalid, rejected(attrs, meta, msg)}

          {:error, reason} ->
            raise Ecto.Hosi.Error, reason: reason
        end

      violations ->
        {:invalid, violations}
    end
  end

  @impl Ecto.Adapter.Schema
  def insert_all(
        meta,
        %{source: source},
        _header,
        rows,
        on_conflict,
        returning,
        placeholders,
        _opts
      ) do
    check_on_conflict!(on_conflict)

    unless placeholders in [nil, []] do
      raise ArgumentError, "Ecto.Adapters.Hosi does not support insert_all placeholders"
    end

    rows_attrs = Enum.map(rows, &field_attrs(source, &1))

    for attrs <- rows_attrs, v <- Keyword.values(attrs), is_tuple(v) do
      raise ArgumentError, "Ecto.Adapters.Hosi insert_all takes plain values only"
    end

    ops =
      rows_attrs
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {attrs, n} ->
        [[:create, [:tmp, n], Attr.marker(source), true]] ++
          for({attr, v} <- attrs, do: [:create, [:tmp, n], attr, Backend.wrap(meta, attr, v)])
      end)

    if ops == [] do
      {0, nil}
    else
      case Backend.write(meta, ops) do
        {:ok, report} ->
          ids = for n <- 1..length(rows_attrs), do: Backend.temp_id(report, n)
          {length(ids), insert_all_returning(meta, source, ids, returning)}

        {:error, {_, :"write-rejected", msg}} ->
          raise Ecto.Hosi.Error, message: "insert_all was rejected: " <> msg

        {:error, reason} ->
          raise Ecto.Hosi.Error, reason: reason
      end
    end
  end

  @impl Ecto.Adapter.Schema
  def update(meta, %{source: source}, fields, filters, returning, _opts) do
    {id, locks} = split_filters(filters)
    marker = Attr.marker(source)
    attrs = field_attrs(source, fields, keep_nil: true)
    {nils, sets} = Enum.split_with(attrs, fn {_, v} -> is_nil(v) end)

    # Setting a field to nil retracts its current value, which has to be read first.
    old = if nils == [], do: %{}, else: read_entity(meta, id)

    deletes =
      for {attr, _} <- nils,
          v <- List.wrap(Map.get(old, attr)),
          do: {[:delete, id, attr, Backend.wrap(meta, attr, v)], [:holds, id, attr, v]}

    ops =
      for({attr, v} <- sets, do: [:create, id, attr, Backend.wrap(meta, attr, v)]) ++
        Enum.map(deletes, &elem(&1, 0))

    conds =
      [[:holds, id, marker, true]] ++
        Enum.map(deletes, &elem(&1, 1)) ++ lock_conditions(source, id, locks)

    case check_unique(meta, sets, id) do
      [] ->
        write_guarded(
          meta,
          ops,
          conds,
          fn -> returning_values(meta, source, id, returning) end,
          sets
        )

      violations ->
        {:invalid, violations}
    end
  end

  @impl Ecto.Adapter.Schema
  def delete(meta, %{source: source}, filters, _returning, _opts) do
    {id, locks} = split_filters(filters)
    marker = Attr.marker(source)
    entity = read_entity(meta, id)

    if Map.has_key?(entity, marker) do
      ops =
        for {attr, vals} <- entity,
            v <- vals,
            do: [:delete, id, attr, Backend.wrap(meta, attr, v)]

      conds = [[:holds, id, marker, true]] ++ lock_conditions(source, id, locks)
      write_guarded(meta, ops, conds, fn -> [] end, [])
    else
      {:error, :stale}
    end
  end

  ## ------------------------------------------------------------ Ecto.Adapter.Storage

  @impl Ecto.Adapter.Storage
  def storage_up(opts) do
    dir = Keyword.fetch!(opts, :dir)

    if File.dir?(dir) do
      {:error, :already_up}
    else
      case File.mkdir_p(dir) do
        :ok -> :ok
        {:error, reason} -> {:error, :file.format_error(reason) |> to_string()}
      end
    end
  end

  @impl Ecto.Adapter.Storage
  def storage_down(opts) do
    dir = Keyword.fetch!(opts, :dir)

    if File.dir?(dir) do
      case File.rm_rf(dir) do
        {:ok, _} -> :ok
        {:error, reason, _} -> {:error, :file.format_error(reason) |> to_string()}
      end
    else
      {:error, :already_down}
    end
  end

  @impl Ecto.Adapter.Storage
  def storage_status(opts), do: if(File.dir?(Keyword.fetch!(opts, :dir)), do: :up, else: :down)

  ## ------------------------------------------------------------ helpers

  # The BEAM starts with SIGCHLD ignored, so the kernel reaps every child the moment it exits.
  # hosigraph's Haskell runtime lives inside the BEAM and starts `dtlv` (or java) itself; when
  # it then waits for that child it gets ECHILD ("waitForProcess: does not exist (No child
  # processes)"). Restoring the default makes the wait work. It is a setting of the whole VM.
  defp wait_for_children! do
    :os.set_signal(:sigchld, :default)
  end

  defp check_on_conflict!({:raise, _, _}), do: :ok

  defp check_on_conflict!(other) do
    raise ArgumentError,
          "Ecto.Adapters.Hosi supports only on_conflict: :raise for now, got: #{inspect(other)}"
  end

  # [{field, value}] -> [{attr, value}] (nil values are not facts, except when retracting)
  defp field_attrs(source, fields, opts \\ []) do
    keep_nil? = Keyword.get(opts, :keep_nil, false)

    for {field, value} <- fields, keep_nil? or not is_nil(value) do
      if field == :id do
        raise ArgumentError,
              "Ecto.Adapters.Hosi cannot insert or change an id: hosigraph makes them"
      end

      {Attr.attr(source, field), value}
    end
  end

  defp split_filters(filters) do
    {id_pair, locks} = Enum.split_with(filters, fn {f, _} -> f == :id end)

    case id_pair do
      [{:id, id}] when is_integer(id) ->
        {id, locks}

      _ ->
        raise ArgumentError, "Ecto.Adapters.Hosi needs the integer :id to update or delete a row"
    end
  end

  defp lock_conditions(source, id, locks) do
    for {field, v} <- locks do
      attr = Attr.attr(source, field)
      if is_nil(v), do: [:unset, id, attr], else: [:holds, id, attr, v]
    end
  end

  defp write_guarded(meta, ops, conds, on_ok, attrs) do
    if ops == [] do
      # nothing to change: just see that the row still exists
      case Backend.get_entities(meta, [conds |> hd() |> Enum.at(1)]) |> Backend.ok!() do
        [entity] when map_size(entity) > 0 -> {:ok, on_ok.()}
        _ -> {:error, :stale}
      end
    else
      case Backend.write(meta, ops, when: conds) do
        {:ok, _} -> {:ok, on_ok.()}
        {:error, {_, :conflict, _}} -> {:error, :stale}
        {:error, {_, :"write-rejected", msg}} -> {:invalid, rejected(attrs, meta, msg)}
        {:error, reason} -> raise Ecto.Hosi.Error, reason: reason
      end
    end
  end

  defp read_entity(meta, id) do
    case Backend.get_entities(meta, [id]) |> Backend.ok!() do
      [entity] -> entity
      _ -> %{}
    end
  end

  # The values Ecto asked back (`:id`, or fields it wants read after the write).
  defp returning_values(_meta, _source, id, [:id]), do: [id: id]
  defp returning_values(_meta, _source, _id, []), do: []

  defp returning_values(meta, source, id, returning) do
    entity = read_entity(meta, id)

    for field <- returning do
      if field == :id,
        do: {:id, id},
        else: {field, Backend.first(entity, Attr.attr(source, field))}
    end
  end

  defp insert_all_returning(_meta, _source, _ids, []), do: nil
  defp insert_all_returning(_meta, _source, ids, [:id]), do: Enum.map(ids, &[&1])

  defp insert_all_returning(meta, source, ids, returning) do
    entities = Backend.get_entities(meta, ids) |> Backend.ok!()

    for {id, entity} <- Enum.zip(ids, entities) do
      for field <- returning do
        if field == :id, do: id, else: Backend.first(entity, Attr.attr(source, field))
      end
    end
  end

  ## ---- unique constraints
  #
  # Before writing, ask whether a unique value is already taken: that answers precisely, with the
  # constraint name `unique_constraint/3` expects. hosigraph's own `unique` stays the guard against
  # races; if it still refuses, `rejected/3` works out which attribute from the message.

  defp check_unique(%{precheck_unique: false}, _attrs, _self_id), do: []

  defp check_unique(meta, attrs, self_id) do
    for {attr, v} <- attrs,
        match?(%{^attr => %{unique: _}}, meta.attrs),
        taken?(meta, attr, v, self_id) do
      {:unique, Attr.constraint_name(attr)}
    end
  end

  defp taken?(meta, attr, value, self_id) do
    req = %{q: "[:find ?e :in $ ?v :where [?e #{Attr.kw(attr)} ?v]]", inputs: [[:scalar, value]]}
    rows = meta |> Backend.query(req) |> Backend.ok!()
    Enum.any?(rows, fn [e] -> e != self_id end)
  end

  defp rejected(attrs, meta, message) do
    uniques = for {attr, _} <- attrs, match?(%{^attr => %{unique: _}}, meta.attrs), do: attr
    named = Enum.filter(uniques, &mentions?(message, &1))

    case {named, uniques} do
      {[_ | _], _} -> Enum.map(named, &{:unique, Attr.constraint_name(&1)})
      {[], [one]} -> [unique: Attr.constraint_name(one)]
      _ -> raise Ecto.Hosi.Error, message: "hosigraph refused the write: " <> message
    end
  end

  # does the message name this attribute, as `:user/email`, `:"user/email"` or plain `user/email`?
  defp mentions?(message, attr) do
    Regex.match?(~r/(?<![\w\/\-])#{Regex.escape(Atom.to_string(attr))}(?![\w\/\-])/, message)
  end

  @doc false
  def __check_unique__(meta, attrs, self_id), do: check_unique(meta, attrs, self_id)
end
