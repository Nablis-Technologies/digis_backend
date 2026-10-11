# frozen_string_literal: true

# Reduce libvips operation-cache and worker-thread pressure on memory-limited
# containers. These settings do not cap total process or decoder memory.
if defined?(Vips)
  Vips.concurrency_set(1)
  Vips.cache_set_max(0)
  Vips.cache_set_max_mem(0)
  Vips.cache_set_max_files(0)
end
