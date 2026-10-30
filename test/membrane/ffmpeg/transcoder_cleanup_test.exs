defmodule Membrane.FFmpeg.TranscoderCleanupTest do
  use ExUnit.Case, async: true

  alias Membrane.FFmpeg.Transcoder.Filter

  test "cleanup in another process observes exit without waiting for the timeout" do
    {:ok, pid, os_pid} =
      :exec.run([System.find_executable("sh"), "-c", "printf ready; exec sleep 30"], [
        :monitor,
        :stdout
      ])

    on_exit(fn -> :exec.stop(pid) end)
    assert_receive {:stdout, ^os_pid, "ready"}, 1_000

    cleanup = Task.async(fn -> Filter.stop_ffmpeg(pid) end)
    assert Task.await(cleanup, 2_000) == :ok
    assert_receive {:DOWN, ^os_pid, :process, ^pid, _reason}, 1_000
    refute Process.alive?(pid)
  end

  test "cleanup tolerates an already exited process" do
    {:ok, pid, os_pid} = :exec.run([System.find_executable("true")], [:monitor])
    assert_receive {:DOWN, ^os_pid, :process, ^pid, _reason}, 1_000

    cleanup = Task.async(fn -> Filter.stop_ffmpeg(pid) end)
    assert Task.await(cleanup, 2_000) == :ok
  end

  test "cleanup allows the five-second grace period before a forced exit" do
    {:ok, pid, os_pid} =
      :exec.run(
        [System.find_executable("sh"), "-c", "trap '' TERM; printf ready; exec sleep 30"],
        [:monitor, :stdout, {:kill, "kill -s TERM ${CHILD_PID}"}, {:kill_timeout, 5}]
      )

    on_exit(fn -> :exec.stop(pid) end)
    assert_receive {:stdout, ^os_pid, "ready"}, 1_000

    :ok = :exec.kill(pid, 15)
    refute_receive {:DOWN, ^os_pid, :process, ^pid, _reason}, 100
    assert Process.alive?(pid)

    cleanup = Task.async(fn -> Filter.stop_ffmpeg(pid) end)
    assert Task.await(cleanup, 7_000) == :ok
    assert_receive {:DOWN, ^os_pid, :process, ^pid, _reason}, 1_000
    refute Process.alive?(pid)
  end
end
