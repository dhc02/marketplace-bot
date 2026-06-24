defmodule MarketplaceBot.EarcTest do
  use MarketplaceBot.DataCase, async: false
  alias MarketplaceBot.Earc
  alias MarketplaceBot.Earc.Model

  test "normalize_key is case/space insensitive" do
    assert Earc.normalize_key("Denon", "AVR-X3700H") == Earc.normalize_key("denon", " avr-x3700h ")
  end

  test "normalize_key is hyphen-insensitive" do
    assert Earc.normalize_key("Marantz", "SR-6015") == Earc.normalize_key("Marantz", "SR6015")
  end

  test "upsert_model creates then updates by key" do
    {:ok, m} = Earc.upsert_model("Denon", "AVR-X3700H", %{verdict: "yes", source: "seed"})
    assert %Model{verdict: "yes", source: "seed"} = m
    {:ok, m2} = Earc.upsert_model("denon", "avr-x3700h", %{verdict: "unknown", source: "llm"})
    assert m2.id == m.id
    assert m2.verdict == "unknown"
  end

  test "find_by_key" do
    {:ok, _} = Earc.upsert_model("Yamaha", "RX-V685", %{verdict: "no"})
    assert %Model{verdict: "no"} = Earc.find_by_key(Earc.normalize_key("Yamaha", "RX-V685"))
    assert is_nil(Earc.find_by_key("nope"))
  end

  test "set_user_verdict marks source user" do
    {:ok, m} = Earc.upsert_model("Sony", "STR-DN1080", %{verdict: "unknown", source: "llm"})
    {:ok, m} = Earc.set_user_verdict(m, "yes")
    assert m.verdict == "yes" and m.source == "user"
  end

  defmodule YesLLM do
    @behaviour MarketplaceBot.Earc.LLM.Behaviour
    @impl true
    def lookup(_b, _m, _o \\ []), do: {:ok, "yes"}
  end

  test "resolve_with_fallback returns a table hit without calling the LLM" do
    {:ok, _} = Earc.upsert_model("Denon", "AVR-X3700H", %{verdict: "yes", source: "seed"})
    {:ok, m} = Earc.resolve_with_fallback("Denon", "AVR-X3700H", llm: __MODULE__.YesLLM)
    assert m.verdict == "yes" and m.source == "seed"
  end

  test "resolve_with_fallback calls the LLM on a miss and caches as llm" do
    {:ok, m} = Earc.resolve_with_fallback("Onkyo", "TX-RZ50", llm: __MODULE__.YesLLM)
    assert m.verdict == "yes" and m.source == "llm"
    # Cached: a second call still reads the row (not re-resolved here)
    assert Earc.find_by_key(Earc.normalize_key("Onkyo", "TX-RZ50")).source == "llm"
  end

  test "resolve_with_fallback never overwrites a user verdict" do
    {:ok, m} = Earc.upsert_model("Sony", "STR-DN1080", %{verdict: "no", source: "user"})
    {:ok, m2} = Earc.resolve_with_fallback("Sony", "STR-DN1080", llm: __MODULE__.YesLLM)
    assert m2.id == m.id and m2.verdict == "no" and m2.source == "user"
  end

  test "resolve_with_fallback returns transient unknown for blank brand/model (no crash)" do
    for {b, m} <- [{"", ""}, {nil, nil}, {"  ", nil}] do
      assert {:ok, model} = Earc.resolve_with_fallback(b, m, llm: __MODULE__.YesLLM)
      assert model.verdict == "unknown"
      assert is_nil(model.id)
    end
  end
end
