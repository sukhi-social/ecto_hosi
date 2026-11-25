defmodule Ecto.Hosi.Schema do
  @moduledoc """
  Optional helper for Ecto schemas stored in hosigraph.

      defmodule MyApp.User do
        use Ecto.Schema
        use Ecto.Hosi.Schema

        hosi_unique :email       # hosigraph refuses a second user with this email

        schema "user" do
          field :email, :string
        end
      end

  Without `hosi_unique` the schema works the same, just with no uniqueness in the store.
  `build/1` turns a list of schemas into the `schema:` map hosigraph is opened with.
  """

  alias Ecto.Hosi.{Attr, Types}

  defmacro __using__(_opts) do
    quote do
      import Ecto.Hosi.Schema, only: [hosi_unique: 1]
      Module.register_attribute(__MODULE__, :hosi_unique, accumulate: true)
      @before_compile Ecto.Hosi.Schema
    end
  end

  @doc "Declare fields (an atom or a list of atoms) whose values hosigraph keeps unique."
  defmacro hosi_unique(fields) do
    quote do
      Module.put_attribute(__MODULE__, :hosi_unique, List.wrap(unquote(fields)))
    end
  end

  defmacro __before_compile__(env) do
    uniques = env.module |> Module.get_attribute(:hosi_unique) |> List.flatten() |> Enum.uniq()

    quote do
      @doc false
      def __hosi__(:unique), do: unquote(uniques)
    end
  end

  @doc """
  The hosigraph schema for these Ecto schemas: `%{attr => %{type: .., unique: ..}}`.

  `belongs_to` foreign keys become `:ref` attributes; the primary key is the entity id and has no attribute.
  """
  def build(schemas) do
    Enum.reduce(schemas, %{}, fn mod, acc -> Map.merge(acc, build_one(mod)) end)
  end

  defp build_one(mod) do
    Code.ensure_compiled!(mod)
    source = mod.__schema__(:source)

    unless mod.__schema__(:primary_key) == [:id] and mod.__schema__(:type, :id) == :id do
      raise ArgumentError,
            "#{inspect(mod)}: Ecto.Adapters.Hosi needs an integer primary key named :id " <>
              "(it is the hosigraph entity id)"
    end

    fks =
      for name <- mod.__schema__(:associations),
          %Ecto.Association.BelongsTo{owner_key: key} <- [mod.__schema__(:association, name)],
          do: key

    uniques = if function_exported?(mod, :__hosi__, 1), do: mod.__hosi__(:unique), else: []

    fields =
      for field <- mod.__schema__(:fields), field != :id, into: %{} do
        type = if field in fks, do: :ref, else: Types.hosi_type(mod.__schema__(:type, field))
        spec = %{type: type}
        spec = if field in uniques, do: Map.put(spec, :unique, :value), else: spec
        {Attr.attr(source, field), spec}
      end

    Map.put(fields, Attr.marker(source), %{type: :boolean})
  end
end
