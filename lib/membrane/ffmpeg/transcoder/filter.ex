defmodule Membrane.FFmpeg.Transcoder.Filter do
  @moduledoc """
  Internal module. Outputs MPEG-TS as an unparsed remote stream.
  """
  use Membrane.Filter, flow_control_hints?: false
  require Membrane.Logger

  @ffmpeg_stop_timeout 6_000
  @ffmpeg_cleanup_timeout 7_000
  @ffmpeg_cleanup_tag :ffmpeg_process

  # Keep a writer open until FFmpeg exits, including when it never opens its
  # subtitle output. The child inherits that writer until its read-only open
  # completes, so closing stdin cannot race the reader's startup. Closing the
  # writer then lets cat drain to EOF; wait keeps its stdout ahead of DOWN.
  @text_reader_script """
  set -e
  exec 3<>"$1"
  (
    exec 4<"$1"
    exec 3>&-
    exec "$2" <&4
  ) &
  reader=$!
  while IFS= read -r _; do :; done
  exec 3>&-
  wait "$reader"
  """

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
       eos_sent?: false,
       outputs: %{video: [], audio: [], scte: []},
       text_readers: %{}
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

    {text_readers, text_selectors, text_outputs} =
      ctx
      |> text_pads()
      |> Enum.with_index()
      |> Enum.reduce({%{}, [], []}, fn {pad, idx}, {readers_acc, sel_acc, out_acc} ->
        reader = start_text_reader!(ctx.resource_guard, pad)

        selector =
          case ctx.pads[pad].options.source do
            {:dvb_teletext, page_number} ->
              ~w(-txt_format text -fix_sub_duration -txt_page #{page_number})
          end

        output = ["-map", "0:s:#{idx}?", "-f", "srt", reader.fifo]

        readers_acc = Map.put(readers_acc, reader.ospid, reader)
        {readers_acc, sel_acc ++ selector, out_acc ++ output}
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
      ) ++
        pcr_period ++
        ~w(
          -f mpegts
          -
        )

    command =
      [executable!("ffmpeg")] ++
        ~w(-y -hide_banner -loglevel warning) ++
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

    Membrane.ResourceGuard.register(
      ctx.resource_guard,
      fn ->
        Membrane.Logger.info(
          "ffmpeg[transcoder]: resource guard called, closing ffmpeg: pid=#{inspect(pid)}, ospid=#{inspect(ospid)}"
        )

        stop_ffmpeg(pid)
      end,
      timeout: @ffmpeg_cleanup_timeout,
      tag: @ffmpeg_cleanup_tag
    )

    state = %{state | ffmpeg: %{pid: pid, ospid: ospid}, text_readers: text_readers}

    text_formats =
      ctx
      |> text_pads()
      |> Enum.map(&{:stream_format, {&1, %Membrane.RemoteStream{}}})

    {[{:stream_format, {:ts, %Membrane.RemoteStream{}}} | text_formats], state}
  end

  @doc false
  def stop_ffmpeg(pid) do
    # ResourceGuard runs cleanup in a new task. erlexec's original monitor sends
    # DOWN only to the process that started FFmpeg, so the task needs its own.
    monitor = Process.monitor(pid)

    try do
      case :exec.stop_and_wait(pid, @ffmpeg_stop_timeout) do
        {:error, :timeout} -> raise "FFmpeg did not stop within #{@ffmpeg_stop_timeout}ms"
        _exit_status -> :ok
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  @impl true
  def handle_buffer(_pad, buffer, _ctx, state = %{ffmpeg: nil}) do
    Membrane.Logger.warning(
      "ffmpeg[transcoder]: dropping #{byte_size(buffer.payload)} bytes as ffmpeg is not running"
    )

    {[], state}
  end

  def handle_buffer(_pad, buffer, _ctx, state) do
    :ok = :exec.send(state.ffmpeg.ospid, buffer.payload)
    {[], state}
  end

  @impl true
  def handle_end_of_stream(_pad, ctx, state = %{ffmpeg: nil}) do
    maybe_end_of_stream(ctx, %{state | closing: true})
  end

  def handle_end_of_stream(_pad, _ctx, state = %{closing: true}), do: {[], state}

  def handle_end_of_stream(_pad, _ctx, state) do
    # Wait for the DOWN message before sending this one out.
    {[], close_ffmpeg(state)}
  end

  @impl true
  def handle_info({:stdout, ospid, payload}, _ctx, state = %{ffmpeg: %{ospid: ospid}}) do
    {[buffer: {:ts, %Membrane.Buffer{payload: payload}}], state}
  end

  def handle_info({:stdout, ospid, payload}, _ctx, state)
      when is_map_key(state.text_readers, ospid) do
    pad = state.text_readers[ospid].pad
    {[buffer: {pad, %Membrane.Buffer{payload: payload}}], state}
  end

  def handle_info({:stderr, ospid, payload}, _ctx, state)
      when is_map_key(state.text_readers, ospid) do
    Membrane.Logger.warning("ffmpeg[text reader]: #{String.trim(payload)}")
    {[], state}
  end

  def handle_info(
        {:DOWN, ospid, :process, _pid, reason},
        ctx,
        state = %{ffmpeg: %{ospid: ospid}}
      ) do
    reason = normalize_exit_reason(reason)

    level = if state.closing or reason == :normal, do: :info, else: :error
    Membrane.Logger.log(level, "ffmpeg[transcoder]: exited with reason: #{inspect(reason)}")

    Membrane.ResourceGuard.unregister(ctx.resource_guard, @ffmpeg_cleanup_tag)

    Enum.each(state.text_readers, fn {_ospid, reader} ->
      :ok = :exec.send(reader.ospid, :eof)
    end)

    notification =
      {:transcoder_exited, %{reason: reason, input_eos_received?: state.closing}}

    {actions, state} = maybe_end_of_stream(ctx, %{state | ffmpeg: nil})
    {[notify_parent: notification] ++ actions, state}
  end

  def handle_info({:DOWN, ospid, :process, _pid, reason}, ctx, state)
      when is_map_key(state.text_readers, ospid) do
    if state.ffmpeg != nil or normalize_exit_reason(reason) != :normal do
      raise FFmpegError, {:text_reader_exited, normalize_exit_reason(reason)}
    end

    {reader, readers} = Map.pop(state.text_readers, ospid)
    Membrane.ResourceGuard.unregister(ctx.resource_guard, reader.cleanup_tag)
    File.rm_rf!(Path.dirname(reader.fifo))
    maybe_end_of_stream(ctx, %{state | text_readers: readers})
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

  defp start_text_reader!(resource_guard, pad) do
    base = Path.join(System.tmp_dir!(), "membrane_ffmpeg_transcoder")
    File.mkdir_p!(base)
    dir = Path.join(base, "#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir!(dir)
    tag = Membrane.ResourceGuard.register(resource_guard, fn -> File.rm_rf!(dir) end)
    fifo = Path.join(dir, "text.fifo")
    {_, 0} = System.cmd("mkfifo", [fifo], stderr_to_stdout: true)

    {:ok, pid, ospid} =
      :exec.run(
        [executable!("sh"), "-c", @text_reader_script, "text-reader", fifo, executable!("cat")],
        [:stdin, :stdout, :stderr, :monitor, {:group, 0}, :kill_group, {:kill_timeout, 1}]
      )

    Membrane.ResourceGuard.register(resource_guard, fn -> stop_ffmpeg(pid) end,
      tag: tag,
      timeout: @ffmpeg_cleanup_timeout
    )

    %{pid: pid, ospid: ospid, fifo: fifo, pad: pad, cleanup_tag: tag}
  end

  defp executable!(name),
    do: System.find_executable(name) || raise(FFmpegError, "Executable not found: #{name}")

  defp normalize_exit_reason(:normal), do: :normal

  defp normalize_exit_reason({kind, status}) when kind in [:status, :exit_status],
    do: :exec.status(status)

  defp normalize_exit_reason(reason), do: reason

  defp close_ffmpeg(state) do
    :exec.send(state.ffmpeg.ospid, :eof)
    put_in(state, [:closing], true)
  end

  defp maybe_end_of_stream(ctx, %{ffmpeg: nil, text_readers: readers, eos_sent?: false} = state)
       when map_size(readers) == 0 do
    text_eos =
      ctx
      |> text_pads()
      |> Enum.map(&{:end_of_stream, &1})

    {[{:end_of_stream, :ts} | text_eos], %{state | eos_sent?: true}}
  end

  defp maybe_end_of_stream(_ctx, state), do: {[], state}
end
