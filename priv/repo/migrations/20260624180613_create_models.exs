defmodule MarketplaceBot.Repo.Migrations.CreateModels do
  use Ecto.Migration

  def change do
    create table(:models) do
      add :brand, :string
      add :model, :string
      add :key, :string, null: false
      add :verdict, :string, default: "unknown", null: false
      add :source, :string, default: "seed", null: false
      add :notes, :text
      timestamps(type: :utc_datetime)
    end

    create unique_index(:models, [:key])
  end
end
