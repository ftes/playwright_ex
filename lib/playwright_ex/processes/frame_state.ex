defmodule PlaywrightEx.FrameState do
  @moduledoc false

  defstruct url: "", load_states: MapSet.new(), document_request: nil, document_ref: nil

  @type t :: %__MODULE__{
          url: String.t(),
          document_ref: reference(),
          load_states: MapSet.t(String.t()),
          document_request: %{guid: PlaywrightEx.guid()} | nil
        }

  def new(initializer) do
    %__MODULE__{
      url: initializer[:url] || "",
      document_ref: make_ref(),
      load_states: MapSet.new(List.wrap(initializer[:load_states]), &to_string/1)
    }
  end

  def update(state, :loadstate, params) do
    load_states =
      state.load_states
      |> add(params[:add])
      |> remove(params[:remove])

    %{state | load_states: load_states}
  end

  def update(state, :navigated, params) do
    state = %{state | url: params[:url] || state.url}

    case params do
      %{new_document: document} ->
        %{state | load_states: MapSet.new(["commit"]), document_request: document[:request], document_ref: make_ref()}

      _same_document ->
        state
    end
  end

  def error(:frame_detached), do: {:error, %{message: "Navigating frame was detached!"}}
  def error(:page_closed), do: {:error, %{message: "Navigation failed because page was closed!"}}
  def error(:page_crashed), do: {:error, %{message: "Navigation failed because page crashed!"}}

  defp add(states, nil), do: states
  defp add(states, value), do: MapSet.put(states, to_string(value))
  defp remove(states, nil), do: states
  defp remove(states, value), do: MapSet.delete(states, to_string(value))
end
