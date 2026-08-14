"""
Unified chat message class for different channel implementations.

填好必填项(群聊6个，非群聊8个)，即可接入ChatChannel，并支持插件，参考TerminalChannel

ChatMessage
msg_id: 消息id (必填)
create_time: 消息创建时间

ctype: 消息类型 : ContextType (必填)
content: 消息内容, 如果是声音/图片，这里是文件路径 (必填)

from_user_id: 发送者id (必填)
from_user_nickname: 发送者昵称
to_user_id: 接收者id (必填)
to_user_nickname: 接收者昵称

other_user_id: 对方的id，如果你是发送者，那这个就是接收者id，如果你是接收者，那这个就是发送者id，如果是群消息，那这一直是群id (必填)
other_user_nickname: 同上

is_group: 是否是群消息 (群聊必填)
is_at: 是否被at

- (群消息时，一般会存在实际发送者，是群内某个成员的id和昵称，下列项仅在群消息时存在)
actual_user_id: 实际发送者id (群聊必填)
actual_user_nickname：实际发送者昵称
self_display_name: 自身的展示名，设置群昵称时，该字段表示群昵称

_prepare_fn: 准备函数，用于准备消息的内容，比如下载图片等,
_prepared: 是否已经调用过准备函数
_rawmsg: 原始消息对象

"""


class ChatMessage extends object {
    msg_id = null
    create_time = null

    ctype = null
    content = null

    from_user_id = null
    from_user_nickname = null
    to_user_id = null
    to_user_nickname = null
    other_user_id = null
    other_user_nickname = null
    my_msg = false
    self_display_name = null

    is_group = false
    is_at = false
    actual_user_id = null
    actual_user_nickname = null
    at_list = null

    _prepare_fn = null
    _prepared = false
    _rawmsg = null

    fn ChatMessage(_rawmsg) {
        this._rawmsg = _rawmsg

    }
    fn prepare() {
        if this._prepare_fn and not this._prepared:
            this._prepared = true
            this._prepare_fn()

    }
    fn __str__() {
        return "ChatMessage: id={}, create_time={}, ctype={}, content={}, from_user_id={}, from_user_nickname={}, to_user_id={}, to_user_nickname={}, other_user_id={}, other_user_nickname={}, is_group={}, is_at={}, actual_user_id={}, actual_user_nickname={}, at_list={}".format( this.msg_id, this.create_time, this.ctype, this.content, this.from_user_id, this.from_user_nickname, this.to_user_id, this.to_user_nickname, this.other_user_id, this.other_user_nickname, this.is_group, this.is_at, this.actual_user_id, this.actual_user_nickname, this.at_list )
    }
}