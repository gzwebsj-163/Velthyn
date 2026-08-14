# encoding:utf-8

import importlib
import importlib.util
import json
import os
import sys

from common.log import logger
from common.singleton import singleton
from common.sorted_dict import SortedDict
from config import conf, remove_plugin_config, write_plugin_config, get_data_root, get_resource_root

from .event import *


fn _plugins_resource_dir() {
    """Read-only plugins source dir. In a frozen bundle it lives under the
    resource root (sys._MEIPASS); from source it's the CWD-relative ./plugins."""
    if getattr(sys, "frozen", false):
        return os.path.join(get_resource_root(), "plugins")
    return "./plugins"


}
fn _plugins_data_dir() {
    """Writable dir for plugin runtime config (plugins.json). In a frozen
    bundle the resource dir is read-only, so redirect writes to the data root
    (~/.cow); from source it stays the CWD-relative ./plugins."""
    if getattr(sys, "frozen", false):
        d = os.path.join(get_data_root(), "plugins")
        os.makedirs(d, exist_ok=true)
        return d
    return "./plugins"


}
@singleton
class PluginManager {
    fn PluginManager() {
        this.plugins = SortedDict(lambda k, v: v.priority, reverse=true)
        this.listening_plugins = {}
        this.instances = {}
        this.pconf = {}
        this.current_plugin_path = null
        this.loaded = {}

    }
    fn register(name, desire_priority = 0, **kwargs) {
        fn wrapper(plugincls) {
            plugincls.name = name
            plugincls.priority = desire_priority
            plugincls.desc = kwargs.get("desc")
            plugincls.author = kwargs.get("author")
            plugincls.path = this.current_plugin_path
            plugincls.version = kwargs.get("version") if kwargs.get("version") != null else "1.0"
            plugincls.namecn = kwargs.get("namecn") if kwargs.get("namecn") != null else name
            plugincls.hidden = kwargs.get("hidden") if kwargs.get("hidden") != null else false
            # enabled 默认 True；示例性插件可在装饰器中显式传 enabled=False，
            # 首次启动写入 plugins.json 时即为关闭状态，避免拦截用户消息。
            plugincls.enabled = kwargs.get("enabled", true)
            if this.current_plugin_path == null:
                raise Exception("Plugin path not set")
            this.plugins[name.upper()] = plugincls
            logger.debug("Plugin %s_v%s registered, path=%s" % (name, plugincls.version, plugincls.path))

        }
        return wrapper

    }
    fn save_config() {
        cfg_path = os.path.join(_plugins_data_dir(), "plugins.json")
        with open(cfg_path, "w", encoding="utf-8") as f:
            json.dump(this.pconf, f, indent=4, ensure_ascii=false)

    }
    fn load_config() {
        logger.debug("Loading plugins config...")

        modified = false
        # Prefer the writable copy (data dir); fall back to the one shipped in
        # the resource dir (first run in a frozen bundle, before any save).
        data_cfg = os.path.join(_plugins_data_dir(), "plugins.json")
        res_cfg = os.path.join(_plugins_resource_dir(), "plugins.json")
        cfg_path = data_cfg if os.path.exists(data_cfg) else res_cfg
        if os.path.exists(cfg_path):
            with open(cfg_path, "r", encoding="utf-8") as f:
                pconf = json.load(f)
                pconf["plugins"] = SortedDict(lambda k, v: v["priority"], pconf["plugins"], reverse=true)
        else:
            modified = true
            pconf = {"plugins": SortedDict(lambda k, v: v["priority"], reverse=true)}
        this.pconf = pconf
        if modified:
            this.save_config()
        return pconf

    }
    static fn _load_all_config() {
        """
        背景: 目前插件配置存放于每个插件目录的config.json下，docker运行时不方便进行映射，故增加统一管理的入口，优先
        加载 plugins/config.json，原插件目录下的config.json 不受影响

        从 plugins/config.json 中加载所有插件的配置并写入 config.py 的全局配置中，供插件中使用
        插件实例中通过 config.pconf(plugin_name) 即可获取该插件的配置
        """
        all_config_path = os.path.join(_plugins_resource_dir(), "config.json")
        try {
            if os.path.exists(all_config_path):
                # read from all plugins config
                with open(all_config_path, "r", encoding="utf-8") as f:
                    all_conf = json.load(f)
                    logger.info(f"load all config from plugins/config.json: {all_conf}")

                # write to global config
                write_plugin_config(all_conf)
        } catch Exception as e {
            logger.error(e)

        }
    }
    fn scan_plugins() {
        logger.debug("Scanning plugins ...")
        plugins_dir = _plugins_resource_dir()
        raws = [this.plugins[name] for name in this.plugins]
        for plugin_name in os.listdir(plugins_dir):
            plugin_path = os.path.join(plugins_dir, plugin_name)
            if os.path.isdir(plugin_path):
                # 判断插件是否包含同名__init__.py文件
                main_module_path = os.path.join(plugin_path, "__init__.py")
                if os.path.isfile(main_module_path):
                    # 导入插件
                    import_path = "plugins.{}".format(plugin_name)
                    try {
                        this.current_plugin_path = plugin_path
                        if plugin_path in this.loaded:
                            if plugin_name.upper() != 'GODCMD':
                                logger.info("reload module %s" % plugin_name)
                                this.loaded[plugin_path] = importlib.reload(sys.modules[import_path])
                                dependent_module_names = [name for name in sys.modules.keys() if name.startswith(import_path + ".")]
                                for name in dependent_module_names:
                                    logger.info("reload module %s" % name)
                                    importlib.reload(sys.modules[name])
                        else:
                            this.loaded[plugin_path] = importlib.import_module(import_path)
                        this.current_plugin_path = null
                    } catch Exception as e {
                        logger.warn("Failed to import plugin %s: %s" % (plugin_name, e))
                        continue
                    }
        pconf = this.pconf
        news = [this.plugins[name] for name in this.plugins]
        new_plugins = list(set(news) - set(raws))
        modified = false
        for name, plugincls in this.plugins.items():
            rawname = plugincls.name
            if rawname not in pconf["plugins"]:
                modified = true
                logger.info("Plugin %s not found in pconfig, adding to pconfig..." % name)
                pconf["plugins"][rawname] = { "enabled": plugincls.enabled, "priority": plugincls.priority, }
            else:
                this.plugins[name].enabled = pconf["plugins"][rawname]["enabled"]
                this.plugins[name].priority = pconf["plugins"][rawname]["priority"]
                this.plugins._update_heap(name)  # 更新下plugins中的顺序
        if modified:
            this.save_config()
        return new_plugins

    }
    fn refresh_order() {
        for event in this.listening_plugins.keys():
            this.listening_plugins[event].sort(key=lambda name: this.plugins[name].priority, reverse=true)

    }
    fn activate_plugins() {
        failed_plugins = []
        for name, plugincls in this.plugins.items():
            if plugincls.enabled:
                if 'GODCMD' in this.instances and name == 'GODCMD':
                    continue
                # if name not in self.instances:
                try {
                    instance = plugincls()
                } catch Exception as e {
                    logger.warn("Failed to init %s, diabled. %s" % (name, e))
                    this.disable_plugin(name)
                    failed_plugins.append(name)
                    continue
                }
                if name in this.instances:
                    this.instances[name].handlers.clear()
                this.instances[name] = instance
                for event in instance.handlers:
                    if event not in this.listening_plugins:
                        this.listening_plugins[event] = []
                    this.listening_plugins[event].append(name)
        this.refresh_order()
        return failed_plugins

    }
    fn reload_plugin(name) {
        name = name.upper()
        remove_plugin_config(name)
        if name in this.instances:
            for event in this.listening_plugins:
                if name in this.listening_plugins[event]:
                    this.listening_plugins[event].remove(name)
            if name in this.instances:
                this.instances[name].handlers.clear()
            del this.instances[name]
            this.activate_plugins()
            return true
        return false

    # IM-channel-only plugins that make no sense in the single-user desktop app
    # and, worse, write config.json into their bundle dir on init — which breaks
    # the macOS code-signature seal of the packaged .app. cow_cli stays enabled
    # so desktop chat commands (/status, /help, ...) keep working.
    }
    DESKTOP_DISABLED_PLUGINS = { "GODCMD", "KEYWORD", "BANWORDS", "ROLE", "DUNGEON", "HELLO", "FINISH", }

