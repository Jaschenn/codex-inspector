// xcrun swift scripts/measure_native_memory.swift OUTPUT.json UI_PID CORE_PID [SAMPLES]
// Activity Monitor uses physical footprint, not RSS. No process contents are recorded.
import Darwin
import Foundation

struct ProcessMemory: Codable {
  let pid: Int32
  let footprintBytes: UInt64
  let residentBytes: UInt64
}

struct MemorySample: Codable {
  let timestamp: String
  let processes: [ProcessMemory]
  var totalFootprintBytes: UInt64
}

func measure(_ pid: Int32) throws -> ProcessMemory {
  var info = rusage_info_v2()
  let status = withUnsafeMutablePointer(to: &info) { pointer in
    pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
      proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
    }
  }
  guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
  return ProcessMemory(
    pid: pid, footprintBytes: info.ri_phys_footprint,
    residentBytes: info.ri_resident_size)
}

guard CommandLine.arguments.count >= 4,
  let ui = Int32(CommandLine.arguments[2]), let core = Int32(CommandLine.arguments[3])
else {
  fatalError("Usage: measure_native_memory.swift OUTPUT.json UI_PID CORE_PID [SAMPLES]")
}
let count = CommandLine.arguments.count > 4 ? Int(CommandLine.arguments[4]) ?? 20 : 20
guard count > 0 else { fatalError("SAMPLES must be positive") }
var samples: [MemorySample] = []
for index in 0..<count {
  let processes = try [ui, core].map(measure)
  samples.append(
    MemorySample(
      timestamp: ISO8601DateFormatter().string(from: Date()),
      processes: processes, totalFootprintBytes: processes.reduce(0) { $0 + $1.footprintBytes }))
  if index + 1 < count { Thread.sleep(forTimeInterval: 1) }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(samples).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
let values = samples.map(\.totalFootprintBytes).sorted()
print("Total footprint: median \(values[values.count / 2]) bytes; max \(values.last!) bytes")
