defmodule MarketplaceBot.KagiTest do
  use ExUnit.Case, async: false
  alias MarketplaceBot.Kagi

  defp stub_capturing_path do
    Req.Test.stub(MarketplaceBot.Kagi, fn conn ->
      send(self(), {:kagi_path, conn.request_path})
      Req.Test.json(conn, %{"data" => %{"output" => "answer", "references" => []}})
    end)
  end

  test "defaults to the v0 FastGPT endpoint" do
    stub_capturing_path()

    assert {:ok, %{answer: "answer"}} =
             Kagi.fastgpt("does X support eARC?",
               req_options: [plug: {Req.Test, MarketplaceBot.Kagi}]
             )

    assert_received {:kagi_path, "/api/v0/fastgpt"}
  end

  test "KAGI_FASTGPT_URL env overrides the endpoint (zero-code v1 cutover)" do
    System.put_env("KAGI_FASTGPT_URL", "https://kagi.com/api/v1/fastgpt")
    on_exit(fn -> System.delete_env("KAGI_FASTGPT_URL") end)
    stub_capturing_path()

    assert {:ok, _} =
             Kagi.fastgpt("q", req_options: [plug: {Req.Test, MarketplaceBot.Kagi}])

    assert_received {:kagi_path, "/api/v1/fastgpt"}
  end
end
