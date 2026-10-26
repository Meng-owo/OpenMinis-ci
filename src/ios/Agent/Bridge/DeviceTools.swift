import Foundation
import BridgeCore

/// 设备能力工具组（合并第 19 条）：把 OpenMinis 已有的 apple-* 能力
/// 注册进桥的工具注册中心，对外经「搜」「命令」调度。
///
/// 一项能力一个文件（BluetoothDeviceTool / PhotosDeviceTool /
/// LocationDeviceTool / NotificationDeviceTool / ClipboardDeviceTool），
/// 每个文件的 `register(into:)` 照 FakeTools 的声明格式写；
/// 执行统一走 OffloadToolRunner 落到 NativeOffloads 的现成实现。
enum DeviceTools {
    /// 设备工具统一前缀。重试前按这个前缀把注册表里残留的全部清掉——
    /// 不依赖下面这张手写名单（名单漏过一项就永久 failed，见 2026-10-20 审计）。
    static let namePrefix = "device_"

    /// 全部工具注册名。仅供文档与测试核对预期清单，不再参与重试注销。
    static let toolNames: [String] = [
        ClipboardDeviceTool.toolName,
        ClipboardDeviceTool.readToolName,
        LocationDeviceTool.toolName,
        LocationDeviceTool.currentToolName,
        NotificationDeviceTool.toolName,
        NotificationDeviceTool.scheduleToolName,
        NotificationDeviceTool.cancelToolName,
        PhotosDeviceTool.toolName,
        PhotosDeviceTool.writeToolName,
        PhotosDeviceTool.deleteToolName,
        BluetoothDeviceTool.toolName,
    ]

    static func registerAll(into registry: ToolRegistry) async throws {
        try await ClipboardDeviceTool.register(into: registry)
        try await LocationDeviceTool.register(into: registry)
        try await NotificationDeviceTool.register(into: registry)
        try await PhotosDeviceTool.register(into: registry)
        try await BluetoothDeviceTool.register(into: registry)
    }

    /// 清掉注册表里所有 `device_*` 残留，为重试做准备。
    /// 按前缀扫而不是按名单扫：名单是人维护的，漏一项就会让重试撞
    /// duplicateName 并把整组永久卡在 failed。返回被清掉的名字。
    @discardableResult
    static func clearRegistered(into registry: ToolRegistry) async -> [String] {
        var cleared: [String] = []
        let descriptors = await registry.allDescriptors()
        for descriptor in descriptors where descriptor.name.hasPrefix(namePrefix) {
            if await registry.unregister(name: descriptor.name) {
                cleared.append(descriptor.name)
            }
        }
        return cleared
    }
}
