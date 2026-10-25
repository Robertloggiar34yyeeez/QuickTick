import Foundation
import os
import UIKit
import Darwin

enum FeedPerformance {
    static func emit(_ stage: String, started: Date, count: Int) {
        #if DEBUG
        let ms = Date().timeIntervalSince(started) * 1000
        Logger(subsystem: "QuickTick", category: "FeedPerformance").debug("stage=\(stage, privacy: .public) ms=\(ms, privacy: .public) posts=\(count, privacy: .public)")
        if ProcessInfo.processInfo.arguments.contains("--measure-performance") {
            print("QUICKTICK_METRIC stage=\(stage) ms=\(ms) count=\(count)")
        }
        #endif
    }
}

/// Opt-in local diagnostics. Display-link scheduling gaps are not GPU frame
/// timings, and simulator battery values must never be treated as device data.
@MainActor final class FeedFrameMonitor: NSObject {
    static let shared = FeedFrameMonitor()
    #if DEBUG
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var started: CFTimeInterval?
    private var frames = 0, gaps = 0
    @objc private func tick(_ link: CADisplayLink) {
        guard UIApplication.shared.applicationState == .active else { last = nil; started = nil; frames = 0; gaps = 0; return }
        if let last, link.timestamp - last > max(link.duration, link.targetTimestamp - link.timestamp) * 1.5 { gaps += 1 }
        last = link.timestamp
        if started == nil { started = link.timestamp }
        frames += 1
        let elapsed = link.timestamp - (started ?? link.timestamp)
        guard elapsed >= 5 else { return }
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        let rss = status == KERN_SUCCESS ? Int(info.resident_size) : -1
        let fps = Double(frames - 1) / elapsed, hitches = gaps
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let battery = UIDevice.current.batteryLevel
        Task {
            let hits = await MediaImagePipeline.shared.hits, misses = await MediaImagePipeline.shared.misses
            print("QUICKTICK_METRIC displaylink_fps=\(fps) scheduling_gaps=\(hitches) rss_bytes=\(rss) thermal=\(thermal) low_power=\(lowPower) battery=\(battery) image_hits=\(hits) image_misses=\(misses)")
        }
        started = link.timestamp; frames = 1; gaps = 0
    }
    #endif
    func startIfRequested() {
        #if DEBUG
        guard link == nil, ProcessInfo.processInfo.arguments.contains("--measure-performance") else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let value = CADisplayLink(target: self, selector: #selector(tick(_:)))
        value.add(to: .main, forMode: .common); link = value
        #endif
    }
}
