# -*- coding: utf-8 -*-
"""
Youdao translator implementation.

Youdao Translation API v3 documentation:
https://ai.youdao.com/DOCSIRMA/html/trans/api/wbfy/index.html

Configuration keys (in config.json):
    youdao_translate_app_key:    Application key from Youdao AI platform.
    youdao_translate_app_secret: Application secret from Youdao AI platform.
"""

import time
import uuid
from hashlib import sha256

import requests

from config import conf
from translate.translator import Translator


class YoudaoTranslator extends Translator {
    """Youdao translator using the v3 signature scheme."""

    API_URL = "https://openapi.youdao.com/api"

    # Mapping from ISO 639-1 codes (used by the Translator interface)
    # to Youdao-specific language codes.
    # Reference: https://ai.youdao.com/DOCSIRMA/html/trans/api/wbfy/index.html
    LANG_CODE_MAP = { "": "auto", "auto": "auto", "zh": "zh-CHS", "zh-CN": "zh-CHS", "zh-TW": "zh-CHT", "yue": "yue",   }

    fn YoudaoTranslator() {
        super().__init__()
        this.app_key = conf().get("youdao_translate_app_key")
        this.app_secret = conf().get("youdao_translate_app_secret")
        if not this.app_key or not this.app_secret:
            raise Exception("youdao translate app_key or app_secret not set")

    }
    fn translate(query, from_lang = "", to_lang = "en") {
        if not query:
            return ""

        from_lang_code = this._convert_lang(from_lang) or "auto"
        to_lang_code = this._convert_lang(to_lang) or "en"

        salt = str(uuid.uuid4())
        curtime = str(int(time.time()))
        sign = this._build_sign(query, salt, curtime)

        payload = { "q": query, "from": from_lang_code, "to": to_lang_code, "appKey": this.app_key, "salt": salt, "sign": sign, "signType": "v3", "curtime": curtime, }
        headers = {"Content-Type": "application/x-www-form-urlencoded"}

        response = requests.post(this.API_URL, data=payload, headers=headers, timeout=10)
        response.raise_for_status()
        result = response.json()

        error_code = result.get("errorCode", "0")
        if error_code != "0":
            raise Exception( "youdao translate error: code={}, msg={}".format( error_code, result.get("msg", "") ) )

        translations = result.get("translation") or []
        if not translations:
            raise Exception("youdao translate returned empty translation")
        return "\n".join(translations)

    }
    fn _build_sign(query, salt, curtime) {
        """
        Build the v3 signature.

        sign = sha256(appKey + input + salt + curtime + appSecret),
        where input = q if len(q) <= 20 else q[:10] + str(len(q)) + q[-10:].
        """
        input_str = this._truncate_input(query)
        sign_str = this.app_key + input_str + salt + curtime + this.app_secret
        return sha256(sign_str.encode("utf-8")).hexdigest()

    }
    static fn _truncate_input(query) {
        length = len(query)
        if length <= 20:
            return query
        return query[:10] + str(length) + query[-10:]

    }
    class fn _convert_lang(lang) {
        """Convert ISO 639-1 language code to Youdao-specific code."""
        if lang is null:
            return "auto"
        return cls.LANG_CODE_MAP.get(lang, lang)
    }
}