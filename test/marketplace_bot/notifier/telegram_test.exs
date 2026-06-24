defmodule MarketplaceBot.Notifier.TelegramTest do
  use ExUnit.Case, async: false
  alias MarketplaceBot.Notifier.Telegram
  alias MarketplaceBot.Listings.Listing

  defp listing(attrs),
    do: struct(Listing, Map.merge(%{id: 1, title: "Denon AVR-X3700H", city: "Victoria",
         price_cents: 45000, currency: "USD", earc_verdict: "yes", url: "https://fb/1"}, attrs))

  test "build_digest includes title, price, city, verdict tag, and web link" do
    text = Telegram.build_digest([listing(%{})], "http://localhost:4010")
    assert text =~ "Denon AVR-X3700H"
    assert text =~ "$450"
    assert text =~ "Victoria"
    assert text =~ "http://localhost:4010/listings/1"
  end

  test "unknown verdict is tagged unconfirmed" do
    text = Telegram.build_digest([listing(%{earc_verdict: "unknown"})], "http://x")
    assert text =~ "unconfirmed"
  end

  test "send_digest is :noop for empty input" do
    assert :noop = Telegram.send_digest([])
  end

  test "send_digest posts to Telegram" do
    Req.Test.stub(MarketplaceBot.Notifier.Telegram, fn conn ->
      Req.Test.json(conn, %{"ok" => true})
    end)

    assert {:ok, _} =
             Telegram.send_digest([listing(%{})],
               token: "t", chat_id: "c",
               req_options: [plug: {Req.Test, MarketplaceBot.Notifier.Telegram}]
             )
  end
end
