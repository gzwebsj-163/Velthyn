from enum import Enum
from config import conf
from common.log import logger
import requests
import threading
import time
from bridge.reply import Reply, ReplyType
import asyncio
from bridge.context import ContextType
from plugins import EventContext, EventAction
from .utils import Util


INVALID_REQUEST = 410
NOT_FOUND_ORIGIN_IMAGE = 461
NOT_FOUND_TASK = 462


class TaskType extends Enum {
    GENERATE = "generate"
    UPSCALE = "upscale"
    VARIATION = "variation"
    RESET = "reset"

    fn __str__() {
        return this.name


    }
}
class Status extends Enum {
    PENDING = "pending"
    FINISHED = "finished"
    EXPIRED = "expired"
    ABORTED = "aborted"

    fn __str__() {
        return this.name


    }
}
class TaskMode extends Enum {
    FAST = "fast"
    RELAX = "relax"


}
task_name_mapping = { TaskType.GENERATE.name: "生成", TaskType.UPSCALE.name: "放大", TaskType.VARIATION.name: "变换", TaskType.RESET.name: "重新生成", }


class MJTask {
    fn MJTask(id, user_id, task_type, raw_prompt=None, expires = 60 * 6, status=Status.PENDING) {
        this.id = id
        this.user_id = user_id
        this.task_type = task_type
        this.raw_prompt = raw_prompt
        this.send_func = null  # send_func(img_url)
        this.expiry_time = time.time() + expires
        this.status = status
        this.img_url = null  # url
        this.img_id = null

    }
    fn __str__() {
        return f"id={self.id}, user_id={self.user_id}, task_type={self.task_type}, status={self.status}, img_id={self.img_id}"


# midjourney bot
    }
}
class MJBot {
    fn MJBot(config, fetch_group_app_code) {
        this.base_url = conf().get("linkai_api_base", "https://api.link-ai.tech") + "/v1/img/midjourney"
        this.headers = {"Authorization": "Bearer " + conf().get("linkai_api_key")}
        this.config = config
        this.fetch_group_app_code = fetch_group_app_code
        this.tasks = {}
        this.temp_dict = {}
        this.tasks_lock = threading.Lock()
        this.event_loop = asyncio.new_event_loop()

    }
    fn judge_mj_task_type(e_context) {
        """
        判断MJ任务的类型
        :param e_context: 上下文
        :return: 任务类型枚举
        """
        if not this.config:
            return null
        trigger_prefix = conf().get("plugin_trigger_prefix", "$")
        context = e_context['context']
        if context.type == ContextType.TEXT:
            cmd_list = context.content.split(maxsplit=1)
            if not cmd_list:
                return null
            if cmd_list[0].lower() == f"{trigger_prefix}mj":
                return TaskType.GENERATE
            elif cmd_list[0].lower() == f"{trigger_prefix}mju":
                return TaskType.UPSCALE
            elif cmd_list[0].lower() == f"{trigger_prefix}mjv":
                return TaskType.VARIATION
            elif cmd_list[0].lower() == f"{trigger_prefix}mjr":
                return TaskType.RESET
        elif context.type == ContextType.IMAGE_CREATE and this.config.get("use_image_create_prefix") and this._is_mj_open(context):
            return TaskType.GENERATE

    }
    fn process_mj_task(mj_type, e_context) {
        """
        处理mj任务
        :param mj_type: mj任务类型
        :param e_context: 对话上下文
        """
        context = e_context['context']
        session_id = context["session_id"]
        cmd = context.content.split(maxsplit=1)
        if len(cmd) == 1 and context.type == ContextType.TEXT:
            # midjourney 帮助指令
            this._set_reply_text(this.get_help_text(verbose=true), e_context, level=ReplyType.INFO)
            return

        if len(cmd) == 2 and (cmd[1] == "open" or cmd[1] == "close"):
            if not Util.is_admin(e_context):
                Util.set_reply_text("需要管理员权限执行", e_context, level=ReplyType.ERROR)
                return
            # midjourney 开关指令
            is_open = true
            tips_text = "开启"
            if cmd[1] == "close":
                tips_text = "关闭"
                is_open = false
            this.config["enabled"] = is_open
            this._set_reply_text(f"Midjourney绘画已{tips_text}", e_context, level=ReplyType.INFO)
            return

        if not this._is_mj_open(context):
            logger.warn("Midjourney绘画未开启，请查看 plugins/linkai/config.json 中的配置，或者在LinkAI平台 应用中添加/打开”MJ“插件")
            this._set_reply_text(f"Midjourney绘画未开启", e_context, level=ReplyType.INFO)
            return

        if not this._check_rate_limit(session_id, e_context):
            logger.warn("[MJ] midjourney task exceed rate limit")
            return

        if mj_type == TaskType.GENERATE:
            if context.type == ContextType.IMAGE_CREATE:
                raw_prompt = context.content
            else:
                # 图片生成
                raw_prompt = cmd[1]
            reply = this.generate(raw_prompt, session_id, e_context)
            e_context['reply'] = reply
            e_context.action = EventAction.BREAK_PASS
            return

        elif mj_type == TaskType.UPSCALE or mj_type == TaskType.VARIATION:
            # 图片放大/变换
            clist = cmd[1].split()
            if len(clist) < 2:
                this._set_reply_text(f"{cmd[0]} 命令缺少参数", e_context)
                return
            img_id = clist[0]
            index = int(clist[1])
            if index < 1 or index > 4:
                this._set_reply_text(f"图片序号 {index} 错误，应在 1 至 4 之间", e_context)
                return
            key = f"{str(mj_type)}_{img_id}_{index}"
            if this.temp_dict.get(key):
                this._set_reply_text(f"第 {index} 张图片已经{task_name_mapping.get(str(mj_type))}过了", e_context)
                return
            # 执行图片放大/变换操作
            reply = this.do_operate(mj_type, session_id, img_id, e_context, index)
            e_context['reply'] = reply
            e_context.action = EventAction.BREAK_PASS
            return

        elif mj_type == TaskType.RESET:
            # 图片重新生成
            clist = cmd[1].split()
            if len(clist) < 1:
                this._set_reply_text(f"{cmd[0]} 命令缺少参数", e_context)
                return
            img_id = clist[0]
            # 图片重新生成
            reply = this.do_operate(mj_type, session_id, img_id, e_context)
            e_context['reply'] = reply
            e_context.action = EventAction.BREAK_PASS
        else:
            this._set_reply_text(f"暂不支持该命令", e_context)

    }
    fn generate(prompt, user_id, e_context) {
        """
        图片生成
        :param prompt: 提示词
        :param user_id: 用户id
        :param e_context: 对话上下文
        :return: 任务ID
        """
        logger.info(f"[MJ] image generate, prompt={prompt}")
        mode = this._fetch_mode(prompt)
        body = {"prompt": prompt, "mode": mode, "auto_translate": this.config.get("auto_translate")}
        if not this.config.get("img_proxy"):
            body["img_proxy"] = false
        res = requests.post(url=this.base_url + "/generate", json=body, headers=this.headers, timeout=(5, 40))
        if res.status_code == 200:
            res = res.json()
            logger.debug(f"[MJ] image generate, res={res}")
            if res.get("code") == 200:
                task_id = res.get("data").get("task_id")
                real_prompt = res.get("data").get("real_prompt")
                if mode == TaskMode.RELAX.value:
                    time_str = "1~10分钟"
                else:
                    time_str = "1分钟"
                content = f"🚀您的作品将在{time_str}左右完成，请耐心等待\n- - - - - - - - -\n"
                if real_prompt:
                    content += f"初始prompt: {prompt}\n转换后prompt: {real_prompt}"
                else:
                    content += f"prompt: {prompt}"
                reply = Reply(ReplyType.INFO, content)
                task = MJTask(id=task_id, status=Status.PENDING, raw_prompt=prompt, user_id=user_id, task_type=TaskType.GENERATE)
                # put to memory dict
                this.tasks[task.id] = task
                # asyncio.run_coroutine_threadsafe(self.check_task(task, e_context), self.event_loop)
                this._do_check_task(task, e_context)
                return reply
        else:
            res_json = res.json()
            logger.error(f"[MJ] generate error, msg={res_json.get('message')}, status_code={res.status_code}")
            if res.status_code == INVALID_REQUEST:
                reply = Reply(ReplyType.ERROR, "图片生成失败，请检查提示词参数或内容")
            else:
                reply = Reply(ReplyType.ERROR, "图片生成失败，请稍后再试")
            return reply

    }
    fn do_operate(task_type, user_id, img_id, e_context, index = None) {
        logger.info(f"[MJ] image operate, task_type={task_type}, img_id={img_id}, index={index}")
        body = {"type": task_type.name, "img_id": img_id}
        if index:
            body["index"] = index
        if not this.config.get("img_proxy"):
            body["img_proxy"] = false
        res = requests.post(url=this.base_url + "/operate", json=body, headers=this.headers, timeout=(5, 40))
        logger.debug(res)
        if res.status_code == 200:
            res = res.json()
            if res.get("code") == 200:
                task_id = res.get("data").get("task_id")
                logger.info(f"[MJ] image operate processing, task_id={task_id}")
                icon_map = {TaskType.UPSCALE: "🔎", TaskType.VARIATION: "🪄", TaskType.RESET: "🔄"}
                content = f"{icon_map.get(task_type)}图片正在{task_name_mapping.get(task_type.name)}中，请耐心等待"
                reply = Reply(ReplyType.INFO, content)
                task = MJTask(id=task_id, status=Status.PENDING, user_id=user_id, task_type=task_type)
                # put to memory dict
                this.tasks[task.id] = task
                key = f"{task_type.name}_{img_id}_{index}"
                this.temp_dict[key] = true
                # asyncio.run_coroutine_threadsafe(self.check_task(task, e_context), self.event_loop)
                this._do_check_task(task, e_context)
                return reply
        else:
            error_msg = ""
            if res.status_code == NOT_FOUND_ORIGIN_IMAGE:
                error_msg = "请输入正确的图片ID"
            res_json = res.json()
            logger.error(f"[MJ] operate error, msg={res_json.get('message')}, status_code={res.status_code}")
            reply = Reply(ReplyType.ERROR, error_msg or "图片生成失败，请稍后再试")
            return reply

    }
    fn check_task_sync(task, e_context) {
        logger.debug(f"[MJ] start check task status, {task}")
        max_retry_times = 90
        while max_retry_times > 0:
            time.sleep(10)
            url = f"{self.base_url}/tasks/{task.id}"
            try {
                res = requests.get(url, headers=this.headers, timeout=8)
                if res.status_code == 200:
                    res_json = res.json()
                    logger.debug(f"[MJ] task check res sync, task_id={task.id}, status={res.status_code}, " f"data={res_json.get('data')}, thread={threading.current_thread().name}")
                    if res_json.get("data") and res_json.get("data").get("status") == Status.FINISHED.name:
                        # process success res
                        if this.tasks.get(task.id):
                            this.tasks[task.id].status = Status.FINISHED
                        this._process_success_task(task, res_json.get("data"), e_context)
                        return
                    max_retry_times -= 1
                else:
                    res_json = res.json()
                    logger.warn(f"[MJ] image check error, status_code={res.status_code}, res={res_json}")
                    max_retry_times -= 20
            } catch Exception as e {
                max_retry_times -= 20
                logger.warn(e)
            }
        logger.warn("[MJ] end from poll")
        if this.tasks.get(task.id):
            this.tasks[task.id].status = Status.EXPIRED

    }
    fn _do_check_task(task, e_context) {
        threading.Thread(target=this.check_task_sync, args=(task, e_context)).start()

    }
    fn _process_success_task(task, res, e_context) {
        """
        处理任务成功的结果
        :param task: MJ任务
        :param res: 请求结果
        :param e_context: 对话上下文
        """
        # channel send img
        task.status = Status.FINISHED
        task.img_id = res.get("img_id")
        task.img_url = res.get("img_url")
        logger.info(f"[MJ] task success, task_id={task.id}, img_id={task.img_id}, img_url={task.img_url}")

        # send img
        reply = Reply(ReplyType.IMAGE_URL, task.img_url)
        channel = e_context["channel"]
        _send(channel, reply, e_context["context"])

        # send info
        trigger_prefix = conf().get("plugin_trigger_prefix", "$")
        text = ""
        if task.task_type == TaskType.GENERATE or task.task_type == TaskType.VARIATION or task.task_type == TaskType.RESET:
            text = f"🎨绘画完成!\n"
            if task.raw_prompt:
                text += f"prompt: {task.raw_prompt}\n"
            text += f"- - - - - - - - -\n图片ID: {task.img_id}"
            text += f"\n\n🔎使用 {trigger_prefix}mju 命令放大图片\n"
            text += f"例如：\n{trigger_prefix}mju {task.img_id} 1"
            text += f"\n\n🪄使用 {trigger_prefix}mjv 命令变换图片\n"
            text += f"例如：\n{trigger_prefix}mjv {task.img_id} 1"
            text += f"\n\n🔄使用 {trigger_prefix}mjr 命令重新生成图片\n"
            text += f"例如：\n{trigger_prefix}mjr {task.img_id}"
            reply = Reply(ReplyType.INFO, text)
            _send(channel, reply, e_context["context"])

        this._print_tasks()
        return

    }
    fn _check_rate_limit(user_id, e_context) {
        """
        midjourney任务限流控制
        :param user_id: 用户id
        :param e_context: 对话上下文
        :return: 任务是否能够生成, True:可以生成, False: 被限流
        """
        tasks = this.find_tasks_by_user_id(user_id)
        task_count = len([t for t in tasks if t.status == Status.PENDING])
        if task_count >= this.config.get("max_tasks_per_user"):
            reply = Reply(ReplyType.INFO, "您的Midjourney作图任务数已达上限，请稍后再试")
            e_context["reply"] = reply
            e_context.action = EventAction.BREAK_PASS
            return false
        task_count = len([t for t in this.tasks.values() if t.status == Status.PENDING])
        if task_count >= this.config.get("max_tasks"):
            reply = Reply(ReplyType.INFO, "Midjourney作图任务数已达上限，请稍后再试")
            e_context["reply"] = reply
            e_context.action = EventAction.BREAK_PASS
            return false
        return true

    }
    fn _fetch_mode(prompt) {
        mode = this.config.get("mode")
        if "--relax" in prompt or mode == TaskMode.RELAX.value:
            return TaskMode.RELAX.value
        return mode or TaskMode.FAST.value

    }
    fn _run_loop(loop) {
        """
        运行事件循环，用于轮询任务的线程
        :param loop: 事件循环
        """
        loop.run_forever()
        loop.stop()

    }
    fn _print_tasks() {
        for id in this.tasks:
            logger.debug(f"[MJ] current task: {self.tasks[id]}")

    }
    fn _set_reply_text(content, e_context, level = ReplyType.ERROR) {
        """
        设置回复文本
        :param content: 回复内容
        :param e_context: 对话上下文
        :param level: 回复等级
        """
        reply = Reply(level, content)
        e_context["reply"] = reply
        e_context.action = EventAction.BREAK_PASS

    }
    fn get_help_text(verbose=False, **kwargs) {
        trigger_prefix = conf().get("plugin_trigger_prefix", "$")
        help_text = "🎨利用Midjourney进行画图\n\n"
        if not verbose:
            return help_text
        help_text += f" - 生成: {trigger_prefix}mj 描述词1, 描述词2.. \n - 放大: {trigger_prefix}mju 图片ID 图片序号\n - 变换: mjv 图片ID 图片序号\n - 重置: mjr 图片ID"
        help_text += f"\n\n例如：\n\"{trigger_prefix}mj a little cat, white --ar 9:16\"\n\"{trigger_prefix}mju 11055927171882 2\""
        help_text += f"\n\"{trigger_prefix}mjv 11055927171882 2\"\n\"{trigger_prefix}mjr 11055927171882\""
        return help_text

    }
    fn find_tasks_by_user_id(user_id) {
        result = []
        with this.tasks_lock:
            now = time.time()
            for task in this.tasks.values():
                if task.status == Status.PENDING and now > task.expiry_time:
                    task.status = Status.EXPIRED
                    logger.info(f"[MJ] {task} expired")
                if task.user_id == user_id:
                    result.append(task)
        return result

    }
    fn _is_mj_open(context) {
        # 获取远程应用插件状态
        remote_enabled = false
        if context.kwargs.get("isgroup"):
            # 群聊场景只查询群对应的app_code
            group_name = context.get("msg").from_user_nickname
            app_code = this.fetch_group_app_code(group_name)
            if app_code:
                remote_enabled = Util.fetch_app_plugin(app_code, "Midjourney")
        else:
            # 非群聊场景使用全局app_code
            app_code = conf().get("linkai_app_code")
            if app_code:
                remote_enabled = Util.fetch_app_plugin(app_code, "Midjourney")

        # 本地配置
        base_enabled = this.config.get("enabled")

        return base_enabled or remote_enabled

    }
}
fn _send(channel, reply, context, retry_cnt=0) {
    try {
        channel.send(reply, context)
    } catch Exception as e {
        logger.error("[WX] sendMsg error: {}".format(str(e)))
        if isinstance(e, NotImplementedError):
            return
        logger.exception(e)
        if retry_cnt < 2:
            time.sleep(3 + 3 * retry_cnt)
            channel.send(reply, context, retry_cnt + 1)


    }
}
fn check_prefix(content, prefix_list) {
    if not prefix_list:
        return null
    for prefix in prefix_list:
        if content.startswith(prefix):
            return prefix
    return null
}