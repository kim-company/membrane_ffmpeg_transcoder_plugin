defmodule Membrane.FFmpeg.TranscoderTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  require Membrane.Pad
  import Membrane.Testing.Assertions

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
    assert_end_of_stream(pid, {:sink, :video}, :input, 3_000)
    assert_end_of_stream(pid, {:sink, :sd}, :input, 3_000)
    assert_end_of_stream(pid, {:sink, :audio}, :input, 3_000)
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
    assert_end_of_stream(pid, {:sink, :video}, :input, 3_000)
    assert_end_of_stream(pid, {:sink, :audio}, :input, 3_000)
    assert_end_of_stream(pid, {:sink, :scte}, :input, 3_000)

    assert_sink_buffer(
      pid,
      {:sink, :scte},
      %Membrane.Buffer{
        payload:
          <<0, 252, 48, 37, 0, 0, 0, 0, 0, 0, 0, 255, 240, 20, 5, 0, 0, 0, 100, 127, 239, 254, 0,
            82, 101, 192, 126, 0, 82, 101, 192, 0, 1, 18, 255, 0, 0, 93, 125, 122, 192>>,
        dts: 56_080_000_000,
        pts: nil
      },
      5_000
    )

    assert_sink_buffer(
      pid,
      {:sink, :scte},
      %Membrane.Buffer{
        payload:
          <<0, 252, 48, 32, 0, 0, 0, 0, 0, 0, 0, 255, 240, 15, 5, 0, 0, 0, 100, 127, 79, 254, 0,
            164, 203, 128, 0, 1, 18, 255, 0, 0, 108, 20, 127, 68>>,
        dts: 116_280_000_000,
        pts: nil
      },
      5_000
    )
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
    assert_end_of_stream(pid, {:sink, :video}, :input, 3_000)
    assert_end_of_stream(pid, {:sink, :audio}, :input, 3_000)
    assert_end_of_stream(pid, {:sink, :text}, :input, 3_000)

    assert_sink_buffer(
      pid,
      {:sink, :text},
      %Membrane.Buffer{
        payload: "♪ Mit Zucker lacht das Leben ♪",
        pts: 2_342_000_000
      },
      5_000
    )

    assert_sink_buffer(
      pid,
      {:sink, :text},
      %Membrane.Buffer{
        payload: "Alte Werbespots stellen Zucker\nals Kraftspender dar.",
        pts: 4_842_000_000
      },
      5_000
    )

    assert_sink_buffer(
      pid,
      {:sink, :text},
      %Membrane.Buffer{
        payload: "Auch in den 70ern\nist sein Ruf noch gut.",
        pts: 9_742_000_000
      },
      5_000
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
      assert_end_of_stream(pid, {:sink, ^id}, :input, 60_000)
      assert_video_properties("#{tmp_dir}/#{id}.mp4", opts)
    end)

    @audio_outputs
    |> Enum.each(fn {id, opts} ->
      id = "a_#{id}"
      assert_end_of_stream(pid, {:sink, ^id}, :input, 60_000)
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
  end

  defp ffprobe(path) do
    ~w(ffprobe -show_streams -of json #{path})
    |> Enum.join(" ")
    |> :exec.run([:sync, {:stderr, :null}, :stdout])
    |> then(fn {:ok, elems} ->
      elems
      |> Keyword.fetch!(:stdout)
      |> Enum.into(<<>>)
      |> JSON.decode!()
    end)
  end
end
