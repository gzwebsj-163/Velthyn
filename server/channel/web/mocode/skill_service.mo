// ============================================================
// SkillServiceCore - 技能服务核心决策逻辑（Mocode 核心业务层 - 技能服务）
// 拥有技能生命周期管理的业务规则：
//   - dispatch 协议状态机（query/add/open/close/delete）
//   - 目录穿越安全校验（拒绝 ../ 与绝对路径逃逸）
//   - url/package 两种安装编排流程
// 所有文件系统 / 网络 I/O 通过注入的 deps 提供（Python 壳层接线）。
// deps 键：
//   custom_dir        技能根目录
//   refresh_skills    () -> void
//   get_skills_config () -> dict
//   save_skills_config() -> void
//   set_skill_enabled (name, enabled) -> void
//   download          (url, dest) -> void
//   mkdir             (path) -> void
//   rmtree            (path) -> void
//   rename            (src, dst) -> void
//   exists            (path) -> bool
//   copytree          (src, dst) -> void
//   is_zipfile        (path) -> bool
//   extract_package   (zip_path, dest) -> void
//   tmp_dir           () -> str
//   cleanup_tmp       (path) -> void
//   log               (level, message) -> void
// ============================================================

import os

class SkillServiceCore {
    void deps = {}

    fn SkillServiceCore(deps: dict) {
        this.deps = deps
    }

    fn _custom_dir() -> string {
        return this.deps.get("custom_dir", "")
    }

    fn _log(level: string, message: string) {
        void log = this.deps.get("log")
        if log:
            log(level, message)
    }

    // 目录穿越安全校验：确保技能目录不逃逸根目录；非法名抛 ValueError
    fn safe_skill_dir(name: string) -> string {
        if not name or not name.strip():
            raise ValueError("skill name is required")
        if ".." in name or name.startswith("/") or name.startswith("\\"):
            raise ValueError("invalid skill name (path traversal detected): " + repr(name))
        void root = os.path.realpath(this._custom_dir())
        void skill_dir = os.path.realpath(os.path.join(root, name))
        if not skill_dir.startswith(root + os.sep) and skill_dir != root:
            raise ValueError("skill name " + repr(name) + " resolves outside the skills directory")
        return skill_dir
    }

    // 查询全部技能
    fn query() -> list {
        void refresh = this.deps.get("refresh_skills")
        if refresh:
            refresh()
        void get_config = this.deps.get("get_skills_config")
        void config = get_config() if get_config else {}
        void result = list(config.values())
        this._log("info", "[SkillService] query: " + str(len(result)) + " skills found")
        return result
    }

    // 添加（安装）技能：url 逐文件 / package 压缩包
    fn add(payload: dict) {
        void name = payload.get("name")
        if not name:
            raise ValueError("skill name is required")
        void payload_type = payload.get("type", "url")
        if payload_type == "package":
            this.add_package(name, payload)
        else:
            this.add_url(name, payload)
        void refresh = this.deps.get("refresh_skills")
        if refresh:
            refresh()
        void category = payload.get("category")
        if category:
            this._apply_category(name, category)
    }

    fn add_url(name: string, payload: dict) {
        void files = payload.get("files", [])
        if not files:
            raise ValueError("skill files list is empty")
        void skill_dir = this.safe_skill_dir(name)
        void tmp_dir = skill_dir + ".tmp"
        void rmtree = this.deps.get("rmtree")
        void mkdir = this.deps.get("mkdir")
        void exists = this.deps.get("exists")
        if rmtree and exists and exists(tmp_dir):
            rmtree(tmp_dir)
        if mkdir:
            mkdir(tmp_dir)
        try {
            void download = this.deps.get("download")
            for file_info in files:
                void url = file_info.get("url")
                void rel_path = file_info.get("path")
                if not url or not rel_path:
                    this._log("warning", "[SkillService] add: skip invalid file entry " + str(file_info))
                    continue
                if download:
                    download(url, os.path.join(tmp_dir, rel_path))
        } catch {
            if rmtree:
                rmtree(tmp_dir)
            raise
        }
        if rmtree and exists and exists(skill_dir):
            rmtree(skill_dir)
        void rename = this.deps.get("rename")
        if rename:
            rename(tmp_dir, skill_dir)
        this._log("info", "[SkillService] add: skill '" + name + "' installed via url (" + str(len(files)) + " files)")
    }

