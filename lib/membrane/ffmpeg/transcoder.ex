defmodule Membrane.FFmpeg.Transcoder do
  @moduledoc """
  Tasks as input an unparsed stream and provides on each pad an unparsed, transcoded stream
  with the desired properties.

  Input might be MPEG-TS or FLV but other streaming containers might work as well. If the
  input stream contains more than 1 video and 1 audio stream, which one will be picked is
  undefined behaviour.
  """
  use Membrane.Bin, flow_control_hints?: false
  alias Membrane.FFmpeg.Transcoder

  require Membrane.Logger

  # FFmpeg always puts the first MPEGTS stream at this index,
  # the other ones follow.
  @mpeg_ts_pid_base_offset 256

  def_options(
    wait_random_access_indicator: [
      spec: boolean(),
      default: true,
      description: """
      If enabled, emits packets only after the random access indicator is found
      in the MPEG-TS PES stream, otherwise packets are emitted immediately. When
      enabled, it means that the first video packet that comes out is going to
      be a keyframe unit.
      """
    ]
  )

  def_input_pad(:input,
    availability: :always,
    accepted_format: Membrane.RemoteStream
  )

  def_output_pad(:audio,
    accepted_format: any_of(Membrane.RemoteStream, Membrane.AAC, Membrane.H264),
    availability: :on_request,
    options: [
      copy: [
        spec: boolean(),
        description: "If enabled, the stream will not be re-encoded",
        default: false
      ],
      codec: [
        spec: :aac | :opus,
        description: "Audio codec to use for encoding. Ignored when copy is true.",
        default: :aac
      ],
      bitrate: [
        spec: pos_integer(),
        description: "Maximum bitrate",
        default: 128_000
      ],
      sample_rate: [
        spec: pos_integer(),
        default: 48_000
      ],
      channels: [
        spec: pos_integer(),
        default: 2
      ]
    ]
  )

  def_output_pad(:video,
    accepted_format: any_of(Membrane.RemoteStream, Membrane.AAC, Membrane.H264),
    availability: :on_request,
    options: [
      copy: [
        spec: boolean(),
        description: "If enabled, the stream will not be re-encoded",
        default: false
      ],
      resolution: [
        spec: {integer(), integer()},
        description: "Resolution of the given output.",
        default: {-2, 720}
      ],
      bitrate: [
        spec: pos_integer(),
        description: "Maximum bitrate",
        default: 3_300_000
      ],
      profile: [
        spec: atom(),
        description: "H264 Profile",
        default: :high
      ],
      crf: [
        spec: pos_integer(),
        default: 26
      ],
      preset: [
        spec: atom(),
        default: :high
      ],
      tune: [
        spec: atom(),
        default: :zerolatency
      ],
      fps: [
        spec: pos_integer(),
        default: 30
      ],
      gop_size: [
        spec: pos_integer(),
        default: 60
      ],
      b_frames: [
        spec: pos_integer(),
        default: 3
      ],
      level: [
        spec: String.t(),
        default: "3.1"
      ]
    ]
  )

  def_output_pad(:text,
    accepted_format: Membrane.Text,
    availability: :on_request,
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

  def_output_pad(:scte,
    accepted_format: any_of(Membrane.RemoteStream, Membrane.AAC, Membrane.H264),
    availability: :on_request,
    options: [
      pid: [
        default: nil,
        spec: pos_integer(),
        description: "PID of the SCTE stream. When `nil` it grabs the first stream."
      ]
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    spec = [
      bin_input(:input)
      |> child(:transcoder, Transcoder.Filter)
      |> via_out(:ts)
      # NOTE: In the case of a specific input source the output is being bursted out after a while.
      # We need to check out whats the reason for this and if the transcoder is the problem.
      # In the meanwhile we keep this as a temporary hack.
      |> via_in(:input, toilet_capacity: 3000)
      |> child(:demuxer, %Membrane.MPEG.TS.Demuxer{
        wait_rai?: opts.wait_random_access_indicator
      })
    ]

    {[spec: spec], %{pid_offset: @mpeg_ts_pid_base_offset}}
  end

  @impl true
  def handle_pad_added(Pad.ref(:text, ref) = pad, ctx, state) do
    spec = [
      get_child(:transcoder)
      |> via_out(:text, options: [source: ctx.pad_options.source])
      |> child({:srt_parser, ref}, Membrane.Subtitles.SRT.Parser)
      |> bin_output(pad)
    ]

    {[spec: spec], state}
  end

  def handle_pad_added(pad, ctx, state) do
    {pid, state} = get_and_update_in(state, [:pid_offset], fn old -> {old, old + 1} end)

    spec = [
      get_child(:demuxer)
      |> via_out(:output, options: [pid: pid])
      |> bin_output(pad)
    ]

    {[
       spec: spec,
       notify_child: {:transcoder, {:stream_added, {Pad.name_by_ref(pad), pid}, ctx.pad_options}}
     ], state}
  end
end
