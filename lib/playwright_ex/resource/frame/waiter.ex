defmodule PlaywrightEx.Resource.Frame.Waiter do
  @moduledoc false

  @type url_matcher :: (String.t() -> boolean())
  @type waiter ::
          {:load_state, String.t()}
          | {:url, url_matcher(), String.t(), :waiting_for_url | :waiting_for_load_state}

  @spec new_load_state_waiter(String.t()) :: waiter()
  def new_load_state_waiter(wait_state), do: {:load_state, wait_state}

  @spec new_url_waiter(url_matcher(), String.t()) :: waiter()
  def new_url_waiter(url_matcher, wait_state) do
    {:url, url_matcher, wait_state, :waiting_for_url}
  end

  @spec normalize_load_states(list(String.t() | atom())) :: MapSet.t(String.t())
  def normalize_load_states(load_states) do
    load_states
    |> List.wrap()
    |> MapSet.new(&normalize_wait_state/1)
  end

  @spec update_load_states(MapSet.t(String.t()), map()) :: MapSet.t(String.t())
  def update_load_states(load_states, params) do
    load_states
    |> maybe_add_load_state(params[:add])
    |> maybe_remove_load_state(params[:remove])
  end

  @spec evaluate(waiter(), %{url: String.t(), load_states: MapSet.t(String.t())}) ::
          {:done, {:ok, nil}} | {:update, waiter()} | {:error, {:error, %{message: String.t()}}}
  def evaluate({:load_state, wait_state} = waiter, frame_state) do
    if load_state_reached?(frame_state.load_states, wait_state) do
      {:done, {:ok, nil}}
    else
      {:update, waiter}
    end
  end

  def evaluate({:url, url_matcher, wait_state, :waiting_for_url} = waiter, frame_state) do
    case match_url(url_matcher, frame_state.url) do
      {:ok, true} ->
        evaluate({:url, url_matcher, wait_state, :waiting_for_load_state}, frame_state)

      {:ok, false} ->
        {:update, waiter}

      {:error, reason} ->
        {:error, {:error, %{message: reason}}}
    end
  end

  def evaluate({:url, _url_matcher, wait_state, :waiting_for_load_state} = waiter, frame_state) do
    if load_state_reached?(frame_state.load_states, wait_state) do
      {:done, {:ok, nil}}
    else
      {:update, waiter}
    end
  end

  defp match_url(url_matcher, url) do
    {:ok, url_matcher.(url)}
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason ->
      {:error, Exception.format(kind, reason, __STACKTRACE__)}
  end

  defp load_state_reached?(_load_states, "commit"), do: true
  defp load_state_reached?(load_states, wait_state), do: MapSet.member?(load_states, wait_state)

  defp maybe_add_load_state(load_states, nil), do: load_states

  defp maybe_add_load_state(load_states, value) do
    MapSet.put(load_states, normalize_wait_state(value))
  end

  defp maybe_remove_load_state(load_states, nil), do: load_states

  defp maybe_remove_load_state(load_states, value) do
    MapSet.delete(load_states, normalize_wait_state(value))
  end

  defp normalize_wait_state(state) when is_atom(state), do: normalize_wait_state(Atom.to_string(state))
  defp normalize_wait_state(state), do: state
end
