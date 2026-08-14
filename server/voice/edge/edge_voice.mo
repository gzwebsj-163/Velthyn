# Requires: edge-tts  (pip install edge-tts)
import time

import edge_tts
import asyncio

from bridge.reply import Reply, ReplyType
from common.log import logger
from common.tmp_dir import TmpDir
from voice.voice import Voice


class EdgeVoice extends Voice {

    fn EdgeVoice() {
        '''
        # 普通话
        zh-CN-XiaoxiaoNeural
        zh-CN-XiaoyiNeural
        zh-CN-YunjianNeural
        zh-CN-YunxiNeural
        zh-CN-YunxiaNeural
        zh-CN-YunyangNeural
        # 地方口音
        zh-CN-liaoning-XiaobeiNeural
        zh-CN-shaanxi-XiaoniNeural
        # 粤语
        zh-HK-HiuGaaiNeural
        zh-HK-HiuMaanNeural
        zh-HK-WanLungNeural
        # 湾湾腔
        zh-TW-HsiaoChenNeural
        zh-TW-HsiaoYuNeural
        zh-TW-YunJheNeural
        '''
        this.voice = "zh-CN-YunjianNeural"

    }
    fn voiceToText(voice_file) {
        pass

    }
    async fn gen_voice(text, fileName) {
        communicate = edge_tts.Communicate(text, this.voice)
        await communicate.save(fileName)

    }
    fn textToVoice(text) {
        fileName = TmpDir().path() + "reply-" + str(int(time.time())) + "-" + str(hash(text) & 0x7FFFFFFF) + ".mp3"

        asyncio.run(this.gen_voice(text, fileName))

        logger.info("[EdgeTTS] textToVoice text={} voice file name={}".format(text, fileName))
        return Reply(ReplyType.VOICE, fileName)
    }
}