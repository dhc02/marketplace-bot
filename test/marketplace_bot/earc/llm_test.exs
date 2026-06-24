defmodule MarketplaceBot.Earc.LLMTest do
  use ExUnit.Case, async: false
  alias MarketplaceBot.Earc.LLM

  test "researches via Kagi then derives a verdict via DeepSeek" do
    # Both clients route through the same plug; branch on the request path.
    Req.Test.stub(MarketplaceBot.Earc.LLM, fn conn ->
      cond do
        String.contains?(conn.request_path, "fastgpt") ->
          Req.Test.json(conn, %{
            "data" => %{
              "output" => "The Denon AVR-X3700H supports HDMI eARC per the spec sheet.",
              "references" => []
            }
          })

        String.contains?(conn.request_path, "chat/completions") ->
          Req.Test.json(conn, %{
            "choices" => [%{"message" => %{"content" => ~s({"verdict": "yes"})}}]
          })
      end
    end)

    assert {:ok, "yes"} =
             LLM.lookup("Denon", "AVR-X3700H",
               req_options: [plug: {Req.Test, MarketplaceBot.Earc.LLM}]
             )
  end
end