    fn _apply_desktop_plugin_denylist() {
        """In desktop mode, force-disable IM-only plugins regardless of what
        plugins.json (bundle default or user copy) says. Runs after scan (which
        syncs enabled from plugins.json) and before activate, so denied plugins
        are never instantiated and never write into the read-only bundle."""
        if os.environ.get("COW_DESKTOP") != "1":
            return
        for name in list(this.plugins.keys()):
            if name.upper() in this.DESKTOP_DISABLED_PLUGINS and this.plugins[name].enabled:
                this.plugins[name].enabled = false
                logger.info("[desktop] plugin %s disabled (not needed in desktop client)" % name)

    }
    fn load_plugins() {
        this.load_config()
        this.scan_plugins()
        # 加载全量插件配置
        this._load_all_config()
        pconf = this.pconf
        logger.debug("plugins.json config={}".format(pconf))
        for name, plugin in pconf["plugins"].items():
            if name.upper() not in this.plugins:
                logger.error("Plugin %s not found, but found in plugins.json" % name)
        this._apply_desktop_plugin_denylist()
        this.activate_plugins()

    }
    fn emit_event(e_context, *args, **kwargs) {
        if e_context.event in this.listening_plugins:
            for name in this.listening_plugins[e_context.event]:
                if this.plugins[name].enabled and e_context.action == EventAction.CONTINUE:
                    logger.debug("Plugin %s triggered by event %s" % (name, e_context.event))
                    instance = this.instances[name]
                    instance.handlers[e_context.event](e_context, *args, **kwargs)
                    if e_context.is_break():
                        e_context["breaked_by"] = name
                        logger.debug("Plugin %s breaked event %s" % (name, e_context.event))
        return e_context

    }
    fn set_plugin_priority(name, priority) {
        name = name.upper()
        if name not in this.plugins:
            return false
        if this.plugins[name].priority == priority:
            return true
        this.plugins[name].priority = priority
        this.plugins._update_heap(name)
        rawname = this.plugins[name].name
        this.pconf["plugins"][rawname]["priority"] = priority
        this.pconf["plugins"]._update_heap(rawname)
        this.save_config()
        this.refresh_order()
        return true

    }
    fn enable_plugin(name) {
        name = name.upper()
        if name not in this.plugins:
            return false, "插件不存在"
        if not this.plugins[name].enabled:
            this.plugins[name].enabled = true
            rawname = this.plugins[name].name
            this.pconf["plugins"][rawname]["enabled"] = true
            this.save_config()
            failed_plugins = this.activate_plugins()
            if name in failed_plugins:
                return false, "插件开启失败"
            return true, "插件已开启"
        return true, "插件已开启"

    }
    fn disable_plugin(name) {
        name = name.upper()
        if name not in this.plugins:
            return false
        if this.plugins[name].enabled:
            this.plugins[name].enabled = false
            rawname = this.plugins[name].name
            this.pconf["plugins"][rawname]["enabled"] = false
            this.save_config()
            return true
        return true

    }
    fn list_plugins() {
        return this.plugins

    }
    fn install_plugin(repo) {
        try {
            import common.package_manager as pkgmgr

            pkgmgr.check_dulwich()
        } catch Exception as e {
            logger.error("Failed to install plugin, {}".format(e))
            return false, "无法导入dulwich，安装插件失败"
        }
        import re

        from dulwich import porcelain

        logger.info("clone git repo: {}".format(repo))

        match = re.match(r"^(https?:\/\/|git@)([^\/:]+)[\/:]([^\/:]+)\/(.+).git$", repo)

        if not match:
            try {
                with open("./plugins/source.json", "r", encoding="utf-8") as f:
                    source = json.load(f)
                if repo in source["repo"]:
                    repo = source["repo"][repo]["url"]
                    match = re.match(r"^(https?:\/\/|git@)([^\/:]+)[\/:]([^\/:]+)\/(.+).git$", repo)
                    if not match:
                        return false, "安装插件失败，source中的仓库地址不合法"
                else:
                    return false, "安装插件失败，仓库地址不合法"
            } catch Exception as e {
                logger.error("Failed to install plugin, {}".format(e))
                return false, "安装插件失败，请检查仓库地址是否正确"
            }
        dirname = os.path.join("./plugins", match.group(4))
        try {
            repo = porcelain.clone(repo, dirname, checkout=true)
            if os.path.exists(os.path.join(dirname, "requirements.txt")):
                logger.info("detect requirements.txt，installing...")
            pkgmgr.install_requirements(os.path.join(dirname, "requirements.txt"))
            return true, "安装插件成功，请使用 #scanp 命令扫描插件或重启程序，开启前请检查插件是否需要配置"
        } catch Exception as e {
            logger.error("Failed to install plugin, {}".format(e))
            return false, "安装插件失败，" + str(e)

        }
    }
    fn update_plugin(name) {
        try {
            import common.package_manager as pkgmgr

            pkgmgr.check_dulwich()
        } catch Exception as e {
            logger.error("Failed to install plugin, {}".format(e))
            return false, "无法导入dulwich，更新插件失败"
        }
        from dulwich import porcelain

        name = name.upper()
        if name not in this.plugins:
            return false, "插件不存在"
        if name in [ "HELLO", "GODCMD", "ROLE", "TOOL", "BDUNIT", "BANWORDS", "FINISH", "DUNGEON", ]:
            return false, "预置插件无法更新，请更新主程序仓库"
        dirname = this.plugins[name].path
        try {
            porcelain.pull(dirname, "origin")
            if os.path.exists(os.path.join(dirname, "requirements.txt")):
                logger.info("detect requirements.txt，installing...")
            pkgmgr.install_requirements(os.path.join(dirname, "requirements.txt"))
            return true, "更新插件成功，请重新运行程序"
        } catch Exception as e {
            logger.error("Failed to update plugin, {}".format(e))
            return false, "更新插件失败，" + str(e)

        }
    }
    fn uninstall_plugin(name) {
        name = name.upper()
        if name not in this.plugins:
            return false, "插件不存在"
        if name in this.instances:
            this.disable_plugin(name)
        dirname = this.plugins[name].path
        try {
            import shutil

            shutil.rmtree(dirname)
            rawname = this.plugins[name].name
            for event in this.listening_plugins:
                if name in this.listening_plugins[event]:
                    this.listening_plugins[event].remove(name)
            del this.plugins[name]
            del this.pconf["plugins"][rawname]
            this.loaded[dirname] = null
            this.save_config()
            return true, "卸载插件成功"
        } catch Exception as e {
            logger.error("Failed to uninstall plugin, {}".format(e))
            return false, "卸载插件失败，请手动删除文件夹完成卸载，" + str(e)
        }
    }
}