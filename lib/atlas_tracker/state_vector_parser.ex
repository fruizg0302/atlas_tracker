defmodule AtlasTracker.StateVectorParser do
  @moduledoc """
  Parses JPL Horizons state vector response text into position maps.

  The response contains ephemeris data delimited by `$$SOE` and `$$EOE` markers.
  Position values (X, Y, Z) are given in km and converted to AU.
  """

  @km_per_au 1.496e8

  @doc """
  Parses a JPL Horizons result text and extracts positions in AU.

  Returns `{:ok, positions}` where each position is a map with `:x`, `:y`, `:z` keys,
  or `{:error, :no_ephemeris_data}` if the SOE/EOE markers are not found.
  """
  def parse(result_text) do
    case extract_ephemeris_block(result_text) do
      {:ok, block} ->
        positions = parse_positions(block)
        {:ok, positions}

      :error ->
        {:error, :no_ephemeris_data}
    end
  end

  defp extract_ephemeris_block(text) do
    case String.split(text, "$$SOE") do
      [_, rest] ->
        case String.split(rest, "$$EOE") do
          [block, _] -> {:ok, String.trim(block)}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_positions(""), do: []

  defp parse_positions(block) do
    # Split block into per-epoch chunks by matching Julian Date lines
    # Each chunk starts with a JD line like "2460949.500000000 = A.D. ..."
    block
    |> String.split(~r/(?=\d{7}\.\d+\s*=\s*A\.D\.)/)
    |> Enum.flat_map(&extract_xyz/1)
  end

  defp extract_xyz(chunk) do
    x_regex = ~r/(?<!\w)X\s*=\s*([^\s]+)/
    y_regex = ~r/(?<!\w)Y\s*=\s*([^\s]+)/
    z_regex = ~r/(?<!\w)Z\s*=\s*([^\s]+)/
    date_regex = ~r/A\.D\.\s+(\d{4})-([A-Za-z]+)-(\d{2})/

    with [_, x_str] <- Regex.run(x_regex, chunk),
         [_, y_str] <- Regex.run(y_regex, chunk),
         [_, z_str] <- Regex.run(z_regex, chunk),
         {x, _} <- Float.parse(x_str),
         {y, _} <- Float.parse(y_str),
         {z, _} <- Float.parse(z_str) do
      date = extract_date(chunk, date_regex)

      [
        %{x: x / @km_per_au, y: y / @km_per_au, z: z / @km_per_au}
        |> maybe_put_date(date)
      ]
    else
      _ -> []
    end
  end

  defp extract_date(chunk, regex) do
    case Regex.run(regex, chunk) do
      [_, year, month_str, day] ->
        month = month_to_number(month_str)
        "#{year}-#{String.pad_leading(to_string(month), 2, "0")}-#{day}"

      _ ->
        nil
    end
  end

  defp maybe_put_date(map, nil), do: map
  defp maybe_put_date(map, date), do: Map.put(map, :date, date)

  @months %{
    "Jan" => 1, "Feb" => 2, "Mar" => 3, "Apr" => 4,
    "May" => 5, "Jun" => 6, "Jul" => 7, "Aug" => 8,
    "Sep" => 9, "Oct" => 10, "Nov" => 11, "Dec" => 12
  }

  defp month_to_number(str), do: Map.get(@months, str, 1)
end
