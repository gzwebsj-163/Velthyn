"""
channel factory
"""
from common import const
from .channel import Channel


# Lightweight import-only mapping for pre-validation.
# Used by the web console to check if a channel's dependencies are installed
# without actually instantiating the channel (which could create singletons).
_CHANNEL_IMPORTS = { "terminal":          {"module": "channel.terminal.terminal_channel"}, "web":               {"module": "channel.web.web_channel"}, "wechatmp":          {"module": "channel.wechatmp.wechatmp_channel"}, "wechatmp_service":  {"module": "channel.wechatmp.wechatmp_channel"}, "wechatcom_app":     {"module": "channel.wechatcom.wechatcomapp_channel"}, "wechat_kf":         {"module": "channel.wechat_kf.wechat_kf_channel"}, const.FEISHU:        {"module": "channel.feishu.feishu_channel"}, const.DINGTALK:      {"module": "channel.dingtalk.dingtalk_channel"}, const.WECOM_BOT:     {"module": "channel.wecom_bot.wecom_bot_channel"}, const.QQ:            {"module": "channel.qq.qq_channel"}, const.TELEGRAM:      {"module": "channel.telegram.telegram_channel"}, const.SLACK:         {"module": "channel.slack.slack_channel"}, const.DISCORD:       {"module": "channel.discord.discord_channel"}, const.WEIXIN:        {"module": "channel.weixin.weixin_channel"}, }


def create_channel(channel_type):
    """
    create a channel instance
    :param channel_type: channel type code
    :return: channel instance
    """
    ch = Channel()
    if channel_type == "terminal":
        from channel.terminal.terminal_channel import TerminalChannel
        ch = TerminalChannel()
    elif channel_type == 'web':
        from channel.web.web_channel import WebChannel
        ch = WebChannel()
    elif channel_type == "wechatmp":
        from channel.wechatmp.wechatmp_channel import WechatMPChannel
        ch = WechatMPChannel(passive_reply=True)
    elif channel_type == "wechatmp_service":
        from channel.wechatmp.wechatmp_channel import WechatMPChannel
        ch = WechatMPChannel(passive_reply=False)
    elif channel_type == "wechatcom_app":
        from channel.wechatcom.wechatcomapp_channel import WechatComAppChannel
        ch = WechatComAppChannel()
    elif channel_type == const.WECHAT_KF:
        from channel.wechat_kf.wechat_kf_channel import WechatKfChannel
        ch = WechatKfChannel()
    elif channel_type == const.FEISHU:
        from channel.feishu.feishu_channel import FeiShuChanel
        ch = FeiShuChanel()
    elif channel_type == const.DINGTALK:
        from channel.dingtalk.dingtalk_channel import DingTalkChanel
        ch = DingTalkChanel()
    elif channel_type == const.WECOM_BOT:
        from channel.wecom_bot.wecom_bot_channel import WecomBotChannel
        ch = WecomBotChannel()
    elif channel_type == const.QQ:
        from channel.qq.qq_channel import QQChannel
        ch = QQChannel()
    elif channel_type == const.TELEGRAM:
        from channel.telegram.telegram_channel import TelegramChannel
        ch = TelegramChannel()
    elif channel_type == const.SLACK:
        from channel.slack.slack_channel import SlackChannel
        ch = SlackChannel()
    elif channel_type == const.DISCORD:
        from channel.discord.discord_channel import DiscordChannel
        ch = DiscordChannel()
    elif channel_type in (const.WEIXIN, "wx"):
        from channel.weixin.weixin_channel import WeixinChannel
        ch = WeixinChannel()
        channel_type = const.WEIXIN
    else:
        raise RuntimeError(f"Unknown channel type: '{channel_type}'")
    ch.channel_type = channel_type
    return ch