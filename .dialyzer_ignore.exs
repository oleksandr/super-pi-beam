# Dialyzer warnings that are false positives. Fix the code instead when a warning is real.
[
  # OTP 28 opaque checks: `Task` refs and `MapSet` values passed to functions that accept them.
  {"lib/super_pi/cli.ex", :call_with_opaque},
  {"lib/super_pi/gateway/agui.ex", :call_with_opaque},
  {"lib/super_pi/gateway/router.ex", :call_with_opaque},
  {"lib/super_pi/env/local.ex", :call_with_opaque},
  {"lib/super_pi/env/local.ex", :call_without_opaque},
  {"lib/super_pi/memory.ex", :call_with_opaque},
  {"lib/super_pi/memory.ex", :call_without_opaque},
  # `Fsmx.transition_multi/5` spec does not accept an `Ecto.Multi`.
  {"lib/super_pi/durable/task_engine.ex", :call_without_opaque},
  # Exile specs are wrong: `os_pid/1` returns `{:ok, pid}`, and `await_exit/2` returns the raw exit status.
  {"lib/super_pi/env/sandbox_runner.ex", :pattern_match},
  # Defensive clause for an empty IP list.
  {"lib/super_pi/web/fetch.ex", :pattern_match_cov}
]
