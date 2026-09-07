import Darwin

/// Memory this process is holding
enum ProcessMemory {
  /// What Activity Monitor shows in its Memory column: every page kept alive,
  /// compressed ones included
  static var footprint: Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
      }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Int(info.phys_footprint)
  }
}
