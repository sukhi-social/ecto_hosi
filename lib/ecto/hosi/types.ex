defmodule Ecto.Hosi.Types do
  @moduledoc false
  # Ecto types <-> the value types hosigraph keeps (any/string/long/double/boolean/keyword/ref).
  # Times are kept as microseconds since the epoch (a long), so `highest/4` can order them.

  @epoch_date ~D[1970-01-01]
  @epoch_naive ~N[1970-01-01 00:00:00]

  @doc "The hosigraph type for an Ecto type."
  def hosi_type(ecto_type) do
    case Ecto.Type.type(ecto_type) do
      t when t in [:id, :integer] ->
        :long

      :string ->
        :string

      :boolean ->
        :boolean

      :float ->
        :double

      :decimal ->
        :string

      :date ->
        :long

      t when t in [:time, :time_usec] ->
        :string

      t when t in [:naive_datetime, :naive_datetime_usec, :utc_datetime, :utc_datetime_usec] ->
        :long

      other ->
        raise ArgumentError,
              "Ecto.Adapters.Hosi does not support the Ecto type #{inspect(ecto_type)} " <>
                "(primitive #{inspect(other)}) yet"
    end
  end

  ## ---- the Ecto.Adapter loaders/dumpers callbacks

  def dumpers(p, type) when p in [:utc_datetime, :utc_datetime_usec], do: [type, ns(&dump_utc/1)]

  def dumpers(p, type) when p in [:naive_datetime, :naive_datetime_usec],
    do: [type, ns(&dump_naive/1)]

  def dumpers(:date, type), do: [type, ns(&dump_date/1)]
  def dumpers(p, type) when p in [:time, :time_usec], do: [type, ns(&dump_time/1)]
  def dumpers(:decimal, type), do: [type, ns(&dump_decimal/1)]
  def dumpers(_primitive, type), do: [type]

  def loaders(p, type) when p in [:utc_datetime, :utc_datetime_usec], do: [ns(&load_utc/1), type]

  def loaders(p, type) when p in [:naive_datetime, :naive_datetime_usec],
    do: [ns(&load_naive/1), type]

  def loaders(:date, type), do: [ns(&load_date/1), type]
  def loaders(p, type) when p in [:time, :time_usec], do: [ns(&load_time/1), type]
  def loaders(:decimal, type), do: [ns(&load_decimal/1), type]
  def loaders(:float, type), do: [ns(&load_float/1), type]
  def loaders(_primitive, type), do: [type]

  # Ecto hands `nil` ("no such fact") to these functions too; it stays `nil`.
  defp ns(fun),
    do: fn
      nil -> {:ok, nil}
      value -> fun.(value)
    end

  defp dump_utc(%DateTime{} = dt), do: {:ok, DateTime.to_unix(dt, :microsecond)}
  defp dump_utc(_), do: :error

  defp dump_naive(%NaiveDateTime{} = n),
    do: {:ok, NaiveDateTime.diff(n, @epoch_naive, :microsecond)}

  defp dump_naive(_), do: :error
  defp dump_date(%Date{} = d), do: {:ok, Date.diff(d, @epoch_date)}
  defp dump_date(_), do: :error
  defp dump_time(%Time{} = t), do: {:ok, Time.to_iso8601(t)}
  defp dump_time(_), do: :error
  defp dump_decimal(%Decimal{} = d), do: {:ok, Decimal.to_string(d, :normal)}
  defp dump_decimal(_), do: :error

  defp load_utc(n) when is_integer(n), do: {:ok, DateTime.from_unix!(n, :microsecond)}
  defp load_utc(_), do: :error

  defp load_naive(n) when is_integer(n),
    do: {:ok, NaiveDateTime.add(@epoch_naive, n, :microsecond)}

  defp load_naive(_), do: :error
  defp load_date(n) when is_integer(n), do: {:ok, Date.add(@epoch_date, n)}
  defp load_date(_), do: :error
  defp load_time(s) when is_binary(s), do: Time.from_iso8601(s)
  defp load_time(_), do: :error
  defp load_decimal(s) when is_binary(s), do: {:ok, Decimal.new(s)}
  defp load_decimal(_), do: :error
  defp load_float(n) when is_integer(n), do: {:ok, n * 1.0}
  defp load_float(n) when is_float(n), do: {:ok, n}
  defp load_float(_), do: :error
end
