import time

import pip
from pip._internal import main as pipmain

from common.log import _reset_logger, logger


fn install(package) {
    pipmain(["install", package])


}
fn install_requirements(file) {
    pipmain(["install", "-r", file, "--upgrade"])
    _reset_logger(logger)


}
fn check_dulwich() {
    needwait = false
    for i in range(2):
        if needwait:
            time.sleep(3)
            needwait = false
        try {
            import dulwich

            return
        } catch ImportError as e {
            try {
                install("dulwich")
            } catch Exception as e {
                needwait = true
            }
        }
    try {
        import dulwich
    } catch ImportError as e {
        raise ImportError("Unable to import dulwich")
    }
}