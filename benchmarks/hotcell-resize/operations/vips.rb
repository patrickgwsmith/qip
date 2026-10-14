require "active_storage/hot_cell/server/transformers/image/vips"

Vips.concurrency_set Integer(ENV.fetch("VIPS_CONCURRENCY", "2"))
