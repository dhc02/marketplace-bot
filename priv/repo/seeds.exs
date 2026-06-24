# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     MarketplaceBot.Repo.insert!(%MarketplaceBot.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

for {brand, model, verdict} <- Code.eval_file("priv/repo/seeds/earc_seed.exs") |> elem(0) do
  {:ok, _} = MarketplaceBot.Earc.upsert_model(brand, model, %{verdict: verdict, source: "seed"})
end
