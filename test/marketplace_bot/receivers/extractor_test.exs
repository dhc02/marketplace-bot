defmodule MarketplaceBot.Receivers.ExtractorTest do
  use ExUnit.Case, async: true
  alias MarketplaceBot.Receivers.Extractor

  test "negative keywords flag obvious non-AV listings" do
    assert Extractor.likely_non_av?("Trailer hitch receiver 2 inch")
    assert Extractor.likely_non_av?("DirecTV satellite receiver")
    refute Extractor.likely_non_av?("Denon AVR-X3700H home theater receiver")
  end

  test "regex extracts known brand/model patterns" do
    assert {:ok, "Denon", "AVR-X3700H"} = Extractor.extract("Denon AVR-X3700H 9.2 receiver")
    assert {:ok, "Yamaha", "RX-V685"} = Extractor.extract("Yamaha RX-V685 like new")
    assert {:ok, "Onkyo", "TX-NR696"} = Extractor.extract("ONKYO tx-nr696 atmos")
    assert {:ok, "Marantz", "SR-6015"} = Extractor.extract("Marantz SR6015")
    assert {:ok, "Pioneer", "VSX-1131"} = Extractor.extract("Pioneer VSX-1131")
  end

  test "extract returns :unknown when no pattern matches" do
    assert :unknown = Extractor.extract("vintage stereo receiver, works great")
  end
end
