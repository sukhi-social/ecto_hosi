# ecto_hosi

An [Ecto](https://hex.pm/packages/ecto) adapter for [hosigraph](https://github.com/sukhi-social/hosigraph),
a database where an append-only event log is the truth and "now" is a Datalevin (Datalog) copy folded from it.

You keep `Repo`, schemas, changesets and `preload`, and you also get **Datalog with recursive rules**,
the **history** of any row, and **real erasure**. It has no SQL, joins, transactions or migrations.
日本語: [README.ja.md](README.ja.md)

> 0.1, not on Hex. Tested on Linux aarch64 only.

## Install

```elixir
# mix.exs
{:ecto_hosi, github: "sukhi-social/ecto_hosi"}
```

You also need:

* **libhosi**, hosigraph's compiled core. Prebuilt downloads exist only for tagged releases, so build it
  (GHC 9.10.3 + cabal): `cabal build hosigraph-abi:flib:hosi` in a hosigraph checkout, then compile your
  app with `HOSI_BUILD=source HOSI_LIB_DIR=<dir of libhosi.so> HOSI_INCLUDE_DIR=<hosigraph-abi/gen/include>`.
  Without it, `mix deps.compile hosi` fails with `... is not in checksum.txt`. (I ran from a checkout with
  `HOSI_PATH`; the `HOSI_LIB_DIR` route is from hosigraph-ex's docs and untried.)
* **Datalevin**: the native `dtlv`, or JDK 21+ with the standalone jar (1.2.10).

## Use

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Hosi
end

config :my_app, MyApp.Repo,
  dir: "/var/lib/my_app/hosi",
  schemas: [MyApp.User, MyApp.Post, MyApp.Follow],
  open: %{config: %{khana: [:dtlv, "/opt/datalevin/dtlv"]}}
  # or: %{config: %{khana: [:jvm, "java", "/opt/datalevin/datalevin-1.2.10-standalone.jar"]}}

defmodule MyApp.User do
  use Ecto.Schema
  use Ecto.Hosi.Schema          # optional, for hosi_unique
  hosi_unique :email            # hosigraph itself refuses a second row with this email

  schema "user" do              # needs an integer :id (the hosigraph entity id)
    field :name, :string
    field :email, :string
    timestamps(type: :utc_datetime_usec)
  end
end
```

Add the Repo to your supervision tree. Rows are stored as facts (`[1 :"user/name" "Ada"]`); the
hosigraph schema is derived from your Ecto schemas at start-up.

**Works as in Ecto:** `insert` `update` (+`optimistic_lock`) `delete` `insert_all` `get` `get_by` `all` `one`
`exists?` `aggregate(:count)` `preload`, `unique_constraint`. Queries cover one schema: `where`
(`== != < <= > >= in is_nil not and or`), `order_by`, `limit`, `offset`, field `select`. Anything else raises
and points to `Repo.datalog/1`.

**Different:**
* `:map`, `{:array, _}` and `:binary` fields are kept as text (JSON, JSON, Base64): they read back and match with `==` as a whole, but cannot be queried inside.
* No transactions. Use `Repo.write_batch/2` for all-or-nothing writes.
* `not` means "no such fact": `where: not (u.age > 30)` also returns rows with no age.
* No `update_all`, `delete_all`, `stream`. `order_by`/`limit` cut in Elixir; use `Repo.highest/4` for "newest N".

**Added to your Repo:**

```elixir
Repo.history(id)                      # every event of that entity
Repo.highest(Post, :inserted_at, 20)  # newest first -> {structs, last}; next page: after: last
Repo.erase([[:ids, [id]]])            # really delete (account removal)
Repo.write_batch(
  insert: {:user, user_changeset},
  insert: {:post, post_changeset, refs: [user_id: :user]}   # may point at a parent not yet written
)                                     #=> {:ok, %{user: ..., post: ...}} | {:error, name, reason}
```

**Rules (recursive Datalog):**

```elixir
defmodule MyApp.Rules do
  use Ecto.Hosi.Rules
  rule :reachable, [a, b] do match MyApp.Follow, from: a, to: b end
  rule :reachable, [a, c] do
    match MyApp.Follow, from: a, to: b
    reachable(b, c)
  end
end

import Ecto.Hosi.Query
Repo.datalog(datalog find: [b], where: [reachable(^me, b)], rules: MyApp.Rules)  #=> [[2], [3]]
```

Checked at compile time (bound variables, arities, field names, stratification).
Details: [docs/rules-input-contract.md](docs/rules-input-contract.md).

## Config keys

`:dir` (hosigraph directory), `:schemas`, `:open` (extra open options, e.g. Datalevin), `:precheck_unique`
(default `true`), `:hosi` (module that talks to hosigraph, default `Hosi`).

## Testing your app

`config :my_app, MyApp.Repo, hosi: Ecto.Hosi.Fake` runs the Repo in memory with no libhosi or Datalevin.
It is only a stand-in and once accepted things the real engine rejected, so test important paths against
the real one too.

## Development

```sh
HOSI_BUILD=none mix test      # stand-in, 53 tests
HOSI_REAL=1 HOSI_PATH=<hosigraph>/hosigraph-ex HOSI_BUILD=source HOSI_JAR=<datalevin.jar> mix test   # real, 52 tests
```

(`HOSI_DTLV=<dtlv>` instead of `HOSI_JAR`. `HOSI_PATH` swaps the git dependency for your checkout.)
Verified on the real engine: GHC 9.10.3, Datalevin 1.2.10 as a JVM, Ecto 3.14.3. Not verified: macOS,
Ecto 3.12/3.13, large data.
