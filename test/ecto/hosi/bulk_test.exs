defmodule Ecto.Hosi.BulkTest do
  use Ecto.Hosi.Case, async: true

  defp user!(attrs) do
    %User{}
    |> User.changeset(Map.merge(%{name: "n", email: "#{System.unique_integer([:positive])}@x"}, attrs))
    |> Repo.insert!()
  end

  describe "update_all" do
    test "set and inc on the rows a where matches, and only those" do
      a = user!(%{name: "Ada", age: 36})
      b = user!(%{name: "Bob", age: 40})
      c = user!(%{name: "Cy", age: 50})

      assert {2, nil} =
               Repo.update_all(from(u in User, where: u.age >= 40),
                 set: [name: "old"],
                 inc: [age: 1]
               )

      assert Repo.get!(User, a.id).name == "Ada"
      assert %{name: "old", age: 41} = Repo.get!(User, b.id)
      assert %{name: "old", age: 51} = Repo.get!(User, c.id)
    end

    test "with ^params, nil (retracts), and another field of the row" do
      a = user!(%{name: "Ada", age: 36})
      new = "Augusta"

      assert {1, nil} = Repo.update_all(from(u in User, where: u.id == ^a.id, update: [set: [name: ^new]]), [])
      assert Repo.get!(User, a.id).name == "Augusta"

      assert {1, nil} = Repo.update_all(from(u in User, where: u.id == ^a.id), set: [age: nil])
      assert Repo.get!(User, a.id).age == nil
      refute Map.has_key?(facts(), {a.id, :"user/age"}) and facts()[{a.id, :"user/age"}] != []

      assert {1, nil} =
               Repo.update_all(from(u in User, where: u.id == ^a.id, update: [set: [email: ^"e@x"]]), [])
    end

    test "dumps times and decimals through the field type" do
      a = user!(%{})
      at = ~U[2020-01-02 03:04:05.000000Z]

      assert {1, nil} =
               Repo.update_all(from(u in User, where: u.id == ^a.id, update: [set: [inserted_at: ^at]]), [])

      assert Repo.get!(User, a.id).inserted_at == at
    end

    test "no match is {0, nil}; the whole table without a where" do
      assert {0, nil} = Repo.update_all(User, set: [name: "x"])
      user!(%{})
      user!(%{})
      assert {2, nil} = Repo.update_all(User, set: [name: "x"])
      assert Repo.all(from(u in User, select: u.name)) == ["x", "x"]
    end
  end

  describe "delete_all" do
    test "removes the matching rows completely" do
      a = user!(%{age: 1})
      b = user!(%{age: 2})
      p = Repo.insert!(%Post{title: "t", user_id: b.id})

      assert {1, nil} = Repo.delete_all(from(u in User, where: u.age == 1))
      assert Repo.get(User, a.id) == nil
      assert Repo.get(User, b.id)
      assert Repo.get(Post, p.id)
      assert Enum.all?(facts(), fn {{id, _}, _} -> id != a.id end)
    end

    test "the whole table, and none" do
      assert {0, nil} = Repo.delete_all(User)
      user!(%{})
      user!(%{})
      assert {2, nil} = Repo.delete_all(User)
      assert Repo.all(User) == []
    end
  end
end
