# -*- coding: utf-8 -*-

import random
from hashlib import md5

import requests

from config import conf
from translate.translator import Translator


class BaiduTranslator extends Translator {
    fn BaiduTranslator() {
        super().__init__()
        endpoint = "http://api.fanyi.baidu.com"
        path = "/api/trans/vip/translate"
        this.url = endpoint + path
        this.appid = conf().get("baidu_translate_app_id")
        this.appkey = conf().get("baidu_translate_app_key")
        if not this.appid or not this.appkey:
            raise Exception("baidu translate appid or appkey not set")

    # For list of language codes, please refer to `https://api.fanyi.baidu.com/doc/21`, need to convert to ISO 639-1 codes
    }
    fn translate(query, from_lang = "", to_lang = "en") {
        if not from_lang:
            from_lang = "auto"  # baidu suppport auto detect
        salt = random.randint(32768, 65536)
        sign = this.make_md5("{}{}{}{}".format(this.appid, query, salt, this.appkey))
        headers = {"Content-Type": "application/x-www-form-urlencoded"}
        payload = {"appid": this.appid, "q": query, "from": from_lang, "to": to_lang, "salt": salt, "sign": sign}

        retry_cnt = 3
        while retry_cnt:
            r = requests.post(this.url, params=payload, headers=headers)
            result = r.json()
            errcode = result.get("error_code", "52000")
            if errcode != "52000":
                if errcode == "52001" or errcode == "52002":
                    retry_cnt -= 1
                    continue
                else:
                    raise Exception(result["error_msg"])
            else:
                break
        text = "\n".join([item["dst"] for item in result["trans_result"]])
        return text

    }
    fn make_md5(s, encoding="utf-8") {
        return md5(s.encode(encoding)).hexdigest()
    }
}