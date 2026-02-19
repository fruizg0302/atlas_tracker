defmodule AtlasTracker.HorizonsClient do
  @base_url "https://ssd.jpl.nasa.gov/api/horizons.api"

  def fetch_state_vectors(object, start_time, stop_time, step_size) do
    params = %{
      "format" => "json",
      "COMMAND" => "'#{object}'",
      "OBJ_DATA" => "YES",
      "MAKE_EPHEM" => "YES",
      "EPHEM_TYPE" => "VECTORS",
      "CENTER" => "'500@10'",
      "START_TIME" => start_time,
      "STOP_TIME" => stop_time,
      "STEP_SIZE" => step_size,
      "VEC_LABELS" => "YES"
    }

    case Req.get(@base_url, params: params) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, exception} ->
        {:error, exception}
    end
  end
end
