import Config

config :logger, level: :info

# Production runs migrations as a separate step (`SuperPi.Release.migrate/0`, or the release
# command `bin/super_pi eval "SuperPi.Release.migrate()"`), so a rolling deploy or a cluster
# never races on the schema. Set SUPER_PI_AUTO_MIGRATE=true to migrate at boot instead.
config :super_pi, auto_migrate: false
