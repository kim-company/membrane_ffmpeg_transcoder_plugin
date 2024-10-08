defmodule Membrane.FFmpeg.Transcoder.Filter do
  @moduledoc """
  Internal module. Outputs MPEG-TS as an unparsed remote stream.
  """
  use Membrane.Filter

  defmodule FFmpegError do
    defexception [:message]

    @impl true
    def exception(value) do
      %FFmpegError{message: "FFmpeg error: #{inspect(value)}"}
    end
  end

  def_input_pad(:input,
    accepted_format:
      %Membrane.RemoteStream{content_format: content_format}
      when content_format in [nil, Membrane.FLV]
  )

  def_output_pad(:output,
    flow_control: :auto,
    accepted_format: Membrane.RemoteStream
  )

  @impl true
  def handle_init(_ctx, _opts) do
    {:ok, pid} = Task.Supervisor.start_link()
    {[], %{ffmpeg: nil, read_ref: nil, outputs: %{video: [], audio: []}, task_supervisor: pid}}
  end

  @impl true
  def handle_stream_format(_pad, _stream_format, _ctx, state) do
    {[forward: %Membrane.RemoteStream{}], state}
  end

  @impl true
  def handle_parent_notification({:stream_added, _opts}, ctx, _state)
      when ctx.playback == :playing,
      do:
        raise(
          "New pads can be added to #{inspect(__MODULE__)} only before playback transition to :playing"
        )

  def handle_parent_notification({:stream_added, {type, sid}, opts}, _ctx, state) do
    {[], update_in(state, [:outputs, type], fn acc -> acc ++ [{sid, opts}] end)}
  end

  @impl true
  def handle_playing(_ctx, state) do
    video_outputs =
      state.outputs.video
      |> Enum.with_index(0)

    audio_outputs =
      state.outputs.audio
      |> Enum.with_index(0)

    filtergraph =
      [
        "[0:v]split=#{length(video_outputs)}#{Enum.map(video_outputs, fn {_output, index} -> "[v#{index}]" end)}",
        Enum.map(video_outputs, fn {{_sid, opts}, index} ->
          {w, h} = opts.resolution

          "[v#{index}]scale=#{w}:#{h},fps=#{opts.fps}[v#{index}out]"
        end)
      ]
      |> List.flatten()
      |> Enum.join(";")

    mappings =
      Enum.flat_map(video_outputs, fn {_opts, index} -> ~w(-map [v#{index}out]) end) ++
        Enum.flat_map(audio_outputs, fn _ -> ~w(-map 0:a) end)

    vcodec =
      Enum.flat_map(video_outputs, fn {{_sid, opts}, index} ->
        ~w(
            -c:v:#{index}
            libx264
            -preset:v:#{index} #{opts.preset}
            -crf:v:#{index} #{opts.crf}
            -tune:v:#{index} #{opts.tune}
            -profile:v:#{index} #{opts.profile}
            -g:v:#{index} #{opts.gop_size}
            -rc-lookahead:v:#{index} #{opts.gop_size}
            -sc_threshold 0
            -force_key_frames:v:#{index} #{"expr:gte(t,n_forced*#{div(opts.gop_size, opts.fps)})"}
            -bf:v:#{index} #{opts.b_frames}
            -maxrate:v:#{index} #{opts.bitrate}
            -bufsize:v:#{index} #{opts.bitrate * 2}
          )
      end)

    acodec =
      Enum.flat_map(audio_outputs, fn {{_sid, opts}, index} ->
        ~w(
        -c:a:#{index} aac -b:a:#{index} #{opts.bitrate} -ar:a:#{index} #{opts.sample_rate} \
      )
      end)

    sid_mapping =
      (state.outputs.video ++ state.outputs.audio)
      |> Enum.with_index()
      |> Enum.flat_map(fn {{sid, _}, index} ->
        ~w(-streamid #{index}:#{sid})
      end)

    muxer = ~w(
            -muxpreload 0
            -muxdelay 0
            -output_ts_offset 0
            -f mpegts
            -
    )

    command = ~w(
          ffmpeg -y -hide_banner
          -loglevel error
          -i -
          -filter_complex #{filtergraph}
        ) ++ mappings ++ vcodec ++ acodec ++ sid_mapping ++ muxer

    Membrane.Logger.debug("FFmpeg: #{Enum.join(command, " ")}")
    {:ok, ffmpeg} = Exile.Process.start_link(command)

    parent = self()

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        :ok = Exile.Process.change_pipe_owner(ffmpeg, :stdout, self())
        read_loop(ffmpeg, parent)
      end)

    {[], %{state | ffmpeg: ffmpeg, read_ref: task.ref}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    :ok = Exile.Process.write(state.ffmpeg, buffer.payload)
    {[], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    # We're not the owners of stdout, so ffmpeg will have its
    # chance to deliver all its data anyway.
    {:ok, 0} = Exile.Process.await_exit(state.ffmpeg, 30_000)
    {[], state}
  end

  @impl true
  def handle_info({:exile, {:data, payload}}, _ctx, state) do
    {[buffer: {:output, %Membrane.Buffer{payload: payload}}], state}
  end

  def handle_info({ref, :eof}, _ctx, state = %{read_ref: ref}) do
    # Avoid receiving the DOWN message.
    Process.demonitor(ref, [:flush])
    {[end_of_stream: :output], state}
  end

  def handle_info({ref, {:error, any}}, _ctx, %{read_ref: ref}) do
    raise FFmpegError, any
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{read_ref: ref}) do
    raise FFmpegError, reason
  end

  defp read_loop(p, parent) do
    case Exile.Process.read(p) do
      {:ok, data} ->
        send(parent, {:exile, {:data, data}})
        read_loop(p, parent)

      :eof ->
        :eof

      {:error, any} ->
        {:error, any}
    end
  end
end
