import Foundation

extension StateRuntime {
    func validateTaskPage(_ page: JSON, in state: JSON) throws {
        guard let space = TaskSpace(rawValue: page["id"].string), space.isCustom else {
            throw RuntimeError("invalid_task_page", "自定义任务页 ID 无效。")
        }
        let title = page["title"].trimmed
        guard !title.isEmpty, title.count <= 60 else {
            throw RuntimeError("invalid_task_page", "任务页名称需要 1–60 个字符。")
        }
        let reserved = ["今日", "日程", "板块", "任务", "私人任务", "工作室台账", "任务关系图", "专注画布", "拼图", "归档与恢复"]
        let names = reserved + state["taskPages"].array.filter { $0["id"] != page["id"] }.map { $0["title"].trimmed }
        guard !names.contains(where: { $0.localizedCaseInsensitiveCompare(title) == .orderedSame }) else {
            throw RuntimeError("duplicate_task_page", "已存在同名页面，请换一个名称。")
        }
    }

    func validateTaskPages(_ state: JSON) throws {
        let pages = state["taskPages"].array
        var ids = Set<String>()
        for page in pages {
            guard ids.insert(page["id"].string).inserted else { throw RuntimeError("duplicate_id", "任务页 ID 重复。") }
            try validateTaskPage(page, in: state)
        }
        for task in state["tasks"].records where task.taskSpace.isCustom && !ids.contains(task.taskSpace.rawValue) {
            throw RuntimeError("task_page_not_found", "任务所属页面不存在，不能保存。")
        }
    }
}
