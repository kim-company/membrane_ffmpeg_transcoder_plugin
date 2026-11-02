# Changelog

## 1.7.0 — 2026-11-02

### Added

- The public transcoder bin forwards one `{:transcoder_exited, details}`
  notification per observed FFmpeg exit. Details include the decoded exit reason
  and whether input EOS had reached the FFmpeg filter when it observed the exit.
- Lifecycle documentation distinguishes process exit from downstream completion
  and leaves recovery and drain deadlines with the parent application.

### Fixed

- Decode erlexec wait statuses correctly for nonzero exits and signals.
- Drain subtitle readers before emitting output EOS, including when FFmpeg fails
  before opening its subtitle FIFO.
- Isolate subtitle FIFOs between concurrent runs and clean up their reader process
  groups and FIFOs on normal completion or graph teardown.
- Avoid duplicate output EOS when input ends after FFmpeg has already exited.
- Avoid crashing while logging a dropped binary buffer after FFmpeg exits.

Output EOS remains available after normal and abnormal FFmpeg exits. The bin does
not restart FFmpeg internally. Internal reader/element faults still propagate
through OTP, and exit notifications are not guaranteed during bin teardown/crash.
Consumers must tolerate either arrival order for the notification and output EOS.

### Development

- Pin the FFmpeg version and check required test codecs before starting pipelines.
- Shorten the video fixture and forced-exit test grace period, retain failure
  diagnostics without passing-test log noise, and verify SCTE cue contents/timing.
- Add lifecycle, concurrent-subtitle, late-reader-output and resource-cleanup
  regressions while retaining damaged-final-frame EOF tolerance.

## 1.6.2 — 2026-10-30

Published as a Git tag; not present in the Hex registry. Included in 1.7.0.

- Monitor the erlexec process from ResourceGuard cleanup so exit is observed in
  the cleanup task, with a six-second stop timeout and seven-second guard timeout
  covering FFmpeg's five-second termination grace period.
