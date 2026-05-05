defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:operator_notice, nil)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("stop-session", %{"identifier" => issue_identifier}, socket) do
    now = DateTime.utc_now()

    case Presenter.stop_session_payload(issue_identifier, orchestrator()) do
      {:ok, payload} ->
        {:noreply,
         socket
         |> assign(:payload, load_payload())
         |> assign(:now, now)
         |> assign(:operator_notice, %{kind: "success", message: "Stopped session #{payload.issue_identifier || issue_identifier}"})}

      {:error, :issue_not_found} ->
        {:noreply,
         socket
         |> assign(:payload, load_payload())
         |> assign(:now, now)
         |> assign(:operator_notice, %{kind: "error", message: "Session not found for #{issue_identifier}"})}

      {:error, :unavailable} ->
        {:noreply,
         socket
         |> assign(:now, now)
         |> assign(:operator_notice, %{kind: "error", message: "Orchestrator unavailable; session was not stopped"})}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @operator_notice do %>
        <section class={"operator-notice operator-notice-#{@operator_notice.kind}"}>
          <%= @operator_notice.message %>
        </section>
      <% end %>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <%= if tracker_url(entry) do %>
                          <a
                            class="issue-id issue-anchor"
                            href={tracker_url(entry)}
                            target="_blank"
                            rel="noopener noreferrer"
                          >
                            <%= entry.issue_identifier %>
                          </a>
                        <% else %>
                          <span class="issue-id"><%= entry.issue_identifier %></span>
                        <% end %>
                        <span class="issue-links">
                          <%= if tracker_url(entry) do %>
                            <a
                              class="issue-link issue-link-primary"
                              href={tracker_url(entry)}
                              target="_blank"
                              rel="noopener noreferrer"
                            >
                              <%= tracker_link_label(tracker_url(entry)) %>
                            </a>
                          <% end %>
                          <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                        </span>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                          <button
                            type="button"
                            class="subtle-button danger-button"
                            phx-click="stop-session"
                            phx-value-identifier={entry.issue_identifier}
                            onclick="return confirm('Stop this session?');"
                          >
                            Stop
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <%= if tracker_url(entry) do %>
                          <a
                            class="issue-id issue-anchor"
                            href={tracker_url(entry)}
                            target="_blank"
                            rel="noopener noreferrer"
                          >
                            <%= entry.issue_identifier %>
                          </a>
                        <% else %>
                          <span class="issue-id"><%= entry.issue_identifier %></span>
                        <% end %>
                        <span class="issue-links">
                          <%= if tracker_url(entry) do %>
                            <a
                              class="issue-link issue-link-primary"
                              href={tracker_url(entry)}
                              target="_blank"
                              rel="noopener noreferrer"
                            >
                              <%= tracker_link_label(tracker_url(entry)) %>
                            </a>
                          <% end %>
                          <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                        </span>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Past sessions</h2>
              <p class="section-copy">Recent completed, failed, and stopped agent sessions.</p>
            </div>
          </div>

          <%= if @payload.past_sessions == [] do %>
            <p class="empty-state">No past sessions in memory.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 980px;">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 7rem;" />
                  <col style="width: 10rem;" />
                  <col style="width: 8.5rem;" />
                  <col style="width: 12rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Status</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Ended</th>
                    <th>Last update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.past_sessions}>
                    <td>
                      <div class="issue-stack">
                        <%= if tracker_url(entry) do %>
                          <a
                            class="issue-id issue-anchor"
                            href={tracker_url(entry)}
                            target="_blank"
                            rel="noopener noreferrer"
                          >
                            <%= entry.issue_identifier %>
                          </a>
                        <% else %>
                          <span class="issue-id"><%= entry.issue_identifier %></span>
                        <% end %>
                        <span class="issue-links">
                          <%= if tracker_url(entry) do %>
                            <a
                              class="issue-link issue-link-primary"
                              href={tracker_url(entry)}
                              target="_blank"
                              rel="noopener noreferrer"
                            >
                              <%= tracker_link_label(tracker_url(entry)) %>
                            </a>
                          <% end %>
                          <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                        </span>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.status)}>
                        <%= entry.status || "ended" %>
                      </span>
                    </td>
                    <td>
                      <span class="mono numeric"><%= compact_session_id(entry.session_id) %></span>
                    </td>
                    <td class="numeric"><%= format_past_runtime_and_turns(entry.runtime_seconds, entry.turn_count) %></td>
                    <td class="mono numeric"><%= entry.ended_at || "n/a" %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.reason || entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.reason || entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_past_runtime_and_turns(seconds, turn_count) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(seconds)} / #{turn_count}"
  end

  defp format_past_runtime_and_turns(seconds, _turn_count), do: format_runtime_seconds(seconds)

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active", "completed", "success"]) ->
        "#{base} state-badge-active"

      String.contains?(normalized, ["blocked", "error", "failed"]) ->
        "#{base} state-badge-danger"

      String.contains?(normalized, ["todo", "queued", "pending", "retry", "stopped"]) ->
        "#{base} state-badge-warning"

      true ->
        base
    end
  end

  defp compact_session_id(nil), do: "n/a"
  defp compact_session_id(session_id) when not is_binary(session_id), do: "n/a"

  defp compact_session_id(session_id) do
    if String.length(session_id) > 16 do
      String.slice(session_id, 0, 6) <> "..." <> String.slice(session_id, -6, 6)
    else
      session_id
    end
  end

  defp tracker_url(entry) do
    case Map.get(entry, :tracker_url) do
      url when is_binary(url) ->
        trimmed = String.trim(url)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp tracker_link_label(url) when is_binary(url) do
    normalized = String.downcase(url)

    cond do
      String.contains?(normalized, "github.com") and String.contains?(normalized, "/pull/") -> "GitHub PR"
      String.contains?(normalized, "github.com") and String.contains?(normalized, "/issues/") -> "GitHub issue"
      String.contains?(normalized, "linear.app") -> "Linear issue"
      true -> "Tracker"
    end
  end

  defp tracker_link_label(_url), do: "Tracker"

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
