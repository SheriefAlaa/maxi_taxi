defmodule MaxiTaxi.TaxiLocationsDatabase do
  use GenServer

  @table __MODULE__

  def child_spec(arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil)
  end

  def init(_) do
    :ets.new(
      @table,
      [:public, :named_table, {:write_concurrency, true}, {:read_concurrency, true}]
    )

    set_neighbours()
    :net_kernel.monitor_nodes(true)

    {:ok, nil}
  end

  defp set_neighbours() do
    neighbours =
      (Node.list() -- [:"manager@127.0.0.1"])
      |> Enum.map(fn node -> {MaxiTaxi.TaxiLocationsCrdt, node} end)

    DeltaCrdt.set_neighbours(MaxiTaxi.TaxiLocationsCrdt, neighbours)
  end

  def handle_info({node_change, _node}, state) when node_change in [:nodeup, :nodedown] do
    # exclude the central test node (manager@127.0.0.1)
    set_neighbours()
    {:noreply, state}
  end

  @type taxi :: String.t()
  @type lat :: float()
  @type lon :: float()
  @type location :: {lat(), lon()}

  @spec update(taxi(), location()) :: :ok
  def update(taxi, location) do
    :ok =
      DeltaCrdt.mutate(MaxiTaxi.TaxiLocationsCrdt, :add, [
        taxi,
        {location, DateTime.utc_now() |> DateTime.to_unix()}
      ])

    # :rpc.multicall(:ets, :insert, [
    #   @table,
    #   {taxi, location, DateTime.utc_now() |> DateTime.to_unix()}
    # ])

    # :ets.insert(@table, {taxi, location})
    :ok
  end

  def on_diffs(diffs) do
    Enum.each(diffs, fn
      {:add, taxi, {location, updated_at}} ->
        :ets.insert(@table, {taxi, location, updated_at})

      {:remove, taxi} ->
        :ets.delete(@table, taxi)
    end)
  end

  @spec fetch(taxi()) :: {:ok, location()} | :no_known_location
  def fetch(taxi) do
    case :ets.lookup(@table, taxi) do
      [] -> :no_known_location
      [{^taxi, location, _updated_at}] -> {:ok, location}
    end
  end

  def all() do
    :ets.tab2list(@table)
  end

  @spec find(location()) :: {:ok, taxi()} | :no_taxi_found
  def find({search_lat, search_lon}) do
    # just using euclidean distance here because it's simple. This works at the equator but will work less well the nearer one gets to the poles.
    # filter for all taxis within 0.01 degree (approx 1.1km at the equator) and then sort on distance

    updated_since =
      DateTime.utc_now()
      |> DateTime.add(-2, :second)
      |> DateTime.to_unix()

    match_spec = [
      {
        {:"$1", {:"$2", :"$3"}, :"$4"},
        [
          {:is_float, :"$2"},
          {:is_float, :"$3"},
          {:is_integer, :"$4"},
          {:>, :"$2", search_lat - 0.01},
          {:<, :"$2", search_lat + 0.01},
          {:>, :"$3", search_lon - 0.01},
          {:<, :"$3", search_lon + 0.01},
          {:>, :"$4", updated_since}
        ],
        [:"$_"]
      }
    ]

    case :ets.select(@table, match_spec) do
      [] ->
        :no_taxi_found

      locations ->
        {taxi, _coords, _updated_at} =
          Enum.sort_by(locations, fn {_taxi, {lat, lon}, _updated_at} ->
            (:math.pow(lat - search_lat, 2) + :math.pow(lon - search_lon, 2))
            |> :math.sqrt()
          end)
          |> hd()

        {:ok, taxi}
    end
  end

  def clear() do
    # :ok = DeltaCrdt.mutate(MaxiTaxi.TaxiLocationsCrdt, :clear, [])
    # :rpc.multicall(:ets, :delete_all_objects, [@table])
    # :ets.delete_all_objects(@table)
  end
end
