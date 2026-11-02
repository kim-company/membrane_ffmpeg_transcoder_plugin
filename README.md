# Membrane.FFmpeg.Transcoder
![Hex.pm Version](https://img.shields.io/hexpm/v/membrane_ffmpeg_transcoder_plugin)

Membrane plugin to transcode video into different qualities using FFmpeg.

## Requirements
- FFmpeg with `libx264` for video encoding, `libfdk_aac` for AAC, and `libopus`
  for Opus (depending on the outputs used).
- The `libzvbi_teletextdec` decoder for teletext subtitle extraction.

## Development and tests

The tool versions and FFmpeg codec build flags used for development are pinned in
`mise.toml`. Building FFmpeg requires a compiler and the native development
libraries for x264, FDK AAC, Opus, and zvbi. With those installed, run `mise install`
and then:

```sh
mix deps.get
mix test
```

The integration tests also require `ffprobe`. They check FFmpeg's encoders and
decoders before starting any pipelines and report missing capabilities directly.
Some distribution builds of FFmpeg omit `libfdk_aac` or `libzvbi`; check the
installed build with `ffmpeg -hide_banner -encoders` and
`ffmpeg -hide_banner -decoders`.

Passing tests stay quiet. Logs, including FFmpeg commands and warnings, are
captured and printed on failure. Use `mix test --slowest 10` for per-test timings.

The audio/video fixture is three seconds long; it covers the full quality ladder
without encoding the original 30-second clip on every run. The subtitle and
SCTE-35 fixtures retain their complete timelines.

## Usage

### Process exit and recovery

The public bin sends its parent this notification when it observes FFmpeg exiting:

```elixir
{:transcoder_exited,
 %{reason: {:signal, :sigkill, false}, input_eos_received?: false}}
```

The reason is `:normal` for exit zero, `{:status, code}` for a nonzero exit, or
`{:signal, signal, core_dump?}` for a signal. Infrastructure failures can report
another reason, such as `:port_closed`. The boolean records whether input EOS had
reached the FFmpeg filter when it observed the exit; it does not establish success.

The bin still emits output EOS after its readers drain, including after nonzero
exits. The notification and output EOS can reach the application in either order.
Process exit does not establish downstream sink completion, recording durability,
or valid/complete media. Applications should coordinate their sinks and apply their
own drain deadline before replacing a graph.

Each bin represents one run: FFmpeg is never restarted internally. Applications
own recovery through supervision. Internal reader/element failures still propagate
as OTP failures. Monitor or supervise the graph too: no exit notification is
guaranteed if the bin is being removed or has crashed.

Subtitle readers and FIFOs belong to their individual runs. They drain on process
exit and are cleaned up on normal completion or graph teardown.

### Basic Multi-Quality Transcoding

```elixir
spec = [
  child(:source, %Membrane.File.Source{location: "input.ts"})
  |> child(:transcoder, Membrane.FFmpeg.Transcoder)
  |> via_out(:video, options: [resolution: {-2, 1080}, bitrate: 6_500_000, fps: 30])
  |> child(:hd_sink, %Membrane.File.Sink{location: "hd.h264"}),

  get_child(:transcoder)
  |> via_out(:video, options: [resolution: {-2, 720}, bitrate: 3_300_000, fps: 30])
  |> child(:sd_sink, %Membrane.File.Sink{location: "sd.h264"}),

  get_child(:transcoder)
  |> via_out(:audio, options: [bitrate: 128_000, sample_rate: 48_000, channels: 2])
  |> child(:audio_sink, %Membrane.File.Sink{location: "audio.aac"})
]
```

### Stream Copy (No Re-encoding)

```elixir
spec = [
  child(:source, %Membrane.File.Source{location: "input.ts"})
  |> child(:transcoder, Membrane.FFmpeg.Transcoder)
  |> via_out(:video, options: [copy: true])
  |> child(:video_sink, %Membrane.File.Sink{location: "video.h264"}),

  get_child(:transcoder)
  |> via_out(:audio, options: [copy: true])
  |> child(:audio_sink, %Membrane.File.Sink{location: "audio.aac"})
]
```

### MP4 Output with Parsers

```elixir
spec = [
  child(:source, %Membrane.File.Source{location: "input.ts"})
  |> child(:transcoder, Membrane.FFmpeg.Transcoder)
  |> via_out(:video, options: [resolution: {-2, 720}, bitrate: 3_300_000])
  |> child(:h264_parser, %Membrane.H264.Parser{output_stream_structure: :avc1})
  |> child(:mp4_muxer, %Membrane.MP4.Muxer.ISOM{fast_start: true})
  |> child(:sink, %Membrane.File.Sink{location: "output.mp4"})
]
```

### Teletext Subtitle Extraction

```elixir
spec = [
  child(:source, %Membrane.File.Source{location: "input_with_teletext.ts"})
  |> child(:transcoder, Membrane.FFmpeg.Transcoder)
  |> via_out(:text, options: [source: {:dvb_teletext, 777}])
  |> child(:subtitle_sink, %Membrane.Testing.Sink{})
]
```

### Video Options
- `resolution`: `{width, height}` (use `-2` for auto-calculated dimension)
- `bitrate`: Maximum bitrate in bits/second
- `fps`: Target framerate
- `profile`: `:baseline`, `:main`, `:high`
- `crf`: Constant rate factor (18-28, lower = higher quality)
- `preset`: `:ultrafast`, `:veryfast`, `:fast`, `:medium`, `:slow`
- `tune`: `:zerolatency`, `:film`, `:animation`
- `gop_size`: GOP size in frames
- `b_frames`: Number of B-frames
- `copy`: Skip re-encoding (boolean)

### Audio Options
- `bitrate`: Target bitrate in bits/second
- `sample_rate`: Sample rate in Hz
- `channels`: Number of audio channels
- `copy`: Skip re-encoding (boolean)

## Features
- buffers come with pts and dts values
- same performance as ffmpeg
- simple API: attach an output with options, that's it (check the test)
- constrains the bitrate
- by adding a Membrane.h264.Parser in the middle, it is compatible with Membrane.MP4.Muxer.CMAF and Membrane.MP4.Muxer.ISOM
- transcodes to AAC and H264

## Copyright and License
Copyright 2024, [KIM Keep In Mind GmbH](https://www.keepinmind.info/)
Licensed under the [Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0)

