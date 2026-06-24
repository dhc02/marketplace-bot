defmodule MarketplaceBot.Jobs.DailyScan do
  @moduledoc "Daily pipeline: fetch → dedup → classify/extract → eARC → digest → record."
  use Oban.Worker, queue: :default, max_attempts: 3

  alias MarketplaceBot.{Listings, Receivers, Earc, Runs}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case run([]) do
      {:ok, _summary} -> :ok
      {:error, %{reason: reason}} -> {:discard, reason}
    end
  end

  @doc "Run the pipeline. `opts` lets tests inject source/llm/notifier; prod uses config."
  @spec run(keyword()) :: {:ok, map()} | {:error, map()}
  def run(opts \\ []) do
    started = DateTime.utc_now() |> DateTime.truncate(:second)
    source = opts[:source] || Application.get_env(:marketplace_bot, :source)
    notifier = opts[:notifier] || Application.get_env(:marketplace_bot, :notifier)

    case source.fetch(opts[:source_opts] || []) do
      {:ok, raw} ->
        {:ok, new} = Listings.upsert_new(raw)

        enriched = Enum.map(new, &enrich(&1, opts))
        matches = Enum.filter(enriched, &match?(&1))

        notifier.send_digest(matches, opts)
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        for l <- matches, do: Listings.update_listing(l, %{notified_at: now})

        {:ok, run} =
          Runs.record(%{
            started_at: started,
            finished_at: now,
            fetched: length(raw),
            new: length(new),
            matched: length(matches),
            errors: %{}
          })

        {:ok, %{run_id: run.id, fetched: length(raw), new: length(new), matched: length(matches)}}

      {:error, reason} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        {:ok, run} = Runs.record(%{started_at: started, finished_at: now, fetched: 0, new: 0, matched: 0, errors: %{"fetch" => inspect(reason)}})
        {:error, %{run_id: run.id, reason: reason}}
    end
  end

  defp enrich(listing, opts) do
    case Receivers.classify_extract(listing, opts) do
      :skip ->
        {:ok, l} = Listings.update_listing(listing, %{is_receiver: false})
        l

      {:ok, brand, model} ->
        {:ok, m} = Earc.resolve_with_fallback(brand, model, opts)

        {:ok, l} =
          Listings.update_listing(listing, %{
            is_receiver: true,
            model_id: m.id,
            earc_verdict: m.verdict
          })

        l
    end
  end

  defp match?(l), do: l.is_receiver and l.earc_verdict in ["yes", "unknown"]
end
