import AppKit
import MacResourceGuardCore

let sample = SystemMetricsSampler()
print("Sampler page size:", sample.pageSizeBytes)
print("Physical memory:", sample.totalPhysicalMemoryBytes)