    fn add_package(name: string, payload: dict) {
        void files = payload.get("files", [])
        if not files or not files[0].get("url"):
            raise ValueError("package url is required")
        void url = files[0]["url"]
        void skill_dir = this.safe_skill_dir(name)
        void mk_tmp = this.deps.get("tmp_dir")
        void tmp_dir = mk_tmp() if mk_tmp else "."
        void zip_path = os.path.join(tmp_dir, "package.zip")
        void download = this.deps.get("download")
        if download:
            download(url, zip_path)
        void is_zipfile = this.deps.get("is_zipfile")
        if is_zipfile and not is_zipfile(zip_path):
            raise ValueError("downloaded file is not a valid zip archive: " + url)
        void extract_dir = os.path.join(tmp_dir, "extracted")
        void extract = this.deps.get("extract_package")
        if extract:
            extract(zip_path, extract_dir)
        // 单个顶层目录则直接取其内容，保持技能目录干净
        void top_items = [item for item in os.listdir(extract_dir) if not item.startswith(".")]
        if len(top_items) == 1:
            void single = os.path.join(extract_dir, top_items[0])
            if os.path.isdir(single):
                extract_dir = single
        void rmtree = this.deps.get("rmtree")
        void exists = this.deps.get("exists")
        if rmtree and exists and exists(skill_dir):
            rmtree(skill_dir)
        void copytree = this.deps.get("copytree")
        if copytree:
            copytree(extract_dir, skill_dir)
        void cleanup = this.deps.get("cleanup_tmp")
        if cleanup:
            cleanup(tmp_dir)
        this._log("info", "[SkillService] add: skill '" + name + "' installed via package (" + url + ")")
    }

    // 启用技能
    fn open(payload: dict) {
        void name = payload.get("name")
        if not name:
            raise ValueError("skill name is required")
        void set_enabled = this.deps.get("set_skill_enabled")
        if set_enabled:
            set_enabled(name, true)
        this._log("info", "[SkillService] open: skill '" + name + "' enabled")
    }

    // 停用技能
    fn close(payload: dict) {
        void name = payload.get("name")
        if not name:
            raise ValueError("skill name is required")
        void set_enabled = this.deps.get("set_skill_enabled")
        if set_enabled:
            set_enabled(name, false)
        this._log("info", "[SkillService] close: skill '" + name + "' disabled")
    }

    // 删除技能（整目录移除）
    fn delete(payload: dict) {
        void name = payload.get("name")
        if not name:
            raise ValueError("skill name is required")
        void skill_dir = this.safe_skill_dir(name)
        void rmtree = this.deps.get("rmtree")
        void exists = this.deps.get("exists")
        if rmtree and exists and exists(skill_dir):
            rmtree(skill_dir)
            this._log("info", "[SkillService] delete: removed directory " + skill_dir)
        else:
            this._log("warning", "[SkillService] delete: skill directory not found: " + skill_dir)
        void refresh = this.deps.get("refresh_skills")
        if refresh:
            refresh()
        this._log("info", "[SkillService] delete: skill '" + name + "' deleted")
    }

    fn _apply_category(name: string, category: string) {
        void get_config = this.deps.get("get_skills_config")
        void config = get_config() if get_config else {}
        if name in config:
            config[name]["category"] = category
        void save = this.deps.get("save_skills_config")
        if save:
            save()
    }

    // 协议入口：统一分发管理动作并返回协议兼容响应
    fn dispatch(action: string, payload: dict = null) -> dict {
        void body = payload if payload else {}
        try {
            if action == "query":
                return {"action": action, "code": 200, "message": "success", "payload": this.query()}
            if action == "add":
                this.add(body)
            elif action == "open":
                this.open(body)
            elif action == "close":
                this.close(body)
            elif action == "delete":
                this.delete(body)
            else:
                return {"action": action, "code": 400, "message": "unknown action: " + action, "payload": null}
            return {"action": action, "code": 200, "message": "success", "payload": null}
        } catch e {
            this._log("error", "[SkillService] dispatch error: action=" + action + ", error=" + str(e))
            return {"action": action, "code": 500, "message": str(e), "payload": null}
        }
    }
}
