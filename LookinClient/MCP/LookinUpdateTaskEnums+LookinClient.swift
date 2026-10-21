//
//  LookinUpdateTaskEnums+LookinClient.swift
//  Lookin
//
//  Created by huangj on 2026/10/21.
//
//  LookinShared 里的任务枚举以 NS_ENUM 原始值定义但没有暴露 Swift 命名成员，
//  MCP 服务等调用方此前只能写 LookinStaticAsyncUpdateTaskType(rawValue: 1)! 这样的魔数。
//  这里给出具名常量，作为客户端侧的唯一取值入口。
//

import Foundation

extension LookinStaticAsyncUpdateTaskType {
    /// 仅拉取属性，不拉取截图
    static let lk_noScreenshot = LookinStaticAsyncUpdateTaskType(rawValue: 0)!
    /// 单图层截图
    static let lk_soloScreenshot = LookinStaticAsyncUpdateTaskType(rawValue: 1)!
    /// 分组（含子图层）截图
    static let lk_groupScreenshot = LookinStaticAsyncUpdateTaskType(rawValue: 2)!
}

extension LookinDetailUpdateTaskAttrRequest {
    /// 不需要属性
    static let lk_notNeed = LookinDetailUpdateTaskAttrRequest(rawValue: 0)!
    /// 需要属性
    static let lk_need = LookinDetailUpdateTaskAttrRequest(rawValue: 1)!
    /// 明确不需要（已持有）
    static let lk_notNeedExplicit = LookinDetailUpdateTaskAttrRequest(rawValue: 2)!
}
