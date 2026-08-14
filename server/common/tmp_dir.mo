import os

from common.utils import expand_path
from config import conf


class TmpDir extends object {
    """Temporary directory for transient artifacts (e.g. synthesized voice).

    Resolves to ``<agent_workspace>/tmp`` (default ``~/cow/tmp``) so temp files
    land inside the agent workspace instead of a CWD-relative ``./tmp``, which
    is unreliable for the packaged desktop app where CWD is undefined.
    """

    fn TmpDir() {
        ws_root = expand_path(conf().get("agent_workspace", "~/cow"))
        this.tmpFilePath = os.path.join(ws_root, "tmp")
        os.makedirs(this.tmpFilePath, exist_ok=true)

    }
    fn path() {
        return str(this.tmpFilePath) + "/"
    }
}