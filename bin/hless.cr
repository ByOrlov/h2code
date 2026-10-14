# hless executable entry (the shard target) — keeps the CLI call out of
# src/hless.cr so specs can require the module without side effects.
require "../src/hless"

exit Hless.run(ARGV)
