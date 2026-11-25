real? = System.get_env("HOSI_REAL") == "1"

base = [
  dir: System.tmp_dir!() |> Path.join("ecto_hosi_test_dir"),
  schemas: [Ecto.Hosi.Test.User, Ecto.Hosi.Test.Post, Ecto.Hosi.Test.Follow]
]

config =
  if real? do
    # a real hosigraph with a real Datalevin: HOSI_DTLV=/path/to/dtlv HOSI_REAL=1 mix test
    dtlv = System.fetch_env!("HOSI_DTLV")
    base ++ [hosi: Hosi, open: %{config: %{khana: [:dtlv, dtlv]}}]
  else
    base ++ [hosi: Ecto.Hosi.Fake]
  end

Application.put_env(:ecto_hosi, Ecto.Hosi.Test.Repo, config)

# tests that look inside the stand-in only run on it; tests that need hosigraph's (missing) rules input
# can be left out with `--exclude needs_rules_door`
ExUnit.configure(exclude: if(real?, do: [:fake_only], else: []))
ExUnit.start()
