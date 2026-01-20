defmodule Membrane.FFmpeg.Transcoder.Filter do
  @moduledoc """
  Internal module. Outputs MPEG-TS as an unparsed remote stream.
  """
  use Membrane.Filter, flow_control_hints?: false
  require Membrane.Logger

  defmodule FFmpegError do
    defexception [:message]

    @impl true
    def exception({:error, error}) do
      %FFmpegError{message: inspect(error)}
    end

    def exception(other) do
      %FFmpegError{message: inspect(other)}
    end
  end

  def_input_pad(:input,
    availability: :always,
    accepted_format: Membrane.RemoteStream
  )

  def_output_pad(:ts,
    flow_control: :auto,
    accepted_format: Membrane.RemoteStream
  )

  def_output_pad(:text,
    flow_control: :auto,
    availability: :on_request,
    accepted_format: Membrane.RemoteStream,
    options: [
      source: [
        spec: {:dvb_teletext, 100..899},
        description: """
        Defines the source of the captions. Currently supported:
        * Teletext: `{:dvb_teletext, page_number}`
        """
      ]
    ]
  )

  @impl true
  def handle_init(_ctx, _opts) do
    {[],
     %{
       ffmpeg: nil,
       closing: false,
       outputs: %{video: [], audio: [], scte: []},
       text_ports: %{}
     }}
  end

  @impl true
  def handle_stream_format(_pad, _stream_format, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_parent_notification({:stream_added, _opts}, ctx, _state)
      when ctx.playback == :playing do
    raise(
      "New pads can be added to #{inspect(__MODULE__)} only before playback transition to :playing"
    )
  end

  def handle_parent_notification({:stream_added, {type, sid}, opts}, _ctx, state) do
    {[], update_in(state, [:outputs, type], fn acc -> acc ++ [{sid, opts}] end)}
  end

  @impl true
  def handle_playing(ctx, state) do
    video_outputs =
      state.outputs.video
      |> Enum.with_index(0)

    video_outputs_no_copy = Enum.reject(video_outputs, fn {{_sid, opts}, _idx} -> opts.copy end)

    audio_outputs =
      state.outputs.audio
      |> Enum.with_index(0)

    scte_outputs =
      state.outputs.scte
      |> Enum.with_index(0)

    filtercomplex =
      if length(video_outputs_no_copy) > 0 do
        video_outputs = video_outputs_no_copy

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

        ~w(-filter_complex #{filtergraph})
      else
        []
      end

    mappings =
      Enum.flat_map(video_outputs, fn {{_sid, opts}, index} ->
        if opts.copy do
          ~w(-map 0:v:0)
        else
          ~w(-map [v#{index}out])
        end
      end) ++
        Enum.flat_map(audio_outputs, fn _ -> ~w(-map 0:a:0) end) ++
        Enum.flat_map(scte_outputs, fn {{_sid, opts}, _index} ->
          if opts[:pid] do
            ~w(-map i:#{opts[:pid]})
          else
            ~w(-map 0:d:0)
          end
        end)

    vcodec =
      Enum.flat_map(video_outputs, fn {{_sid, opts}, index} ->
        if opts.copy do
          ~w(
            -c:v:#{index}
            copy
            -copyinkf:v:#{index}
            )
        else
          # The +cgop flag is required for HLS as it will produce independent GOPs.
          ~w(
            -c:v:#{index}
            libx264
            -flags +cgop
            -preset:v:#{index} #{opts.preset}
            -level:v:#{index} #{opts.level}
            -crf:v:#{index} #{opts.crf}
            -tune:v:#{index} #{opts.tune}
            -profile:v:#{index} #{opts.profile}
            -g:v:#{index} #{opts.gop_size}
            -rc-lookahead:v:#{index} #{opts.gop_size}
            -sc_threshold 0
            -pix_fmt:v:#{index} yuv420p
            -force_key_frames:v:#{index} #{"expr:gte(t,n_forced*#{div(opts.gop_size, opts.fps)})"}
            -bf:v:#{index} #{opts.b_frames}
            -maxrate:v:#{index} #{opts.bitrate}
            -bufsize:v:#{index} #{opts.bitrate * 2}
          )
        end
      end)

    acodec =
      Enum.flat_map(audio_outputs, fn {{_sid, opts}, index} ->
        if opts.copy do
          ~w(
            -c:a:#{index} copy
          )
        else
          case opts.codec do
            :opus ->
              ~w(
                -c:a:#{index} libopus
                -b:a:#{index} #{opts.bitrate}
                -ac:a:#{index} #{opts.channels}
                -ar:a:#{index} #{opts.sample_rate}
                -vbr:a:#{index} on
                -compression_level:a:#{index} 10
                -application:a:#{index} audio
              )

            :aac ->
              ~w(
                -c:a:#{index} libfdk_aac
                -b:a:#{index} #{opts.bitrate}
                -ac:a:#{index} #{opts.channels}
                -ar:a:#{index} #{opts.sample_rate}
              )
          end
        end
      end)

    sid_mapping =
      (state.outputs.video ++ state.outputs.audio ++ state.outputs.scte)
      |> Enum.with_index()
      |> Enum.flat_map(fn {{sid, _}, index} ->
        ~w(-streamid #{index}:#{sid})
      end)

    {text_ports, text_selectors, text_outputs} =
      ctx
      |> text_pads()
      |> Enum.with_index()
      |> Enum.reduce({%{}, [], []}, fn {pad, idx}, {ports_acc, sel_acc, out_acc} ->
        fifo = make_fifo!("text_#{idx}.fifo")

        # TODO
        # erlexec here as well? Ports are leaked this way apparently.
        port = Port.open({:spawn, "cat #{fifo}"}, [:binary])

        Membrane.ResourceGuard.register(ctx.resource_guard, fn ->
          try do
            Port.close(port)
          rescue
            _e -> :ok
          after
            File.rm(fifo)
          end
        end)

        selector =
          case ctx.pads[pad].options.source do
            {:dvb_teletext, page_number} ->
              ~w(-txt_format text -fix_sub_duration -txt_page #{page_number})
          end

        output = ~w(-map 0:s:#{idx}? -f srt #{fifo})

        ports_acc = Map.put(ports_acc, port, %{fifo: fifo, pad: pad})
        {ports_acc, sel_acc ++ selector, out_acc ++ output}
      end)

    pcr_period =
      if video_outputs == [] and audio_outputs != [] do
        ~w(-pcr_period 40)
      else
        []
      end

    muxer =
      ~w(
        -muxpreload 0
        -muxdelay 0
        -mpegts_copyts 1
      ) ++ pcr_period ++
        ~w(
          -f mpegts
          -
        )

    command =
      ~w(#{System.find_executable("ffmpeg")} -y -hide_banner -loglevel warning) ++
        text_selectors ++
        ~w(-i - -copyts) ++
        filtercomplex ++ mappings ++ vcodec ++ acodec ++ sid_mapping ++ muxer ++ text_outputs

    Membrane.Logger.info("ffmpeg[transcoder]: #{Enum.join(command, " ")}")

    {:ok, pid, ospid} =
      :exec.run(
        command,
        [
          :stdin,
          {:stderr,
           fn _, _, payload ->
             payload
             |> String.split("\n")
             |> Enum.map(&String.trim/1)
             |> Enum.filter(fn x -> x != "" end)
             |> Enum.each(fn x -> Membrane.Logger.warning("ffmpeg[transcoder]: #{x}") end)
           end},
          {:stdout, self()},
          :monitor,
          {:kill, "kill -s TERM ${CHILD_PID}"},
          {:kill_timeout, 5}
        ]
      )

    Membrane.Logger.info(
      "ffmpeg[transcoder]: ffmpeg started: pid=#{inspect(pid)}, ospid=#{inspect(ospid)}"
    )

    Membrane.ResourceGuard.register(ctx.resource_guard, fn ->
      Membrane.Logger.info(
        "ffmpeg[transcoder]: resource guard called, closing ffmpeg: pid=#{inspect(pid)}, ospid=#{inspect(ospid)}"
      )

      :exec.stop_and_wait(ospid, 5_000)
    end)

    state = %{state | ffmpeg: %{pid: pid, ospid: ospid}, text_ports: text_ports}

    text_formats =
      ctx
      |> text_pads()
      |> Enum.map(&{:stream_format, {&1, %Membrane.RemoteStream{}}})

    {[{:stream_format, {:ts, %Membrane.RemoteStream{}}} | text_formats], state}
  end

  @impl true
  def handle_buffer(_pad, buffer, _ctx, state = %{ffmpeg: nil}) do
    Membrane.Logger.warning(
      "ffmpeg[transcoder]: dropping #{length(buffer.payload)} bytes as ffmpeg is not running"
    )

    {[], state}
  end

  def handle_buffer(_pad, buffer, _ctx, state) do
    :ok = :exec.send(state.ffmpeg.ospid, buffer.payload)
    {[], state}
  end

  @impl true
  def handle_end_of_stream(_pad, ctx, state = %{ffmpeg: nil}) do
    forward_end_of_stream(ctx, state)
  end

  def handle_end_of_stream(_pad, _ctx, state = %{closing: false}) do
    # Wait for the DOWN message before sending this one out.
    {[], close_ffmpeg(state)}
  end

  @impl true
  def handle_info({:stdout, ospid, payload}, _ctx, state = %{ffmpeg: %{ospid: ospid}}) do
    {[buffer: {:ts, %Membrane.Buffer{payload: payload}}], state}
  end

  def handle_info({port, {:data, payload}}, _ctx, state)
      when is_map_key(state.text_ports, port) do
    pad = state.text_ports[port].pad
    {[buffer: {pad, %Membrane.Buffer{payload: payload}}], state}
  end

  def handle_info(
        {:DOWN, ospid, :process, _pid, reason},
        ctx,
        state = %{ffmpeg: %{ospid: ospid}}
      ) do
    reason =
      case reason do
        :normal ->
          :normal

        {:status, status} ->
          :exec.status(status)

        {:exit_status, code} ->
          {:status, code}
      end

    level = if state.closing or reason == :normal, do: :info, else: :error
    Membrane.Logger.log(level, "ffmpeg[transcoder]: exited with reason: #{inspect(reason)}")

    forward_end_of_stream(ctx, state)
  end

  def handle_info(msg, _ctx, state) do
    Membrane.Logger.debug("Unhandled message received: #{inspect(msg)}")
    {[], state}
  end

  defp text_pads(ctx) do
    ctx.pads
    |> Map.keys()
    |> Enum.filter(&match?(Pad.ref(:text, _), &1))
  end

  defp make_fifo!(name) do
    dir = Path.join([System.tmp_dir!(), "membrane_ffmpeg_transcoder"])
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    _ = File.rm(path)
    {_, 0} = System.cmd("mkfifo", [path])
    path
  end

  defp close_ffmpeg(state) do
    :exec.send(state.ffmpeg.ospid, :eof)
    put_in(state, [:closing], true)
  end

  defp forward_end_of_stream(ctx, state) do
    text_eos =
      ctx
      |> text_pads()
      |> Enum.map(&{:end_of_stream, &1})

    {[{:end_of_stream, :ts} | text_eos], put_in(state, [:ffmpeg], nil)}
  end
end
