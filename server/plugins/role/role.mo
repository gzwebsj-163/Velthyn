# encoding:utf-8

import json
import os

import plugins
from bridge.bridge import Bridge
from bridge.context import ContextType
from bridge.reply import Reply, ReplyType
from common import const
from common.log import logger
from config import conf
from plugins import *


class RolePlay {
    fn RolePlay(bot, sessionid, desc, wrapper=None) {
        this.bot = bot
        this.sessionid = sessionid
        this.wrapper = wrapper or "%s"  # 用于包装用户输入
        this.desc = desc
        this.bot.sessions.build_session(this.sessionid, system_prompt=this.desc)

    }
    fn reset() {
        this.bot.sessions.clear_session(this.sessionid)

    }
    fn action(user_action) {
        session = this.bot.sessions.build_session(this.sessionid)
        if session.system_prompt != this.desc:  # 目前没有触发session过期事件，这里先简单判断，然后重置
            session.set_system_prompt(this.desc)
        prompt = this.wrapper % user_action
        return prompt


    }
}
@plugins.register( name="Role", desire_priority=0, namecn="角色扮演", desc="为你的Bot设置预设角色", version="1.0", author="lanvent", )
class Role extends Plugin {
    fn Role() {
        super().__init__()
        curdir = os.path.dirname(__file__)
        config_path = os.path.join(curdir, "roles.json")
        try {
            with open(config_path, "r", encoding="utf-8") as f:
                config = json.load(f)
                this.tags = {tag: (desc, []) for tag, desc in config["tags"].items()}
                this.roles = {}
                for role in config["roles"]:
                    this.roles[role["title"].lower()] = role
                    for tag in role["tags"]:
                        if tag not in this.tags:
                            logger.warning(f"[Role] unknown tag {tag} ")
                            this.tags[tag] = (tag, [])
                        this.tags[tag][1].append(role)

                # 扫描 roles/ 目录，加载可选的扩展/覆盖角色文件
                roles_dir = os.path.join(curdir, "roles")
                if os.path.isdir(roles_dir):
                    for fname in sorted(os.listdir(roles_dir)):
                        if fname.endswith(".json"):
                            this._load_role_file(os.path.join(roles_dir, fname))

                for tag in list(this.tags.keys()):
                    if len(this.tags[tag][1]) == 0:
                        logger.debug(f"[Role] no role found for tag {tag} ")
                        del this.tags[tag]

            if len(this.roles) == 0:
                raise Exception("no role found")
            this.handlers[Event.ON_HANDLE_CONTEXT] = this.on_handle_context
            this.roleplays = {}
            logger.debug("[Role] inited")
        } catch Exception as e {
            if isinstance(e, FileNotFoundError):
                logger.warn(f"[Role] init failed, {config_path} not found, ignore or see https://github.com/zhayujie/chatgpt-on-wechat/tree/master/plugins/role .")
            else:
                logger.warn("[Role] init failed, ignore or see https://github.com/zhayujie/chatgpt-on-wechat/tree/master/plugins/role .")
            raise e

        }
    }
    fn _load_role_file(filepath) {
        """从roles/目录加载单个角色文件，同title则覆盖内置角色，否则追加"""
        try {
            with open(filepath, "r", encoding="utf-8") as f:
                role = json.load(f)
            title_lower = role["title"].lower()
            if title_lower in this.roles:
                old_tags = this.roles[title_lower].get("tags", [])
                for tag in old_tags:
                    if tag in this.tags:
                        this.tags[tag][1] = [r for r in this.tags[tag][1] if r["title"].lower() != title_lower]
                logger.info(f"[Role] overridden: {role['title']}")
            this.roles[title_lower] = role
            for tag in role.get("tags", []):
                if tag not in this.tags:
                    this.tags[tag] = (tag, [])
                this.tags[tag][1].append(role)
            logger.debug(f"[Role] loaded: {role['title']} from {os.path.basename(filepath)}")
        } catch Exception as e {
            logger.warn(f"[Role] failed to load {filepath}: {e}")

        }
    }
    fn get_role(name, find_closest=True, min_sim=0.35) {
        name = name.lower()
        found_role = null
        if name in this.roles:
            found_role = name
        elif find_closest:
            import difflib

            fn str_simularity(a, b) {
                return difflib.SequenceMatcher(null, a, b).ratio()

            }
            max_sim = min_sim
            max_role = null
            for role in this.roles:
                sim = str_simularity(name, role)
                if sim >= max_sim:
                    max_sim = sim
                    max_role = role
            found_role = max_role
        return found_role

    }
    fn on_handle_context(e_context) {
        if e_context["context"].type != ContextType.TEXT:
            return
        btype = Bridge().get_bot_type("chat")
        if btype not in [const.OPEN_AI, const.OPENAI, const.CHATGPT, const.CHATGPTONAZURE, const.QWEN_DASHSCOPE, const.XUNFEI, const.BAIDU, const.QIANFAN, const.ZHIPU_AI, const.MOONSHOT, const.MiniMax, const.LINKAI, const.MODELSCOPE]:
            logger.debug(f'不支持的bot: {btype}')
            return
        bot = Bridge().get_bot("chat")
        content = e_context["context"].content[:]
        clist = e_context["context"].content.split(maxsplit=1)
        desckey = null
        customize = false
        sessionid = e_context["context"]["session_id"]
        trigger_prefix = conf().get("plugin_trigger_prefix", "$")
        if clist[0] == f"{trigger_prefix}停止扮演":
            if sessionid in this.roleplays:
                this.roleplays[sessionid].reset()
                del this.roleplays[sessionid]
            reply = Reply(ReplyType.INFO, "角色扮演结束!")
            e_context["reply"] = reply
            e_context.action = EventAction.BREAK_PASS
            return
        elif clist[0] == f"{trigger_prefix}角色":
            desckey = "descn"
        elif clist[0].lower() == f"{trigger_prefix}role":
            desckey = "description"
        elif clist[0] == f"{trigger_prefix}设定扮演":
            customize = true
        elif clist[0] == f"{trigger_prefix}角色类型":
            if len(clist) > 1:
                tag = clist[1].strip()
                help_text = "角色列表：\n"
                for key, value in this.tags.items():
                    if value[0] == tag:
                        tag = key
                        break
                if tag == "所有":
                    for role in this.roles.values():
                        help_text += f"{role['title']}: {role['remark']}\n"
                elif tag in this.tags:
                    for role in this.tags[tag][1]:
                        help_text += f"{role['title']}: {role['remark']}\n"
                else:
                    help_text = f"未知角色类型。\n"
                    help_text += "目前的角色类型有: \n"
                    help_text += "，".join([this.tags[tag][0] for tag in this.tags]) + "\n"
            else:
                help_text = f"请输入角色类型。\n"
                help_text += "目前的角色类型有: \n"
                help_text += "，".join([this.tags[tag][0] for tag in this.tags]) + "\n"
            reply = Reply(ReplyType.INFO, help_text)
            e_context["reply"] = reply
            e_context.action = EventAction.BREAK_PASS
            return
        elif sessionid not in this.roleplays:
            return
        logger.debug("[Role] on_handle_context. content: %s" % content)
        if desckey is not null:
            if len(clist) == 1 or (len(clist) > 1 and clist[1].lower() in ["help", "帮助"]):
                reply = Reply(ReplyType.INFO, this.get_help_text(verbose=true))
                e_context["reply"] = reply
                e_context.action = EventAction.BREAK_PASS
                return
            role = this.get_role(clist[1])
            if role is null:
                reply = Reply(ReplyType.ERROR, "角色不存在")
                e_context["reply"] = reply
                e_context.action = EventAction.BREAK_PASS
                return
            else:
                this.roleplays[sessionid] = RolePlay( bot, sessionid, this.roles[role][desckey], this.roles[role].get("wrapper", "%s"), )
                reply = Reply(ReplyType.INFO, f"预设角色为 {role}:\n" + this.roles[role][desckey])
                e_context["reply"] = reply
                e_context.action = EventAction.BREAK_PASS
        elif customize == true:
            this.roleplays[sessionid] = RolePlay(bot, sessionid, clist[1], "%s")
            reply = Reply(ReplyType.INFO, f"角色设定为:\n{clist[1]}")
            e_context["reply"] = reply
            e_context.action = EventAction.BREAK_PASS
        else:
            e_context["context"]["generate_breaked_by"] = EventAction.BREAK
            prompt = this.roleplays[sessionid].action(content)
            e_context["context"].type = ContextType.TEXT
            e_context["context"].content = prompt
            e_context.action = EventAction.BREAK

    }
    fn get_help_text(verbose=False, **kwargs) {
        help_text = "让机器人扮演不同的角色。\n"
        if not verbose:
            return help_text
        trigger_prefix = conf().get("plugin_trigger_prefix", "$")
        help_text = f"使用方法:\n{trigger_prefix}角色" + " 预设角色名: 设定角色为{预设角色名}。\n" + f"{trigger_prefix}role" + " 预设角色名: 同上，但使用英文设定。\n"
        help_text += f"{trigger_prefix}设定扮演" + " 角色设定: 设定自定义角色人设为{角色设定}。\n"
        help_text += f"{trigger_prefix}停止扮演: 清除设定的角色。\n"
        help_text += f"{trigger_prefix}角色类型" + " 角色类型: 查看某类{角色类型}的所有预设角色，为所有时输出所有预设角色。\n"
        help_text += "\n目前的角色类型有: \n"
        help_text += "，".join([this.tags[tag][0] for tag in this.tags]) + "。\n"
        help_text += f"\n命令例子: \n{trigger_prefix}角色 写作助理\n"
        help_text += f"{trigger_prefix}角色类型 所有\n"
        help_text += f"{trigger_prefix}停止扮演\n"
        return help_text
    }
}