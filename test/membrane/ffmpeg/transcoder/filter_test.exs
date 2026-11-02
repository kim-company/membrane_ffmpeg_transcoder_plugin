defmodule Membrane.FFmpeg.Transcoder.FilterTest do
  use ExUnit.Case, async: true

  alias Membrane.FFmpeg.Transcoder.Filter
  import ExUnit.CaptureLog
  require Membrane.Pad

  describe "handle_buffer/4 when ffmpeg is not running" do
    test "drops the buffer without crashing on a binary payload" do
      state = state([])
      buffer = %Membrane.Buffer{payload: <<85, 39, 138, 71, 0, 1, 2, 3>>}

      assert {[], ^state} = Filter.handle_buffer(:input, buffer, %{}, state)
    end
  end

  describe "FFmpeg exit status decoding" do
    test "decodes the wait status from a real nonzero process exit" do
      {:ok, pid, ospid} = :exec.run([System.find_executable("sh"), "-c", "exit 7"], [:monitor])
      assert_receive {:DOWN, ^ospid, :process, ^pid, {:exit_status, status}}, 1_000

      logs = capture_exit(pid, ospid, {:exit_status, status})
      assert logs =~ "exited with reason: {:status, 7}"
    end

    test "decodes termination by signal from a real process exit" do
      {:ok, pid, ospid} =
        :exec.run([System.find_executable("sh"), "-c", "kill -KILL $$"], [:monitor])

      assert_receive {:DOWN, ^ospid, :process, ^pid, {:exit_status, status}}, 1_000

      logs = capture_exit(pid, ospid, {:exit_status, status})
      assert logs =~ "exited with reason: {:signal, :sigkill, false}"
    end
  end

  @tag :tmp_dir
  test "exit notification leaves EOS pending until the reader's last bytes and exit", %{
    tmp_dir: dir
  } do
    pad = Membrane.Pad.ref(:text, 0)
    guard = start_supervised!({Membrane.ResourceGuard, self()})

    {:ok, reader_pid, reader_ospid} =
      :exec.run([System.find_executable("cat")], [:stdin, :stdout, :monitor])

    on_exit(fn -> Filter.stop_ffmpeg(reader_pid) end)
    fifo = Path.join(dir, "reader/text.fifo")
    File.mkdir_p!(Path.dirname(fifo))
    File.touch!(fifo)

    state =
      state(
        ffmpeg: %{pid: self(), ospid: 123},
        text_readers: %{
          reader_ospid => %{
            pid: reader_pid,
            ospid: reader_ospid,
            pad: pad,
            fifo: fifo,
            cleanup_tag: make_ref()
          }
        }
      )

    ctx = %{pads: %{pad => %{}}, resource_guard: guard}
    :ok = :exec.send(reader_pid, "last subtitle\n")

    assert {[
              notify_parent:
                {:transcoder_exited, %{reason: {:status, 1}, input_eos_received?: false}}
            ],
            state} =
             Filter.handle_info({:DOWN, 123, :process, self(), {:exit_status, 256}}, ctx, state)

    assert_receive {:stdout, ^reader_ospid, payload}, 1_000

    assert {[buffer: {^pad, %Membrane.Buffer{payload: ^payload}}], state} =
             Filter.handle_info({:stdout, reader_ospid, payload}, ctx, state)

    assert payload == "last subtitle\n"

    assert_receive {:DOWN, ^reader_ospid, :process, ^reader_pid, :normal}, 1_000

    assert {[end_of_stream: :ts, end_of_stream: ^pad], state} =
             Filter.handle_info({:DOWN, reader_ospid, :process, reader_pid, :normal}, ctx, state)

    assert {[], state} = Filter.handle_end_of_stream(:input, ctx, state)
    assert {[], ^state} = Filter.handle_end_of_stream(:input, ctx, state)
    refute File.exists?(fifo)
  end

  test "a failed text reader remains an element failure rather than a successful drain" do
    state = state(text_readers: %{123 => %{}})

    assert_raise Filter.FFmpegError, ~r/text_reader_exited/, fn ->
      Filter.handle_info({:DOWN, 123, :process, self(), {:exit_status, 256}}, %{}, state)
    end
  end

  test "a reader that exits before FFmpeg is an element failure even with exit zero" do
    state = state(ffmpeg: %{pid: self(), ospid: 456}, text_readers: %{123 => %{}})

    assert_raise Filter.FFmpegError, ~r/text_reader_exited/, fn ->
      Filter.handle_info({:DOWN, 123, :process, self(), :normal}, %{}, state)
    end
  end

  defp capture_exit(pid, ospid, reason) do
    guard = start_supervised!({Membrane.ResourceGuard, self()})

    capture_log(fn ->
      state = state(ffmpeg: %{pid: pid, ospid: ospid}, closing: true)

      assert {[notify_parent: {:transcoder_exited, _}, end_of_stream: :ts], %{ffmpeg: nil}} =
               Filter.handle_info(
                 {:DOWN, ospid, :process, pid, reason},
                 %{pads: %{}, resource_guard: guard},
                 state
               )
    end)
  end

  defp state(overrides) do
    {[], state} = Filter.handle_init(%{}, %{})
    Map.merge(state, Map.new(overrides))
  end
end
