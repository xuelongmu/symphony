defmodule SymphonyElixir.Multi.DashboardPlug do
  @moduledoc """
  Small dashboard hub for switching between child Symphony dashboards.
  """

  import Plug.Conn

  alias SymphonyElixir.Multi.Launcher

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{method: "GET", path_info: []} = conn, opts) do
    payload = payload(opts)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, render_html(payload))
  end

  def call(%Plug.Conn{method: "GET", path_info: ["api", "v1", "state"]} = conn, opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(payload(opts)))
  end

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: %{code: "not_found", message: "Route not found"}}))
  end

  @spec payload(keyword()) :: map()
  def payload(opts) do
    launcher = Keyword.fetch!(opts, :launcher)
    status_fun = Keyword.get(opts, :status_fun, &Launcher.status/1)
    fetch_child_state? = Keyword.get(opts, :fetch_child_state?, true)
    request_fun = Keyword.get(opts, :request_fun, &Req.get/2)

    workflows =
      launcher
      |> status_fun.()
      |> workflow_payloads(fetch_child_state?, request_fun, opts)

    %{
      generated_at: now_iso8601(),
      counts: %{
        workflows: length(workflows),
        running: Enum.count(workflows, &(&1.status == "running")),
        exited: Enum.count(workflows, &(&1.status == "exited"))
      },
      workflows: workflows
    }
  end

  defp workflow_payloads(statuses, false, request_fun, _opts) do
    Enum.map(statuses, &workflow_payload(&1, false, request_fun))
  end

  defp workflow_payloads(statuses, true, request_fun, opts) do
    max_concurrency = Keyword.get(opts, :child_state_max_concurrency, 8)
    timeout = Keyword.get(opts, :child_state_timeout, 1_000)

    statuses
    |> Task.async_stream(&workflow_payload(&1, true, request_fun),
      max_concurrency: max_concurrency,
      on_timeout: :kill_task,
      timeout: timeout
    )
    |> Enum.zip(statuses)
    |> Enum.map(fn
      {{:ok, payload}, _status} ->
        payload

      {{:exit, reason}, status} ->
        Map.put(status, :child_state, %{available: false, error: inspect(reason)})
    end)
  end

  defp workflow_payload(status, false, _request_fun), do: Map.put(status, :child_state, nil)

  defp workflow_payload(status, true, request_fun) do
    Map.put(status, :child_state, fetch_child_state(status.dashboard_url, request_fun))
  end

  defp fetch_child_state(nil, _request_fun), do: nil

  defp fetch_child_state(dashboard_url, request_fun) do
    url = String.trim_trailing(dashboard_url, "/") <> "/api/v1/state"

    case request_fun.(url, receive_timeout: 750, retry: false) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        %{
          available: true,
          counts: map_get(body, "counts"),
          generated_at: map_get(body, "generated_at")
        }

      {:ok, %{status: status}} ->
        %{available: false, error: "HTTP #{status}"}

      {:error, reason} ->
        %{available: false, error: inspect(reason)}
    end
  end

  defp render_html(payload) do
    workflow_cards =
      payload.workflows
      |> Enum.map_join("\n", &render_workflow_card/1)

    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Cacophany</title>
        <style>
          :root {
            color-scheme: light;
            font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            background: #f6f8fb;
            color: #172033;
          }
          body { margin: 0; }
          main { max-width: 1120px; margin: 0 auto; padding: 40px 24px 56px; }
          header { display: flex; justify-content: space-between; gap: 24px; align-items: end; margin-bottom: 28px; }
          h1 { margin: 0; font-size: 32px; line-height: 1.15; font-weight: 720; }
          p { margin: 0; color: #566174; }
          .summary { display: flex; gap: 12px; flex-wrap: wrap; justify-content: flex-end; }
          .pill { border: 1px solid #d8dee9; background: #fff; border-radius: 999px; padding: 8px 12px; font-size: 13px; color: #2d3748; }
          .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 16px; }
          .card { background: #fff; border: 1px solid #d8dee9; border-radius: 8px; padding: 18px; box-shadow: 0 10px 30px rgba(23, 32, 51, 0.06); }
          .card-head { display: flex; justify-content: space-between; gap: 16px; align-items: start; margin-bottom: 14px; }
          .name { font-size: 18px; font-weight: 700; color: #172033; overflow-wrap: anywhere; }
          .status { border-radius: 999px; padding: 4px 9px; font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: 0; }
          .running { background: #e7f8ee; color: #166534; }
          .exited { background: #fff3df; color: #9a4d00; }
          .meta { display: grid; gap: 8px; margin: 12px 0 16px; font-size: 13px; }
          .label { color: #687589; }
          .value { color: #172033; overflow-wrap: anywhere; }
          .actions { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; }
          a.button { color: #fff; background: #1f6feb; border-radius: 6px; padding: 9px 12px; text-decoration: none; font-weight: 700; font-size: 14px; }
          a.link { color: #1f6feb; text-decoration: none; font-size: 13px; }
          .counts { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 12px; }
          .count { background: #f2f5f9; border-radius: 6px; padding: 7px 9px; font-size: 12px; color: #2d3748; }
          @media (max-width: 720px) {
            header { display: grid; align-items: start; }
            .summary { justify-content: flex-start; }
          }
        </style>
      </head>
      <body>
        <main>
          <header>
            <div>
              <h1>Cacophany</h1>
              <p>Switch between independent repo dashboards started by the cacophany launcher.</p>
            </div>
            <div class="summary">
              <span class="pill">#{payload.counts.workflows} workflows</span>
              <span class="pill">#{payload.counts.running} running</span>
              <span class="pill">#{payload.counts.exited} exited</span>
            </div>
          </header>
          <section class="grid">
            #{workflow_cards}
          </section>
        </main>
      </body>
    </html>
    """
  end

  defp render_workflow_card(workflow) do
    status_class = if workflow.status == "running", do: "running", else: "exited"
    child_counts = render_child_counts(workflow.child_state)
    dashboard_link = dashboard_link(workflow.dashboard_url)

    """
    <article class="card">
      <div class="card-head">
        <div class="name">#{html_escape(workflow.name)}</div>
        <span class="status #{status_class}">#{html_escape(workflow.status)}</span>
      </div>
      <div class="meta">
        <div><span class="label">Workflow:</span> <span class="value">#{html_escape(workflow.workflow)}</span></div>
        <div><span class="label">Logs:</span> <span class="value">#{html_escape(workflow.logs_root || "default")}</span></div>
        <div><span class="label">Started:</span> <span class="value">#{html_escape(workflow.started_at || "n/a")}</span></div>
      </div>
      #{child_counts}
      <div class="actions">
        #{dashboard_link}
        <a class="link" href="/api/v1/state">Hub JSON</a>
      </div>
    </article>
    """
  end

  defp render_child_counts(nil), do: ""

  defp render_child_counts(%{available: true, counts: counts}) when is_map(counts) do
    running = map_get(counts, "running") || 0
    retrying = map_get(counts, "retrying") || 0
    past_sessions = map_get(counts, "past_sessions") || 0

    """
    <div class="counts">
      <span class="count">Running #{html_escape(to_string(running))}</span>
      <span class="count">Retrying #{html_escape(to_string(retrying))}</span>
      <span class="count">Past #{html_escape(to_string(past_sessions))}</span>
    </div>
    """
  end

  defp render_child_counts(%{available: false, error: error}) do
    """
    <div class="counts">
      <span class="count">Dashboard unavailable: #{html_escape(error)}</span>
    </div>
    """
  end

  defp render_child_counts(_child_state), do: ""

  defp dashboard_link(nil), do: ~s(<span class="label">No dashboard port configured</span>)

  defp dashboard_link(url) do
    ~s(<a class="button" href="#{html_escape(url)}">Open dashboard</a>)
  end

  defp map_get(map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp html_escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
