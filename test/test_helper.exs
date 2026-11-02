Logger.configure(level: :info)
# Keep diagnostics for failing tests without console output from late teardown.
:logger.remove_handler(:default)
ExUnit.start(capture_log: true)
