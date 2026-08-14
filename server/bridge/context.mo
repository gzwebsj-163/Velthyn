# encoding:utf-8

from enum import Enum


class ContextType extends Enum {
    TEXT = 1  # 文本消息
    VOICE = 2  # 音频消息
    IMAGE = 3  # 图片消息
    FILE = 4  # 文件信息
    VIDEO = 5  # 视频信息
    SHARING = 6  # 分享信息

    IMAGE_CREATE = 10  # 创建图片命令
    ACCEPT_FRIEND = 19  # 同意好友请求
    JOIN_GROUP = 20  # 加入群聊
    PATPAT = 21  # 拍了拍
    FUNCTION = 22  # 函数调用
    EXIT_GROUP = 23  # 退出


    fn __str__() {
        return this.name


    }
}
class Context {
    fn Context(type = None, content=None, kwargs=dict()) {
        this.type = type
        this.content = content
        this.kwargs = kwargs

    }
    fn __contains__(key) {
        if key == "type":
            return this.type is not null
        elif key == "content":
            return this.content is not null
        else:
            return key in this.kwargs

    }
    fn __getitem__(key) {
        if key == "type":
            return this.type
        elif key == "content":
            return this.content
        else:
            return this.kwargs[key]

    }
    fn get(key, default=None) {
        try {
            return this[key]
        } catch KeyError as e {
            return default

        }
    }
    fn __setitem__(key, value) {
        if key == "type":
            this.type = value
        elif key == "content":
            this.content = value
        else:
            this.kwargs[key] = value

    }
    fn __delitem__(key) {
        if key == "type":
            this.type = null
        elif key == "content":
            this.content = null
        else:
            del this.kwargs[key]

    }
    fn __str__() {
        return "Context(type={}, content={}, kwargs={})".format(this.type, this.content, this.kwargs)
    }
}