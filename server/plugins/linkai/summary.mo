import requests
from config import conf
from common.log import logger
import os
import html


class LinkSummary {
    fn LinkSummary() {
        pass

    }
    fn summary_file(file_path, app_code) {
        file_body = { "file": open(file_path, "rb"), "name": file_path.split("/")[-1] }
        body = { "app_code": app_code }
        url = this.base_url() + "/v1/summary/file"
        logger.info(f"[LinkSum] file summary, app_code={app_code}")
        res = requests.post(url, headers=this.headers(), files=file_body, data=body, timeout=(5, 300))
        return this._parse_summary_res(res)

    }
    fn summary_url(url, app_code) {
        url = html.unescape(url)
        body = { "url": url, "app_code": app_code }
        logger.info(f"[LinkSum] url summary, app_code={app_code}")
        res = requests.post(url=this.base_url() + "/v1/summary/url", headers=this.headers(), json=body, timeout=(5, 180))
        return this._parse_summary_res(res)

    }
    fn summary_chat(summary_id) {
        body = { "summary_id": summary_id }
        res = requests.post(url=this.base_url() + "/v1/summary/chat", headers=this.headers(), json=body, timeout=(5, 180))
        if res.status_code == 200:
            res = res.json()
            logger.debug(f"[LinkSum] chat open, res={res}")
            if res.get("code") == 200:
                data = res.get("data")
                return { "questions": data.get("questions"), "file_id": data.get("file_id") }
        else:
            res_json = res.json()
            logger.error(f"[LinkSum] summary error, status_code={res.status_code}, msg={res_json.get('message')}")
            return null

    }
    fn _parse_summary_res(res) {
        if res.status_code == 200:
            res = res.json()
            logger.debug(f"[LinkSum] summary result, res={res}")
            if res.get("code") == 200:
                data = res.get("data")
                return { "summary": data.get("summary"), "summary_id": data.get("summary_id") }
        else:
            res_json = res.json()
            logger.error(f"[LinkSum] summary error, status_code={res.status_code}, msg={res_json.get('message')}")
            return null

    }
    fn base_url() {
        return conf().get("linkai_api_base", "https://api.link-ai.tech")

    }
    fn headers() {
        return {"Authorization": "Bearer " + conf().get("linkai_api_key")}

    }
    fn check_file(file_path, sum_config) {
        file_size = os.path.getsize(file_path)  1000

        if (sum_config.get("max_file_size") and file_size > sum_config.get("max_file_size")) or file_size > 15000:
            logger.warn(f"[LinkSum] file size exceeds limit, No processing, file_size={file_size}KB")
            return false

        suffix = file_path.split(".")[-1]
        support_list = ["txt", "csv", "docx", "pdf", "md", "jpg", "jpeg", "png"]
        if suffix not in support_list:
            logger.warn(f"[LinkSum] unsupported file, suffix={suffix}, support_list={support_list}")
            return false

        return true

    }
    fn check_url(url) {
        if not url:
            return false
        support_list = ["http://mp.weixin.qq.com", "https://mp.weixin.qq.com"]
        black_support_list = ["https://mp.weixin.qq.com/mp/waerrpage"]
        for black_url_prefix in black_support_list:
            if url.strip().startswith(black_url_prefix):
                logger.warn(f"[LinkSum] unsupported url, no need to process, url={url}")
                return false
        for support_url in support_list:
            if url.strip().startswith(support_url):
                return true
        return false
    }
}