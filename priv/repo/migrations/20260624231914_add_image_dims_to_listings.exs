defmodule MarketplaceBot.Repo.Migrations.AddImageDimsToListings do
  use Ecto.Migration

  def change do
    alter table(:listings) do
      add :image_dims, :map
    end
  end
end
