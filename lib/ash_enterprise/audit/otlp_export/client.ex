defmodule AshEnterprise.Audit.OtlpExport.Client do
  @moduledoc """
  The one place the audit export talks HTTP: an OTLP/HTTP JSON `POST <endpoint>/v1/logs`
  (Iron Law #20, one facade per external service).

  Synchronous and without retries of its own. The caller (`AshEnterprise.Audit.ExportWorker`)
  advances its cursor only on a 2xx, so a failed post is retried by the next run, and a
  failure is a value the caller records rather than an exception.

  A failure's reason is a few words: `"http 503"`, `"transport: econnrefused"`. Never the
  response body, the request, the endpoint or its headers, because the reason is stored
  (`AshEnterprise.Audit.ExportCursor.last_error`) and the headers carry credentials.

  Configured as `config :ash_enterprise, AshEnterprise.Audit.ExportWorker` (see there);
  `:req_options` is merged into the request, which is how tests answer it with a
  `Req.Test` stub.
  """

  @path "/v1/logs"
  @timeout 15_000

  @doc """
  Posts `body` to `endpoint`. `headers` is a list of `{name, value}` pairs, or the W3C
  `name=value,name=value` string `OTEL_EXPORTER_OTLP_HEADERS` holds.
  """
  @spec post_logs(String.t(), map(), keyword()) :: :ok | {:error, String.t()}
  def post_logs(endpoint, body, opts \\ []) do
    [
      url: String.trim_trailing(endpoint, "/") <> @path,
      method: :post,
      json: body,
      headers: headers(Keyword.get(opts, :headers)),
      retry: false,
      receive_timeout: @timeout
    ]
    |> Req.new()
    |> Req.merge(Keyword.get(opts, :req_options, []))
    |> Req.request()
    |> case do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, "http #{status}"}
      {:error, %{reason: reason}} -> {:error, "transport: #{short(reason)}"}
      {:error, error} -> {:error, "transport: #{short(error)}"}
    end
  end

  @doc """
  Parses the W3C `name=value,name=value` header form, percent-decoding each value as the
  OpenTelemetry specification asks. A pair without `=` is ignored.
  """
  @spec headers(nil | String.t() | [{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def headers(nil), do: []
  def headers(list) when is_list(list), do: list

  def headers(string) when is_binary(string) do
    for pair <- String.split(string, ",", trim: true),
        [name, value] <- [String.split(pair, "=", parts: 2)],
        name = String.trim(name),
        name != "",
        do: {String.downcase(name), value |> String.trim() |> URI.decode()}
  end

  defp short(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp short(%{__exception__: true} = error),
    do: error.__struct__ |> inspect() |> String.slice(0, 80)

  defp short(_reason), do: "unknown"
end
