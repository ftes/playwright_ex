import Config

# The repo's own: the Linux test container (scripts/linux) keeps the driver in /cache.
if dir = System.get_env("PW_CACHE_DIR"), do: config(:playwright, :driver, cache_dir: dir)
