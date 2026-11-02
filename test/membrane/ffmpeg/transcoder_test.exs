defmodule Membrane.FFmpeg.TranscoderTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  require Membrane.Pad
  import Membrane.Testing.Assertions
  import ExUnit.CaptureLog

  @moduletag timeout: 15_000
  @eos_timeout 10_000
  @crf 26

  @input_path "test/data/av-sync-test.ts"

  @video_outputs [
    fhd: [
      resolution: {-2, 1080},
      bitrate: 6_500_000,
      profile: :high,
      fps: 30,
      gop_size: 60,
      b_frames: 3,
      crf: @crf,
      preset: :veryfast,
      tune: :zerolatency
    ],
    hd: [
      resolution: {-2, 720},
      bitrate: 3_300_000,
      profile: :high,
      fps: 30,
      gop_size: 60,
      b_frames: 3,
      crf: @crf,
      preset: :veryfast,
      tune: :zerolatency
    ],
    sd: [
      resolution: {-2, 360},
      bitrate: 1_200_000,
      profile: :main,
      fps: 15,
      gop_size: 30,
      b_frames: 3,
      crf: @crf,
      preset: :veryfast,
      tune: :zerolatency
    ],
    mobile: [
      resolution: {-2, 234},
      bitrate: 200_000,
      profile: :baseline,
      fps: 15,
      gop_size: 30,
      b_frames: 0,
      crf: @crf,
      preset: :veryfast,
      tune: :zerolatency
    ]
  ]

  @audio_outputs [
    hd: [
      channels: 2,
      bitrate: 98_000,
      sample_rate: 44_100
    ],
    fhd: [
      channels: 2,
      bitrate: 128_000,
      sample_rate: 48_000
    ]
  ]

  setup_all do
    for executable <- ["ffmpeg", "ffprobe"] do
      assert System.find_executable(executable),
             "#{executable} is required; run mise install before running the integration tests"
    end

    for {option, required} <- [
          {"-encoders", ~w(libx264 libfdk_aac libopus)},
          {"-decoders", ~w(libzvbi_teletextdec)}
        ] do
      {output, status} = System.cmd("ffmpeg", ["-hide_banner", option], stderr_to_stdout: true)
      assert status == 0, "ffmpeg #{option} failed:\n#{output}"
      missing = Enum.reject(required, &String.contains?(output, &1))

      assert missing == [],
             "FFmpeg is missing #{Enum.join(missing, ", ")}; use the full build pinned in mise.toml"
    end

    :ok
  end

  @tag :tmp_dir
  test "copy", %{tmp_dir: tmp_dir} do
    spec = [
      child(:source, %Membrane.File.Source{
        location: @input_path
      })
      |> child(:transcoder, Membrane.FFmpeg.Transcoder)
      |> via_out(:video, options: [copy: true])
      |> child({:sink, :video}, %Membrane.File.Sink{location: "#{tmp_dir}/video.h264"}),
      get_child(:transcoder)
      |> via_out(:audio, options: [copy: true])
      |> child({:sink, :audio}, %Membrane.File.Sink{location: "#{tmp_dir}/audio.aac"}),
      # We're also adding a non-copy output to ensure copy and non-copy can live together.
      get_child(:transcoder)
      |> via_out(:video, options: @video_outputs[:sd])
      |> child({:sink, :sd}, %Membrane.File.Sink{location: "#{tmp_dir}/sd.h264"})
    ]

    pid = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)

    for output <- [:video, :sd, :audio] do
      assert_end_of_stream(pid, {:sink, ^output}, :input, @eos_timeout)
    end

    for filename <- ["video.h264", "sd.h264", "audio.aac"] do
      assert File.stat!(Path.join(tmp_dir, filename)).size > 0
    end
  end

  test "transcodes audio to Opus" do
    spec = [
      child(:source, %Membrane.File.Source{
        location: @input_path
      })
      |> child(:transcoder, Membrane.FFmpeg.Transcoder)
      |> via_out(:audio,
        options: [codec: :opus, bitrate: 96_000, sample_rate: 48_000, channels: 2]
      )
      |> child(:sink, Membrane.Testing.Sink)
    ]

    pid = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_end_of_stream(pid, :sink, :input, @eos_timeout)

    for _ <- 1..5 do
      assert_sink_buffer(pid, :sink, %Membrane.Buffer{payload: payload}, 0)
      assert byte_size(payload) > 0
    end
  end

  @tag :tmp_dir
  test "finishes at EOF despite a damaged final video frame", %{tmp_dir: tmp_dir} do
    # The final video PES starts at packet 960. Keep its first TS packet,
    # truncating the last frame while preserving the preceding three seconds.
    payload = File.read!(@input_path) |> binary_part(0, 188 * 961)
    output_path = Path.join(tmp_dir, "truncated.h264")

    logs =
      capture_log(fn ->
        spec =
          child(:source, %Membrane.Testing.Source{output: [payload]})
          |> child(:transcoder, Membrane.FFmpeg.Transcoder)
          |> via_out(:video, options: @video_outputs[:sd])
          |> child(:sink, %Membrane.File.Sink{location: output_path})

        pid = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
        assert_end_of_stream(pid, :sink, :input, @eos_timeout)
        assert Process.alive?(pid)
      end)

    # Establish that this actually exercised a decoder error, rather than
    # merely a shorter valid stream, and that FFmpeg nevertheless exited zero.
    assert logs =~ "error while decoding"
    assert logs =~ "exited with reason: :normal"

    {frames, status} =
      System.cmd(
        "ffprobe",
        [
          "-v",
          "error",
          "-count_frames",
          "-select_streams",
          "v:0",
          "-show_entries",
          "stream=nb_read_frames",
          "-of",
          "csv=p=0",
          output_path
        ],
        stderr_to_stdout: true
      )

    assert status == 0, frames
    assert frames |> String.trim() |> String.to_integer() >= 45
  end

  @tag :tmp_dir
  test "extracts scte35 markers", %{tmp_dir: tmp_dir} do
    spec = [
      child(:source, %Membrane.File.Source{
        location: "test/data/scte35-test.ts"
      })
      |> child(:transcoder, Membrane.FFmpeg.Transcoder)
      |> via_out(:video, options: [copy: true])
      |> child({:sink, :video}, %Membrane.File.Sink{location: "#{tmp_dir}/video.h264"}),
      get_child(:transcoder)
      |> via_out(:audio, options: [copy: true])
      |> child({:sink, :audio}, %Membrane.File.Sink{location: "#{tmp_dir}/audio.aac"}),
      get_child(:transcoder)
      |> via_out(:scte, options: [])
      |> child({:sink, :scte}, %Membrane.Testing.Sink{})
    ]

    pid = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)

    for output <- [:video, :audio, :scte] do
      assert_end_of_stream(pid, {:sink, ^output}, :input, @eos_timeout)
    end

    # FFmpeg versions may change the section framing and descriptors. Verify
    # every cue's meaning and timing rather than one muxer's byte representation.
    for {event_id, splice_time, out_of_network, break_duration} <- [
          {100, 60_000_000_000, 1, %{auto_return: 0, duration: 60_000_000_000}},
          {100, 120_000_000_000, 0, nil},
          {101, 180_000_000_000, 1, %{auto_return: 0, duration: 60_000_000_000}}
        ] do
      assert_sink_buffer(pid, {:sink, :scte}, %Membrane.Buffer{} = buffer, 0)

      assert {:ok,
              %MPEG.TS.PSI{
                table_type: :scte35,
                table: %MPEG.TS.SCTE35{
                  protocol_version: 0,
                  encrypted_packet: 0,
                  pts_adjustment: 0,
                  splice_command_type: :splice_insert,
                  splice_command: %MPEG.TS.SCTE35.SpliceInsert{
                    event_id: ^event_id,
                    cancel_indicator: 0,
                    out_of_network_indicator: ^out_of_network,
                    splice_time: %{pts: ^splice_time},
                    break_duration: ^break_duration
                  }
                }
              }} = MPEG.TS.PSI.unmarshal(buffer.payload, true)

      assert is_integer(buffer.dts)
      assert buffer.dts < splice_time
      assert splice_time - buffer.dts < 5_000_000_000
    end

    refute_sink_buffer(pid, {:sink, :scte}, %Membrane.Buffer{}, 0)
  end

  @tag :tmp_dir
  test "extracts teletext subtitles", %{tmp_dir: tmp_dir} do
    spec = [
      child(:source, %Membrane.File.Source{
        location: "test/data/subtitle-test.ts"
      })
      |> child(:transcoder, Membrane.FFmpeg.Transcoder)
      |> via_out(:video, options: [copy: true])
      |> child({:sink, :video}, %Membrane.File.Sink{location: "#{tmp_dir}/video.h264"}),
      get_child(:transcoder)
      |> via_out(:audio, options: [copy: true])
      |> child({:sink, :audio}, %Membrane.File.Sink{location: "#{tmp_dir}/audio.aac"}),
      get_child(:transcoder)
      |> via_out(:text, options: [source: {:dvb_teletext, 777}])
      |> child({:sink, :text}, %Membrane.Testing.Sink{})
    ]

    pid = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)

    for output <- [:video, :audio, :text] do
      assert_end_of_stream(pid, {:sink, ^output}, :input, @eos_timeout)
    end

    assert_sink_buffer(
      pid,
      {:sink, :text},
      %Membrane.Buffer{
        payload: "♪ Mit Zucker lacht das Leben ♪",
        pts: 2_342_000_000
      },
      0
    )

    assert_sink_buffer(
      pid,
      {:sink, :text},
      %Membrane.Buffer{
        payload: "Alte Werbespots stellen Zucker\nals Kraftspender dar.",
        pts: 4_842_000_000
      },
      0
    )

    assert_sink_buffer(
      pid,
      {:sink, :text},
      %Membrane.Buffer{
        payload: "Auch in den 70ern\nist sein Ruf noch gut.",
        pts: 9_742_000_000
      },
      0
    )
  end

  @tag :tmp_dir
  test "transcodes an input video into multiple qualities", %{tmp_dir: tmp_dir} do
    spec =
      [
        child(:source, %Membrane.File.Source{
          location: @input_path
        })
        |> child(:transcoder, Membrane.FFmpeg.Transcoder)
      ] ++
        Enum.map(@audio_outputs, fn {id, opts} ->
          id = "a_#{id}"

          get_child(:transcoder)
          |> via_out(:audio, options: opts)
          |> child({:parser, id}, %Membrane.AAC.Parser{
            out_encapsulation: :none,
            output_config: :esds
          })
          |> child({:muxer, id}, %Membrane.MP4.Muxer.ISOM{
            fast_start: true
          })
          |> child({:sink, id}, %Membrane.File.Sink{location: "#{tmp_dir}/#{id}.mp4"})
        end) ++
        Enum.map(@video_outputs, fn {id, opts} ->
          id = "v_#{id}"

          get_child(:transcoder)
          |> via_out(:video, options: opts)
          |> child({:parser, id}, %Membrane.H264.Parser{
            output_stream_structure: :avc1
          })
          # We're outputing it into mp4 to onbtain all stream information
          # with ffprobe.
          |> child({:muxer, id}, %Membrane.MP4.Muxer.ISOM{
            fast_start: true
          })
          |> child({:sink, id}, %Membrane.File.Sink{location: "#{tmp_dir}/#{id}.mp4"})
        end)

    pid = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)

    @video_outputs
    |> Enum.each(fn {id, opts} ->
      id = "v_#{id}"
      assert_end_of_stream(pid, {:sink, ^id}, :input, @eos_timeout)
      assert_video_properties("#{tmp_dir}/#{id}.mp4", opts)
    end)

    @audio_outputs
    |> Enum.each(fn {id, opts} ->
      id = "a_#{id}"
      assert_end_of_stream(pid, {:sink, ^id}, :input, @eos_timeout)
      assert_audio_properties("#{tmp_dir}/#{id}.mp4", opts)
    end)
  end

  defp assert_video_properties(path, opts) do
    props = ffprobe(path)
    assert [stream] = props["streams"]

    {_width, height} = opts[:resolution]
    assert stream["height"] == height

    # Instead of matching directly we use this for baseline profile, which in
    # ffmpeg results in "Constrained Baseline".
    expected_profile = opts[:profile] |> to_string |> String.capitalize()
    assert String.contains?(stream["profile"], expected_profile)
    assert stream["codec_name"] == "h264"
    assert String.to_integer(stream["bit_rate"]) <= opts[:bitrate]

    [num, den] =
      stream["avg_frame_rate"]
      |> String.split("/")
      |> Enum.map(&String.to_integer/1)

    have_framerate = num / den
    assert_in_delta have_framerate, opts[:fps], 0.1
  end

  defp assert_audio_properties(path, opts) do
    props = ffprobe(path)

    assert [stream] = props["streams"]
    assert stream["codec_name"] == "aac"
    assert String.to_integer(stream["bit_rate"]) <= opts[:bitrate]
    assert String.to_integer(stream["sample_rate"]) == opts[:sample_rate]
    assert stream["channels"] == opts[:channels]
  end

  defp ffprobe(path) do
    {output, status} =
      System.cmd("ffprobe", ["-v", "error", "-show_streams", "-of", "json", path],
        stderr_to_stdout: true
      )

    assert status == 0, "ffprobe failed for #{path}:\n#{output}"
    JSON.decode!(output)
  end
end
