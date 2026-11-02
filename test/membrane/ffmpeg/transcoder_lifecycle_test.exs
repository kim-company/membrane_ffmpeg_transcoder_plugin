defmodule Membrane.FFmpeg.TranscoderLifecycleTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  alias Membrane.Testing.Pipeline

  @moduletag timeout: 15_000
  @input_path Path.expand("../../data/av-sync-test.ts", __DIR__)
  @subtitle_path Path.expand("../../data/subtitle-test.ts", __DIR__)

  defmodule Source do
    use Membrane.Source
    def_output_pad(:output, flow_control: :push, accepted_format: Membrane.RemoteStream)

    @impl true
    def handle_playing(_ctx, state),
      do: {[stream_format: {:output, %Membrane.RemoteStream{}}, notify_parent: :ready], state}

    @impl true
    def handle_parent_notification({:feed, payload}, _ctx, state),
      do: {[buffer: {:output, %Membrane.Buffer{payload: payload}}], state}

    def handle_parent_notification(:finish, _ctx, state),
      do: {[end_of_stream: :output, notify_parent: :eof_sent], state}
  end

  test "public bin reports successful process exit and still delivers media EOS" do
    pid = start_pipeline(%Membrane.File.Source{location: @input_path})

    assert_pipeline_notified(
      pid,
      :transcoder,
      {:transcoder_exited, %{reason: :normal, input_eos_received?: true}},
      3_000
    )

    assert_end_of_stream(pid, :video, :input, 3_000)
    assert_sink_buffer(pid, :video, %Membrane.Buffer{}, 0)
    refute_pipeline_notified(pid, :transcoder, {:transcoder_exited, _}, 0)
    assert Process.alive?(pid)
  end

  test "nonzero exit after input EOS is reported without crashing the pipeline" do
    pid = start_pipeline(%Membrane.Testing.Source{output: ["not a media stream"]})

    assert_pipeline_notified(
      pid,
      :transcoder,
      {:transcoder_exited, %{reason: {:status, 183}, input_eos_received?: true}},
      3_000
    )

    assert_end_of_stream(pid, :video, :input, 3_000)
    refute_sink_buffer(pid, :video, %Membrane.Buffer{}, 0)
    assert Process.alive?(pid)
  end

  @tag :tmp_dir
  test "signal before input EOS is reported once, without an implicit restart", %{tmp_dir: dir} do
    pid = start_pipeline(Source)
    assert_pipeline_notified(pid, :source, :ready)
    Pipeline.notify_child(pid, :source, {:feed, streaming_input(dir)})
    assert_sink_buffer(pid, :video, %Membrane.Buffer{}, 3_000)
    {filter, command} = ffmpeg_command(pid)
    assert :ok = :exec.kill(command.pid, 9)

    assert_pipeline_notified(
      pid,
      :transcoder,
      {:transcoder_exited, %{reason: {:signal, :sigkill, false}, input_eos_received?: false}},
      3_000
    )

    assert_end_of_stream(pid, :video, :input, 3_000)
    Pipeline.notify_child(pid, :source, {:feed, "late input"})
    Pipeline.notify_child(pid, :source, :finish)
    assert_pipeline_notified(pid, :source, :eof_sent)
    # Synchronize with the filter only to flush the late input/EOF callbacks.
    eventually(fn -> :sys.get_state(filter).internal_state.closing end)
    refute_pipeline_notified(pid, :transcoder, {:transcoder_exited, _}, 0)
    refute_receive {Pipeline, ^pid, {:handle_element_end_of_stream, {:video, :input}}}, 0
    assert Process.alive?(pid)
  end

  @tag :tmp_dir
  test "signal while draining is reported with input EOS already received", %{tmp_dir: dir} do
    pid = start_pipeline(Source)
    assert_pipeline_notified(pid, :source, :ready)
    Pipeline.notify_child(pid, :source, {:feed, streaming_input(dir)})
    assert_sink_buffer(pid, :video, %Membrane.Buffer{}, 3_000)
    {filter, command} = ffmpeg_command(pid)

    # Stop FFmpeg before EOF so its exit cannot race the phase under test.
    assert {_, 0} = System.cmd("kill", ["-STOP", Integer.to_string(command.ospid)])
    Pipeline.notify_child(pid, :source, :finish)
    eventually(fn -> :sys.get_state(filter).internal_state.closing end)
    assert :ok = :exec.kill(command.pid, 9)

    assert_pipeline_notified(
      pid,
      :transcoder,
      {:transcoder_exited, %{reason: {:signal, :sigkill, false}, input_eos_received?: true}},
      3_000
    )

    assert_end_of_stream(pid, :video, :input, 3_000)
    assert Process.alive?(pid)
  end

  test "failure before FFmpeg opens a subtitle FIFO still finishes every output" do
    pid = start_pipeline(%Membrane.Testing.Source{output: ["not a media stream"]}, text?: true)

    assert_pipeline_notified(
      pid,
      :transcoder,
      {:transcoder_exited, %{reason: {:status, 183}}},
      3_000
    )

    assert_end_of_stream(pid, :video, :input, 3_000)
    assert_end_of_stream(pid, :text, :input, 3_000)
  end

  test "concurrent subtitle runs retain their own complete caption streams" do
    pipelines =
      for _ <- 1..2,
          do: start_pipeline(%Membrane.File.Source{location: @subtitle_path}, text?: true)

    for pid <- pipelines do
      assert_pipeline_notified(pid, :transcoder, {:transcoder_exited, %{reason: :normal}}, 3_000)
      assert_end_of_stream(pid, :video, :input, 3_000)
      assert_end_of_stream(pid, :text, :input, 3_000)

      for {text, pts} <- [
            {"♪ Mit Zucker lacht das Leben ♪", 2_342_000_000},
            {"Alte Werbespots stellen Zucker\nals Kraftspender dar.", 4_842_000_000},
            {"Auch in den 70ern\nist sein Ruf noch gut.", 9_742_000_000}
          ] do
        assert_sink_buffer(pid, :text, %Membrane.Buffer{payload: ^text, pts: ^pts}, 0)
      end
    end
  end

  test "normal completion releases the subtitle process group and FIFO while the bin stays alive" do
    pid = start_pipeline(Source, text?: true)
    assert_pipeline_notified(pid, :source, :ready)
    {_command, readers} = owned_processes(pid)
    assert readers != []
    Pipeline.notify_child(pid, :source, {:feed, File.read!(@subtitle_path)})
    Pipeline.notify_child(pid, :source, :finish)
    assert_pipeline_notified(pid, :transcoder, {:transcoder_exited, %{reason: :normal}}, 3_000)
    assert_end_of_stream(pid, :text, :input, 3_000)

    for reader <- readers do
      refute File.exists?(Path.dirname(reader.fifo))

      eventually(fn ->
        not Process.alive?(reader.pid) and not process_group_alive?(reader.ospid)
      end)
    end

    assert Process.alive?(pid)
  end

  test "explicit teardown releases FFmpeg and subtitle readers that never received input" do
    pid = start_pipeline(Source, text?: true)
    assert_pipeline_notified(pid, :source, :ready)
    {command, readers} = owned_processes(pid)
    assert Process.alive?(command.pid)
    assert signalable?(Integer.to_string(command.ospid))
    assert readers != []
    assert :ok = Pipeline.terminate(pid, asynchronous?: false)

    eventually(fn ->
      not Process.alive?(command.pid) and not signalable?(Integer.to_string(command.ospid))
    end)

    for reader <- readers do
      eventually(fn ->
        not File.exists?(Path.dirname(reader.fifo)) and not Process.alive?(reader.pid) and
          not process_group_alive?(reader.ospid)
      end)
    end
  end

  defp start_pipeline(source, opts \\ []) do
    spec = [
      child(:source, source)
      |> child(:transcoder, Membrane.FFmpeg.Transcoder)
      |> via_out(:video, options: [copy: true])
      |> child(:video, Membrane.Testing.Sink)
    ]

    spec =
      if opts[:text?] do
        spec ++
          [
            get_child(:transcoder)
            |> via_out(:text, options: [source: {:dvb_teletext, 777}])
            |> child(:text, Membrane.Testing.Sink)
          ]
      else
        spec
      end

    Pipeline.start_link_supervised!(spec: spec)
  end

  defp streaming_input(dir) do
    path = Path.join(dir, "streaming.ts")

    {output, status} =
      System.cmd(
        "ffmpeg",
        [
          "-v",
          "error",
          "-stream_loop",
          "3",
          "-i",
          @input_path,
          "-map",
          "0:v",
          "-c",
          "copy",
          "-t",
          "10",
          "-f",
          "mpegts",
          path
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    File.read!(path)
  end

  # Private state is used only to target the owned OS process and inject faults.
  defp ffmpeg_command(pipeline) do
    filter = Pipeline.get_child_pid!(pipeline, [:transcoder, :transcoder])
    {filter, :sys.get_state(filter).internal_state.ffmpeg}
  end

  defp owned_processes(pipeline) do
    filter = Pipeline.get_child_pid!(pipeline, [:transcoder, :transcoder])
    eventually(fn -> :sys.get_state(filter).internal_state.ffmpeg != nil end)
    state = :sys.get_state(filter).internal_state

    for reader <- Map.values(state.text_readers) do
      eventually(fn -> process_group_alive?(reader.ospid) end)
    end

    {state.ffmpeg, Map.values(state.text_readers)}
  end

  defp process_group_alive?(ospid), do: signalable?("-#{ospid}")

  defp signalable?(target) do
    {_, status} = System.cmd("kill", ["-0", target], stderr_to_stdout: true)
    status == 0
  end

  defp eventually(predicate, attempts \\ 200) do
    cond do
      predicate.() ->
        :ok

      attempts == 0 ->
        flunk("condition did not become true")

      true ->
        Process.sleep(5)
        eventually(predicate, attempts - 1)
    end
  end
end
