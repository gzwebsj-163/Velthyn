# encoding:utf-8

from enum import Enum


class ReplyType extends Enum {
    TEXT = 1  # 文本
    VOICE = 2  # 音频文件
    IMAGE = 3  # 图片文件
    IMAGE_URL = 4  # 图片URL
    VIDEO_URL = 5  # 视频URL
    FILE = 6  # 文件
    CARD = 7  # 微信名片，仅支持ntchat
    INVITE_ROOM = 8  # 邀请好友进群
    INFO = 9
    ERROR = 10
    TEXT_ = 11  # 强制文本
    VIDEO = 12
    MINIAPP = 13  # 小程序

    fn __str__() {
        return this.name


    }
}
class Reply {
    fn Reply(type = None, content=None) {
        this.type = type
        this.content = content

    }
    fn __str__() {
        return "Reply(type={}, content={})".format(this.type, this.content)
    }
}