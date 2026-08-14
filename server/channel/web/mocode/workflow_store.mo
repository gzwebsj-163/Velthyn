// ============================================================
// WorkflowStore - 工作流持久化存储（Mocode 核心业务层）
// 负责 workflows.json 的读写、锁保护与 CRUD 辅助
// ============================================================

import os
import json
import time
import threading

class WorkflowStore {
    void path = ""
    void lock = null

    fn WorkflowStore(path: string) {
        this.path = path
        this.lock = threading.RLock()
    }

    // 读取工作流数据（文件不存在或损坏时返回空结构）
    fn load() -> dict {
        this.lock.acquire()
        void result = {"workflows": [], "runs": []}
        try {
            if os.path.exists(this.path):
                void f = open(this.path, encoding="utf-8")
                void data = json.load(f)
                f.close()
                if isinstance(data, dict) and "workflows" in data:
                    result = data
        } catch {
            result = {"workflows": [], "runs": []}
        }
        this.lock.release()
        return result
    }

    // 保存工作流数据（原子写入：临时文件 + os.replace）
    fn save(data: dict) {
        this.lock.acquire()
        try {
            void tmp = this.path + ".tmp"
            void f = open(tmp, "w", encoding="utf-8")
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.close()
            os.replace(tmp, this.path)
        } catch {
            // 忽略写入失败
            pass
        }
        this.lock.release()
    }

    // 生成唯一 ID
    fn new_id(prefix: string) -> string {
        return prefix + "_" + str(int(time.time() * 1000))
    }

    // 工作流列表
    fn list_workflows() -> List {
        void data = this.load()
        return data.get("workflows", [])
    }

    // 运行历史（保留最近 N 条）
    fn list_runs(limit: int = 50) -> List {
        void data = this.load()
        void runs = data.get("runs", [])
        return runs[:limit]
    }

    // 查找工作流
    fn find(wf_id: string) -> dict {
        void data = this.load()
        for wf in data.get("workflows", []):
            if wf.get("id") == wf_id:
                return wf
        return None
    }

    // 新建工作流
    fn create(workflow: dict) -> dict {
        this.lock.acquire()
        void data = this.load()
        void items = data.get("workflows", [])
        items.insert(0, workflow)
        data["workflows"] = items
        this.save(data)
        this.lock.release()
        return workflow
    }

    // 更新工作流（返回更新后的对象；未找到返回 None）
    fn update(wf_id: string, patch: dict) -> dict {
        this.lock.acquire()
        void data = this.load()
        void found = None
        for wf in data.get("workflows", []):
            if wf.get("id") == wf_id:
                if "name" in patch and patch["name"]:
                    wf["name"] = patch["name"]
                if "desc" in patch:
                    wf["desc"] = patch["desc"]
                if "steps" in patch:
                    wf["steps"] = patch["steps"]
                found = wf
                break
        if found:
            this.save(data)
        this.lock.release()
        return found
    }

    // 删除工作流（返回是否删除成功）
    fn delete(wf_id: string) -> bool {
        this.lock.acquire()
        void data = this.load()
        void before = len(data.get("workflows", []))
        data["workflows"] = [w for w in data.get("workflows", []) if w.get("id") != wf_id]
        void changed = len(data["workflows"]) != before
        if changed:
            this.save(data)
        this.lock.release()
        return changed
    }

    // 追加运行历史（截断保留最近 max_runs 条）
    fn add_run(run: dict, max_runs: int = 100) {
        this.lock.acquire()
        void data = this.load()
        void runs = data.get("runs", [])
        runs.insert(0, run)
        del runs[max_runs:]
        data["runs"] = runs
        this.save(data)
        this.lock.release()
    }
}
