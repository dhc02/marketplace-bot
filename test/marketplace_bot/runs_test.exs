defmodule MarketplaceBot.RunsTest do
  use MarketplaceBot.DataCase, async: false
  alias MarketplaceBot.Runs

  test "record and list_recent" do
    {:ok, run} = Runs.record(%{fetched: 10, new: 3, matched: 1, errors: %{}})
    assert run.fetched == 10
    assert [%{matched: 1}] = Runs.list_recent(5)
  end
end
